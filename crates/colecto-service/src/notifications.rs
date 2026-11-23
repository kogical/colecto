//! Desktop notifications for new mail while no Colecto window is open. The daemon runs this
//! against its own socket, or, in relay mode, against a remote daemon that does the syncing.
use std::path::Path;
use std::time::Duration;

/// Errors of the relay, which runs as a Tokio task and so must be `Send`.
type AgentError = Box<dyn std::error::Error + Send + Sync>;

pub fn read_token(path: &Path) -> Result<String, Box<dyn std::error::Error>> {
    let metadata = std::fs::symlink_metadata(path)?;
    if !metadata.is_file() {
        return Err("Token path must be a regular file, not a symlink".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        if metadata.uid() != rustix::process::geteuid().as_raw() {
            return Err("Token file must be owned by the current OS user".into());
        }
        if metadata.permissions().mode() & 0o077 != 0 {
            return Err("Token file must be readable only by its owner (chmod 600)".into());
        }
    }
    let token = std::fs::read_to_string(path)?.trim().to_owned();
    Ok(token)
}

fn connection(origin: &str) -> Result<(reqwest::Url, reqwest::Client), AgentError> {
    let socket = origin.strip_prefix("unix:");
    if socket.is_some_and(|p| !Path::new(p).is_absolute()) {
        return Err("Socket path must be absolute".into());
    }
    let url = reqwest::Url::parse(if socket.is_some() {
        "http://localhost"
    } else {
        origin
    })?;
    if socket.is_none()
        && (url.scheme() != "https"
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.path() != "/"
            || url.query().is_some()
            || url.fragment().is_some())
    {
        return Err("Notification agent requires an HTTPS server origin".into());
    }
    let builder = reqwest::Client::builder();
    #[cfg(unix)]
    let builder = if let Some(socket) = socket {
        builder.unix_socket(socket)
    } else {
        builder
    };
    #[cfg(not(unix))]
    if socket.is_some() {
        return Err("Unix sockets unavailable".into());
    }
    let client = builder
        .connect_timeout(Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .build()?;
    Ok((url, client))
}

pub async fn run_agent(origin: &str, token_file: &Path) -> Result<(), AgentError> {
    let (url, client) = connection(origin)?;
    let mut backoff = 1;
    loop {
        let result: Result<(), AgentError> = async {
            let token =
                zeroize::Zeroizing::new(read_token(token_file).map_err(|error| error.to_string())?);
            let mut response = client
                .get(url.join("api/v1/events")?)
                .bearer_auth(token.as_str())
                .header("x-colecto-account", "demo")
                .send()
                .await?
                .error_for_status()?;
            backoff = 1;
            let mut events = Events::default();
            while let Some(chunk) = response.chunk().await? {
                for _ in 0..events.feed(&chunk)? {
                    if !mail_enabled(&client, &url, &token).await {
                        continue;
                    }
                    if let Err(error) =
                        show("New mail", "Open Colecto to read your messages.").await
                    {
                        tracing::warn!(%error, "Desktop notification failed");
                    }
                }
            }
            Ok(())
        }
        .await;
        if let Err(error) = result {
            tracing::warn!(%error, retry_seconds = backoff, "Notification connection unavailable");
        }
        tokio::time::sleep(Duration::from_secs(backoff)).await;
        backoff = (backoff * 2).min(60);
    }
}

/// Notifications enabled preference; on when it cannot be read.
async fn mail_enabled(client: &reqwest::Client, url: &reqwest::Url, token: &str) -> bool {
    let preferences: Result<serde_json::Value, AgentError> = async {
        Ok(client
            .get(url.join("api/v1/preferences")?)
            .bearer_auth(token)
            .header("x-colecto-account", "demo")
            .timeout(Duration::from_secs(10))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?)
    }
    .await;
    preferences.map_or(true, |prefs| prefs["notifications"]["enabled"] != false)
}

/// Post a notification over the freedesktop D-Bus interface, which every Linux desktop
/// implements, rather than through `notify-send`, which not every distribution installs.
#[cfg(target_os = "linux")]
async fn show(summary: &str, body: &str) -> Result<(), AgentError> {
    use dbus::arg::{PropMap, Variant};
    let (resource, connection) = dbus_tokio::connection::new_session_sync()?;
    // The resource drives the connection; it only returns when the connection is lost.
    let driver = tokio::spawn(resource);
    let proxy = dbus::nonblock::Proxy::new(
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        Duration::from_secs(5),
        connection,
    );
    let mut hints = PropMap::new();
    hints.insert(
        "desktop-entry".into(),
        Variant(Box::new("colecto".to_owned())),
    );
    let actions: Vec<String> = Vec::new();
    let result: Result<(u32,), dbus::Error> = proxy
        .method_call(
            "org.freedesktop.Notifications",
            "Notify",
            (
                "Colecto", 0u32, "colecto", summary, body, actions, hints, -1i32,
            ),
        )
        .await;
    driver.abort();
    result?;
    Ok(())
}

#[cfg(not(target_os = "linux"))]
async fn show(_: &str, _: &str) -> Result<(), AgentError> {
    Err("Background desktop notifications are available only on Linux".into())
}

/// Reads the server-sent event stream incrementally and counts mail events with new
/// messages, unless a Colecto window was open when it was sent: that window shows its own
/// notification.
#[derive(Default)]
struct Events {
    pending: Vec<u8>,
    event: String,
    data: String,
}
impl Events {
    /// Feed the next bytes of the stream; returns how many notifications to show.
    fn feed(&mut self, bytes: &[u8]) -> Result<usize, std::io::Error> {
        self.pending.extend_from_slice(bytes);
        let mut notify = 0;
        while let Some(end) = self.pending.iter().position(|byte| *byte == b'\n') {
            let line: Vec<u8> = self.pending.drain(..=end).collect();
            if line.len() > 65536 {
                return Err(std::io::Error::other(
                    "Notification event line exceeds limit",
                ));
            }
            let line = std::str::from_utf8(&line)
                .map_err(std::io::Error::other)?
                .trim_end_matches(['\r', '\n']);
            if line.is_empty() {
                if self.event == "mail"
                    && serde_json::from_str::<serde_json::Value>(&self.data)
                        .ok()
                        .is_some_and(|v| {
                            v["ids"].as_array().is_some_and(|a| !a.is_empty())
                                && v["windows"].as_u64().unwrap_or(0) == 0
                        })
                {
                    notify += 1;
                }
                self.event.clear();
                self.data.clear();
            } else if let Some(value) = line.strip_prefix("event:") {
                self.event = value.trim_start().into();
            } else if let Some(value) = line.strip_prefix("data:") {
                if self.data.len() + value.len() > 65536 {
                    return Err(std::io::Error::other("Notification event exceeds limit"));
                }
                if !self.data.is_empty() {
                    self.data.push('\n');
                }
                self.data.push_str(value.trim_start());
            }
        }
        if self.pending.len() > 65536 {
            return Err(std::io::Error::other(
                "Notification event line exceeds limit",
            ));
        }
        Ok(notify)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn notifications_ignore_initial_snapshot_and_empty_or_malformed_events() {
        let input = b"event: ready\ndata: {}\n\nevent: mail\ndata: {\"ids\":[]}\n\nevent: mail\ndata: invalid\n\nevent: mail\ndata: {\"account\":\"a\",\"ids\":[\"new\"]}\n\nevent: mail\ndata: {\"account\":\"a\",\"ids\":[\"open\"],\"windows\":1}\n\n";
        let mut events = Events::default();
        // Split mid-line, as the network does.
        let (first, second) = input.split_at(40);
        let count = events.feed(first).unwrap() + events.feed(second).unwrap();
        assert_eq!(count, 1, "a window that is open shows its own notification");
    }

    #[test]
    fn oversized_events_are_bounded() {
        assert!(Events::default().feed(&vec![b'x'; 65538]).is_err());
    }
}

#[cfg(all(test, unix))]
mod socket_tests {
    use super::*;

    #[tokio::test]
    async fn notifier_connects_over_unix_socket_with_localhost_authority() {
        use std::{
            io::{BufRead, BufReader, Write},
            os::unix::net::UnixListener,
        };
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("mail.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut request = String::new();
            let mut reader = BufReader::new(&mut stream);
            loop {
                let mut line = String::new();
                assert!(reader.read_line(&mut line).unwrap() > 0);
                if line == "\r\n" {
                    break;
                }
                request.push_str(&line);
            }
            assert!(request.starts_with("GET /api/v1/events HTTP/1.1"));
            assert!(request.to_ascii_lowercase().contains("host: localhost"));
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
                .unwrap();
        });
        let (url, client) = connection(&format!("unix:{}", socket.display())).unwrap();
        assert_eq!(
            client
                .get(url.join("api/v1/events").unwrap())
                .send()
                .await
                .unwrap()
                .text()
                .await
                .unwrap(),
            "ok"
        );
        server.join().unwrap();
        assert!(connection("unix:relative.sock").is_err());
        assert!(connection("http://example.com").is_err());
    }
}
