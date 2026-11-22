import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../data/platform/file_io.dart';
import 'html_message_document.dart';

const _linuxWebViewChannel = MethodChannel('com.kogical.colecto/webview');

/// Builds a lazy, sandboxed platform WebView for HTML email on Desktop and
/// Mobile (`AGENTS.md` rule 5):
/// - **Linux:** First-party ephemeral WebKitGTK 4.1 (`webkit2gtk-4.1`) with
///   JavaScript disabled and external link interception.
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
  ValueChanged<String>? onOpenUrl,
}) {
  if (kIsWeb) return null;
  final document = buildSandboxedEmailDocument(
    sanitizedHtml,
    designed: designed,
    ink: ink,
    link: link,
    bg: bg,
  );
  if (Platform.isLinux) {
    return _LinuxWebKitHtmlView(
      document: document,
      designed: designed,
      bg: designed ? '#ffffff' : bg,
      height: height,
      fallback: fallback,
      onOpenUrl: onOpenUrl,
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

/// Linux WebKitGTK 4.1 host widget synced to the native `GtkOverlay` child.
///
/// Automatically hides the overlay whenever another route (Settings, Command
/// Palette, dialogs, menus) is pushed above the reader, and destroys the
/// WebKitGTK instance on [dispose] so zero WebView RAM stays alive when no
/// HTML email is open.
class _LinuxWebKitHtmlView extends StatefulWidget {
  const _LinuxWebKitHtmlView({
    required this.document,
    required this.designed,
    required this.bg,
    required this.height,
    required this.fallback,
    this.onOpenUrl,
  });

  final String document;
  final bool designed;
  final String bg;
  final double height;
  final Widget fallback;
  final ValueChanged<String>? onOpenUrl;

  @override
  State<_LinuxWebKitHtmlView> createState() => _LinuxWebKitHtmlViewState();
}

class _LinuxWebKitHtmlViewState extends State<_LinuxWebKitHtmlView>
    with WidgetsBindingObserver {
  final _slotKey = GlobalKey();
  ScrollPosition? _scrollPosition;
  bool _pluginMissing = false;
  bool _loaded = false;
  Rect? _lastRect;
  bool _lastVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _linuxWebViewChannel.setMethodCallHandler(_handleNativeCall);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync(reload: true));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextPos = Scrollable.maybeOf(context)?.position;
    if (nextPos != _scrollPosition) {
      _scrollPosition?.removeListener(_onScroll);
      _scrollPosition = nextPos;
      _scrollPosition?.addListener(_onScroll);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync(reload: false));
  }

  @override
  void didUpdateWidget(_LinuxWebKitHtmlView old) {
    super.didUpdateWidget(old);
    final changed = old.document != widget.document || old.bg != widget.bg;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _sync(reload: changed || !_loaded),
    );
  }

  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync(reload: false));
  }

  void _onScroll() {
    _sync(reload: false);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'openUrl' && call.arguments is String) {
      final url = call.arguments as String;
      (widget.onOpenUrl ?? openExternalUrl)(url);
    }
    return null;
  }

  @override
  void dispose() {
    _scrollPosition?.removeListener(_onScroll);
    WidgetsBinding.instance.removeObserver(this);
    _linuxWebViewChannel.setMethodCallHandler(null);
    if (!_pluginMissing) {
      unawaited(
        _linuxWebViewChannel.invokeMethod<void>('dispose').catchError((_) {}),
      );
    }
    super.dispose();
  }

  Rect? _measureVisibleRect() {
    final renderBox = _slotKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize || !renderBox.attached) {
      return null;
    }
    final topLeft = renderBox.localToGlobal(Offset.zero);
    var rect = topLeft & renderBox.size;

    // Clip to the enclosing Scrollable's viewport so the GTK overlay never
    // overlaps the sticky reader toolbar or top bar.
    final scrollBox =
        Scrollable.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    if (scrollBox != null && scrollBox.hasSize && scrollBox.attached) {
      final clip = scrollBox.localToGlobal(Offset.zero) & scrollBox.size;
      rect = rect.intersect(clip);
    }
    if (rect.width <= 1 || rect.height <= 1) return null;
    return rect;
  }

  Future<void> _sync({required bool reload}) async {
    if (!mounted || _pluginMissing) return;
    final routeCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    final rect = routeCurrent ? _measureVisibleRect() : null;
    final visible = routeCurrent && rect != null;

    try {
      if (reload) {
        _loaded = true;
        _lastRect = rect;
        _lastVisible = visible;
        final ok = await _linuxWebViewChannel.invokeMethod<bool>('loadHtml', {
          'html': widget.document,
          'bg': widget.bg,
          'x': rect?.left.round() ?? 0,
          'y': rect?.top.round() ?? 0,
          'width': rect?.width.round() ?? 0,
          'height': rect?.height.round() ?? 0,
          'visible': visible,
        });
        if (ok != true && mounted) {
          setState(() => _pluginMissing = true);
        }
      } else if (visible != _lastVisible || rect != _lastRect) {
        _lastRect = rect;
        _lastVisible = visible;
        await _linuxWebViewChannel.invokeMethod<void>('updateRect', {
          'x': rect?.left.round() ?? 0,
          'y': rect?.top.round() ?? 0,
          'width': rect?.width.round() ?? 0,
          'height': rect?.height.round() ?? 0,
          'visible': visible,
        });
      }
    } on MissingPluginException {
      if (mounted) setState(() => _pluginMissing = true);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_pluginMissing) return widget.fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.designed ? 8 : 0),
      child: ColoredBox(
        color: widget.designed
            ? const Color(0xFFFFFFFF)
            : const Color(0x00000000),
        child: SizedBox(
          key: _slotKey,
          width: double.infinity,
          height: widget.height,
        ),
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
