import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'coordinator.dart';
import 'kogi_web_view.dart';

/// Marks Flutter content that can float above a [KogiWebView] without being
/// a route (a toast, an inline popover). While it is on screen, clicks on it
/// reach Flutter instead of the WebKit view underneath.
///
/// Routes (dialogs, menus, sheets) need no occluder: views under a route
/// that is not current stop taking input on their own.
class KogiWebViewOccluder extends SingleChildRenderObjectWidget {
  const KogiWebViewOccluder({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderOccluder();
}

class _RenderOccluder extends RenderProxyBox implements FrameClient {
  final Coordinator _c = Coordinator.instance;
  bool _active = false;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _active = KogiWebView.isPlatformSupported;
    if (_active) _c.attach(this);
  }

  @override
  void detach() {
    if (_active) _c.detach(this);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (_active) context.addLayer(PresenceLayer(this));
  }

  @override
  void syncAfterFrame({required bool seen}) {
    _c.setOccluder(
      this,
      seen && attached && hasSize ? globalBounds(this) : null,
    );
  }
}
