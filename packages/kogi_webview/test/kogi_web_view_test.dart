import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kogi_webview/kogi_webview.dart';

const _channel = MethodChannel('kogi_webview');

Widget _host(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(child: SizedBox(width: 300, height: 200, child: child)),
);

void main() {
  final calls = <MethodCall>[];

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    calls.clear();
  });

  testWidgets('builds the fallback off Linux', (tester) async {
    await tester.pumpWidget(
      _host(const KogiWebView(html: '<p>x</p>', fallback: Text('fallback'))),
    );
    expect(find.text('fallback'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('falls back when the runner has no GtkOverlay', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return null; // native "create" refuses
        });
    await tester.pumpWidget(
      _host(const KogiWebView(html: '<p>x</p>', fallback: Text('fallback'))),
    );
    await tester.pump();
    expect(find.text('fallback'), findsOneWidget);
    expect(calls.map((c) => c.method), contains('create'));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('loads, places and disposes the native view', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return call.method == 'create' ? {'wayland': true} : null;
        });
    await tester.pumpWidget(
      _host(const KogiWebView(html: '<p>hello</p>', blockNetwork: true)),
    );
    await tester.pump();
    await tester.pump();

    final load = calls.firstWhere((c) => c.method == 'load');
    expect((load.arguments as Map)['html'], '<p>hello</p>');
    expect((load.arguments as Map)['blockNetwork'], true);

    final place = calls.lastWhere((c) => c.method == 'place');
    final args = (place.arguments as Map).cast<String, Object?>();
    expect(args['visible'], true);
    expect(args['sw'], 300.0);
    expect(args['sh'], 200.0);

    await tester.pumpWidget(_host(const SizedBox()));
    expect(calls.last.method, 'dispose');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
