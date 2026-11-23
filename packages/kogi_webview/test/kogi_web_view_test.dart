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

  testWidgets('places a scaled view at its on-screen size and zoom', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return call.method == 'create' ? {'wayland': true} : null;
        });
    // Like an app-wide zoom: laid out at 300x200, painted at 1.1x.
    await tester.pumpWidget(
      Transform.scale(
        scale: 1.1,
        alignment: Alignment.topLeft,
        child: _host(const KogiWebView(html: '<p>zoomed</p>')),
      ),
    );
    await tester.pump();
    await tester.pump();

    final place = calls.lastWhere((c) => c.method == 'place');
    final args = (place.arguments as Map).cast<String, Object?>();
    expect(args['sw'] as double, closeTo(330, 1e-6));
    expect(args['sh'] as double, closeTo(220, 1e-6));
    expect(args['zoom'] as double, closeTo(1.1, 1e-6));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('falls back when the native side cannot block the network', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return call.method == 'create' ? {'wayland': true} : null;
        });
    var unavailable = 0;
    await tester.pumpWidget(
      _host(
        KogiWebView(
          html: '<p>x</p>',
          fallback: const Text('fallback'),
          onUnavailable: () => unavailable++,
        ),
      ),
    );
    await tester.pump();
    final id =
        (calls.firstWhere((c) => c.method == 'create').arguments as Map)['id'];
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _channel.name,
          _channel.codec.encodeMethodCall(
            MethodCall('unavailable', {'id': id}),
          ),
          (_) {},
        );
    await tester.pump();
    expect(find.text('fallback'), findsOneWidget);
    expect(unavailable, 1);
    expect(calls.last.method, 'dispose');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
