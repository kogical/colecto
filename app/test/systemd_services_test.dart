import 'dart:io';

import 'package:colecto/data/platform/systemd_services.dart';
import 'package:colecto/data/platform/systemd_services_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LinuxSystemdServiceManager', () {
    test(
      'generates versioned, properly quoted daemon and notification units',
      () {
        final daemon = LinuxSystemdServiceManager.generateUnit(
          kind: SystemdServiceKind.daemon,
          executablePath: '/opt/My App/colecto-daemon',
          appVersion: '0.11.4',
        );
        expect(daemon, contains('# Managed by Colecto'));
        expect(daemon, contains('# Colecto-Version: 0.11.4'));
        expect(daemon, contains('ExecStart="/opt/My App/colecto-daemon"'));
        expect(daemon, contains('RuntimeDirectoryMode=0700'));
        expect(daemon, contains('WantedBy=default.target'));

        final notify = LinuxSystemdServiceManager.generateUnit(
          kind: SystemdServiceKind.notifications,
          executablePath: '/usr/bin/colecto-daemon',
          appVersion: '0.11.4',
        );
        expect(
          notify,
          contains('COLECTO_RELAY_ORIGIN=unix:%t/colecto/mail.sock'),
        );
        expect(notify, contains('WantedBy=graphical-session.target'));
      },
    );

    test(
      'detects outdated units and never offers to downgrade newer units',
      () {
        final current = LinuxSystemdServiceManager.generateUnit(
          kind: SystemdServiceKind.daemon,
          executablePath: '/usr/bin/colecto-daemon',
          appVersion: '0.11.4',
        );
        expect(
          LinuxSystemdServiceManager.computeUpdateTo(
            installed: current,
            expected: current,
            appVersion: '0.11.4',
          ),
          isNull,
        );

        final older = current.replaceAll('0.11.4', '0.10.0');
        expect(
          LinuxSystemdServiceManager.computeUpdateTo(
            installed: older,
            expected: current,
            appVersion: '0.11.4',
          ),
          '0.11.4',
        );

        final moved = current.replaceAll('/usr/bin', '/opt/bin');
        expect(
          LinuxSystemdServiceManager.computeUpdateTo(
            installed: moved,
            expected: current,
            appVersion: '0.11.4',
          ),
          '0.11.4',
        );

        final newer = current.replaceAll('0.11.4', '99.0.0');
        expect(
          LinuxSystemdServiceManager.computeUpdateTo(
            installed: newer,
            expected: current,
            appVersion: '0.11.4',
          ),
          isNull,
        );
      },
    );

    test('installs, updates, toggles autostart, stops, and uninstalls managed units', () async {
      final tmp = Directory.systemTemp.createTempSync('colecto_systemd_test_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      final calls = <String>[];
      var enabled = false;
      var active = false;

      final manager = LinuxSystemdServiceManager(
        isLinuxOverride: true,
        unitDirectory: () => tmp,
        resolveDaemonExecutable: () => '/usr/bin/colecto-daemon',
        resolveSocketPath: () => '/run/user/1000/colecto/mail.sock',
        runSystemctl: (args) async {
          calls.add(args.join(' '));
          switch (args.first) {
            case 'show-environment':
            case 'daemon-reload':
            case 'reenable':
            case 'try-restart':
              return true;
            case 'is-enabled':
              return enabled;
            case 'is-active':
              return active;
            case 'enable':
              enabled = true;
              if (args.contains('--now')) active = true;
              return true;
            case 'disable':
              enabled = false;
              if (args.contains('--now')) active = false;
              return true;
            case 'start':
              active = true;
              return true;
            case 'stop':
              active = false;
              return true;
            default:
              return false;
          }
        },
      );

      await manager.install(
        SystemdServiceKind.daemon,
        appVersion: '0.11.4',
        autostart: true,
      );
      final unitFile = File('${tmp.path}/colecto-daemon.service');
      expect(unitFile.existsSync(), isTrue);

      final status = await manager.loadStatus(appVersion: '0.11.4');
      expect(status[SystemdServiceKind.daemon]!.installed, isTrue);
      expect(status[SystemdServiceKind.daemon]!.enabled, isTrue);
      expect(status[SystemdServiceKind.daemon]!.active, isTrue);
      expect(status[SystemdServiceKind.daemon]!.version, '0.11.4');

      await manager.stop(SystemdServiceKind.daemon);
      expect(active, isFalse);

      await manager.uninstall(SystemdServiceKind.daemon);
      expect(unitFile.existsSync(), isFalse);
    });

    test(
      'refuses to touch foreign unit files not written by Colecto',
      () async {
        final tmp = Directory.systemTemp.createTempSync(
          'colecto_systemd_foreign_',
        );
        addTearDown(() => tmp.deleteSync(recursive: true));

        File('${tmp.path}/colecto-daemon.service')
            .writeAsStringSync('[Unit]\n');
        final manager = LinuxSystemdServiceManager(
          isLinuxOverride: true,
          unitDirectory: () => tmp,
          resolveDaemonExecutable: () => '/usr/bin/colecto-daemon',
          runSystemctl: (_) async => true,
        );

        await expectLater(
          () => manager.install(
            SystemdServiceKind.daemon,
            appVersion: '0.11.4',
            autostart: true,
          ),
          throwsStateError,
        );
      },
    );
  });
}
