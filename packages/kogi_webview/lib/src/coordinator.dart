import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// Something the coordinator re-syncs after every composited frame.
abstract class FrameClient {
  /// Called once per frame after compositing. [seen] says whether the
  /// client's layer was part of the scene that was just built.
  void syncAfterFrame({required bool seen});
}

/// Owns the method channel and the per-frame bookkeeping shared by every
/// [KogiWebView] and occluder in the app.
class Coordinator {
  Coordinator._() {
    channel.setMethodCallHandler(_onNative);
  }

  static final Coordinator instance = Coordinator._();

  final MethodChannel channel = const MethodChannel('kogi_webview');

  final Map<int, NativeEvents> _views = {};
  final Set<FrameClient> _clients = {};
  final Set<FrameClient> _seen = {};
  final Map<Object, Rect> _occluders = {};
  Float64List? _sentOccluders;
  bool _hooked = false;
  bool _globalRoute = false;
  int _nextId = 1;

  int nextId() => _nextId++;

  void attachView(int id, NativeEvents events, FrameClient client) {
    _views[id] = events;
    attach(client);
    if (!_globalRoute) {
      _globalRoute = true;
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    }
  }

  void detachView(int id, FrameClient client) {
    _views.remove(id);
    detach(client);
    if (_views.isEmpty && _globalRoute) {
      _globalRoute = false;
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    }
  }

  void attach(FrameClient client) {
    _clients.add(client);
    if (!_hooked) {
      _hooked = true;
      // Registered after the rendering binding's own persistent callback, so
      // it runs once layout, paint and compositing for the frame are done.
      SchedulerBinding.instance.addPersistentFrameCallback(_afterFrame);
    }
  }

  void detach(FrameClient client) {
    _clients.remove(client);
    _seen.remove(client);
    setOccluder(client, null);
  }

  void markSeen(FrameClient client) => _seen.add(client);

  void setOccluder(Object owner, Rect? rect) {
    if (rect == null) {
      _occluders.remove(owner);
    } else {
      _occluders[owner] = rect;
    }
  }

  void _afterFrame(Duration _) {
    if (_clients.isEmpty) return;
    for (final client in _clients.toList()) {
      client.syncAfterFrame(seen: _seen.contains(client));
    }
    _seen.clear();
    _flushOccluders();
  }

  void _flushOccluders() {
    final flat = Float64List(_occluders.length * 4);
    var i = 0;
    for (final r in _occluders.values) {
      flat[i++] = r.left;
      flat[i++] = r.top;
      flat[i++] = r.width;
      flat[i++] = r.height;
    }
    if (listEquals(flat, _sentOccluders)) return;
    _sentOccluders = flat;
    invoke('setOccluders', flat);
  }

  // Pointer events that reach Flutter never touched WebKit, so any press
  // here means keyboard focus belongs back in Flutter.
  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) invoke('focusFlutter');
  }

  Future<T?> invoke<T>(String method, [Object? args]) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    }
  }

  Future<dynamic> _onNative(MethodCall call) async {
    final args = (call.arguments as Map).cast<String, Object?>();
    if (call.method == 'scroll') {
      // Replay as an ordinary Flutter wheel event at the pointer, so content
      // under the view scrolls exactly like the rest of the app.
      GestureBinding.instance.handlePointerEvent(
        PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          device: _scrollDevice,
          position: Offset(_d(args['x']), _d(args['y'])),
          // The factor Flutter's Linux embedder applies to wheel deltas.
          scrollDelta: Offset(_d(args['dx']) * 53, _d(args['dy']) * 53),
        ),
      );
      return null;
    }
    final view = _views[args['id']];
    if (view == null) return null;
    switch (call.method) {
      case 'height':
        view.onHeight(_d(args['height']));
      case 'link':
        view.onLink(args['url']! as String);
      case 'contextMenu':
        view.onContextMenu(
          Offset(_d(args['x']), _d(args['y'])),
          args['link'] as String?,
          args['hasSelection'] == true,
        );
    }
    return null;
  }

  static const _scrollDevice = 0x6b6f6769; // 'kogi'
  static double _d(Object? v) => (v as num?)?.toDouble() ?? 0;
}

/// Native events routed to one view.
abstract class NativeEvents {
  void onHeight(double height);
  void onLink(String url);
  void onContextMenu(Offset globalPosition, String? link, bool hasSelection);
}

/// A layer that draws nothing and is re-added to the scene on every frame,
/// telling the coordinator its owner is really on screen this frame (not
/// offstage, not culled by an `Opacity(0)` or an `IndexedStack`).
class PresenceLayer extends Layer {
  PresenceLayer(this.client);

  final FrameClient client;

  @override
  bool get alwaysNeedsAddToScene => true;

  @override
  void addToScene(ui.SceneBuilder builder) =>
      Coordinator.instance.markSeen(client);
}
