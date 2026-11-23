import 'package:http/http.dart' as http;

import 'background_service.dart';

http.Client unixSocketClient(String path) =>
    throw UnsupportedError('Unix sockets are unavailable on the web');

class _NoBackgroundService implements BackgroundService {
  const _NoBackgroundService();

  @override
  bool get isAvailable => false;

  @override
  Future<BackgroundStatus> status() async => BackgroundStatus.unsupported;

  @override
  Future<LocalMailService?> connect() async => null;

  @override
  Future<LocalMailService> enableMail({required bool startOnLogin}) =>
      throw UnsupportedError('Background service is Linux only');

  @override
  Future<void> enableRelay({
    required String origin,
    required String token,
    required bool startOnLogin,
  }) => throw UnsupportedError('Background service is Linux only');

  @override
  Future<void> pause() async {}

  @override
  Future<void> disable() async {}

  @override
  Future<void> setStartOnLogin(bool enabled) async {}
}

BackgroundService createBackgroundService() => const _NoBackgroundService();
