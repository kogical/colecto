import 'package:material_ui/material_ui.dart';

import '../theme/colecto_palette.dart';
import 'html_message_iframe_stub.dart'
    if (dart.library.js_interop) 'html_message_iframe_web.dart';
import 'html_message_native.dart';
import 'html_message_webview_stub.dart'
    if (dart.library.io) 'html_message_webview_io.dart';

/// Displays Rust-sanitized HTML email (`AGENTS.md` rule 5):
/// - On Web, inside a real `<iframe sandbox>` via `HtmlElementView`.
/// - On Linux, inside a live WebKitGTK view from `packages/kogi_webview`
///   composited under Flutter (JS and, unless allowed, network loads off).
/// - On Windows/macOS/Android/iOS, inside a lazy `InAppWebView` (JS disabled).
/// - In headless widget tests (or when no platform WebView is available), falls
///   back cleanly to [NativeSanitizedHtmlView].
class HtmlMessageView extends StatelessWidget {
  const HtmlMessageView({
    super.key,
    required this.html,
    required this.plainTextFallback,
    required this.height,
    this.allowRemoteContent = false,
    this.onOpenUrl,
  });

  final String html;
  final String plainTextFallback;
  final double height;

  /// The owner chose to load remote images for this message; WebViews that
  /// can block network loads (Linux) otherwise block them all.
  final bool allowRemoteContent;
  final ValueChanged<String>? onOpenUrl;

  static final _styleTagPattern = RegExp(r'<style\b', caseSensitive: false);
  static final _bgcolorPattern = RegExp(r'\bbgcolor\s*=', caseSensitive: false);
  static final _inlineBgColorPattern = RegExp(
    r'background-color\s*:\s*(?!transparent\b|inherit\b|initial\b|unset\b)[^;"'
    "'"
    r']+',
    caseSensitive: false,
  );
  static final _inlineColorPattern = RegExp(
    r'(?:^|[;"'
    "'"
    r'\s])color\s*:\s*(?!inherit\b|currentcolor\b|initial\b|unset\b)[^;"'
    "'"
    r']+',
    caseSensitive: false,
  );

  /// Mail that paints its own background, carries a `<style>` sheet, or sets
  /// explicit ink colors keeps a light sheet so dark text and logos designed
  /// for a white canvas stay readable in dark mode.
  static bool isDesigned(String html) =>
      _styleTagPattern.hasMatch(html) ||
      _bgcolorPattern.hasMatch(html) ||
      _inlineBgColorPattern.hasMatch(html) ||
      _inlineColorPattern.hasMatch(html);

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    final designed = isDesigned(html);
    final ink = ColectoPalette.toHex(p.bodyInk);
    final link = ColectoPalette.toHex(p.accent);
    final bg = ColectoPalette.toHex(p.bg);

    final frame = buildWebSandboxedHtmlIframe(
      html,
      designed: designed,
      ink: ink,
      link: link,
      height: height,
    );
    if (frame != null) return frame;

    final fallback = NativeSanitizedHtmlView(
      html: html,
      plainTextFallback: plainTextFallback,
      designed: designed,
      onOpenUrl: onOpenUrl,
    );

    final webView = buildPlatformSandboxedWebView(
      sanitizedHtml: html,
      designed: designed,
      ink: ink,
      link: link,
      bg: bg,
      height: height,
      fallback: fallback,
      allowRemoteContent: allowRemoteContent,
      onOpenUrl: onOpenUrl,
    );
    return webView ?? fallback;
  }
}
