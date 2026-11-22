import 'dart:io';

import 'systemd_services.dart';

typedef SystemctlRunner = Future<bool> Function(List<String> args);

const _managedMarker = '# Managed by Colecto';
const _versionMarker = '# Colecto-Version: ';

/// Linux implementation of [SystemdServiceManager] using `systemctl --user`
/// and `$XDG_CONFIG_HOME/systemd/user/`.
///
/// Mirrors pre-Flutter Colecto's `services.rs`: versioned `# Managed by Colecto`
/// unit files, symlink/foreign-unit refusal, atomic writes, and no downgrades.
class LinuxSystemdServiceManager implements SystemdServiceManager {
  LinuxSystemdServiceManager({
    SystemctlRunner? runSystemctl,
    Directory Function()? unitDirectory,
    String? Function()? resolveDaemonExecutable,
    String? Function()? resolveSocketPath,
    this.isLinuxOverride,
  }) : _runSystemctl = runSystemctl ?? _defaultRunSystemctl,
       _unitDirectory = unitDirectory ?? _defaultUnitDirectory,
       _resolveDaemonExecutable =
           resolveDaemonExecutable ?? _defaultResolveDaemonExecutable,
       _resolveSocketPath = resolveSocketPath ?? _defaultResolveSocketPath;

  final SystemctlRunner _runSystemctl;
  final Directory Function() _unitDirectory;
  final String? Function() _resolveDaemonExecutable;
  final String? Function() _resolveSocketPath;
  final bool? isLinuxOverride;

  @override
  bool get isLinuxHost => isLinuxOverride ?? Platform.isLinux;

  static Future<bool> _defaultRunSystemctl(List<String> args) async {
    try {
      final result = await Process.run('systemctl', [
        '--user',
        ...args,
      ]).timeout(const Duration(seconds: 10));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Directory _defaultUnitDirectory() {
    final env = Platform.environment;
    final xdg = env['XDG_CONFIG_HOME']?.trim();
    final base = (xdg != null && xdg.isNotEmpty)
        ? xdg
        : '${env['HOME'] ?? ''}/.config';
    return Directory('$base/systemd/user');
  }

  static String? _defaultResolveSocketPath() {
    final runtime = Platform.environment['XDG_RUNTIME_DIR']?.trim();
    if (runtime == null || runtime.isEmpty) return null;
    return '$runtime/colecto/mail.sock';
  }

  static String? _defaultResolveDaemonExecutable() {
    final candidates = <String>[];
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      candidates.add('$exeDir/colecto-daemon');
    } catch (_) {}

    final pathEnv = Platform.environment['PATH'] ?? '';
    for (final dir in pathEnv.split(':')) {
      if (dir.isNotEmpty) candidates.add('$dir/colecto-daemon');
    }

    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      candidates.add('$home/.local/bin/colecto-daemon');
    }
    candidates.addAll(const [
      '/usr/local/bin/colecto-daemon',
      '/usr/bin/colecto-daemon',
    ]);

    for (final path in candidates) {
      final file = File(path);
      if (file.existsSync()) return file.absolute.path;
    }
    return null;
  }

  /// Quotes an executable path for a systemd `ExecStart=` directive.
  static String quoteExecArg(String value) {
    for (final code in value.codeUnits) {
      if (code < 0x20 || code == 0x7F) {
        throw const FormatException(
          'Executable path contains control characters',
        );
      }
    }
    final escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('%', '%%')
        .replaceAll(r'$', r'$$');
    return '"$escaped"';
  }

  /// Generates the systemd user unit file for [kind].
  static String generateUnit({
    required SystemdServiceKind kind,
    required String executablePath,
    required String appVersion,
  }) {
    final exec = quoteExecArg(executablePath);
    final String environment;
    final String ordering;
    final String target;
    switch (kind) {
      case SystemdServiceKind.daemon:
        environment =
            'Environment=COLECTO_SOCKET=%t/colecto/mail.sock\n'
            'RuntimeDirectory=colecto\n'
            'RuntimeDirectoryMode=0700\n'
            'Environment=COLECTO_DATA_DIR=%h/.local/state/colecto\n'
            'EnvironmentFile=-%h/.config/colecto/daemon.env';
        ordering =
            'After=network-online.target\n'
            'Wants=network-online.target';
        target = 'default.target';
      case SystemdServiceKind.notifications:
        environment =
            'EnvironmentFile=-%h/.config/colecto/notifications.env\n'
            'Environment=COLECTO_RELAY_ORIGIN=unix:%t/colecto/mail.sock\n'
            'Environment=COLECTO_TOKEN_FILE=%h/.local/state/colecto/owner-token';
        ordering =
            'PartOf=graphical-session.target\n'
            'After=graphical-session.target';
        target = 'graphical-session.target';
    }
    return '$_managedMarker\n'
        '$_versionMarker$appVersion\n'
        '[Unit]\n'
        'Description=Colecto ${kind.id}\n'
        '$ordering\n'
        '\n'
        '[Service]\n'
        'Type=simple\n'
        'ExecStart=$exec\n'
        '$environment\n'
        'UMask=0077\n'
        'Restart=on-failure\n'
        'RestartSec=5\n'
        'NoNewPrivileges=true\n'
        '\n'
        '[Install]\n'
        'WantedBy=$target\n';
  }

  static (int, int, int)? _parseRelease(String value) {
    final parts = value.split(RegExp(r'[.\-+]'));
    if (parts.length < 3) return null;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    final c = int.tryParse(parts[2]);
    if (a == null || b == null || c == null) return null;
    return (a, b, c);
  }

  static bool _isNewer((int, int, int) a, (int, int, int) b) {
    if (a.$1 != b.$1) return a.$1 > b.$1;
    if (a.$2 != b.$2) return a.$2 > b.$2;
    return a.$3 > b.$3;
  }

  static String? extractVersion(String unitText) {
    for (final line in unitText.split('\n')) {
      if (line.startsWith(_versionMarker)) {
        return line.substring(_versionMarker.length).trim();
      }
    }
    return null;
  }

  /// Returns [appVersion] when an installed unit differs from [expected] and
  /// was not written by a newer Colecto version.
  static String? computeUpdateTo({
    required String installed,
    required String expected,
    required String appVersion,
  }) {
    if (installed == expected) return null;
    final installedVer = extractVersion(installed);
    final parsedInstalled = installedVer == null
        ? null
        : _parseRelease(installedVer);
    final parsedCurrent = _parseRelease(appVersion);
    if (parsedInstalled != null &&
        parsedCurrent != null &&
        _isNewer(parsedInstalled, parsedCurrent)) {
      return null;
    }
    return appVersion;
  }

  void _ensureManaged(File file) {
    if (FileSystemEntity.isLinkSync(file.path)) {
      throw StateError('Refusing a symlink unit');
    }
    if (!file.existsSync()) return;
    final text = file.readAsStringSync();
    final hasMarker = text
        .split('\n')
        .any((line) => line.trim() == _managedMarker);
    if (!hasMarker) {
      throw StateError(
        'This unit was not written by Colecto; manage it outside the app.',
      );
    }
  }

  void _writeUnitAtomically(File file, String content) {
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(content);
    tmp.renameSync(file.path);
  }

  File _unitFile(SystemdServiceKind kind) =>
      File('${_unitDirectory().path}/${kind.unitName}');

  @override
  Future<Map<SystemdServiceKind, SystemdServiceStatus>> loadStatus({
    required String appVersion,
  }) async {
    if (!isLinuxHost) return const {};

    final exe = _resolveDaemonExecutable();
    final hasSystemd = await _runSystemctl(const ['show-environment']);
    final supported = exe != null && hasSystemd;
    final reason = !hasSystemd
        ? 'Local systemd user manager unavailable'
        : exe == null
        ? 'colecto-daemon executable not found on this machine'
        : null;
    final socket = _resolveSocketPath();

    final out = <SystemdServiceKind, SystemdServiceStatus>{};
    for (final kind in SystemdServiceKind.values) {
      final file = _unitFile(kind);
      String? text;
      if (file.existsSync() && !FileSystemEntity.isLinkSync(file.path)) {
        try {
          text = file.readAsStringSync();
        } catch (_) {}
      }
      final installed = text != null;
      final version = text == null ? null : extractVersion(text);
      String? updateTo;
      if (supported && text != null) {
        final expected = generateUnit(
          kind: kind,
          executablePath: exe,
          appVersion: appVersion,
        );
        updateTo = computeUpdateTo(
          installed: text,
          expected: expected,
          appVersion: appVersion,
        );
      }
      final enabled =
          supported &&
          installed &&
          await _runSystemctl(['is-enabled', kind.unitName]);
      final active =
          supported &&
          installed &&
          await _runSystemctl(['is-active', kind.unitName]);
      out[kind] = SystemdServiceStatus(
        kind: kind,
        supported: supported,
        installed: installed,
        enabled: enabled,
        active: active,
        version: version,
        updateTo: updateTo,
        reason: reason,
        socketPath: socket,
      );
    }
    return out;
  }

  Future<String> _requireSupportedExecutable() async {
    if (!isLinuxHost) {
      throw StateError('User services are supported only on Linux.');
    }
    final exe = _resolveDaemonExecutable();
    if (exe == null) {
      throw StateError(
        'Could not find the colecto-daemon executable on this machine.',
      );
    }
    if (!await _runSystemctl(const ['show-environment'])) {
      throw StateError('Local systemd user manager is unavailable.');
    }
    return exe;
  }

  @override
  Future<void> install(
    SystemdServiceKind kind, {
    required String appVersion,
    required bool autostart,
  }) async {
    final exe = await _requireSupportedExecutable();
    final file = _unitFile(kind);
    _ensureManaged(file);
    _writeUnitAtomically(
      file,
      generateUnit(kind: kind, executablePath: exe, appVersion: appVersion),
    );
    if (!await _runSystemctl(const ['daemon-reload'])) {
      throw StateError('systemctl daemon-reload failed.');
    }
    final args = autostart
        ? ['enable', '--now', kind.unitName]
        : ['start', kind.unitName];
    if (!await _runSystemctl(args)) {
      throw StateError('Failed to start ${kind.unitName}.');
    }
  }

  @override
  Future<void> update(
    SystemdServiceKind kind, {
    required String appVersion,
  }) async {
    final exe = await _requireSupportedExecutable();
    final file = _unitFile(kind);
    _ensureManaged(file);
    if (!file.existsSync()) {
      throw StateError('Service is not installed by Colecto.');
    }
    final wasEnabled = await _runSystemctl(['is-enabled', kind.unitName]);
    _writeUnitAtomically(
      file,
      generateUnit(kind: kind, executablePath: exe, appVersion: appVersion),
    );
    if (!await _runSystemctl(const ['daemon-reload'])) {
      throw StateError('systemctl daemon-reload failed.');
    }
    if (wasEnabled && !await _runSystemctl(['reenable', kind.unitName])) {
      throw StateError('systemctl reenable failed.');
    }
    if (!await _runSystemctl(['try-restart', kind.unitName])) {
      throw StateError('systemctl try-restart failed.');
    }
  }

  @override
  Future<void> setAutostart(
    SystemdServiceKind kind, {
    required bool enabled,
  }) async {
    await _requireSupportedExecutable();
    final file = _unitFile(kind);
    _ensureManaged(file);
    if (!file.existsSync()) {
      throw StateError('Service is not installed by Colecto.');
    }
    final op = enabled ? 'enable' : 'disable';
    if (!await _runSystemctl([op, kind.unitName])) {
      throw StateError('systemctl $op failed.');
    }
  }

  @override
  Future<void> start(SystemdServiceKind kind) async {
    await _requireSupportedExecutable();
    final file = _unitFile(kind);
    _ensureManaged(file);
    if (!file.existsSync()) {
      throw StateError('Service is not installed by Colecto.');
    }
    if (!await _runSystemctl(['start', kind.unitName])) {
      throw StateError('Failed to start ${kind.unitName}.');
    }
  }

  @override
  Future<void> stop(SystemdServiceKind kind) async {
    await _requireSupportedExecutable();
    final file = _unitFile(kind);
    _ensureManaged(file);
    if (!file.existsSync()) {
      throw StateError('Service is not installed by Colecto.');
    }
    if (!await _runSystemctl(['stop', kind.unitName])) {
      throw StateError('Failed to stop ${kind.unitName}.');
    }
  }

  @override
  Future<void> uninstall(SystemdServiceKind kind) async {
    await _requireSupportedExecutable();
    final file = _unitFile(kind);
    _ensureManaged(file);
    if (!file.existsSync()) {
      throw StateError('Service is not installed by Colecto.');
    }
    if (!await _runSystemctl(['disable', '--now', kind.unitName])) {
      throw StateError('Failed to stop and disable ${kind.unitName}.');
    }
    file.deleteSync();
    if (!await _runSystemctl(const ['daemon-reload'])) {
      throw StateError('systemctl daemon-reload failed.');
    }
  }
}

SystemdServiceManager createPlatformSystemdServiceManager() =>
    LinuxSystemdServiceManager();
