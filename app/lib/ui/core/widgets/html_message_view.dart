import 'package:material_ui/material_ui.dart';

import '../theme/colecto_palette.dart';
import 'html_message_iframe_stub.dart'
    if (dart.library.js_interop) 'html_message_iframe_web.dart';
import 'html_message_native.dart';

/// Displays Rust-sanitized HTML email:
/// - On Web, inside a real `<iframe sandbox>` via `HtmlElementView`, created
///   once per document and faded in after it paints.
/// - On Desktop/Mobile, via [NativeSanitizedHtmlView] (real HTML5/CSS widget
///   tree with zero WebView RAM).
class HtmlMessageView extends StatelessWidget {
  const HtmlMessageView({
    super.key,
    required this.html,
    required this.plainTextFallback,
    required this.height,
    this.onOpenUrl,
  });

  final String html;
  final String plainTextFallback;
  final double height;
  final ValueChanged<String>? onOpenUrl;

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

  /// Mail that paints its own background or explicit ink colors keeps a light
  /// sheet, so dark text and logos designed for a white canvas stay readable
  /// in dark mode.
  static bool isDesigned(String html) =>
      _bgcolorPattern.hasMatch(html) ||
      _inlineBgColorPattern.hasMatch(html) ||
      _inlineColorPattern.hasMatch(html);

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    final designed = isDesigned(html);
    final frame = buildWebSandboxedHtmlIframe(
      html,
      designed: designed,
      ink: ColectoPalette.toHex(p.bodyInk),
      link: ColectoPalette.toHex(p.accent),
      height: height,
    );
    if (frame != null) return frame;
    return NativeSanitizedHtmlView(
      html: html,
      plainTextFallback: plainTextFallback,
      designed: designed,
      onOpenUrl: onOpenUrl,
    );
  }
}
