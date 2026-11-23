import 'package:http/http.dart' as http;

import 'background_service_io.dart'
    if (dart.library.js_interop) 'background_service_web.dart'
    as impl;

/// What the background unit runs.
enum BackgroundMode {
  /// `colecto-daemon` owns this device's mail store: it syncs, serves the app
  /// over a private Unix socket, and shows desktop notifications.
  mail,

  /// `colecto-daemon` only shows notifications for a remote server's mail.
  relay,
}

/// The local mail service the app talks to while the background unit owns
/// the mail store.
class LocalMailService {
  const LocalMailService({required this.socketPath, required this.token});

  final String socketPath;
  final String token;

  /// Base URL for [RemoteHttpBackend]; the daemon only accepts `localhost`.
  static const baseUrl = 'http://localhost';

  /// A new HTTP client that reaches the daemon through [socketPath].
  http.Client client() => impl.unixSocketClient(socketPath);
}

/// Snapshot of the background unit.
class BackgroundStatus {
  const BackgroundStatus({
    required this.supported,
    this.installed = false,
    this.mode,
    this.relayOrigin,
    this.startOnLogin = false,
    this.running = false,
    this.reason,
  });

  static const unsupported = BackgroundStatus(supported: false);

  /// systemd and `colecto-daemon` are both available.
  final bool supported;
  final bool installed;
  final BackgroundMode? mode;
  final String? relayOrigin;
  final bool startOnLogin;
  final bool running;

  /// Why [supported] is false.
  final String? reason;
}

/// Keeps Colecto running after its window closes, as one `systemd --user`
/// unit (`colecto-daemon.service`) that the app writes, updates, and removes
/// itself. Linux only; elsewhere [isAvailable] is false.
abstract class BackgroundService {
  /// Whether this platform can run the background unit at all.
  bool get isAvailable;

  Future<BackgroundStatus> status();

  /// When the unit is installed in [BackgroundMode.mail], starts it if needed,
  /// waits for its socket, and returns how to reach it. Returns null when the
  /// app should open the mail store itself. If the unit cannot be reached it
  /// is stopped, so the store is never open twice.
  Future<LocalMailService?> connect();

  /// Installs and starts the unit in [BackgroundMode.mail]. The caller must
  /// have closed its own handle on the mail store first.
  Future<LocalMailService> enableMail({required bool startOnLogin});

  /// Installs and starts the unit in [BackgroundMode.relay] for [origin].
  Future<void> enableRelay({
    required String origin,
    required String token,
    required bool startOnLogin,
  });

  /// Stops the unit and leaves it installed, for a connection it cannot
  /// serve (demo mail, or a plain-HTTP server).
  Future<void> pause();

  /// Stops and removes the unit. Mail it synced stays in the mail store.
  Future<void> disable();

  Future<void> setStartOnLogin(bool enabled);
}

BackgroundService createBackgroundService() => impl.createBackgroundService();
