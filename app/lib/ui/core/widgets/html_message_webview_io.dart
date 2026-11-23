import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:kogi_webview/kogi_webview.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/platform/file_io.dart';
import '../kit/kit.dart';
import 'html_message_document.dart';

/// Builds a lazy, sandboxed platform WebView for HTML email on Desktop and
/// Mobile (`AGENTS.md` rule 5):
/// - **Linux:** a live WebKitGTK view from `packages/kogi_webview`, shown
///   through a hole in Flutter's frame so it scrolls, clips and sits under
///   dialogs like Flutter content. JavaScript and network loads are off.
/// - **Windows / macOS / Android / iOS:** Native OS WebView via
///   `flutter_inappwebview` (WebView2 / WKWebView / Android WebView) with
///   JavaScript disabled and external link interception.
/// - **Headless tests:** Returns [fallback] cleanly when no native WebView
///   platform implementation is registered.
Widget? buildPlatformSandboxedWebView({
  required String sanitizedHtml,
  required bool designed,
  required String ink,
  required String link,
  required String bg,
  required double height,
  required Widget fallback,
  bool allowRemoteContent = false,
  ValueChanged<String>? onOpenUrl,
}) {
  final document = buildSandboxedEmailDocument(
    sanitizedHtml,
    designed: designed,
    ink: ink,
    link: link,
    bg: bg,
  );
  if (Platform.isLinux) {
    return _LinuxHtmlView(
      document: document,
      background: designed ? const Color(0xFFFFFFFF) : _parseHex(bg),
      frameHeight: height,
      allowRemoteContent: allowRemoteContent,
      fallback: fallback,
      onOpenUrl: onOpenUrl ?? openExternalUrl,
    );
  }
  if (Platform.isWindows ||
      Platform.isMacOS ||
      Platform.isAndroid ||
      Platform.isIOS) {
    if (InAppWebViewPlatform.instance == null) return fallback;
    return _InAppWebViewHtmlView(
      document: document,
      designed: designed,
      height: height,
      onOpenUrl: onOpenUrl,
    );
  }
  return fallback;
}

Color _parseHex(String hex) {
  final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0;
  return Color(hex.length <= 7 ? 0xFF000000 | v : v);
}

/// Linux: the message sized to its content so it scrolls with the reader.
/// Very tall messages get the reader's frame height and scroll inside it, so
/// the native view never grows past what WebKit can paint cheaply.
class _LinuxHtmlView extends StatefulWidget {
  const _LinuxHtmlView({
    required this.document,
    required this.background,
    required this.frameHeight,
    required this.allowRemoteContent,
    required this.fallback,
    required this.onOpenUrl,
  });

  final String document;
  final Color background;
  final double frameHeight;
  final bool allowRemoteContent;
  final Widget fallback;
  final ValueChanged<String> onOpenUrl;

  @override
  State<_LinuxHtmlView> createState() => _LinuxHtmlViewState();
}

class _LinuxHtmlViewState extends State<_LinuxHtmlView> {
  static const _maxContentHeight = 12000.0;
  static const _minHeight = 48.0;

  double? _contentHeight;
  bool _unavailable = !KogiWebView.isPlatformSupported;

  @override
  void didUpdateWidget(_LinuxHtmlView old) {
    super.didUpdateWidget(old);
    if (old.document != widget.document) _contentHeight = null;
  }

  void _menu(KogiWebViewContextMenu m) {
    final link = m.link;
    showColectoContextMenu(
      context: context,
      globalPosition: m.globalPosition,
      items: [
        if (m.hasSelection)
          ColectoMenuItem(
            label: 'Copy',
            icon: LucideIcons.copy,
            onSelected: m.copySelection,
          ),
        if (link != null) ...[
          ColectoMenuItem(
            label: 'Open link',
            icon: LucideIcons.externalLink,
            onSelected: () => widget.onOpenUrl(link),
          ),
          ColectoMenuItem(
            label: 'Copy link',
            icon: LucideIcons.link,
            onSelected: () => Clipboard.setData(ClipboardData(text: link)),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Without the native view (tests, a runner without the overlay) the
    // Flutter renderer lays out at its natural height.
    if (_unavailable) return widget.fallback;
    final content = _contentHeight;
    final tall = content != null && content > _maxContentHeight;
    final height = content == null || tall
        ? widget.frameHeight
        : content.clamp(_minHeight, _maxContentHeight);
    return SizedBox(
      height: height,
      child: KogiWebView(
        html: widget.document,
        background: widget.background,
        blockNetwork: !widget.allowRemoteContent,
        scrollsInternally: tall,
        onContentHeight: (h) {
          if (mounted && h != _contentHeight) {
            setState(() => _contentHeight = h);
          }
        },
        onLinkTap: widget.onOpenUrl,
        onContextMenu: _menu,
        onUnavailable: () {
          if (mounted) setState(() => _unavailable = true);
        },
      ),
    );
  }
}

/// Native OS WebView for Windows (WebView2), macOS (WKWebView), Android
/// (Android WebView), and iOS (WKWebView) via `flutter_inappwebview`.
class _InAppWebViewHtmlView extends StatelessWidget {
  const _InAppWebViewHtmlView({
    required this.document,
    required this.designed,
    required this.height,
    this.onOpenUrl,
  });

  final String document;
  final bool designed;
  final double height;
  final ValueChanged<String>? onOpenUrl;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(designed ? 8 : 0),
      child: SizedBox(
        height: height,
        child: InAppWebView(
          key: ValueKey(Object.hash(designed, document)),
          initialData: InAppWebViewInitialData(
            data: document,
            mimeType: 'text/html',
            encoding: 'utf-8',
            baseUrl: WebUri('about:blank'),
          ),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: false,
            incognito: true,
            transparentBackground: !designed,
            supportZoom: false,
            useShouldOverrideUrlLoading: true,
            allowsInlineMediaPlayback: false,
            mediaPlaybackRequiresUserGesture: true,
          ),
          shouldOverrideUrlLoading: (controller, navigationAction) async {
            final uri = navigationAction.request.url;
            if (uri == null || uri.toString() == 'about:blank') {
              return NavigationActionPolicy.ALLOW;
            }
            final scheme = uri.scheme.toLowerCase();
            if (scheme == 'http' || scheme == 'https' || scheme == 'mailto') {
              (onOpenUrl ?? openExternalUrl)(uri.toString());
            }
            return NavigationActionPolicy.CANCEL;
          },
        ),
      ),
    );
  }
}
