//! Async IMAP plumbing: a small dedicated Tokio runtime, an inactivity timeout for sockets,
//! and a per-account pool of logged-in sessions so most operations skip connect, TLS and LOGIN.
use std::{
    collections::HashMap,
    future::Future,
    hash::{BuildHasher, Hash},
    io,
    pin::Pin,
    sync::{Mutex, OnceLock},
    task::{Context, Poll},
    time::{Duration, Instant},
};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

/// Any byte stream an IMAP session can run over (TLS in production, plain TCP in tests).
pub(crate) trait Io: AsyncRead + AsyncWrite + Unpin + Send + std::fmt::Debug {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send + std::fmt::Debug> Io for T {}

pub(crate) type Session = async_imap::Session<Box<dyn Io>>;

/// IMAP work runs on its own runtime, so callers on any thread (Tokio blocking threads, FFI
/// threads, plain test threads) can wait for it without needing a runtime of their own.
fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("colecto-imap")
            .enable_all()
            .build()
            .expect("the IMAP runtime starts")
    })
}

/// Run an IMAP future to completion from synchronous code. Must not be called from inside an
/// async task; every caller reaches IMAP through a blocking thread.
pub(crate) fn block_on<F: Future>(future: F) -> F::Output {
    runtime().block_on(future)
}

/// Fails a read or write that makes no progress for `limit`, like a socket timeout. Long
/// transfers stay alive as long as bytes keep moving.
#[derive(Debug)]
pub(crate) struct Deadline<S> {
    inner: S,
    limit: Duration,
    read: Option<Pin<Box<tokio::time::Sleep>>>,
    write: Option<Pin<Box<tokio::time::Sleep>>>,
}

impl<S> Deadline<S> {
    pub(crate) fn new(inner: S, limit: Duration) -> Self {
        Self {
            inner,
            limit,
            read: None,
            write: None,
        }
    }
}

fn expired(
    timer: &mut Option<Pin<Box<tokio::time::Sleep>>>,
    limit: Duration,
    cx: &mut Context<'_>,
) -> bool {
    let sleep = timer.get_or_insert_with(|| Box::pin(tokio::time::sleep(limit)));
    if sleep.as_mut().poll(cx).is_ready() {
        *timer = None;
        return true;
    }
    false
}

fn timed_out() -> io::Error {
    io::Error::new(io::ErrorKind::TimedOut, "mail server timed out")
}

impl<S: AsyncRead + Unpin> AsyncRead for Deadline<S> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        match Pin::new(&mut this.inner).poll_read(cx, buf) {
            Poll::Ready(result) => {
                this.read = None;
                Poll::Ready(result)
            }
            Poll::Pending if expired(&mut this.read, this.limit, cx) => {
                Poll::Ready(Err(timed_out()))
            }
            Poll::Pending => Poll::Pending,
        }
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for Deadline<S> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        let this = self.get_mut();
        match Pin::new(&mut this.inner).poll_write(cx, buf) {
            Poll::Ready(result) => {
                this.write = None;
                Poll::Ready(result)
            }
            Poll::Pending if expired(&mut this.write, this.limit, cx) => {
                Poll::Ready(Err(timed_out()))
            }
            Poll::Pending => Poll::Pending,
        }
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        match Pin::new(&mut this.inner).poll_flush(cx) {
            Poll::Ready(result) => {
                this.write = None;
                Poll::Ready(result)
            }
            Poll::Pending if expired(&mut this.write, this.limit, cx) => {
                Poll::Ready(Err(timed_out()))
            }
            Poll::Pending => Poll::Pending,
        }
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_shutdown(cx)
    }
}

/// Idle sessions kept per account. Several let a message open while a refresh or
/// prefetch is still downloading; providers allow far more (Gmail: 15).
const MAX_IDLE_SESSIONS: usize = 3;
/// Older idle sessions are dropped rather than reused; servers close quiet ones (RFC 3501
/// §5.4 requires at least 30 minutes) and NAT routers often sooner.
const MAX_IDLE: Duration = Duration::from_secs(10 * 60);
/// A session idle for longer than this is checked with NOOP before it is reused.
const VERIFY_AFTER: Duration = Duration::from_secs(30);

struct Idle {
    session: Session,
    since: Instant,
}

/// Idle sessions, keyed by a hash of everything that identifies the login (host, port,
/// user, password, TLS settings), so changed credentials never reuse an old session.
fn pool() -> &'static Mutex<HashMap<u64, Vec<Idle>>> {
    static POOL: OnceLock<Mutex<HashMap<u64, Vec<Idle>>>> = OnceLock::new();
    POOL.get_or_init(Mutex::default)
}

pub(crate) fn pool_key(parts: impl Hash) -> u64 {
    static STATE: OnceLock<std::collections::hash_map::RandomState> = OnceLock::new();
    STATE.get_or_init(Default::default).hash_one(parts)
}

/// A pooled session for `key`, if one is still usable.
pub(crate) async fn checkout(key: u64) -> Option<Session> {
    loop {
        let idle = pool().lock().ok()?.get_mut(&key)?.pop()?;
        let Idle { mut session, since } = idle;
        if since.elapsed() > MAX_IDLE {
            continue;
        }
        // Updates the server sent while the session sat idle are stale by now.
        while session.unsolicited_responses.try_recv().is_ok() {}
        if since.elapsed() < VERIFY_AFTER || session.noop().await.is_ok() {
            return Some(session);
        }
    }
}

/// Return a healthy session for reuse.
pub(crate) fn checkin(key: u64, session: Session) {
    if let Ok(mut pool) = pool().lock() {
        let idle = pool.entry(key).or_default();
        idle.retain(|entry| entry.since.elapsed() <= MAX_IDLE);
        if idle.len() < MAX_IDLE_SESSIONS {
            idle.push(Idle {
                session,
                since: Instant::now(),
            });
        }
    }
}

#[cfg(test)]
pub(crate) fn idle_count(key: u64) -> usize {
    pool()
        .lock()
        .map(|pool| pool.get(&key).map_or(0, Vec::len))
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    /// The service reaches IMAP from Tokio blocking threads, where waiting is allowed.
    #[test]
    fn waits_from_another_runtimes_blocking_threads() {
        let outer = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .build()
            .unwrap();
        let value = outer.block_on(async {
            tokio::task::spawn_blocking(|| super::block_on(async { 7 }))
                .await
                .unwrap()
        });
        assert_eq!(value, 7);
    }
}
