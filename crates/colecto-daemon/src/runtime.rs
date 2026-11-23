//! Foreground runtime for `colecto-daemon` (standalone daemon and notification relay).
use crate::{AccessPolicy, Assets, Daemon};
use colecto_service::{MailService, notifications, secrets};
use std::{
    env,
    path::{Path, PathBuf},
    time::Duration,
};

const USAGE: &str = "Usage:
  colecto-daemon                    Serve mail (configured with COLECTO_* variables)
  colecto-daemon export <file.zip>  Back up accounts, drafts, labels and settings
  colecto-daemon import <file.zip>  Replace this daemon's data with a backup

Stop the daemon before export or import; both use COLECTO_DATA_DIR.
COLECTO_BACKUP_PASSPHRASE seals a new backup (and includes saved passwords), or opens a
sealed one. COLECTO_MASTER_PASSWORD unlocks credentials protected by a master password.";

fn data_directory() -> PathBuf {
    env::var_os("COLECTO_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(".colecto"))
}

/// `export` or `import` a backup in the same format as the app and the HTTP API.
fn backup(command: &str, file: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let mut accounts = secrets::open_accounts(&data_directory())?;
    if accounts.security().locked
        && let Ok(password) = env::var("COLECTO_MASTER_PASSWORD")
    {
        accounts.unlock(&password)?;
    }
    let passphrase = env::var("COLECTO_BACKUP_PASSPHRASE")
        .ok()
        .filter(|p| !p.is_empty());
    if command == "export" {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        let bytes =
            accounts.export_backup(passphrase.as_deref(), env!("CARGO_PKG_VERSION"), now)?;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        std::io::Write::write_all(&mut options.open(file)?, &bytes)?;
        println!(
            "Backed up to {}{}",
            file.display(),
            if passphrase.is_some() {
                ", sealed with your passphrase and including saved passwords"
            } else {
                ". Saved passwords are not included without COLECTO_BACKUP_PASSPHRASE"
            }
        );
    } else {
        accounts.import_backup(&std::fs::read(file)?, passphrase.as_deref())?;
        println!("Restored {}", file.display());
    }
    Ok(())
}

pub async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        None => {}
        Some(command @ ("export" | "import")) => {
            let file = args
                .next()
                .ok_or_else(|| format!("Usage: colecto-daemon {command} <backup.zip>"))?;
            let command = command.to_owned();
            return tokio::task::spawn_blocking(move || {
                backup(&command, Path::new(&file)).map_err(|e| e.to_string())
            })
            .await?
            .map_err(Into::into);
        }
        Some("help" | "--help" | "-h") => {
            println!("{USAGE}");
            return Ok(());
        }
        Some(other) => return Err(format!("Unknown command `{other}`.\n\n{USAGE}").into()),
    }
    // Relay mode: a remote daemon syncs the mail, and this one only shows its notifications.
    if let Ok(origin) = env::var("COLECTO_RELAY_ORIGIN") {
        let token_file = PathBuf::from(
            env::var_os("COLECTO_TOKEN_FILE").ok_or("Relay mode requires COLECTO_TOKEN_FILE")?,
        );
        tracing::info!(%origin, "Relaying desktop notifications from a remote Colecto");
        return notifications::run_agent(&origin, &token_file)
            .await
            .map_err(|error| error as Box<dyn std::error::Error>);
    }
    let directory = data_directory();
    let assets = match env::var_os("COLECTO_ASSETS") {
        Some(path) => Assets::Directory(PathBuf::from(path)),
        None => Assets::None,
    };
    let interval = env::var("COLECTO_SYNC_SECONDS")
        .unwrap_or_else(|_| "60".into())
        .parse::<u64>()?;
    if interval < 10 {
        return Err("COLECTO_SYNC_SECONDS must be at least 10".into());
    }
    let bind = env::var("COLECTO_BIND")
        .unwrap_or_else(|_| "127.0.0.1".into())
        .parse::<std::net::IpAddr>()?;
    let port = env::var("COLECTO_PORT")
        .unwrap_or_else(|_| "4173".into())
        .parse::<u16>()?;
    let socket = env::var_os("COLECTO_SOCKET").map(PathBuf::from);
    let remote = env::var("COLECTO_PUBLIC_ORIGIN").ok();
    let token_file = env::var_os("COLECTO_TOKEN_FILE").map(PathBuf::from);
    if !bind.is_loopback() && remote.is_none() {
        return Err(
            "Non-loopback listeners require COLECTO_PUBLIC_ORIGIN and COLECTO_TOKEN_FILE".into(),
        );
    }
    if socket.is_some() && remote.is_some() {
        return Err("Use a local Unix socket or remote HTTPS origin, not both".into());
    }
    let listener = if socket.is_none() {
        Some(tokio::net::TcpListener::bind((bind, port)).await?)
    } else {
        None
    };
    let authority = listener
        .as_ref()
        .map(|l| l.local_addr().map(|a| a.to_string()))
        .transpose()?
        .unwrap_or_else(|| "localhost".into());
    let (policy, ephemeral) = match remote {
        Some(origin) => {
            let path = token_file
                .as_ref()
                .ok_or("Remote mode requires COLECTO_TOKEN_FILE")?;
            (
                AccessPolicy::remote(&origin, notifications::read_token(path)?)?,
                false,
            )
        }
        None => match token_file.as_ref() {
            Some(path) => (
                AccessPolicy::local(authority.clone(), notifications::read_token(path)?)?,
                false,
            ),
            None => (AccessPolicy::local_ephemeral(authority.clone())?, true),
        },
    };
    let accounts = secrets::open_accounts(&directory)?;
    let service = MailService::new(accounts)?;
    let daemon = Daemon::new(service.clone(), policy.clone(), assets)?;
    let (stop, stopped) = tokio::sync::watch::channel(false);
    let worker = tokio::spawn(
        service
            .clone()
            .run_background(Duration::from_secs(interval), stopped),
    );
    let shutdown = async move {
        shutdown_signal().await;
        let _ = stop.send(true);
    };
    if let Some(listener) = listener {
        println!("Colecto: http://{authority}");
        println!("Data directory: {}", directory.display());
        if ephemeral {
            println!("Access token (ephemeral): {}", policy.token());
        }
        axum::serve(listener, daemon.router())
            .with_graceful_shutdown(shutdown)
            .await?;
    } else {
        #[cfg(unix)]
        {
            let socket = OwnedSocket::bind(socket.as_ref().unwrap())?;
            println!(
                "Colecto HTTP socket: {} (Host: localhost)",
                socket.path.display()
            );
            if ephemeral {
                println!("Access token (ephemeral): {}", policy.token());
            }
            if let Some(token_path) = token_file.as_deref() {
                desktop_notifications(&socket.path, token_path);
            }
            axum::serve(socket.listener()?, daemon.router())
                .with_graceful_shutdown(shutdown)
                .await?;
        }
        #[cfg(not(unix))]
        {
            return Err("Unix sockets are unavailable on this platform".into());
        }
    }
    worker.await?;
    tracing::info!("Colecto daemon stopped");
    Ok(())
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .expect("install SIGTERM handler");
        tokio::select! { _ = tokio::signal::ctrl_c() => {}, _ = terminate.recv() => {} }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}

#[cfg(unix)]
pub struct OwnedSocket {
    path: PathBuf,
    listener: std::os::unix::net::UnixListener,
    identity: (u64, u64),
}

#[cfg(unix)]
impl OwnedSocket {
    pub fn bind(path: &Path) -> Result<Self, Box<dyn std::error::Error>> {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let parent = path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .ok_or("Socket requires an explicit private parent directory")?;
        let metadata = std::fs::metadata(parent)?;
        if !metadata.is_dir() || metadata.permissions().mode() & 0o077 != 0 {
            return Err("Socket directory must be private (chmod 700)".into());
        }
        let listener = std::os::unix::net::UnixListener::bind(path)?;
        let metadata = std::fs::symlink_metadata(path)?;
        let socket = Self {
            path: path.into(),
            listener,
            identity: (metadata.dev(), metadata.ino()),
        };
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        socket.listener.set_nonblocking(true)?;
        Ok(socket)
    }

    pub fn listener(&self) -> Result<tokio::net::UnixListener, std::io::Error> {
        tokio::net::UnixListener::from_std(self.listener.try_clone()?)
    }
}

#[cfg(unix)]
impl Drop for OwnedSocket {
    fn drop(&mut self) {
        use std::os::unix::fs::MetadataExt;
        if std::fs::symlink_metadata(&self.path).is_ok_and(|m| (m.dev(), m.ino()) == self.identity)
        {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

#[cfg(unix)]
fn desktop_notifications(socket: &Path, token_file: &Path) {
    let session = env::var_os("DBUS_SESSION_BUS_ADDRESS").is_some()
        || env::var_os("XDG_RUNTIME_DIR").is_some_and(|dir| Path::new(&dir).join("bus").exists());
    if !cfg!(target_os = "linux")
        || !session
        || env::var("COLECTO_NOTIFICATIONS").is_ok_and(|value| value == "off")
    {
        return;
    }
    let origin = format!("unix:{}", socket.display());
    let token_file = token_file.to_path_buf();
    tokio::spawn(async move {
        if let Err(error) = notifications::run_agent(&origin, &token_file).await {
            tracing::warn!(%error, "Desktop notifications stopped");
        }
    });
}
