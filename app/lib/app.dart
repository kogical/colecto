import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:fluent_ui/fluent_ui.dart' show FluentLocalizations;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
// macos_ui still looks up the legacy `package:flutter/material.dart`
// `MaterialLocalizations`, a different type from material_ui's.
// ignore: deprecated_member_use
import 'package:flutter/material.dart'
    as legacy
    show DefaultMaterialLocalizations;
import 'package:material_ui/material_ui.dart';

import 'ui/core/kit/kit.dart';
import 'ui/core/theme/colecto_palette.dart';
import 'ui/core/theme/colecto_scroll_behavior.dart';
import 'ui/core/widgets/toast_overlay.dart';
import 'ui/features/shell/mail_controller.dart';
import 'ui/features/shell/mail_shell.dart';

/// Whole-interface zoom (Ctrl/Cmd +, -, 0): lays the app out at
/// `size / factor` and scales it up, like a browser's page zoom, so layouts
/// reflow instead of overflowing.
class _Zoom extends StatelessWidget {
  const _Zoom({required this.factor, required this.child});

  final double factor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (factor == 1) return child;
    final mq = MediaQuery.of(context);
    final size = mq.size / factor;
    return MediaQuery(
      data: mq.copyWith(
        size: size,
        padding: mq.padding / factor,
        viewPadding: mq.viewPadding / factor,
        viewInsets: mq.viewInsets / factor,
      ),
      child: FittedBox(
        fit: BoxFit.fill,
        alignment: Alignment.topLeft,
        child: SizedBox(width: size.width, height: size.height, child: child),
      ),
    );
  }
}

class ColectoApp extends StatefulWidget {
  const ColectoApp({super.key, required this.controller});

  final MailController controller;

  @override
  State<ColectoApp> createState() => _ColectoAppState();
}

class _ColectoAppState extends State<ColectoApp> {
  late final AppLifecycleListener _lifecycle;

  bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        if (widget.controller.hasPendingSends) {
          await widget.controller.flushPendingSends();
        }
        return AppExitResponse.exit;
      },
      onInactive: () {
        if (kIsWeb) {
          unawaited(widget.controller.flushPendingSends());
        }
      },
      onHide: () {
        if (kIsWeb || _isMobile) {
          unawaited(widget.controller.flushPendingSends());
        }
      },
      onPause: () {
        if (_isMobile) {
          unawaited(widget.controller.flushPendingSends());
        }
      },
      onDetach: () {
        if (_isMobile) {
          unawaited(widget.controller.flushPendingSends());
        }
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    super.dispose();
  }

  /// Global zoom shortcuts (Ctrl/Cmd +, -, 0) handled above the Navigator so
  /// they work everywhere — main workspace, Settings, composer, and dialogs.
  bool _onGlobalKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    final keys = HardwareKeyboard.instance;
    final mod = keys.isControlPressed || keys.isMetaPressed;
    if (!mod || keys.isAltPressed) return false;

    final logical = event.logicalKey;
    final physical = event.physicalKey;
    final ch = event.character;

    if (logical == LogicalKeyboardKey.equal ||
        logical == LogicalKeyboardKey.add ||
        logical == LogicalKeyboardKey.numpadAdd ||
        physical == PhysicalKeyboardKey.equal ||
        ch == '+' ||
        ch == '=') {
      widget.controller.zoomIn();
      return true;
    }
    if (logical == LogicalKeyboardKey.minus ||
        logical == LogicalKeyboardKey.numpadSubtract ||
        logical == LogicalKeyboardKey.underscore ||
        physical == PhysicalKeyboardKey.minus ||
        ch == '-' ||
        ch == '_') {
      widget.controller.zoomOut();
      return true;
    }
    if (logical == LogicalKeyboardKey.digit0 ||
        logical == LogicalKeyboardKey.numpad0 ||
        physical == PhysicalKeyboardKey.digit0) {
      widget.controller.resetZoom();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final prefs = controller.preferences;
        final style = controller.design;

        Widget app(ColorScheme? light, ColorScheme? dark) => KeyedSubtree(
          key: ValueKey(controller.reloadEpoch),
          child: MaterialApp(
            title: 'Colecto',
            debugShowCheckedModeBanner: false,
            // Fluent widgets (ComboBox, dialogs) need their own strings;
            // macOS popups (MacosPopupButton) throw without the legacy
            // Material ones, so the Design select couldn't open.
            localizationsDelegates: const [
              FluentLocalizations.delegate,
              legacy.DefaultMaterialLocalizations.delegate,
            ],
            themeMode: controller.themeMode,
            // Zero duration ensures design, font, and theme changes apply
            // immediately without stale-theme races or full-tree lerp jank.
            themeAnimationDuration: Duration.zero,
            scrollBehavior: style.pointer
                ? const ColectoDesktopScrollBehavior()
                : const MaterialScrollBehavior(),
            theme: buildColectoTheme(
              brightness: Brightness.light,
              preferences: prefs,
              style: style,
              dynamicScheme: light?.harmonized(),
            ),
            darkTheme: buildColectoTheme(
              brightness: Brightness.dark,
              preferences: prefs,
              style: style,
              dynamicScheme: dark?.harmonized(),
            ),
            // `Preferences.font_size` (13–18 px, 14 default) scales every
            // label with the system text size rather than replacing it.
            // `_Zoom` wraps the `Builder` so the inner `MediaQuery` inherits
            // `_Zoom`'s scaled `size`, `padding`, and `viewInsets`.
            builder: (context, child) {
              final factor = (prefs.fontSize ?? 14) / 14;
              return _Zoom(
                factor: controller.zoom,
                child: Builder(
                  builder: (zoomedCtx) {
                    final mq = MediaQuery.of(zoomedCtx);
                    return MediaQuery(
                      data: mq.copyWith(
                        textScaler: factor == 1
                            ? mq.textScaler
                            : TextScaler.linear(
                                mq.textScaler.scale(1) * factor,
                              ),
                      ),
                      child: ColectoDesignScope(
                        style: style,
                        child: Stack(
                          children: [
                            child!,
                            // Always above Navigator routes (Settings, dialogs).
                            ToastOverlay(
                              toasts: controller.toasts,
                              position: prefs.notifications.position,
                              onDismiss: controller.dismissToast,
                              onHold: controller.holdToast,
                              topInset: mq.size.width < 600 ? 8 : 56,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              );
            },
            home: MailShell(controller: controller),
          ),
        );

        // Material You: on the Material design, with no accent picked, the
        // system's dynamic colours drive the whole palette.
        final useSystemColors =
            style == ColectoPlatformStyle.android &&
            !kIsWeb &&
            (prefs.accent == null || prefs.accent!.isEmpty);
        return useSystemColors
            ? DynamicColorBuilder(builder: app)
            : app(null, null);
      },
    );
  }
}
