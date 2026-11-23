//! The Tokio runtime every network transport (IMAP, SMTP, JMAP) runs on.
//!
//! `MailStore` and `MailReader` are synchronous and run on blocking threads, because Turso's
//! local I/O blocks the thread that polls it. Network work is truly async: it runs on this
//! runtime, so connections, pools and timers live in one place.
use std::{future::Future, sync::OnceLock};

fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("colecto-net")
            .enable_all()
            .build()
            .expect("the network runtime starts")
    })
}

/// Run a network future to completion from synchronous code. Must not be called from inside
/// an async task; every caller reaches the network through a blocking thread.
pub(crate) fn block_on<F: Future>(future: F) -> F::Output {
    runtime().block_on(future)
}

#[cfg(test)]
mod tests {
    /// The service reaches the network from Tokio blocking threads, where waiting is allowed.
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
