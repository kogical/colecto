import 'dart:io';

import 'package:colecto/data/platform/background_service.dart';
import 'package:colecto/data/platform/background_service_io.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake `systemctl --user` that records calls and, for `start`/`restart`,
/// serves [onStart] so the service's socket wait succeeds.
class _Systemd {
  final calls = <String>[];
  var enabled = false;
  var active = false;
  Future<void> Function()? onStart;

  Future<bool> run(List<String> args) async {
    calls.add(args.join(' '));
    switch (args.first) {
      case 'show-environment' || 'daemon-reload':
        return true;
      case 'is-enabled':
        return enabled;
      case 'is-active':
        return active;
      case 'enable':
        enabled = true;
      case 'disable':
        enabled = false;
        if (args.contains('--now')) active = false;
      case 'start' || 'restart':
        active = true;
        await onStart?.call();
      case 'stop':
        active = false;
    }
    return true;
  }
}

void main() {
  late Directory tmp;
  late BackgroundPaths paths;
  late _Systemd systemd;
  ServerSocket? server;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('colecto_background_');
    paths = BackgroundPaths(
      unitDirectory: '${tmp.path}/units',
      dataDirectory: '${tmp.path}/My Data/com.kogical.colecto',
      stateDirectory: '${tmp.path}/state',
      socketPath: '${tmp.path}/mail.sock',
    );
    systemd = _Systemd()
      ..onStart = () async {
        server ??= await ServerSocket.bind(
          InternetAddress(paths.socketPath!, type: InternetAddressType.unix),
          0,
        );
      };
  });

  tearDown(() async {
    await server?.close();
    server = null;
    tmp.deleteSync(recursive: true);
  });

  LinuxBackgroundService service({bool appImage = false}) =>
      LinuxBackgroundService(
        appVersion: '0.12.1',
        isLinuxOverride: true,
        paths: paths,
        runSystemctl: systemd.run,
        resolveDaemonExecutable: () => DaemonLauncher(
          appImage
              ? '/home/me/Apps/Colecto.AppImage'
              : '/usr/bin/colecto-daemon',
          appImage: appImage,
        ),
        socketTimeout: const Duration(seconds: 2),
      );

  test('mail mode shares the app store and an owner-only token', () async {
    final local = await service().enableMail(startOnLogin: true);

    final unit = File(paths.unitFile).readAsStringSync();
    expect(unit, contains('# Colecto-Version: 0.12.1'));
    expect(unit, contains('ExecStart="/usr/bin/colecto-daemon"'));
    expect(unit, contains('Environment=COLECTO_SOCKET=%t/colecto/mail.sock'));
    expect(
      unit,
      contains('Environment="COLECTO_DATA_DIR=${paths.dataDirectory}"'),
    );
    expect(
      unit,
      contains('Environment="COLECTO_TOKEN_FILE=${paths.mailTokenFile}"'),
    );
    expect(unit, contains('NoNewPrivileges=true'));

    expect(local.token, hasLength(64));
    expect(File(paths.mailTokenFile).readAsStringSync(), local.token);
    expect(File(paths.mailTokenFile).statSync().modeString(), 'rw-------');
    expect(systemd.enabled, isTrue);

    final status = await service().status();
    expect(status.installed, isTrue);
    expect(status.mode, BackgroundMode.mail);
    expect(status.running, isTrue);
  });

  test('connect reuses an up-to-date unit and its token', () async {
    final first = await service().enableMail(startOnLogin: false);
    final unit = File(paths.unitFile).readAsStringSync();
    systemd.calls.clear();

    final again = await service().connect();
    expect(again?.token, first.token);
    expect(File(paths.unitFile).readAsStringSync(), unit);
    expect(systemd.calls, contains('start colecto-daemon.service'));
    expect(systemd.calls, isNot(contains('restart colecto-daemon.service')));
  });

  test(
    'connect repairs a 0.12.0 unit that used another store and no token',
    () async {
      Directory(paths.unitDirectory).createSync(recursive: true);
      File(paths.unitFile).writeAsStringSync(
        '# Managed by Colecto\n# Colecto-Version: 0.12.0\n[Service]\n'
        'ExecStart="/usr/bin/colecto-daemon"\n'
        'Environment=COLECTO_DATA_DIR=%h/.local/state/colecto\n',
      );
      systemd.enabled = true;

      final local = await service().connect();
      expect(local, isNotNull);
      expect(
        File(paths.unitFile).readAsStringSync(),
        contains(paths.dataDirectory),
      );
      expect(File(paths.mailTokenFile).readAsStringSync(), local!.token);
      expect(systemd.enabled, isTrue);
    },
  );

  test('connect stops a unit whose socket never answers', () async {
    await service().enableMail(startOnLogin: true);
    await server?.close();
    server = null;
    final sock = File(paths.socketPath!);
    if (sock.existsSync()) sock.deleteSync();
    systemd.onStart = null;

    expect(await service().connect(), isNull);
    expect(systemd.calls.last, 'stop colecto-daemon.service');
  });

  test('an AppImage runs itself, not its temporary mount', () async {
    await service(appImage: true).enableMail(startOnLogin: true);
    final unit = File(paths.unitFile).readAsStringSync();
    expect(
      unit,
      contains('ExecStart="/home/me/Apps/Colecto.AppImage" --colecto-daemon'),
    );
    expect(unit, isNot(contains('NoNewPrivileges')));
  });

  test('relay mode follows a remote server, and disable cleans up', () async {
    await service().enableRelay(
      origin: 'https://mail.example.org',
      token: 'remote-token',
      startOnLogin: true,
    );
    final unit = File(paths.unitFile).readAsStringSync();
    expect(
      unit,
      contains('Environment="COLECTO_RELAY_ORIGIN=https://mail.example.org"'),
    );
    expect(unit, isNot(contains('COLECTO_SOCKET')));
    expect(File(paths.relayTokenFile).readAsStringSync(), 'remote-token');

    final status = await service().status();
    expect(status.mode, BackgroundMode.relay);
    expect(status.relayOrigin, 'https://mail.example.org');
    expect(await service().connect(), isNull);

    await service().disable();
    expect(File(paths.unitFile).existsSync(), isFalse);
    expect(File(paths.relayTokenFile).existsSync(), isFalse);
    expect(systemd.calls, contains('disable --now colecto-daemon.service'));
  });

  test('removes the old notification relay unit, but only its own', () async {
    Directory(paths.unitDirectory).createSync(recursive: true);
    final relay = File('${paths.unitDirectory}/colecto-notifications.service')
      ..writeAsStringSync('# Managed by Colecto\n[Unit]\n');
    await service().connect();
    expect(relay.existsSync(), isFalse);
    expect(
      systemd.calls,
      contains('disable --now colecto-notifications.service'),
    );

    relay.writeAsStringSync('[Unit]\n');
    await service().connect();
    expect(relay.existsSync(), isTrue);
  });

  test('never touches a unit Colecto did not write', () async {
    Directory(paths.unitDirectory).createSync(recursive: true);
    File(paths.unitFile).writeAsStringSync('[Unit]\n');
    expect(await service().connect(), isNull);
    await expectLater(
      service().enableMail(startOnLogin: true),
      throwsStateError,
    );
    expect(File(paths.unitFile).readAsStringSync(), '[Unit]\n');
    final status = await service().status();
    expect(status.supported, isFalse);
  });

  test('never downgrades a unit written by a newer Colecto', () {
    final current = LinuxBackgroundService.generateUnit(
      mode: BackgroundMode.mail,
      launcher: const DaemonLauncher('/usr/bin/colecto-daemon'),
      appVersion: '0.12.1',
      paths: paths,
    );
    expect(
      LinuxBackgroundService.needsRewrite(
        installed: current.replaceAll('0.12.1', '0.11.0'),
        expected: current,
        appVersion: '0.12.1',
      ),
      isTrue,
    );
    expect(
      LinuxBackgroundService.needsRewrite(
        installed: current.replaceAll('0.12.1', '99.0.0'),
        expected: current,
        appVersion: '0.12.1',
      ),
      isFalse,
    );
  });
}
