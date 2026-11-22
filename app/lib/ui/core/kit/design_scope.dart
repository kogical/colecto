part of 'kit.dart';

/// Gives the design libraries their themes, all derived from the one Colecto
/// palette and active font, so a shadcn, Fluent, macOS, Material or Cupertino
/// control always matches the accent, typography and surfaces around it.
class ColectoDesignScope extends StatelessWidget {
  const ColectoDesignScope({super.key, this.style, required this.child});

  final ColectoPlatformStyle? style;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = ColectoPalette.of(context);
    final font = ColectoFont.of(context);
    final family =
        font.family ?? Theme.of(context).textTheme.bodyMedium?.fontFamily;
    final fallback = font.fallback;

    // Ensure every descendant inherits the active font family and fallback,
    // even inside routes or widgets that bypass Material's TextTheme.
    final styledChild = DefaultTextStyle.merge(
      style: TextStyle(fontFamily: family, fontFamilyFallback: fallback),
      child: child,
    );

    // Keep all three design InheritedWidget themes mounted in a stable order:
    // - Navigator is never reparented when switching designs.
    // - Exiting dialogs/popovers from the previous design never throw a
    //   missing-theme ErrorWidget during their exit transition.
    return shad.ShadTheme(
      data: _shadTheme(p, family, fallback),
      child: fl.FluentTheme(
        data: _fluentTheme(p, family),
        child: mac.MacosTheme(
          data: mac.MacosThemeData(
            brightness: p.brightness,
            primaryColor: p.accent,
            canvasColor: p.bg,
            dividerColor: p.lineSoft,
            typography: _macosTypography(p, family, fallback),
          ),
          child: styledChild,
        ),
      ),
    );
  }

  static mac.MacosTypography _macosTypography(
    ColectoPalette p,
    String? family,
    List<String> fallback,
  ) {
    final base = mac.MacosTypography(color: p.ink);
    TextStyle apply(TextStyle s) =>
        s.copyWith(fontFamily: family, fontFamilyFallback: fallback);
    return mac.MacosTypography(
      color: p.ink,
      largeTitle: apply(base.largeTitle),
      title1: apply(base.title1),
      title2: apply(base.title2),
      title3: apply(base.title3),
      headline: apply(base.headline),
      subheadline: apply(base.subheadline),
      body: apply(base.body),
      callout: apply(base.callout),
      footnote: apply(base.footnote),
      caption1: apply(base.caption1),
      caption2: apply(base.caption2),
    );
  }

  static shad.ShadThemeData _shadTheme(
    ColectoPalette p,
    String? family,
    List<String> fallback,
  ) {
    final base = shad.ShadTextTheme(family: family ?? 'Mona Sans');
    TextStyle? withFallback(TextStyle? s) => s?.copyWith(
      fontFamily: family ?? 'Mona Sans',
      fontFamilyFallback: fallback,
    );
    return shad.ShadThemeData(
      brightness: p.brightness,
      radius: const BorderRadius.all(Radius.circular(8)),
      textTheme: base.copyWith(
        h1Large: withFallback(base.h1Large),
        h1: withFallback(base.h1),
        h2: withFallback(base.h2),
        h3: withFallback(base.h3),
        h4: withFallback(base.h4),
        p: withFallback(base.p),
        blockquote: withFallback(base.blockquote),
        table: withFallback(base.table),
        list: withFallback(base.list),
        lead: withFallback(base.lead),
        large: withFallback(base.large),
        small: withFallback(base.small),
        muted: withFallback(base.muted),
      ),
      colorScheme: shad.ShadColorScheme(
        background: p.bg,
        foreground: p.ink,
        card: p.float,
        cardForeground: p.ink,
        popover: p.float,
        popoverForeground: p.ink,
        primary: p.accent,
        primaryForeground: p.accentInk,
        secondary: p.control,
        secondaryForeground: p.ink,
        muted: p.raise,
        mutedForeground: p.ink3,
        accent: p.raise,
        accentForeground: p.ink,
        destructive: p.dangerBg,
        destructiveForeground: p.dangerInk,
        border: p.line,
        input: p.line,
        ring: p.accent,
        selection: p.accent.withValues(alpha: 0.32),
      ),
    );
  }

  static fl.FluentThemeData _fluentTheme(ColectoPalette p, String? family) {
    Color mix(Color c, double t) => Color.lerp(p.accent, c, t)!;
    const black = Color(0xFF000000);
    const white = Color(0xFFFFFFFF);
    final accent = fl.AccentColor.swatch({
      'darkest': mix(black, 0.45),
      'darker': mix(black, 0.3),
      'dark': mix(black, 0.15),
      'normal': p.accent,
      'light': mix(white, 0.15),
      'lighter': mix(white, 0.3),
      'lightest': mix(white, 0.45),
    });
    return fl.FluentThemeData(
      brightness: p.brightness,
      accentColor: accent,
      fontFamily: family,
      scaffoldBackgroundColor: p.bg,
      micaBackgroundColor: p.ground,
      cardColor: p.float,
      menuColor: p.float,
      selectionColor: p.accent,
      visualDensity: VisualDensity.standard,
    );
  }
}
