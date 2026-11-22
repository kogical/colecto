import 'systemd_services_stub.dart'
    if (dart.library.io) 'systemd_services_io.dart';

/// Linux systemd user services managed by Colecto.
enum SystemdServiceKind {
  daemon(
    id: 'daemon',
    unitName: 'colecto-daemon.service',
    title: 'Mail service',
    description:
        'Keeps syncing mail when the app is closed. The app connects to it '
        'through a private local socket.',
  ),
  notifications(
    id: 'notifications',
    unitName: 'colecto-notifications.service',
    title: 'Desktop notifications',
    description:
        'Shows a desktop notification for new mail from the background '
        'service.',
  );

  const SystemdServiceKind({
    required this.id,
    required this.unitName,
    required this.title,
    required this.description,
  });

  final String id;
  final String unitName;
  final String title;
  final String description;
}

/// Snapshot of a single systemd user service.
class SystemdServiceStatus {
  const SystemdServiceStatus({
    required this.kind,
    required this.supported,
    required this.installed,
    required this.enabled,
    required this.active,
    this.version,
    this.updateTo,
    this.reason,
    this.socketPath,
  });

  final SystemdServiceKind kind;
  final bool supported;
  final bool installed;
  final bool enabled;
  final bool active;
  final String? version;
  final String? updateTo;
  final String? reason;
  final String? socketPath;

  String get stateLabel {
    if (!installed) return 'Not installed';
    return active ? 'Running' : 'Stopped';
  }
}

/// Manages Colecto's Linux `systemd --user` units.
abstract class SystemdServiceManager {
  /// Whether this platform can host Linux systemd user services.
  bool get isLinuxHost;

  Future<Map<SystemdServiceKind, SystemdServiceStatus>> loadStatus({
    required String appVersion,
  });

  Future<void> install(
    SystemdServiceKind kind, {
    required String appVersion,
    required bool autostart,
  });

  Future<void> update(SystemdServiceKind kind, {required String appVersion});

  Future<void> setAutostart(SystemdServiceKind kind, {required bool enabled});

  Future<void> start(SystemdServiceKind kind);

  Future<void> stop(SystemdServiceKind kind);

  Future<void> uninstall(SystemdServiceKind kind);
}

SystemdServiceManager createSystemdServiceManager() =>
    createPlatformSystemdServiceManager();
