import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'coordinator.dart';

/// A right-click (or Menu key) inside a [KogiWebView].
@immutable
class KogiWebViewContextMenu {
  const KogiWebViewContextMenu({
    required this.globalPosition,
    required this.link,
    required this.hasSelection,
    required this.copySelection,
  });

  /// Where the menu was requested, in Flutter global coordinates.
  final Offset globalPosition;

  /// The link under the pointer, if any.
  final String? link;

  /// Whether the click landed on selected text.
  final bool hasSelection;

  /// Copies the view's current selection to the clipboard.
  final VoidCallback copySelection;
}

/// A live WebKitGTK view that composites like ordinary Flutter content on
/// Linux: it clips to scroll viewports, scrolls with the page, sits under
/// Flutter popups and dialogs, and keeps native text selection and links.
///
/// The view fills the size its parent gives it; report [onContentHeight] to
/// size it to the document. Navigation never happens inside the view: every
/// link activation is passed to [onLinkTap]. Page JavaScript is disabled, and
/// [blockNetwork] (on by default) stops all `http(s)`/`ws(s)`/`ftp` loads.
///
/// On other platforms, or when the runner is not set up (see the README), it
/// builds [fallback].
class KogiWebView extends StatefulWidget {
  const KogiWebView({
    super.key,
    required this.html,
    this.background = const Color(0xFFFFFFFF),
    this.blockNetwork = true,
    this.scrollsInternally = false,
    this.onLinkTap,
    this.onContentHeight,
    this.onContextMenu,
    this.onUnavailable,
    this.fallback,
  });

  /// The document to show. It is loaded with an `about:blank` base URL.
  final String html;

  /// Painted behind the document, and by Flutter until it first loads.
  final Color background;

  /// Blocks every network fetch (remote images, fonts, tracking pixels).
  final bool blockNetwork;

  /// When true the document scrolls inside the view (use this when the view
  /// is smaller than its content). When false, wheel events over the view
  /// scroll the enclosing Flutter scrollable instead.
  final bool scrollsInternally;

  final ValueChanged<String>? onLinkTap;

  /// The document's content height in logical pixels, after each load and
  /// after the view's width changes.
  final ValueChanged<double>? onContentHeight;

  /// Without a handler, right-clicks inside the view do nothing.
  final ValueChanged<KogiWebViewContextMenu>? onContextMenu;

  /// Called once if the view cannot be shown here (another platform, a
  /// runner without the GtkOverlay, or [blockNetwork] cannot be enforced),
  /// e.g. to swap in a differently sized fallback.
  final VoidCallback? onUnavailable;

  /// Built on unsupported platforms or when the native side is unavailable.
  final Widget? fallback;

  /// Whether this platform can host a [KogiWebView] at all.
  static bool get isPlatformSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  @override
  State<KogiWebView> createState() => _KogiWebViewState();
}

class _KogiWebViewState extends State<KogiWebView>
    implements FrameClient, NativeEvents {
  final Coordinator _c = Coordinator.instance;
  late final int _id = _c.nextId();
  bool _unsupported = !KogiWebView.isPlatformSupported;
  bool _created = false;
  bool _revealed = false;
  bool _wayland = true;
  bool _covered = false;
  ModalRoute<Object?>? _route;
  Map<String, Object>? _lastPlace;
  bool? _lastCovered;

  @override
  void initState() {
    super.initState();
    if (_unsupported) {
      SchedulerBinding.instance.addPostFrameCallback(
        (_) => widget.onUnavailable?.call(),
      );
      return;
    }
    _c.attachView(_id, this, this);
    _create();
  }

  Future<void> _create() async {
    final info = await _c.invoke<Map<Object?, Object?>>('create', {'id': _id});
    if (!mounted) return;
    if (info == null) {
      setState(() => _unsupported = true);
      _c.detachView(_id, this);
      widget.onUnavailable?.call();
      return;
    }
    _created = true;
    _wayland = info['wayland'] == true;
    _load();
    // Make sure a frame runs so the view gets placed even on a static page.
    SchedulerBinding.instance.scheduleFrame();
  }

  void _load() {
    if (!_created) return;
    _c.invoke('load', {
      'id': _id,
      'html': widget.html,
      'background': widget.background.toARGB32(),
      'blockNetwork': widget.blockNetwork,
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void didUpdateWidget(KogiWebView old) {
    super.didUpdateWidget(old);
    if (old.html != widget.html ||
        old.background != widget.background ||
        old.blockNetwork != widget.blockNetwork) {
      _load();
    }
    if (old.scrollsInternally != widget.scrollsInternally) _lastPlace = null;
  }

  @override
  void dispose() {
    if (!_unsupported) {
      _c.detachView(_id, this);
      _c.invoke('dispose', {'id': _id});
    }
    super.dispose();
  }

  // ── Native events ───────────────────────────────────────────────────────

  @override
  void onHeight(double height) {
    if (!mounted) return;
    if (!_revealed) setState(() => _revealed = true);
    if (height > 0) widget.onContentHeight?.call(height);
  }

  @override
  void onLink(String url) => widget.onLinkTap?.call(url);

  @override
  void onUnavailable() {
    // The native side cannot honour this widget's settings (for example the
    // network filter failed to compile), so it refused to load the page.
    if (!mounted || _unsupported) return;
    setState(() => _unsupported = true);
    _c.detachView(_id, this);
    _c.invoke('dispose', {'id': _id});
    widget.onUnavailable?.call();
  }

  @override
  void onContextMenu(Offset globalPosition, String? link, bool hasSelection) {
    widget.onContextMenu?.call(
      KogiWebViewContextMenu(
        globalPosition: globalPosition,
        link: link,
        hasSelection: hasSelection,
        copySelection: () => _c.invoke('copySelection', {'id': _id}),
      ),
    );
  }

  // ── Per-frame placement ─────────────────────────────────────────────────

  @override
  void syncAfterFrame({required bool seen}) {
    if (!_created || !mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    final onScreen = seen && box != null && box.attached && box.hasSize;
    final place = <String, Object>{'id': _id, 'visible': onScreen};
    if (onScreen) {
      final slot = globalBounds(box);
      final clip = _clipRect();
      place.addAll({
        'sx': slot.left,
        'sy': slot.top,
        'sw': slot.width,
        'sh': slot.height,
        'cx': clip.left,
        'cy': clip.top,
        'cw': clip.width,
        'ch': clip.height,
        'internalScroll': widget.scrollsInternally,
        // Scaled ancestors (an app-wide zoom) scale the page with them.
        'zoom': box.size.width > 0 ? slot.width / box.size.width : 1.0,
      });
    }
    if (!mapEquals(place, _lastPlace)) {
      _lastPlace = place;
      _c.invoke('place', place);
    }
    // A route above this one (dialog, menu, sheet) takes WebKit's input.
    final covered = !(_route?.isCurrent ?? true);
    if (covered != _lastCovered) {
      _lastCovered = covered;
      _c.invoke('setCovered', {'id': _id, 'covered': covered});
      // On X11 a covered view is hidden (it would paint over the route), so
      // show its background instead of an empty hole.
      if (!_wayland) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _covered = covered);
        });
      }
    }
  }

  /// The window, narrowed by every enclosing scroll viewport.
  Rect _clipRect() {
    final view = View.maybeOf(context);
    var clip = view == null
        ? Rect.largest
        : Offset.zero & (view.physicalSize / view.devicePixelRatio);
    BuildContext ctx = context;
    for (var s = Scrollable.maybeOf(ctx); s != null;) {
      final rb = s.context.findRenderObject() as RenderBox?;
      if (rb != null && rb.hasSize && rb.attached) {
        clip = clip.intersect(globalBounds(rb));
      }
      ctx = s.context;
      s = Scrollable.maybeOf(ctx);
    }
    return clip;
  }

  @override
  Widget build(BuildContext context) {
    if (_unsupported) return widget.fallback ?? const SizedBox.shrink();
    return _Hole(
      client: this,
      reveal: _revealed && !_covered,
      background: widget.background,
    );
  }
}

/// Paints a transparent hole (BlendMode.clear) through everything Flutter
/// drew beneath it, so the WebKit view composited under Flutter shows
/// through. Until the document has loaded it paints [background] instead.
class _Hole extends LeafRenderObjectWidget {
  const _Hole({
    required this.client,
    required this.reveal,
    required this.background,
  });

  final FrameClient client;
  final bool reveal;
  final Color background;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHole(client, reveal, background);

  @override
  void updateRenderObject(BuildContext context, _RenderHole r) => r
    ..reveal = reveal
    ..background = background;
}

class _RenderHole extends RenderBox {
  _RenderHole(this._client, this._reveal, this._background);

  final FrameClient _client;

  bool _reveal;
  set reveal(bool v) {
    if (v == _reveal) return;
    _reveal = v;
    markNeedsPaint();
  }

  Color _background;
  set background(Color v) {
    if (v == _background) return;
    _background = v;
    markNeedsPaint();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    final rect = offset & size;
    context.canvas.drawRect(
      rect,
      _reveal
          ? (Paint()..blendMode = BlendMode.clear)
          : (Paint()..color = _background),
    );
    context.addLayer(PresenceLayer(_client));
  }
}
