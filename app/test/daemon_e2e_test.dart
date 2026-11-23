import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:colecto/data/platform/background_service.dart';
import 'package:colecto/data/repositories/remote_http_backend.dart';
import 'package:colecto/domain/models/mail_models.dart';
import 'package:colecto/domain/models/preferences_models.dart';
import 'package:colecto/domain/models/service_event.dart';

/// Critical-path E2E contract test: spawns the real Rust `colecto-daemon`
/// binary and exercises `RemoteHttpBackend` over real loopback HTTP + SSE.
///
/// Auto-discovers `COLECTO_DAEMON_BIN` or `../target/{debug,release}/colecto-daemon`.
/// Skips cleanly when the Rust binary has not been built yet.
String? _findDaemonBinary() {
  final env = Platform.environment['COLECTO_DAEMON_BIN'];
  if (env != null && env.isNotEmpty && File(env).existsSync()) {
    return env;
  }
  final ext = Platform.isWindows ? '.exe' : '';
  final targetDir = Platform.environment['CARGO_TARGET_DIR'];
  for (final candidate in [
    if (targetDir != null && targetDir.isNotEmpty) ...[
      '$targetDir/debug/colecto-daemon$ext',
      '$targetDir/release/colecto-daemon$ext',
    ],
    '../target/debug/colecto-daemon$ext',
    '../target/release/colecto-daemon$ext',
  ]) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

void main() {
  final binary = _findDaemonBinary();

  test(
    'RemoteHttpBackend <-> live colecto-daemon critical path (HTTP + SSE + persistence)',
    () async {
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      final dataDir = await Directory.systemTemp.createTemp('colecto-e2e-');
      addTearDown(() async {
        if (dataDir.existsSync()) {
          await dataDir.delete(recursive: true);
        }
      });

      final env = Map<String, String>.from(Platform.environment)
        ..removeWhere((k, _) => k.startsWith('COLECTO_'))
        ..['COLECTO_DATA_DIR'] = dataDir.path
        ..['COLECTO_PORT'] = '0'
        ..['COLECTO_NOTIFICATIONS'] = 'off'
        ..['COLECTO_UPDATE_CHECK'] = 'off';

      final proc = await Process.start(
        binary!,
        const [],
        environment: env,
        includeParentEnvironment: false,
      );
      addTearDown(() async {
        proc.kill();
        await proc.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            proc.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
      });

      final urlCompleter = Completer<String>();
      final tokenCompleter = Completer<String>();
      final stdoutSub = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final trimmed = line.trim();
            if (trimmed.startsWith('Colecto: http://') &&
                !urlCompleter.isCompleted) {
              urlCompleter.complete(trimmed.substring('Colecto: '.length));
            } else if (trimmed.startsWith('Access token (ephemeral): ') &&
                !tokenCompleter.isCompleted) {
              tokenCompleter.complete(
                trimmed.substring('Access token (ephemeral): '.length),
              );
            }
          });
      addTearDown(stdoutSub.cancel);

      final baseUrl = await urlCompleter.future.timeout(
        const Duration(seconds: 10),
      );
      final token = await tokenCompleter.future.timeout(
        const Duration(seconds: 10),
      );

      // 1. Unauthenticated client must be rejected with 401.
      final unauth = RemoteHttpBackend(baseUrl: baseUrl, token: 'wrong-token');
      addTearDown(unauth.dispose);
      await expectLater(
        unauth.listAccounts(),
        throwsA(
          isA<MailBackendException>().having(
            (e) => e.isAuthRequired,
            'isAuthRequired',
            isTrue,
          ),
        ),
      );

      // 2. Authenticated client reads version, accounts, folders, and sample mail.
      final backend = RemoteHttpBackend(baseUrl: baseUrl, token: token);
      addTearDown(backend.dispose);

      final version = await backend.version();
      expect(version.api, 'v1');

      final accounts = await backend.listAccounts();
      expect(accounts.any((a) => a.id == 'demo'), isTrue);

      final folders = await backend.folders('demo');
      expect(folders.any((f) => f.id == 'inbox'), isTrue);

      final snapshot = await backend.cachedMessages('demo', folder: 'inbox');
      expect(snapshot.messages, isNotEmpty);

      // 3. Subscribe to live SSE stream and trigger a live MCP preference event.
      final ready = Completer<void>();
      final gotMcp = Completer<void>();
      final eventSub = backend.events().listen((ev) {
        if (ev is ReadyServiceEvent && !ready.isCompleted) ready.complete();
        if (ev is McpServiceEvent && ev.on && !gotMcp.isCompleted) {
          gotMcp.complete();
        }
      });
      addTearDown(eventSub.cancel);

      await ready.future.timeout(const Duration(seconds: 5));

      final updatedPrefs = await backend.updatePreferences(
        const PreferencesPatch(listDensity: ListDensity.compact, mcp: true),
      );
      expect(updatedPrefs.listDensity, ListDensity.compact);
      expect(updatedPrefs.mcp, isTrue);
      await gotMcp.future.timeout(const Duration(seconds: 5));

      await backend.updateLabel('demo', name: 'E2E');
      final labels = await backend.updateLabel(
        'demo',
        name: 'E2E',
        messageId: snapshot.messages.first.id,
      );
      expect(labels['E2E'], contains(snapshot.messages.first.id));

      // 4. Drafts round-trip through Turso storage without sidecar files.
      final draft = await backend.saveDraft(
        'demo',
        const DraftInput(
          recipient: 'friend@example.test',
          subject: 'E2E draft',
          body: 'Persisted in colecto.db',
        ),
      );
      final fetched = await backend.draft('demo', draft.id);
      expect(fetched.subject, 'E2E draft');
      expect(File('${dataDir.path}/colecto.db').existsSync(), isTrue);
      expect(File('${dataDir.path}/owner-token').existsSync(), isFalse);
    },
    skip: binary == null
        ? 'colecto-daemon binary not built (run `just build rust` or `just test e2e`)'
        : false,
  );

  test(
    'the background service: the app reaches colecto-daemon over its socket',
    () async {
      final dir = await Directory.systemTemp.createTemp('colecto-sock-');
      addTearDown(() => dir.delete(recursive: true));
      final runtime = Directory('${dir.path}/run')..createSync();
      await Process.run('chmod', ['700', runtime.path]);
      final socket = '${runtime.path}/mail.sock';
      final tokenFile = File('${dir.path}/mail-token')..writeAsStringSync('');
      await Process.run('chmod', ['600', tokenFile.path]);
      final token = 'a' * 64;
      tokenFile.writeAsStringSync(token);

      final env = Map<String, String>.from(Platform.environment)
        ..removeWhere((k, _) => k.startsWith('COLECTO_'))
        ..['COLECTO_DATA_DIR'] = '${dir.path}/data'
        ..['COLECTO_SOCKET'] = socket
        ..['COLECTO_TOKEN_FILE'] = tokenFile.path
        ..['COLECTO_NOTIFICATIONS'] = 'off'
        ..['COLECTO_UPDATE_CHECK'] = 'off';
      final proc = await Process.start(
        binary!,
        const [],
        environment: env,
        includeParentEnvironment: false,
      );
      addTearDown(() async {
        proc.kill();
        await proc.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            proc.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
      });
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!File(socket).existsSync() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      final local = LocalMailService(socketPath: socket, token: token);
      final backend = RemoteHttpBackend(
        baseUrl: LocalMailService.baseUrl,
        token: token,
        streamClient: local.client,
      );
      addTearDown(backend.dispose);
      expect((await backend.version()).api, 'v1');
      expect(await backend.listAccounts(), isNotEmpty);

      final ready = Completer<void>();
      final sub = backend.events().listen((ev) {
        if (ev is ReadyServiceEvent && !ready.isCompleted) ready.complete();
      });
      addTearDown(sub.cancel);
      await ready.future.timeout(const Duration(seconds: 10));

      final wrong = RemoteHttpBackend(
        baseUrl: LocalMailService.baseUrl,
        token: 'b' * 64,
        streamClient: local.client,
      );
      addTearDown(wrong.dispose);
      await expectLater(
        wrong.listAccounts(),
        throwsA(isA<MailBackendException>()),
      );
    },
    skip: binary == null || !Platform.isLinux
        ? 'colecto-daemon binary not built, or not Linux'
        : false,
  );
}
