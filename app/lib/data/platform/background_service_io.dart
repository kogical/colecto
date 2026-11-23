import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart' show appBuildName;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'background_service.dart';

typedef SystemctlRunner = Future<bool> Function(List<String> args);

/// What the unit runs: `colecto-daemon`, or for an AppImage the image file
/// itself with `--colecto-daemon` (its `AppRun` then starts the daemon), since
/// the image's mount path changes on every launch.
class DaemonLauncher {
  const DaemonLauncher(this.executable, {this.appImage = false});

  final String executable;
  final bool appImage;

  String get execStart => appImage
      ? '${LinuxBackgroundService.quoteExecArg(executable)} --colecto-daemon'
      : LinuxBackgroundService.quoteExecArg(executable);
}

const _managedMarker = '# Managed by Colecto';
const _versionMarker = '# Colecto-Version: ';
const _relayOriginKey = 'COLECTO_RELAY_ORIGIN=';

/// The one unit Colecto installs.
const unitName = 'colecto-daemon.service';

/// The separate relay unit Colecto 0.11.5–0.12.0 installed. It never worked
/// and would notify twice now that the daemon notifies itself, so it goes.
const legacyNotificationUnit = 'colecto-notifications.service';

http.Client unixSocketClient(String path) {
  final address = InternetAddress(path, type: InternetAddressType.unix);
  final client = HttpClient()
    ..connectionFactory = (uri, proxyHost, proxyPort) =>
        Socket.startConnect(address, 0);
  return IOClient(client);
}

/// Where the background unit keeps its files. Mirrors `colecto-ffi`'s data
/// directory so the daemon opens the same mail store and keyring entries as
/// the app.
class BackgroundPaths {
  const BackgroundPaths({
    required this.unitDirectory,
    required this.dataDirectory,
    required this.stateDirectory,
    required this.socketPath,
  });

  factory BackgroundPaths.fromEnvironment([Map<String, String>? environment]) {
    final env = environment ?? Platform.environment;
    String? absolute(String name) {
      final value = env[name]?.trim();
      return value != null && value.startsWith('/') ? value : null;
    }

    final home = env['HOME'] ?? '';
    final explicitData = env['COLECTO_DATA_DIR']?.trim();
    final runtime = absolute('XDG_RUNTIME_DIR');
    return BackgroundPaths(
      unitDirectory:
          '${absolute('XDG_CONFIG_HOME') ?? '$home/.config'}/systemd/user',
      dataDirectory: explicitData != null && explicitData.isNotEmpty
          ? explicitData
          : '${absolute('XDG_DATA_HOME') ?? '$home/.local/share'}'
                '/com.kogical.colecto',
      stateDirectory:
          '${absolute('XDG_STATE_HOME') ?? '$home/.local/state'}/colecto',
      socketPath: runtime == null ? null : '$runtime/colecto/mail.sock',
    );
  }

  final String unitDirectory;
  final String dataDirectory;

  /// Holds the owner-only token files.
  final String stateDirectory;

  /// `%t/colecto/mail.sock`; null without `XDG_RUNTIME_DIR`.
  final String? socketPath;

  String get unitFile => '$unitDirectory/$unitName';
  String get mailTokenFile => '$stateDirectory/mail-token';
  String get relayTokenFile => '$stateDirectory/relay-token';
}

/// Linux [BackgroundService] using `systemctl --user` and a versioned
/// `# Managed by Colecto` unit: it refuses symlinks and units it did not
/// write, writes atomically, and never downgrades a newer unit.
class LinuxBackgroundService implements BackgroundService {
  LinuxBackgroundService({
    String? appVersion,
    SystemctlRunner? runSystemctl,
    BackgroundPaths? paths,
    DaemonLauncher? Function()? resolveDaemonExecutable,
    this.isLinuxOverride,
    this.socketTimeout = const Duration(seconds: 10),
  }) : appVersion = appVersion ?? appBuildName ?? '0.0.0',
       _runSystemctl = runSystemctl ?? _defaultRunSystemctl,
       _paths = paths ?? BackgroundPaths.fromEnvironment(),
       _resolveDaemonExecutable =
           resolveDaemonExecutable ?? _defaultResolveDaemonExecutable;

  final String appVersion;
  final SystemctlRunner _runSystemctl;
  final BackgroundPaths _paths;
  final DaemonLauncher? Function() _resolveDaemonExecutable;
  final bool? isLinuxOverride;
  final Duration socketTimeout;

  @override
  bool get isAvailable => isLinuxOverride ?? Platform.isLinux;

  static Future<bool> _defaultRunSystemctl(List<String> args) async {
    try {
      final result = await Process.run('systemctl', [
        '--user',
        ...args,
      ]).timeout(const Duration(seconds: 30));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static DaemonLauncher? _defaultResolveDaemonExecutable() {
    final image = Platform.environment['APPIMAGE']?.trim();
    if (image != null && image.startsWith('/') && File(image).existsSync()) {
      return DaemonLauncher(image, appImage: true);
    }
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
      if (file.existsSync()) return DaemonLauncher(file.absolute.path);
    }
    return null;
  }

  // ───────────────────────── Unit text ─────────────────────────

  static void _rejectControlCharacters(String value) {
    for (final code in value.codeUnits) {
      if (code < 0x20 || code == 0x7F) {
        throw const FormatException('Path contains control characters');
      }
    }
  }

  /// Quotes an executable path for a systemd `ExecStart=` directive.
  static String quoteExecArg(String value) {
    _rejectControlCharacters(value);
    final escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('%', '%%')
        .replaceAll(r'$', r'$$');
    return '"$escaped"';
  }

  /// An `Environment=` line for one variable. Unlike `ExecStart=`, systemd
  /// does not expand `$` here, only `%` specifiers.
  static String environmentLine(String name, String value) {
    _rejectControlCharacters(value);
    final escaped = '$name=$value'
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('%', '%%');
    return 'Environment="$escaped"';
  }

  /// Generates the unit for [mode]. [relayOrigin] is required for
  /// [BackgroundMode.relay].
  static String generateUnit({
    required BackgroundMode mode,
    required DaemonLauncher launcher,
    required String appVersion,
    required BackgroundPaths paths,
    String? relayOrigin,
  }) {
    final String description;
    final String environment;
    switch (mode) {
      case BackgroundMode.mail:
        description = 'Colecto mail service';
        environment =
            'Environment=COLECTO_SOCKET=%t/colecto/mail.sock\n'
            'RuntimeDirectory=colecto\n'
            'RuntimeDirectoryMode=0700\n'
            '${environmentLine('COLECTO_DATA_DIR', paths.dataDirectory)}\n'
            '${environmentLine('COLECTO_TOKEN_FILE', paths.mailTokenFile)}\n'
            'EnvironmentFile=-%h/.config/colecto/daemon.env';
      case BackgroundMode.relay:
        description = 'Colecto notifications';
        environment =
            '${environmentLine('COLECTO_RELAY_ORIGIN', relayOrigin!)}\n'
            '${environmentLine('COLECTO_TOKEN_FILE', paths.relayTokenFile)}';
    }
    return '$_managedMarker. Change it in Settings → Connection.\n'
        '$_versionMarker$appVersion\n'
        '[Unit]\n'
        'Description=$description\n'
        'After=network-online.target\n'
        'Wants=network-online.target\n'
        '\n'
        '[Service]\n'
        'Type=simple\n'
        'ExecStart=${launcher.execStart}\n'
        '$environment\n'
        'UMask=0077\n'
        'Restart=on-failure\n'
        'RestartSec=5\n'
        // An AppImage mounts itself through the setuid fusermount helper,
        // which NoNewPrivileges blocks.
        '${launcher.appImage ? '' : 'NoNewPrivileges=true\n'}'
        '\n'
        '[Install]\n'
        'WantedBy=default.target\n';
  }

  static bool _isManaged(String text) =>
      text.split('\n').any((line) => line.startsWith(_managedMarker));

  static BackgroundMode modeOf(String unitText) =>
      relayOriginOf(unitText) == null
      ? BackgroundMode.mail
      : BackgroundMode.relay;

  static String? relayOriginOf(String unitText) {
    for (final line in unitText.split('\n')) {
      final start = line.indexOf(_relayOriginKey);
      if (start < 0) continue;
      return line
          .substring(start + _relayOriginKey.length)
          .replaceFirst(RegExp(r'"$'), '')
          .replaceAll('%%', '%');
    }
    return null;
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

  /// Whether an installed unit should be rewritten as [expected]: it differs
  /// and was not written by a newer Colecto.
  static bool needsRewrite({
    required String installed,
    required String expected,
    required String appVersion,
  }) {
    if (installed == expected) return false;
    final installedVer = extractVersion(installed);
    final parsedInstalled = installedVer == null
        ? null
        : _parseRelease(installedVer);
    final parsedCurrent = _parseRelease(appVersion);
    return !(parsedInstalled != null &&
        parsedCurrent != null &&
        _isNewer(parsedInstalled, parsedCurrent));
  }

  // ───────────────────────── Files ─────────────────────────

  /// The managed unit's text, null when none is installed. Throws for a
  /// symlink or a unit Colecto did not write.
  String? _readManagedUnit() {
    final file = File(_paths.unitFile);
    if (FileSystemEntity.isLinkSync(file.path)) {
      throw StateError('Refusing a symlinked $unitName.');
    }
    if (!file.existsSync()) return null;
    final text = file.readAsStringSync();
    if (!_isManaged(text)) {
      throw StateError(
        '$unitName was not written by Colecto; manage it outside the app.',
      );
    }
    return text;
  }

  static void _writeAtomically(String path, String content) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final tmp = File('$path.tmp');
    tmp.writeAsStringSync(content);
    tmp.renameSync(path);
  }

  /// Writes [token] readable only by this user: the daemon refuses token
  /// files anyone else can read.
  Future<void> _writeToken(String path, String token) async {
    final dir = Directory(File(path).parent.path)..createSync(recursive: true);
    final tmp = File('$path.tmp')..writeAsStringSync('');
    final chmod = await Process.run('chmod', ['600', tmp.path]);
    final chmodDir = await Process.run('chmod', ['700', dir.path]);
    if (chmod.exitCode != 0 || chmodDir.exitCode != 0) {
      tmp.deleteSync();
      throw StateError('Could not make the service token private.');
    }
    tmp.writeAsStringSync(token, flush: true);
    tmp.renameSync(path);
  }

  static String _newToken() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 32; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  void _deleteQuietly(String path) {
    try {
      final file = File(path);
      if (file.existsSync() && !FileSystemEntity.isLinkSync(path)) {
        file.deleteSync();
      }
    } catch (_) {}
  }

  // ───────────────────────── systemctl ─────────────────────────

  Future<void> _systemctl(List<String> args) async {
    if (!await _runSystemctl(args)) {
      throw StateError('systemctl --user ${args.join(' ')} failed.');
    }
  }

  Future<DaemonLauncher> _requireExecutable() async {
    if (!isAvailable) {
      throw StateError('The background service is supported only on Linux.');
    }
    final exe = _resolveDaemonExecutable();
    if (exe == null) {
      throw StateError('colecto-daemon was not found on this computer.');
    }
    if (!await _runSystemctl(const ['show-environment'])) {
      throw StateError('The systemd user manager is unavailable.');
    }
    return exe;
  }

  Future<void> _removeLegacyNotificationUnit() async {
    final path = '${_paths.unitDirectory}/$legacyNotificationUnit';
    try {
      if (FileSystemEntity.isLinkSync(path) || !File(path).existsSync()) {
        return;
      }
      if (!_isManaged(File(path).readAsStringSync())) return;
      await _runSystemctl(const ['disable', '--now', legacyNotificationUnit]);
      File(path).deleteSync();
      await _runSystemctl(const ['daemon-reload']);
    } catch (_) {}
  }

  Future<void> _install(String unitText, {required bool startOnLogin}) async {
    _writeAtomically(_paths.unitFile, unitText);
    await _systemctl(const ['daemon-reload']);
    await _systemctl([startOnLogin ? 'enable' : 'disable', unitName]);
    // Restart so a new token or mode takes effect; it starts a stopped unit.
    await _systemctl(const ['restart', unitName]);
  }

  Future<bool> _waitForSocket(String path) async {
    final address = InternetAddress(path, type: InternetAddressType.unix);
    final deadline = DateTime.now().add(socketTimeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final socket = await Socket.connect(
          address,
          0,
          timeout: const Duration(seconds: 1),
        );
        socket.destroy();
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    return false;
  }

  // ───────────────────────── BackgroundService ─────────────────────────

  @override
  Future<BackgroundStatus> status() async {
    if (!isAvailable) return BackgroundStatus.unsupported;
    final hasSystemd = await _runSystemctl(const ['show-environment']);
    final exe = _resolveDaemonExecutable();
    final reason = !hasSystemd
        ? 'The systemd user manager is unavailable here.'
        : exe == null
        ? 'colecto-daemon was not found on this computer.'
        : _paths.socketPath == null
        ? 'XDG_RUNTIME_DIR is not set.'
        : null;
    if (reason != null) {
      return BackgroundStatus(supported: false, reason: reason);
    }
    final String? text;
    try {
      text = _readManagedUnit();
    } on StateError catch (e) {
      return BackgroundStatus(supported: false, reason: e.message);
    }
    if (text == null) return const BackgroundStatus(supported: true);
    return BackgroundStatus(
      supported: true,
      installed: true,
      mode: modeOf(text),
      relayOrigin: relayOriginOf(text),
      startOnLogin: await _runSystemctl(const ['is-enabled', unitName]),
      running: await _runSystemctl(const ['is-active', unitName]),
    );
  }

  @override
  Future<LocalMailService?> connect() async {
    if (!isAvailable) return null;
    await _removeLegacyNotificationUnit();
    final socket = _paths.socketPath;
    final String? text;
    try {
      text = _readManagedUnit();
    } on StateError {
      return null;
    }
    if (text == null || socket == null || modeOf(text) != BackgroundMode.mail) {
      return null;
    }
    try {
      final exe = await _requireExecutable();
      var token = _readToken(_paths.mailTokenFile);
      final expected = generateUnit(
        mode: BackgroundMode.mail,
        launcher: exe,
        appVersion: appVersion,
        paths: _paths,
      );
      final rewrite = needsRewrite(
        installed: text,
        expected: expected,
        appVersion: appVersion,
      );
      if (rewrite || token == null) {
        // Units from Colecto 0.11.5–0.12.0 used another store and no token.
        token = _newToken();
        await _writeToken(_paths.mailTokenFile, token);
        await _install(
          rewrite ? expected : text,
          startOnLogin: await _runSystemctl(const ['is-enabled', unitName]),
        );
      } else {
        await _systemctl(const ['start', unitName]);
      }
      if (await _waitForSocket(socket)) {
        return LocalMailService(socketPath: socket, token: token);
      }
    } catch (_) {}
    // Never leave it starting behind the app's back.
    await _runSystemctl(const ['stop', unitName]);
    return null;
  }

  String? _readToken(String path) {
    try {
      final token = File(path).readAsStringSync().trim();
      return token.isEmpty ? null : token;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<LocalMailService> enableMail({required bool startOnLogin}) async {
    final exe = await _requireExecutable();
    final socket = _paths.socketPath;
    if (socket == null) throw StateError('XDG_RUNTIME_DIR is not set.');
    _readManagedUnit();
    await _removeLegacyNotificationUnit();
    final token = _newToken();
    await _writeToken(_paths.mailTokenFile, token);
    _deleteQuietly(_paths.relayTokenFile);
    await _install(
      generateUnit(
        mode: BackgroundMode.mail,
        launcher: exe,
        appVersion: appVersion,
        paths: _paths,
      ),
      startOnLogin: startOnLogin,
    );
    if (!await _waitForSocket(socket)) {
      await _runSystemctl(const ['stop', unitName]);
      throw StateError(
        'The background service did not start. '
        'See: journalctl --user -u $unitName',
      );
    }
    return LocalMailService(socketPath: socket, token: token);
  }

  @override
  Future<void> enableRelay({
    required String origin,
    required String token,
    required bool startOnLogin,
  }) async {
    final exe = await _requireExecutable();
    _readManagedUnit();
    await _removeLegacyNotificationUnit();
    await _writeToken(_paths.relayTokenFile, token);
    _deleteQuietly(_paths.mailTokenFile);
    await _install(
      generateUnit(
        mode: BackgroundMode.relay,
        launcher: exe,
        appVersion: appVersion,
        paths: _paths,
        relayOrigin: origin,
      ),
      startOnLogin: startOnLogin,
    );
  }

  @override
  Future<void> pause() async {
    if (!isAvailable) return;
    if (_readManagedUnit() == null) return;
    await _systemctl(const ['stop', unitName]);
  }

  @override
  Future<void> disable() async {
    if (!isAvailable) return;
    if (_readManagedUnit() == null) return;
    await _systemctl(const ['disable', '--now', unitName]);
    File(_paths.unitFile).deleteSync();
    _deleteQuietly(_paths.mailTokenFile);
    _deleteQuietly(_paths.relayTokenFile);
    await _systemctl(const ['daemon-reload']);
  }

  @override
  Future<void> setStartOnLogin(bool enabled) async {
    if (_readManagedUnit() == null) {
      throw StateError('The background service is off.');
    }
    await _systemctl([enabled ? 'enable' : 'disable', unitName]);
  }
}

BackgroundService createBackgroundService() => LinuxBackgroundService();
