import 'systemd_services.dart';

class _StubSystemdServiceManager implements SystemdServiceManager {
  @override
  bool get isLinuxHost => false;

  @override
  Future<Map<SystemdServiceKind, SystemdServiceStatus>> loadStatus({
    required String appVersion,
  }) async => const {};

  @override
  Future<void> install(
    SystemdServiceKind kind, {
    required String appVersion,
    required bool autostart,
  }) => throw UnsupportedError('User services are supported only on Linux');

  @override
  Future<void> update(SystemdServiceKind kind, {required String appVersion}) =>
      throw UnsupportedError('User services are supported only on Linux');

  @override
  Future<void> setAutostart(SystemdServiceKind kind, {required bool enabled}) =>
      throw UnsupportedError('User services are supported only on Linux');

  @override
  Future<void> start(SystemdServiceKind kind) =>
      throw UnsupportedError('User services are supported only on Linux');

  @override
  Future<void> stop(SystemdServiceKind kind) =>
      throw UnsupportedError('User services are supported only on Linux');

  @override
  Future<void> uninstall(SystemdServiceKind kind) =>
      throw UnsupportedError('User services are supported only on Linux');
}

SystemdServiceManager createPlatformSystemdServiceManager() =>
    _StubSystemdServiceManager();
