part of 'kit.dart';

/// A confirmation: a Colecto card on desktop and web, a Cupertino alert on iOS
/// and a Material 3 dialog on Android. Returns true when confirmed.
Future<bool> showColectoConfirm({
  required BuildContext context,
  required String title,
  required String message,
  required String confirmLabel,
  bool danger = false,
}) async {
  final style = colectoPlatformStyle(context);
  switch (style) {
    case ColectoPlatformStyle.ios:
      final ok = await showCupertinoDialog<bool>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            CupertinoDialogAction(
              isDestructiveAction: danger,
              isDefaultAction: !danger,
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      );
      return ok ?? false;
    case ColectoPlatformStyle.android:
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(
                confirmLabel,
                style: danger
                    ? TextStyle(color: ColectoPalette.of(ctx).danger)
                    : null,
              ),
            ),
          ],
        ),
      );
      return ok ?? false;
    case ColectoPlatformStyle.desktop ||
        ColectoPlatformStyle.fluent ||
        ColectoPlatformStyle.macos:
      final ok = await _showDesktopDialog<bool>(
        context: context,
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        danger: danger,
        result: () => true,
      );
      return ok ?? false;
  }
}

/// The desktop designs' alert: `ShadDialog.alert` (Colecto), Fluent
/// `ContentDialog` or `MacosAlertDialog`.
Future<T?> _showDesktopDialog<T>({
  required BuildContext context,
  required String title,
  String? message,
  Widget Function(BuildContext)? content,
  required String confirmLabel,
  bool danger = false,
  required T Function() result,
}) {
  switch (colectoPlatformStyle(context)) {
    case ColectoPlatformStyle.fluent:
      return fl.showDialog<T>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => fl.ContentDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (message != null) Text(message),
              if (content != null) ...[
                const SizedBox(height: 12),
                content(ctx),
              ],
            ],
          ),
          actions: [
            ColectoButton(
              label: confirmLabel,
              variant: danger
                  ? ColectoButtonVariant.danger
                  : ColectoButtonVariant.primary,
              onPressed: () => Navigator.of(ctx).pop(result()),
            ),
            ColectoButton(
              label: 'Cancel',
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
      );
    case ColectoPlatformStyle.macos:
      return mac.showMacosAlertDialog<T>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => mac.MacosAlertDialog(
          appIcon: const ColectoMark(size: 56),
          title: Text(title),
          message: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message != null) Text(message, textAlign: TextAlign.center),
              if (content != null) ...[
                const SizedBox(height: 12),
                content(ctx),
              ],
            ],
          ),
          primaryButton: mac.PushButton(
            controlSize: mac.ControlSize.large,
            color: danger ? ColectoPalette.of(ctx).danger : null,
            onPressed: () => Navigator.of(ctx).pop(result()),
            child: Text(confirmLabel),
          ),
          secondaryButton: mac.PushButton(
            controlSize: mac.ControlSize.large,
            secondary: true,
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
        ),
      );
    default:
      return shad.showShadDialog<T>(
        context: context,
        builder: (ctx) => shad.ShadDialog.alert(
          title: Text(title),
          description: message == null ? null : Text(message),
          actions: [
            ColectoButton(
              label: 'Cancel',
              onPressed: () => Navigator.of(ctx).pop(),
            ),
            ColectoButton(
              label: confirmLabel,
              variant: danger
                  ? ColectoButtonVariant.danger
                  : ColectoButtonVariant.primary,
              onPressed: () => Navigator.of(ctx).pop(result()),
            ),
          ],
          child: content == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: content(ctx),
                ),
        ),
      );
  }
}

/// The route for a large modal page (Settings), presented the way each
/// design presents one:
/// - Colecto: a card that rises 6 px over a dimmed workspace.
/// - Fluent: a `ContentDialog` surface over the smoke layer.
/// - macOS: a sheet.
/// - Material 3: a dialog; a full-screen dialog on phones.
/// - Cupertino: the iOS card sheet.
///
/// With [fullscreen] (phones), the Colecto, Fluent and macOS designs slide the
/// page up over the screen. Escape and the barrier close it.
Route<void> colectoModalRoute(
  BuildContext context, {
  required WidgetBuilder builder,
  bool fullscreen = false,
  Size maxSize = const Size(1080, 780),

  /// Grow only as tall as the content needs (forms), up to [maxSize].
  bool fitContent = false,
}) {
  final p = ColectoPalette.of(context);
  final style = colectoPlatformStyle(context);

  Widget content(BuildContext ctx) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          Navigator.of(ctx).maybePop(),
    },
    // Routes outside Material's own (sheets, Fluent and Colecto dialogs)
    // still need the app's text style and ink.
    child: Material(
      type: MaterialType.transparency,
      child: FocusScope(autofocus: true, child: builder(ctx)),
    ),
  );

  // The modal's size inside the window: 28 px clear of every edge.
  Size sized(BuildContext ctx) {
    final screen = MediaQuery.sizeOf(ctx);
    return Size(
      (screen.width - 56).clamp(0.0, maxSize.width),
      (screen.height - 56).clamp(0.0, maxSize.height),
    );
  }

  Widget surface(BuildContext ctx, {required Decoration decoration}) {
    final size = sized(ctx);
    return Center(
      child: Container(
        width: size.width,
        height: fitContent ? null : size.height,
        constraints: BoxConstraints(maxHeight: size.height),
        decoration: decoration,
        clipBehavior: Clip.antiAlias,
        child: content(ctx),
      ),
    );
  }

  switch (style) {
    case ColectoPlatformStyle.ios:
      return CupertinoSheetRoute<void>(
        scrollableBuilder: (ctx, _) =>
            ColoredBox(color: ColectoPalette.of(ctx).bg, child: content(ctx)),
      );
    case ColectoPlatformStyle.android:
      if (fullscreen) {
        return MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (ctx) => Scaffold(
            backgroundColor: ColectoPalette.of(ctx).bg,
            body: SafeArea(bottom: false, child: content(ctx)),
          ),
        );
      }
      return DialogRoute<void>(
        context: context,
        barrierColor: p.scrim,
        builder: (ctx) {
          final size = sized(ctx);
          return Dialog(
            insetPadding: const EdgeInsets.all(28),
            clipBehavior: Clip.antiAlias,
            backgroundColor: ColectoPalette.of(ctx).bg,
            child: Container(
              width: size.width,
              height: fitContent ? null : size.height,
              constraints: BoxConstraints(maxHeight: size.height),
              child: content(ctx),
            ),
          );
        },
      );
    case ColectoPlatformStyle.desktop ||
            ColectoPlatformStyle.fluent ||
            ColectoPlatformStyle.macos
        when fullscreen:
      return PageRouteBuilder<void>(
        fullscreenDialog: true,
        transitionDuration: ColectoMotion.of(
          context,
          const Duration(milliseconds: 280),
        ),
        reverseTransitionDuration: ColectoMotion.of(
          context,
          const Duration(milliseconds: 200),
        ),
        pageBuilder: (ctx, _, _) => ColoredBox(
          color: ColectoPalette.of(ctx).bg,
          child: SafeArea(bottom: false, child: content(ctx)),
        ),
        transitionsBuilder: (_, a, _, child) => SlideTransition(
          position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(
            CurvedAnimation(
              parent: a,
              curve: ColectoMotion.easeOut,
              reverseCurve: Curves.easeIn,
            ),
          ),
          child: child,
        ),
      );
    case ColectoPlatformStyle.fluent:
      return fl.FluentDialogRoute<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => surface(
          ctx,
          decoration:
              fl.ContentDialogTheme.of(ctx).decoration ??
              BoxDecoration(
                color: p.float,
                borderRadius: BorderRadius.circular(8),
              ),
        ),
      );
    case ColectoPlatformStyle.macos:
      return _MacosSheetRoute(
        barrierColor: p.bg.withValues(alpha: 0.6),
        barrierLabel: 'Close',
        builder: (ctx) {
          final size = sized(ctx);
          return Center(
            child: Container(
              width: size.width,
              height: fitContent ? null : size.height,
              constraints: BoxConstraints(maxHeight: size.height),
              // `MacosSheet`'s surface, drawn here so a design switch
              // (which drops MacosTheme for a frame) can't break it.
              child: Container(
                decoration: BoxDecoration(
                  color: ColectoPalette.of(ctx).bg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    width: 2,
                    color: Colors.white.withValues(
                      alpha: p.isDark ? 0.15 : 0.45,
                    ),
                  ),
                ),
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.black.withValues(
                      alpha: p.isDark ? 0.76 : 0.23,
                    ),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: content(ctx),
              ),
            ),
          );
        },
      );
    case ColectoPlatformStyle.desktop:
      return RawDialogRoute<void>(
        barrierDismissible: true,
        barrierLabel: 'Close',
        barrierColor: p.scrim,
        transitionDuration: ColectoMotion.of(context, ColectoMotion.card),
        pageBuilder: (ctx, _, _) {
          final q = ColectoPalette.of(ctx);
          return surface(
            ctx,
            decoration: BoxDecoration(
              color: q.bg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: q.line),
              boxShadow: [
                BoxShadow(
                  color: q.shadow.withValues(alpha: q.isDark ? 0.8 : 0.22),
                  blurRadius: 100,
                  spreadRadius: -30,
                  offset: const Offset(0, 40),
                ),
                ...q.floatShadow.skip(1),
              ],
            ),
          );
        },
        // Rises 6 px and scales from 0.97 in 220 ms.
        transitionBuilder: (_, a, _, child) {
          final t = CurvedAnimation(
            parent: a,
            curve: ColectoMotion.easeOut,
            reverseCurve: Curves.easeIn,
          );
          return FadeTransition(
            opacity: t,
            child: AnimatedBuilder(
              animation: t,
              child: child,
              builder: (_, child) => Transform.translate(
                offset: Offset(0, 6 * (1 - t.value)),
                child: Transform.scale(
                  scale: 0.97 + 0.03 * t.value,
                  child: child,
                ),
              ),
            ),
          );
        },
      );
  }
}

/// A macOS sheet: it scales in with a slight bounce and fades out, like
/// `showMacosSheet`, but as a route the shell can hold on to.
class _MacosSheetRoute extends PopupRoute<void> {
  _MacosSheetRoute({
    required this.builder,
    required this.barrierColor,
    required this.barrierLabel,
  });

  final WidgetBuilder builder;

  @override
  final Color barrierColor;

  @override
  final String barrierLabel;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 450);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 120);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> a,
    Animation<double> s,
  ) => Semantics(
    scopesRoute: true,
    explicitChildNodes: true,
    child: builder(context),
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return child;
    if (animation.status == AnimationStatus.reverse) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutSine),
        child: child,
      );
    }
    return ScaleTransition(
      scale: Tween(
        begin: 0.9,
        end: 1.0,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutBack)),
      child: FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: Curves.fastLinearToSlowEaseIn,
        ),
        child: child,
      ),
    );
  }
}
