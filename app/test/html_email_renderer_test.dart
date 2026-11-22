import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

import 'package:colecto/ui/core/theme/colecto_palette.dart';
import 'package:colecto/ui/core/widgets/html_message_native.dart';
import 'package:colecto/ui/core/widgets/html_message_view.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Builds a valid solid-color RGBA PNG of exact dimensions [width]×[height]
/// and encodes it as a `data:image/png;base64,...` URI for deterministic,
/// zero-network widget tests.
String _pngDataUri(
  int width,
  int height, {
  int r = 56,
  int g = 139,
  int b = 253,
}) {
  final raw = BytesBuilder(copy: false);
  final row = Uint8List(1 + width * 4);
  row[0] = 0; // filter type: None
  for (var x = 0; x < width; x++) {
    final o = 1 + x * 4;
    row[o] = r;
    row[o + 1] = g;
    row[o + 2] = b;
    row[o + 3] = 255;
  }
  for (var y = 0; y < height; y++) {
    raw.add(row);
  }

  final compressed = zlib.encode(raw.takeBytes());
  final out = BytesBuilder(copy: false)
    ..add(const [137, 80, 78, 71, 13, 10, 26, 10]); // PNG signature

  void chunk(String type, List<int> data) {
    final typeBytes = ascii.encode(type);
    final header = ByteData(4)..setUint32(0, data.length);
    out.add(header.buffer.asUint8List());
    out.add(typeBytes);
    out.add(data);
    final crcInput = Uint8List(typeBytes.length + data.length)
      ..setAll(0, typeBytes)
      ..setAll(typeBytes.length, data);
    final crc = ByteData(4)..setUint32(0, _crc32(crcInput));
    out.add(crc.buffer.asUint8List());
  }

  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 6) // RGBA
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  chunk('IHDR', ihdr.buffer.asUint8List());
  chunk('IDAT', compressed);
  chunk('IEND', const []);

  return 'data:image/png;base64,${base64Encode(out.takeBytes())}';
}

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0xEDB88320 : (crc >>> 1);
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

// ── 5 complex real-world corporate HTML email templates ──────────────────
// Each represents Rust-sanitized HTML (safe inline CSS + `cid:` resolved to
// `data:image/png;base64,...` + blocked remote images stripped of `src`).

final _icon32 = _pngDataUri(32, 32, r: 36, g: 41, b: 47);
final _icon64Retina = _pngDataUri(64, 64, r: 36, g: 41, b: 47);
final _icon24 = _pngDataUri(24, 24, r: 207, g: 34, b: 46);
final _icon20 = _pngDataUri(20, 20, r: 87, g: 96, b: 106);
final _thumb80 = _pngDataUri(80, 80, r: 255, g: 153, b: 0);
final _hero1200 = _pngDataUri(1200, 300, r: 15, g: 118, b: 110);
final _pixel1 = _pngDataUri(1, 1, r: 255, g: 255, b: 255);

/// 1. GitHub Actions workflow failure notification (nested layout tables,
///    small 32×32 brand icon & 24×24 status badge, hidden preheader, job table,
///    inline `<code>` ref, styled CTA button).
final _githubActionsHtml =
    '''
<div style="display:none;max-height:0px;overflow:hidden">
  HIDDEN_PREHEADER_GITHUB_RUN_FAILED
</div>
<table width="100%" cellpadding="0" cellspacing="0" bgcolor="#ffffff" style="background-color:#ffffff;color:#24292f">
  <tr>
    <td align="center" style="padding:24px 16px">
      <table width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%">
        <tr>
          <td align="center" style="padding-bottom:16px">
            <img src="$_icon64Retina" width="32" height="32" alt="GitHub" style="width:32px;height:32px">
          </td>
        </tr>
        <tr>
          <td align="center" style="padding-bottom:12px">
            <h2 style="margin:0;font-size:20px;font-weight:600;color:#24292f">[acme/widget] Release workflow run</h2>
          </td>
        </tr>
        <tr>
          <td align="center" style="padding-bottom:16px">
            <img src="$_icon24" alt="Workflow failed">
          </td>
        </tr>
        <tr>
          <td style="border:1px solid #d0d7de;border-radius:6px;padding:16px">
            <table width="100%" cellpadding="6" cellspacing="0">
              <tr>
                <td style="font-weight:600;color:#24292f">Repository</td>
                <td style="color:#57606a"><code>acme/widget</code></td>
              </tr>
              <tr>
                <td style="font-weight:600;color:#24292f">Branch</td>
                <td style="color:#57606a"><code>release/v2.4.0</code></td>
              </tr>
              <tr>
                <td style="font-weight:600;color:#24292f">Failed job</td>
                <td style="color:#cf222e">Build Linux AppImage</td>
              </tr>
            </table>
            <p align="center" style="margin:16px 0 0 0">
              <a href="https://github.com/acme/widget/actions/runs/12345" style="display:inline-block;background-color:#2da44e;color:#ffffff;padding:8px 16px;border-radius:6px;text-decoration:none;font-weight:600">View workflow run</a>
            </p>
          </td>
        </tr>
      </table>
    </td>
  </tr>
</table>
''';

/// 2. Stripe payment receipt / invoice (outer `bgcolor`, white 600px card,
///    multi-column line-item table with `colspan` and right-aligned totals,
///    HTML entities).
final _stripeReceiptHtml =
    '''
<table width="100%" cellpadding="0" cellspacing="0" bgcolor="#f6f9fc" style="background-color:#f6f9fc;padding:24px 0">
  <tr>
    <td align="center">
      <table width="600" cellpadding="0" cellspacing="0" bgcolor="#ffffff" style="background-color:#ffffff;border-radius:8px;max-width:600px;width:100%">
        <tr>
          <td style="padding:24px 28px">
            <img src="$_icon32" width="32" height="32" alt="Acme Cloud">
            <h1 style="font-size:22px;color:#0a2540;margin:12px 0 4px 0">Receipt from Acme Cloud</h1>
            <p style="color:#425466;margin:0 0 16px 0">Receipt #2048-9912 &mdash; Paid Nov 21, 2026</p>
            <hr>
            <table width="100%" cellpadding="8" cellspacing="0" style="border-collapse:collapse">
              <tr>
                <th align="left" style="color:#425466;border-bottom:1px solid #e6ebf1">Description</th>
                <th align="right" style="color:#425466;border-bottom:1px solid #e6ebf1;text-align:right">Amount</th>
              </tr>
              <tr>
                <td style="color:#0a2540">Pro Workspace &bull; Monthly</td>
                <td align="right" style="color:#0a2540;text-align:right">\$49.00</td>
              </tr>
              <tr>
                <td style="color:#0a2540">Additional build minutes (500)</td>
                <td align="right" style="color:#0a2540;text-align:right">\$10.00</td>
              </tr>
              <tr>
                <td colspan="2" style="border-top:1px solid #e6ebf1;padding-top:10px;font-weight:700;color:#0a2540">Amount paid: \$59.00 USD</td>
              </tr>
            </table>
            <p style="font-size:12px;color:#697386;margin-top:16px">
              Questions? Visit <a href="https://billing.acme.example/support">Acme Billing Support</a> &copy; 2026 Acme Inc.
            </p>
          </td>
        </tr>
      </table>
    </td>
  </tr>
</table>
''';

/// 3. Linear / Notion workspace digest (deeply nested `<div>` cards that broke
///    the old non-greedy regex, avatar icon, `<blockquote>`, nested lists,
///    `<pre><code>` snippet).
final _linearDigestHtml =
    '''
<div style="background-color:#ffffff;color:#1f2328;padding:16px">
  <div style="border:1px solid #e5e7eb;border-radius:8px;padding:16px">
    <div style="margin-bottom:12px">
      <img src="$_icon24" width="24" height="24" alt="Alex" style="width:24px;height:24px;border-radius:50%">
      <strong>Alex Rivera</strong> mentioned you in <code>ENG-412</code>
    </div>
    <div>
      <div>
        <blockquote>
          We should ship the DOM-based renderer before cutting the next beta.
        </blockquote>
      </div>
      <ul>
        <li>Preserve <strong>safe inline styles</strong> in <code>ammonia</code></li>
        <li>Stop upscaling <em>small icons</em> to 380px</li>
        <li>Verify <a href="https://linear.acme.example/issue/ENG-412">issue ENG-412</a> on narrow viewports</li>
      </ul>
      <pre><code>flutter test test/html_email_renderer_test.dart</code></pre>
    </div>
  </div>
</div>
''';

/// 4. E-commerce order & shipping confirmation (wide 640px product table,
///    80×80 thumbnail, 3-column tracker, `<br>` address, oversized 1200×300
///    promo banner, 1×1 tracking pixel, and a blocked remote image with no src).
final _ecommerceOrderHtml =
    '''
<table width="640" cellpadding="0" cellspacing="0" bgcolor="#ffffff" style="background-color:#ffffff;color:#111111">
  <tr>
    <td>
      <img src="$_hero1200" width="1200" height="300" alt="Seasonal banner">
      <img alt="Blocked remote tracking logo" width="120" height="40">
    </td>
  </tr>
  <tr>
    <td style="padding:16px">
      <h2 style="margin:0 0 8px 0">Your order has shipped</h2>
      <p>Order #ORD-88421 is on its way to:<br>Samira Patel<br>742 Evergreen Terrace<br>Portland, OR 97205</p>
      <table width="100%" cellpadding="8" cellspacing="0" style="border:1px solid #dddddd">
        <tr>
          <td width="88"><img src="$_thumb80" width="80" height="80" alt="Mechanical keyboard"></td>
          <td>
            <strong>Split Ergonomic Keyboard</strong><br>
            Qty: 1 &bull; Tactile switches
          </td>
          <td align="right" style="text-align:right">\$189.00</td>
        </tr>
      </table>
      <table width="100%" cellpadding="6" cellspacing="0" style="margin-top:12px">
        <tr>
          <td align="center" style="background-color:#e6f4ea;color:#137333">Ordered</td>
          <td align="center" style="background-color:#e6f4ea;color:#137333">Shipped</td>
          <td align="center" style="background-color:#f1f3f4;color:#5f6368">Delivered</td>
        </tr>
      </table>
      <p style="margin-top:12px"><a href="https://shop.acme.example/track/ORD-88421">Track your package</a></p>
      <img src="$_pixel1" width="1" height="1" alt="">
    </td>
  </tr>
</table>
''';

/// 5. Substack / engineering newsletter (hidden preheader, H1/H2/H3 hierarchy,
///    pull-quote, mixed inline formatting, linked image, ordered + unordered
///    lists, `<hr>`, social icon row).
final _newsletterHtml =
    '''
<div style="display:none;max-height:0px;overflow:hidden">HIDDEN_NEWSLETTER_PREVIEW</div>
<div style="background-color:#ffffff;color:#1a1a1a;padding:16px">
  <h1>Systems Weekly #142</h1>
  <h2>Why email HTML still uses tables in 2026</h2>
  <p>Modern mail clients balance <strong>security</strong>, <em>typography</em>, and <del>legacy hacks</del> clean sandboxing.</p>
  <blockquote>Good rendering starts with a real HTML5 parser, never a regex.</blockquote>
  <p>
    <a href="https://newsletter.acme.example/issue-142">
      <img src="$_hero1200" width="480" height="120" alt="Read full essay">
    </a>
  </p>
  <h3>Three takeaways</h3>
  <ol>
    <li>Respect explicit image dimensions and intrinsic size.</li>
    <li>Keep remote images blocked by default.</li>
    <li>Render designed emails on a readable light sheet.</li>
  </ol>
  <hr>
  <p style="font-size:12px;color:#666666">
    <img src="$_icon20" width="20" height="20" alt="Feed">
    <a href="https://newsletter.acme.example/unsubscribe">Unsubscribe</a>
  </p>
</div>
''';

/// Pumps [HtmlMessageView] inside the same `SingleChildScrollView` +
/// `SelectionArea` + `ConstrainedBox` scaffolding that `ReaderPane` uses.
Future<void> _pumpEmail(
  WidgetTester tester, {
  required String html,
  required double width,
  Brightness brightness = Brightness.dark,
  ValueChanged<String>? onOpenUrl,
  bool expectNativeFallback = true,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final palette = brightness == Brightness.dark
      ? ColectoPalette.dark()
      : ColectoPalette.light();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness, extensions: [palette]),
      home: Scaffold(
        backgroundColor: palette.bg,
        body: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 780),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SelectionArea(
                  child: HtmlMessageView(
                    html: html,
                    plainTextFallback: 'Plain fallback',
                    height: 600,
                    onOpenUrl: onOpenUrl,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // Let the platform WebView probe complete on the real platform channel and
  // fall back to NativeSanitizedHtmlView in headless tests, then decode inline
  // PNG data URIs deterministically.
  await tester.pump();
  if (expectNativeFallback) {
    for (var i = 0; i < 40; i++) {
      if (find.byType(NativeSanitizedHtmlView).evaluate().isNotEmpty) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    for (final element in find.byType(Image).evaluate()) {
      final image = element.widget as Image;
      await precacheImage(image.image, element);
    }
  });
  await tester.pumpAndSettle();
}

Finder _richText(String pattern) =>
    find.textContaining(pattern, findRichText: true);

void main() {
  group('HtmlMessageView.isDesigned', () {
    test('detects designed corporate emails vs simple HTML', () {
      expect(HtmlMessageView.isDesigned(_githubActionsHtml), isTrue);
      expect(HtmlMessageView.isDesigned(_stripeReceiptHtml), isTrue);
      expect(HtmlMessageView.isDesigned(_linearDigestHtml), isTrue);
      expect(HtmlMessageView.isDesigned(_ecommerceOrderHtml), isTrue);
      expect(HtmlMessageView.isDesigned(_newsletterHtml), isTrue);

      expect(
        HtmlMessageView.isDesigned(
          '<p>Hey, are we still on for <strong>Thursday</strong>?</p>',
        ),
        isFalse,
      );
      expect(
        HtmlMessageView.isDesigned(
          '<p style="background-color:transparent">Plain note</p>',
        ),
        isFalse,
      );
    });
  });

  group('Real-world corporate HTML email rendering', () {
    testWidgets(
      '1. GitHub Actions email preserves small icon sizes, hides preheader, and renders table + CTA',
      (tester) async {
        final openedUrls = <String>[];
        await _pumpEmail(
          tester,
          html: _githubActionsHtml,
          width: 780,
          onOpenUrl: openedUrls.add,
        );
        expect(tester.takeException(), isNull);

        // Hidden preheader must not be visibly rendered.
        expect(_richText('HIDDEN_PREHEADER_GITHUB_RUN_FAILED'), findsNothing);

        // Key headings, table cells, and CTA survive nested tables.
        expect(_richText('[acme/widget] Release workflow run'), findsOneWidget);
        expect(_richText('Build Linux AppImage'), findsOneWidget);
        expect(_richText('release/v2.4.0'), findsOneWidget);
        expect(_richText('View workflow run'), findsOneWidget);

        // Regression check for the giant pixelated Octocat / Actions icons:
        // neither the 32×32 retina logo nor the 24×24 intrinsic icon may upscale.
        final images = tester.widgetList<Image>(find.byType(Image)).toList();
        expect(images.length, 2);
        for (final finder in [
          find.byType(Image).at(0),
          find.byType(Image).at(1),
        ]) {
          final size = tester.getSize(finder);
          expect(
            size.width,
            lessThanOrEqualTo(40),
            reason: 'icon upscaled horizontally: $size',
          );
          expect(
            size.height,
            lessThanOrEqualTo(40),
            reason: 'icon upscaled vertically: $size',
          );
          expect(size.width, greaterThan(0));
          expect(size.height, greaterThan(0));
        }

        // Tapping the CTA link invokes the external URL handler.
        await tester.tap(_richText('View workflow run'));
        await tester.pump();
        expect(openedUrls, [
          'https://github.com/acme/widget/actions/runs/12345',
        ]);
      },
    );

    testWidgets(
      '2. Stripe receipt renders multi-column table, colspan total, and HTML entities cleanly',
      (tester) async {
        await _pumpEmail(tester, html: _stripeReceiptHtml, width: 780);
        expect(tester.takeException(), isNull);

        expect(_richText('Receipt from Acme Cloud'), findsOneWidget);
        expect(_richText('Pro Workspace'), findsOneWidget);
        expect(_richText('\$49.00'), findsOneWidget);
        expect(_richText('Amount paid: \$59.00 USD'), findsOneWidget);
        expect(_richText('Acme Billing Support'), findsOneWidget);
        // Entities decoded properly (not raw `&mdash;` or `&copy;`).
        expect(_richText('&mdash;'), findsNothing);
        expect(_richText('&copy;'), findsNothing);
      },
    );

    testWidgets(
      '3. Linear digest renders deeply nested divs, blockquote, list items, and code block',
      (tester) async {
        await _pumpEmail(tester, html: _linearDigestHtml, width: 780);
        expect(tester.takeException(), isNull);

        expect(_richText('Alex Rivera'), findsOneWidget);
        expect(_richText('ENG-412'), findsWidgets);
        expect(
          _richText('DOM-based renderer before cutting the next beta'),
          findsOneWidget,
        );
        expect(_richText('safe inline styles'), findsOneWidget);
        expect(
          _richText('flutter test test/html_email_renderer_test.dart'),
          findsOneWidget,
        );

        // 24×24 avatar stays small.
        final avatarSize = tester.getSize(find.byType(Image).first);
        expect(avatarSize.width, lessThanOrEqualTo(32));
        expect(avatarSize.height, lessThanOrEqualTo(32));
      },
    );

    testWidgets(
      '4. E-commerce order constrains oversized 1200px banner and hides blocked images',
      (tester) async {
        await _pumpEmail(tester, html: _ecommerceOrderHtml, width: 780);
        expect(tester.takeException(), isNull);

        expect(_richText('Your order has shipped'), findsOneWidget);
        expect(_richText('Split Ergonomic Keyboard'), findsOneWidget);
        expect(_richText('\$189.00'), findsOneWidget);
        expect(_richText('Shipped'), findsOneWidget);

        // Oversized 1200×300 banner must fit inside the viewport (<= 748px).
        final bannerSize = tester.getSize(find.byType(Image).first);
        expect(bannerSize.width, lessThanOrEqualTo(748));
        expect(bannerSize.height, greaterThan(0));

        // 1×1 tracking pixel stays tiny.
        final pixelSize = tester.getSize(find.byType(Image).last);
        expect(pixelSize.width, lessThanOrEqualTo(4));
        expect(pixelSize.height, lessThanOrEqualTo(4));
      },
    );

    testWidgets(
      '5. Newsletter renders headings, linked image, lists, and hides preheader',
      (tester) async {
        await _pumpEmail(tester, html: _newsletterHtml, width: 780);
        expect(tester.takeException(), isNull);

        expect(_richText('HIDDEN_NEWSLETTER_PREVIEW'), findsNothing);
        expect(_richText('Systems Weekly #142'), findsOneWidget);
        expect(
          _richText('Why email HTML still uses tables in 2026'),
          findsOneWidget,
        );
        expect(_richText('Respect explicit image dimensions'), findsOneWidget);
        expect(_richText('Unsubscribe'), findsOneWidget);
      },
    );

    testWidgets(
      'all 5 corporate templates render without overflow on a narrow 360px phone viewport',
      (tester) async {
        for (final entry in [
          ('GitHub Actions', _githubActionsHtml),
          ('Stripe Receipt', _stripeReceiptHtml),
          ('Linear Digest', _linearDigestHtml),
          ('E-Commerce Order', _ecommerceOrderHtml),
          ('Newsletter', _newsletterHtml),
        ]) {
          await _pumpEmail(
            tester,
            html: entry.$2,
            width: 360,
            brightness: Brightness.light,
          );
          expect(
            tester.takeException(),
            isNull,
            reason: '${entry.$1} overflowed or threw on 360px viewport',
          );
        }
      },
    );

    testWidgets(
      'simple personal HTML renders transparently without light sheet',
      (tester) async {
        await _pumpEmail(
          tester,
          html: '<p>Hey team,</p><p>See the <a href="https://colecto.dev">docs</a>.</p>',
          width: 780,
        );
        expect(tester.takeException(), isNull);
        expect(_richText('Hey team,'), findsOneWidget);
        expect(_richText('docs'), findsOneWidget);
        // No white sheet ColoredBox for simple plain-ish HTML.
        final whiteBoxes = tester
            .widgetList<ColoredBox>(find.byType(ColoredBox))
            .where((b) => b.color == const Color(0xFFFFFFFF));
        expect(whiteBoxes, isEmpty);
      },
    );

    testWidgets(
      'Linux WebKitGTK channel loads sanitized document and disposes on unmount',
      (tester) async {
        const channel = MethodChannel('com.kogical.colecto/webview');
        final calls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            calls.add(call);
            return call.method == 'loadHtml' ? true : null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );

        await _pumpEmail(
          tester,
          html: '<style>.preheader{display:none}</style><div class="preheader">Hidden</div><p>Hello</p>',
          width: 780,
          expectNativeFallback: false,
        );

        expect(calls.any((c) => c.method == 'loadHtml'), isTrue);
        final loadArgs =
            calls.firstWhere((c) => c.method == 'loadHtml').arguments
                as Map<Object?, Object?>;
        expect(
          loadArgs['html'],
          contains('<style>.preheader{display:none}</style>'),
        );
        expect(loadArgs['bg'], '#ffffff');

        // Unmounting the reader destroys the native WebKitGTK view (0 idle RAM).
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(calls.any((c) => c.method == 'dispose'), isTrue);
      },
    );
  });
}
