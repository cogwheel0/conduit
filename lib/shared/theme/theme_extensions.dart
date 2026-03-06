import 'dart:math' as math;

import 'package:flutter/material.dart';
// Using system fonts; no GoogleFonts dependency required
import 'tweakcn_themes.dart';
import 'color_tokens.dart';

/// Extended theme data for consistent styling across the app
@immutable
class ConduitThemeExtension extends ThemeExtension<ConduitThemeExtension> {
  const ConduitThemeExtension._({
    required this.tokens,
    required this.variant,
    required this.isDark,
    required this.typography,
    required this.surfaces,
    required this.shadows,
    required this.shapes,
  });

  factory ConduitThemeExtension.create({
    required TweakcnThemeDefinition theme,
    required AppColorTokens tokens,
    required Brightness brightness,
    required TypographyThemeExtension typography,
    required SurfaceThemeExtension surfaces,
    required ShadowThemeExtension shadows,
    required ShapeThemeExtension shapes,
  }) {
    return ConduitThemeExtension._(
      tokens: tokens,
      variant: theme.variantFor(brightness),
      isDark: brightness == Brightness.dark,
      typography: typography,
      surfaces: surfaces,
      shadows: shadows,
      shapes: shapes,
    );
  }

  final AppColorTokens tokens;
  final TweakcnThemeVariant variant;
  final bool isDark;
  final TypographyThemeExtension typography;
  final SurfaceThemeExtension surfaces;
  final ShadowThemeExtension shadows;
  final ShapeThemeExtension shapes;

  Color get chatBubbleUser =>
      isDark ? tokens.neutralTone40 : tokens.neutralTone20;
  Color get chatBubbleAssistant =>
      isDark ? tokens.neutralTone20 : tokens.neutralTone00;
  Color get chatBubbleUserText => tokens.neutralOnSurface;
  Color get chatBubbleAssistantText => tokens.neutralOnSurface;
  Color get chatBubbleUserBorder =>
      isDark ? tokens.neutralTone40 : tokens.neutralTone20;
  Color get chatBubbleAssistantBorder =>
      isDark ? tokens.neutralTone40 : tokens.neutralTone20;

  Color get inputBackground =>
      Color.lerp(surfaces.background, surfaces.input, isDark ? 0.35 : 0.75)!;
  Color get inputBorder =>
      Color.lerp(surfaces.border, surfaces.ring, isDark ? 0.4 : 0.2)!;
  Color get inputBorderFocused => surfaces.ring;
  Color get inputText => tokens.neutralOnSurface;
  Color get inputPlaceholder =>
      isDark ? tokens.neutralTone60 : tokens.neutralTone60;
  Color get inputError => tokens.statusError60;

  Color get cardBackground => surfaces.card;
  Color get cardBorder => surfaces.border;
  Color get cardShadow => shadows.shadowSm.first.color;
  List<BoxShadow> get cardShadows => shadows.shadowSm;
  List<BoxShadow> get popoverShadows => shadows.shadowLg;
  List<BoxShadow> get overlayShadows => shadows.shadowXs;

  Color get surfaceBackground => surfaces.background;
  Color get surfaceContainer => surfaces.container;
  Color get surfaceContainerHighest => surfaces.containerHighest;

  Color get buttonPrimary => variant.primary;
  Color get buttonPrimaryText => _onSurfaceColor(variant.primary);
  Color get buttonSecondary => tokens.neutralTone20;
  Color get buttonSecondaryText => tokens.neutralOnSurface;
  Color get buttonDisabled => tokens.neutralTone40;
  Color get buttonDisabledText =>
      isDark ? tokens.neutralTone80 : tokens.neutralTone60;

  StatusPalette get statusPalette => StatusPalette(
    success: StatusColors(
      base: tokens.statusSuccess60,
      onBase: tokens.statusOnSuccess60,
      background: _toneOverlay(tokens.statusSuccess60),
      light: tokens.statusSuccess60,
      dark: Color.alphaBlend(
        tokens.statusSuccess60.withValues(alpha: 0.8),
        tokens.neutralTone20,
      ),
    ),
    warning: StatusColors(
      base: tokens.statusWarning60,
      onBase: tokens.statusOnWarning60,
      background: _toneOverlay(tokens.statusWarning60),
      light: tokens.statusWarning60,
      dark: Color.alphaBlend(
        tokens.statusWarning60.withValues(alpha: 0.8),
        tokens.neutralTone20,
      ),
    ),
    info: StatusColors(
      base: tokens.statusInfo60,
      onBase: tokens.statusOnInfo60,
      background: _toneOverlay(tokens.statusInfo60),
      light: tokens.statusInfo60,
      dark: Color.alphaBlend(
        tokens.statusInfo60.withValues(alpha: 0.8),
        tokens.neutralTone20,
      ),
    ),
    destructive: StatusColors(
      base: tokens.statusError60,
      onBase: tokens.statusOnError60,
      background: _toneOverlay(tokens.statusError60),
      light: tokens.statusError60,
      dark: Color.alphaBlend(
        tokens.statusError60.withValues(alpha: 0.8),
        tokens.neutralTone20,
      ),
    ),
  );

  Color get success => statusPalette.success.base;
  Color get successBackground => statusPalette.success.background;
  Color get error => statusPalette.destructive.base;
  Color get errorBackground => statusPalette.destructive.background;
  Color get warning => statusPalette.warning.base;
  Color get warningBackground => statusPalette.warning.background;
  Color get info => statusPalette.info.base;
  Color get infoBackground => statusPalette.info.background;

  Color get dividerColor =>
      isDark ? tokens.neutralTone40 : tokens.neutralTone20;
  Color get navigationBackground =>
      isDark ? tokens.neutralTone10 : tokens.neutralTone00;
  Color get navigationSelected => variant.primary;
  Color get navigationUnselected =>
      isDark ? tokens.neutralTone80 : tokens.neutralTone60;
  Color get navigationSelectedBackground =>
      _overlay(tokens.overlayMedium, surface: navigationBackground);

  Color get shimmerBase =>
      _overlay(tokens.overlayWeak, surface: tokens.neutralTone10);
  Color get shimmerHighlight => isDark
      ? _overlay(tokens.overlayMedium, surface: tokens.neutralTone20)
      : tokens.neutralTone00;
  Color get loadingIndicator => variant.primary;

  Color get codeBackground => tokens.codeBackground;
  Color get codeBorder => tokens.codeBorder;
  Color get codeText => tokens.codeText;
  Color get codeAccent => tokens.codeAccent;

  Color get textPrimary => tokens.neutralOnSurface;
  Color get textSecondary => tokens.neutralTone80;
  Color get textTertiary => tokens.neutralTone60;
  Color get textInverse => tokens.neutralTone00;
  Color get textDisabled =>
      isDark ? tokens.neutralTone40 : tokens.neutralTone60;

  Color get iconPrimary => tokens.neutralOnSurface;
  Color get iconSecondary => tokens.neutralTone80;
  Color get iconDisabled =>
      isDark ? tokens.neutralTone40 : tokens.neutralTone60;
  Color get iconInverse => tokens.neutralTone00;

  double get radiusSm => shapes.radiusSm;
  double get radiusMd => shapes.radiusMd;
  double get radiusLg => shapes.radiusLg;
  double get radiusXl => shapes.radiusXl;

  Color get sidebarBackground => variant.sidebarBackground;
  Color get sidebarForeground => variant.sidebarForeground;
  Color get sidebarPrimary => variant.sidebarPrimary;
  Color get sidebarPrimaryText => variant.sidebarPrimaryForeground;
  Color get sidebarAccent => variant.sidebarAccent;
  Color get sidebarAccentText => variant.sidebarAccentForeground;
  Color get sidebarBorder => variant.sidebarBorder;
  Color get sidebarRing => variant.sidebarRing;

  TextStyle? get headingLarge => TextStyle(
    fontSize: AppTypography.displaySmall,
    fontWeight: FontWeight.w700,
    color: tokens.neutralOnSurface,
    height: 1.2,
  );

  TextStyle? get headingMedium => TextStyle(
    fontSize: AppTypography.headlineLarge,
    fontWeight: FontWeight.w600,
    color: tokens.neutralOnSurface,
    height: 1.3,
  );

  TextStyle? get headingSmall => TextStyle(
    fontSize: AppTypography.headlineSmall,
    fontWeight: FontWeight.w600,
    color: tokens.neutralOnSurface,
    height: 1.4,
  );

  TextStyle? get bodyLarge => TextStyle(
    fontSize: AppTypography.bodyLarge,
    fontWeight: FontWeight.w400,
    color: tokens.neutralOnSurface,
    height: 1.5,
  );

  TextStyle? get bodyMedium => TextStyle(
    fontSize: AppTypography.bodyMedium,
    fontWeight: FontWeight.w400,
    color: tokens.neutralOnSurface,
    height: 1.5,
  );

  TextStyle? get bodySmall => TextStyle(
    fontSize: AppTypography.bodySmall,
    fontWeight: FontWeight.w400,
    color: isDark ? tokens.neutralTone80 : tokens.neutralTone60,
    height: 1.4,
  );

  TextStyle? get caption => TextStyle(
    fontSize: AppTypography.labelMedium,
    fontWeight: FontWeight.w500,
    color: isDark ? tokens.neutralTone80 : tokens.neutralTone60,
    height: 1.3,
    letterSpacing: 0.5,
  );

  TextStyle? get label => TextStyle(
    fontSize: AppTypography.labelLarge,
    fontWeight: FontWeight.w500,
    color: tokens.neutralTone80,
    height: 1.3,
  );

  TextStyle? get code => TextStyle(
    fontSize: AppTypography.bodySmall,
    fontWeight: FontWeight.w400,
    color: tokens.neutralOnSurface,
    height: 1.4,
    fontFamily: typography.monospaceFont,
    fontFamilyFallback: typography.monospaceFallback,
  );

  @override
  ConduitThemeExtension copyWith({
    AppColorTokens? tokens,
    TweakcnThemeVariant? variant,
    bool? isDark,
    TypographyThemeExtension? typography,
    SurfaceThemeExtension? surfaces,
    ShadowThemeExtension? shadows,
    ShapeThemeExtension? shapes,
  }) {
    return ConduitThemeExtension._(
      tokens: tokens ?? this.tokens,
      variant: variant ?? this.variant,
      isDark: isDark ?? this.isDark,
      typography: typography ?? this.typography,
      surfaces: surfaces ?? this.surfaces,
      shadows: shadows ?? this.shadows,
      shapes: shapes ?? this.shapes,
    );
  }

  @override
  ConduitThemeExtension lerp(
    covariant ThemeExtension<ConduitThemeExtension>? other,
    double t,
  ) {
    if (other is! ConduitThemeExtension) return this;
    return t < 0.5 ? this : other;
  }

  Color _overlay(Color overlay, {Color? surface}) {
    return Color.alphaBlend(overlay, surface ?? surfaceBackground);
  }

  Color _toneOverlay(Color tone) {
    final double alpha = isDark ? 0.24 : 0.12;
    final Color base = isDark ? tokens.neutralTone10 : tokens.neutralTone00;
    return Color.alphaBlend(tone.withValues(alpha: alpha), base);
  }

  Color _onSurfaceColor(Color background) {
    final contrastOnLight = _contrastRatio(background, tokens.neutralTone00);
    final contrastOnDark = _contrastRatio(background, tokens.neutralOnSurface);
    return contrastOnLight >= contrastOnDark
        ? tokens.neutralTone00
        : tokens.neutralOnSurface;
  }

  static double _contrastRatio(Color a, Color b) {
    final luminanceA = a.computeLuminance();
    final luminanceB = b.computeLuminance();
    final lighter = math.max(luminanceA, luminanceB);
    final darker = math.min(luminanceA, luminanceB);
    return (lighter + 0.05) / (darker + 0.05);
  }
}

/// Extension method to easily access Conduit theme from BuildContext
extension ConduitThemeContext on BuildContext {
  ConduitThemeExtension get conduitTheme {
    final theme = Theme.of(this);
    final extension = theme.extension<ConduitThemeExtension>();
    if (extension != null) return extension;
    final palette =
        theme.extension<AppPaletteThemeExtension>()?.palette ??
        TweakcnThemes.t3Chat;
    final TweakcnThemeVariant variant = palette.variantFor(theme.brightness);
    final tokens = theme.brightness == Brightness.dark
        ? AppColorTokens.dark(theme: palette)
        : AppColorTokens.light(theme: palette);
    final TypographyThemeExtension typography =
        theme.extension<TypographyThemeExtension>() ??
        TypographyThemeExtension.fromVariant(variant);
    final SurfaceThemeExtension surfaces =
        theme.extension<SurfaceThemeExtension>() ??
        SurfaceThemeExtension.fromVariant(variant);
    final ShadowThemeExtension shadows =
        theme.extension<ShadowThemeExtension>() ??
        ShadowThemeExtension.standard();
    final ShapeThemeExtension shapes =
        theme.extension<ShapeThemeExtension>() ??
        ShapeThemeExtension.fromVariant(variant);
    return ConduitThemeExtension.create(
      theme: palette,
      tokens: tokens,
      brightness: theme.brightness,
      typography: typography,
      surfaces: surfaces,
      shadows: shadows,
      shapes: shapes,
    );
  }
}

extension ConduitColorTokensContext on BuildContext {
  AppColorTokens get colorTokens {
    final theme = Theme.of(this);
    final tokens = theme.extension<AppColorTokens>();
    if (tokens != null) return tokens;
    final palette =
        theme.extension<AppPaletteThemeExtension>()?.palette ??
        TweakcnThemes.t3Chat;
    return theme.brightness == Brightness.dark
        ? AppColorTokens.dark(theme: palette)
        : AppColorTokens.light(theme: palette);
  }
}

extension ConduitPaletteContext on BuildContext {
  TweakcnThemeDefinition get conduitPalette {
    return Theme.of(this).extension<AppPaletteThemeExtension>()?.palette ??
        TweakcnThemes.t3Chat;
  }
}

extension SidebarThemeContext on BuildContext {
  SidebarThemeExtension get sidebarTheme {
    final theme = Theme.of(this);
    final extension = theme.extension<SidebarThemeExtension>();
    if (extension != null) return extension;
    final palette =
        theme.extension<AppPaletteThemeExtension>()?.palette ??
        TweakcnThemes.t3Chat;
    final TweakcnThemeVariant variant = palette.variantFor(theme.brightness);
    return SidebarThemeExtension.fromVariant(variant);
  }
}

@immutable
class StatusColors {
  const StatusColors({
    required this.base,
    required this.onBase,
    required this.background,
    required this.light,
    required this.dark,
  });

  final Color base;
  final Color onBase;
  final Color background;
  final Color light;
  final Color dark;
}

@immutable
class StatusPalette {
  const StatusPalette({
    required this.success,
    required this.warning,
    required this.info,
    required this.destructive,
  });

  final StatusColors success;
  final StatusColors warning;
  final StatusColors info;
  final StatusColors destructive;
}

@immutable
class TypographyThemeExtension
    extends ThemeExtension<TypographyThemeExtension> {
  const TypographyThemeExtension({
    required this.primaryFont,
    required this.primaryFallback,
    required this.serifFont,
    required this.serifFallback,
    required this.monospaceFont,
    required this.monospaceFallback,
  });

  factory TypographyThemeExtension.fromVariant(TweakcnThemeVariant variant) {
    return TypographyThemeExtension(
      primaryFont: _preferredFont(variant.fontSans),
      primaryFallback: _fallbackForStack(variant.fontSans),
      serifFont: _preferredFont(variant.fontSerif),
      serifFallback: _fallbackForStack(variant.fontSerif),
      monospaceFont: _preferredFont(variant.fontMono),
      monospaceFallback: _fallbackForStack(variant.fontMono),
    );
  }

  final String primaryFont;
  final List<String> primaryFallback;
  final String serifFont;
  final List<String> serifFallback;
  final String monospaceFont;
  final List<String> monospaceFallback;

  @override
  TypographyThemeExtension copyWith({
    String? primaryFont,
    List<String>? primaryFallback,
    String? serifFont,
    List<String>? serifFallback,
    String? monospaceFont,
    List<String>? monospaceFallback,
  }) {
    return TypographyThemeExtension(
      primaryFont: primaryFont ?? this.primaryFont,
      primaryFallback: primaryFallback ?? this.primaryFallback,
      serifFont: serifFont ?? this.serifFont,
      serifFallback: serifFallback ?? this.serifFallback,
      monospaceFont: monospaceFont ?? this.monospaceFont,
      monospaceFallback: monospaceFallback ?? this.monospaceFallback,
    );
  }

  @override
  TypographyThemeExtension lerp(
    covariant ThemeExtension<TypographyThemeExtension>? other,
    double t,
  ) {
    if (other is! TypographyThemeExtension) return this;
    return t < 0.5 ? this : other;
  }
}

@immutable
class SurfaceThemeExtension extends ThemeExtension<SurfaceThemeExtension> {
  const SurfaceThemeExtension({
    required this.background,
    required this.container,
    required this.containerHighest,
    required this.card,
    required this.cardForeground,
    required this.popover,
    required this.popoverForeground,
    required this.muted,
    required this.mutedForeground,
    required this.border,
    required this.ring,
    required this.input,
  });

  factory SurfaceThemeExtension.fromVariant(TweakcnThemeVariant variant) {
    return SurfaceThemeExtension(
      background: variant.background,
      container: Color.lerp(variant.background, variant.card, 0.5)!,
      containerHighest: variant.card,
      card: variant.card,
      cardForeground: variant.cardForeground,
      popover: variant.popover,
      popoverForeground: variant.popoverForeground,
      muted: variant.muted,
      mutedForeground: variant.mutedForeground,
      border: variant.border,
      ring: variant.ring,
      input: variant.input,
    );
  }

  final Color background;
  final Color container;
  final Color containerHighest;
  final Color card;
  final Color cardForeground;
  final Color popover;
  final Color popoverForeground;
  final Color muted;
  final Color mutedForeground;
  final Color border;
  final Color ring;
  final Color input;

  @override
  SurfaceThemeExtension copyWith({
    Color? background,
    Color? container,
    Color? containerHighest,
    Color? card,
    Color? cardForeground,
    Color? popover,
    Color? popoverForeground,
    Color? muted,
    Color? mutedForeground,
    Color? border,
    Color? ring,
    Color? input,
  }) {
    return SurfaceThemeExtension(
      background: background ?? this.background,
      container: container ?? this.container,
      containerHighest: containerHighest ?? this.containerHighest,
      card: card ?? this.card,
      cardForeground: cardForeground ?? this.cardForeground,
      popover: popover ?? this.popover,
      popoverForeground: popoverForeground ?? this.popoverForeground,
      muted: muted ?? this.muted,
      mutedForeground: mutedForeground ?? this.mutedForeground,
      border: border ?? this.border,
      ring: ring ?? this.ring,
      input: input ?? this.input,
    );
  }

  @override
  SurfaceThemeExtension lerp(
    covariant ThemeExtension<SurfaceThemeExtension>? other,
    double t,
  ) {
    if (other is! SurfaceThemeExtension) return this;
    return t < 0.5 ? this : other;
  }
}

@immutable
class ShadowThemeExtension extends ThemeExtension<ShadowThemeExtension> {
  const ShadowThemeExtension({
    required this.shadow2Xs,
    required this.shadowXs,
    required this.shadowSm,
    required this.shadow,
    required this.shadowMd,
    required this.shadowLg,
    required this.shadowXl,
    required this.shadow2Xl,
  });

  factory ShadowThemeExtension.standard() {
    return ShadowThemeExtension(
      shadow2Xs: _buildShadow(const <_ShadowSpec>[
        _ShadowSpec(dx: 0, dy: 1, blur: 3, spread: 0, opacity: 0.05),
      ]),
      shadowXs: _buildShadow(const <_ShadowSpec>[
        _ShadowSpec(dx: 0, dy: 1, blur: 3, spread: 0, opacity: 0.05),
      ]),
      shadowSm: _buildShadow(const <_ShadowSpec>[
        _ShadowSpec(dx: 0, dy: 1, blur: 3, spread: 0, opacity: 0.10),
        _ShadowSpec(dx: 0, dy: 1, blur: 2, spread: -1, opacity: 0.10),
      ]),
      shadow: _buildShadow(const <_ShadowSpec>[
        _ShadowSpec(dx: 0, dy: 1, blur: 3, spread: 0, opacity: 0.10),
        _ShadowSpec(dx: 0, dy: 1, blur: 2, spread: -1, opacity: 0.10),
      ]),
      shadowMd: _buildShadow(const <_ShadowSpec>[
        _ShadowSpec(dx: 0, dy: 1, blur: 3, spread: 0, opacity: 0.10),
        _ShadowSpec(dx: 0, dy: 2, blur: 4, spread: -1, opacity: 0.10),
      ]),
      shadowLg: _buildShadow(const <_ShadowSpec>[
        _ShadowSpec(dx: 0, dy: 1, blur: 3, spread: 0, opacity: 0.10),
        _ShadowSpec(dx: 0, dy: 4, blur: 6, spread: -1, opacity: 0.10),
      ]),
      shadowXl: _buildShadow(const <_ShadowSpec>[
        _ShadowSpec(dx: 0, dy: 1, blur: 3, spread: 0, opacity: 0.10),
        _ShadowSpec(dx: 0, dy: 8, blur: 10, spread: -1, opacity: 0.10),
      ]),
      shadow2Xl: _buildShadow(const <_ShadowSpec>[
        _ShadowSpec(dx: 0, dy: 1, blur: 3, spread: 0, opacity: 0.25),
      ]),
    );
  }

  final List<BoxShadow> shadow2Xs;
  final List<BoxShadow> shadowXs;
  final List<BoxShadow> shadowSm;
  final List<BoxShadow> shadow;
  final List<BoxShadow> shadowMd;
  final List<BoxShadow> shadowLg;
  final List<BoxShadow> shadowXl;
  final List<BoxShadow> shadow2Xl;

  @override
  ShadowThemeExtension copyWith({
    List<BoxShadow>? shadow2Xs,
    List<BoxShadow>? shadowXs,
    List<BoxShadow>? shadowSm,
    List<BoxShadow>? shadow,
    List<BoxShadow>? shadowMd,
    List<BoxShadow>? shadowLg,
    List<BoxShadow>? shadowXl,
    List<BoxShadow>? shadow2Xl,
  }) {
    return ShadowThemeExtension(
      shadow2Xs: shadow2Xs ?? this.shadow2Xs,
      shadowXs: shadowXs ?? this.shadowXs,
      shadowSm: shadowSm ?? this.shadowSm,
      shadow: shadow ?? this.shadow,
      shadowMd: shadowMd ?? this.shadowMd,
      shadowLg: shadowLg ?? this.shadowLg,
      shadowXl: shadowXl ?? this.shadowXl,
      shadow2Xl: shadow2Xl ?? this.shadow2Xl,
    );
  }

  @override
  ShadowThemeExtension lerp(
    covariant ThemeExtension<ShadowThemeExtension>? other,
    double t,
  ) {
    if (other is! ShadowThemeExtension) return this;
    return t < 0.5 ? this : other;
  }
}

@immutable
class ShapeThemeExtension extends ThemeExtension<ShapeThemeExtension> {
  const ShapeThemeExtension({
    required this.radiusBase,
    required this.radiusSm,
    required this.radiusMd,
    required this.radiusLg,
    required this.radiusXl,
  });

  factory ShapeThemeExtension.fromVariant(TweakcnThemeVariant variant) {
    final double base = variant.radius;
    return ShapeThemeExtension(
      radiusBase: base,
      radiusSm: math.max(0, base - 4),
      radiusMd: math.max(0, base - 2),
      radiusLg: base,
      radiusXl: base + 4,
    );
  }

  final double radiusBase;
  final double radiusSm;
  final double radiusMd;
  final double radiusLg;
  final double radiusXl;

  BorderRadius get small => BorderRadius.circular(radiusSm);
  BorderRadius get medium => BorderRadius.circular(radiusMd);
  BorderRadius get large => BorderRadius.circular(radiusLg);
  BorderRadius get extraLarge => BorderRadius.circular(radiusXl);

  @override
  ShapeThemeExtension copyWith({
    double? radiusBase,
    double? radiusSm,
    double? radiusMd,
    double? radiusLg,
    double? radiusXl,
  }) {
    return ShapeThemeExtension(
      radiusBase: radiusBase ?? this.radiusBase,
      radiusSm: radiusSm ?? this.radiusSm,
      radiusMd: radiusMd ?? this.radiusMd,
      radiusLg: radiusLg ?? this.radiusLg,
      radiusXl: radiusXl ?? this.radiusXl,
    );
  }

  @override
  ShapeThemeExtension lerp(
    covariant ThemeExtension<ShapeThemeExtension>? other,
    double t,
  ) {
    if (other is! ShapeThemeExtension) return this;
    return ShapeThemeExtension(
      radiusBase: lerpDouble(radiusBase, other.radiusBase, t),
      radiusSm: lerpDouble(radiusSm, other.radiusSm, t),
      radiusMd: lerpDouble(radiusMd, other.radiusMd, t),
      radiusLg: lerpDouble(radiusLg, other.radiusLg, t),
      radiusXl: lerpDouble(radiusXl, other.radiusXl, t),
    );
  }

  static double lerpDouble(double a, double b, double t) {
    return a + (b - a) * t;
  }
}

@immutable
class SidebarThemeExtension extends ThemeExtension<SidebarThemeExtension> {
  const SidebarThemeExtension({
    required this.background,
    required this.foreground,
    required this.primary,
    required this.primaryForeground,
    required this.accent,
    required this.accentForeground,
    required this.border,
    required this.ring,
  });

  factory SidebarThemeExtension.fromVariant(TweakcnThemeVariant variant) {
    return SidebarThemeExtension(
      background: variant.sidebarBackground,
      foreground: variant.sidebarForeground,
      primary: variant.sidebarPrimary,
      primaryForeground: variant.sidebarPrimaryForeground,
      accent: variant.sidebarAccent,
      accentForeground: variant.sidebarAccentForeground,
      border: variant.sidebarBorder,
      ring: variant.sidebarRing,
    );
  }

  final Color background;
  final Color foreground;
  final Color primary;
  final Color primaryForeground;
  final Color accent;
  final Color accentForeground;
  final Color border;
  final Color ring;

  @override
  SidebarThemeExtension copyWith({
    Color? background,
    Color? foreground,
    Color? primary,
    Color? primaryForeground,
    Color? accent,
    Color? accentForeground,
    Color? border,
    Color? ring,
  }) {
    return SidebarThemeExtension(
      background: background ?? this.background,
      foreground: foreground ?? this.foreground,
      primary: primary ?? this.primary,
      primaryForeground: primaryForeground ?? this.primaryForeground,
      accent: accent ?? this.accent,
      accentForeground: accentForeground ?? this.accentForeground,
      border: border ?? this.border,
      ring: ring ?? this.ring,
    );
  }

  @override
  SidebarThemeExtension lerp(
    covariant ThemeExtension<SidebarThemeExtension>? other,
    double t,
  ) {
    if (other is! SidebarThemeExtension) return this;
    return SidebarThemeExtension(
      background: Color.lerp(background, other.background, t)!,
      foreground: Color.lerp(foreground, other.foreground, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
      primaryForeground: Color.lerp(
        primaryForeground,
        other.primaryForeground,
        t,
      )!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentForeground: Color.lerp(
        accentForeground,
        other.accentForeground,
        t,
      )!,
      border: Color.lerp(border, other.border, t)!,
      ring: Color.lerp(ring, other.ring, t)!,
    );
  }
}

class _ShadowSpec {
  const _ShadowSpec({
    required this.dx,
    required this.dy,
    required this.blur,
    required this.spread,
    required this.opacity,
  });

  final double dx;
  final double dy;
  final double blur;
  final double spread;
  final double opacity;
}

List<BoxShadow> _buildShadow(List<_ShadowSpec> specs) {
  return specs
      .map(
        (spec) => BoxShadow(
          color: Colors.black.withValues(alpha: spec.opacity),
          offset: Offset(spec.dx, spec.dy),
          blurRadius: spec.blur,
          spreadRadius: spec.spread,
        ),
      )
      .toList(growable: false);
}

/// Always returns empty so Flutter uses the platform's
/// default system font (which includes emoji support).
/// CSS font stacks from tweakcn themes are web-oriented
/// and not usable by Flutter's native text engine.
String _preferredFont(List<String> stack) => '';

/// Returns an empty fallback list — the platform system
/// font handles all glyph coverage including emoji.
List<String> _fallbackForStack(List<String> stack) =>
    const <String>[];

/// Consistent spacing values - Enhanced for production with better hierarchy
class Spacing {
  // Base spacing scale (8pt grid system)
  static const double xxs = 2.0;
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 16.0;
  static const double lg = 24.0;
  static const double xl = 32.0;
  static const double xxl = 48.0;
  static const double xxxl = 64.0;

  // Enhanced spacing for specific components with better hierarchy
  static const double buttonPadding = 16.0;
  static const double cardPadding = 20.0;
  static const double inputPadding = 16.0;
  static const double modalPadding = 24.0;
  static const double messagePadding = 16.0;
  static const double navigationPadding = 12.0;
  static const double listItemPadding = 16.0;
  static const double sectionPadding = 24.0;
  static const double pagePadding = 20.0;
  static const double screenPadding = 16.0;

  // Spacing for different densities with improved hierarchy
  static const double compact = 8.0;
  static const double comfortable = 16.0;
  static const double spacious = 24.0;
  static const double extraSpacious = 32.0;

  // Specific component spacing with better consistency
  static const double chatBubblePadding = 12.0;
  static const double actionButtonPadding = 12.0;
  static const double floatingButtonPadding = 16.0;
  static const double bottomSheetPadding = 24.0;
  static const double dialogPadding = 20.0;
  static const double snackbarPadding = 16.0;

  // Layout spacing with improved hierarchy
  static const double gridGap = 16.0;
  static const double listGap = 12.0;
  static const double sectionGap = 32.0;
  static const double contentGap = 24.0;

  // Enhanced spacing for better visual hierarchy
  static const double micro = 4.0;
  static const double small = 8.0;
  static const double medium = 16.0;
  static const double large = 24.0;
  static const double extraLarge = 32.0;
  static const double huge = 48.0;
  static const double massive = 64.0;

  // Component-specific spacing
  static const double iconSpacing = 8.0;
  static const double textSpacing = 4.0;
  static const double borderSpacing = 1.0;
  static const double shadowSpacing = 2.0;
}

/// Consistent border radius values - Enhanced for production with better hierarchy
class AppBorderRadius {
  // Base radius scale
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 16.0;
  static const double xl = 24.0;
  static const double round = 999.0;

  // Enhanced radius values for specific components with better hierarchy
  static const double button = 12.0;
  static const double card = 16.0;
  static const double input = 12.0;
  static const double modal = 20.0;
  static const double messageBubble = 12.0;
  static const double navigation = 12.0;
  static const double avatar = 50.0;
  static const double badge = 20.0;
  static const double chip = 16.0;
  static const double tooltip = 8.0;

  // Border radius for different sizes with improved hierarchy
  static const double small = 6.0;
  static const double medium = 12.0;
  static const double large = 18.0;
  static const double extraLarge = 24.0;
  static const double pill = 999.0;

  // Specific component radius with better consistency
  static const double chatBubble = 20.0;
  static const double actionButton = 14.0;
  static const double floatingButton = 28.0;
  static const double bottomSheet = 24.0;
  static const double dialog = 16.0;
  static const double snackbar = 8.0;

  // Enhanced radius values for better visual hierarchy
  static const double micro = 2.0;
  static const double tiny = 4.0;
  static const double standard = 8.0;
  static const double comfortable = 12.0;
  static const double spacious = 16.0;
  static const double extraSpacious = 24.0;
  static const double circular = 999.0;
}

/// Consistent border width values - Enhanced for production
class BorderWidth {
  static const double thin = 0.5;
  static const double regular = 1.0;
  static const double medium = 1.5;
  static const double thick = 2.0;

  // Enhanced border widths for better visual hierarchy
  static const double micro = 0.5;
  static const double small = 1.0;
  static const double standard = 1.5;
  static const double large = 2.0;
  static const double extraLarge = 3.0;
}

/// Consistent elevation values - Enhanced for production with better hierarchy
class Elevation {
  static const double none = 0.0;
  static const double low = 2.0;
  static const double medium = 4.0;
  static const double high = 8.0;
  static const double highest = 16.0;

  // Enhanced elevation values for better visual hierarchy
  static const double micro = 1.0;
  static const double small = 2.0;
  static const double standard = 4.0;
  static const double large = 8.0;
  static const double extraLarge = 16.0;
  static const double massive = 24.0;
}

/// Helper class for consistent shadows - Enhanced for production with better hierarchy
class ConduitShadows {
  static List<BoxShadow> low(BuildContext context) => _shadow(
    context.colorTokens,
    opacity: 0.08,
    blurRadius: 8,
    offset: const Offset(0, 2),
  );

  static List<BoxShadow> medium(BuildContext context) => _shadow(
    context.colorTokens,
    opacity: 0.12,
    blurRadius: 16,
    offset: const Offset(0, 4),
  );

  static List<BoxShadow> high(BuildContext context) => _shadow(
    context.colorTokens,
    opacity: 0.16,
    blurRadius: 24,
    offset: const Offset(0, 8),
  );

  static List<BoxShadow> glow(BuildContext context) =>
      glowWithTokens(context.colorTokens);

  static List<BoxShadow> glowWithTokens(AppColorTokens tokens) {
    final double alpha = tokens.brightness == Brightness.light ? 0.25 : 0.35;
    return [
      BoxShadow(
        color: tokens.brandTone60.withValues(alpha: alpha),
        blurRadius: 20,
        offset: const Offset(0, 0),
        spreadRadius: 0,
      ),
    ];
  }

  static List<BoxShadow> card(BuildContext context) => _shadow(
    context.colorTokens,
    opacity: 0.06,
    blurRadius: 12,
    offset: const Offset(0, 3),
  );

  static List<BoxShadow> button(BuildContext context) => _shadow(
    context.colorTokens,
    opacity: 0.1,
    blurRadius: 6,
    offset: const Offset(0, 2),
  );

  static List<BoxShadow> modal(BuildContext context) => _shadow(
    context.colorTokens,
    opacity: 0.2,
    blurRadius: 32,
    offset: const Offset(0, 12),
  );

  static List<BoxShadow> navigation(BuildContext context) => _shadow(
    context.colorTokens,
    opacity: 0.08,
    blurRadius: 16,
    offset: const Offset(0, -2),
  );

  static List<BoxShadow> messageBubble(BuildContext context) => _shadow(
    context.colorTokens,
    opacity: 0.04,
    blurRadius: 8,
    offset: const Offset(0, 1),
  );

  static List<BoxShadow> input(BuildContext context) => _shadow(
    context.colorTokens,
    opacity: 0.05,
    blurRadius: 4,
    offset: const Offset(0, 1),
  );

  static List<BoxShadow> pressed(BuildContext context) => _shadow(
    context.colorTokens,
    opacity: 0.15,
    blurRadius: 4,
    offset: const Offset(0, 1),
  );

  static List<BoxShadow> hover(BuildContext context) => _shadow(
    context.colorTokens,
    opacity: 0.12,
    blurRadius: 12,
    offset: const Offset(0, 4),
  );

  static List<BoxShadow> micro(BuildContext context) => _shadow(
    context.colorTokens,
    opacity: 0.04,
    blurRadius: 4,
    offset: const Offset(0, 1),
  );

  static List<BoxShadow> small(BuildContext context) => _shadow(
    context.colorTokens,
    opacity: 0.06,
    blurRadius: 8,
    offset: const Offset(0, 2),
  );

  static List<BoxShadow> standard(BuildContext context) => _shadow(
    context.colorTokens,
    opacity: 0.08,
    blurRadius: 12,
    offset: const Offset(0, 3),
  );

  static List<BoxShadow> large(BuildContext context) => _shadow(
    context.colorTokens,
    opacity: 0.12,
    blurRadius: 16,
    offset: const Offset(0, 4),
  );

  static List<BoxShadow> extraLarge(BuildContext context) => _shadow(
    context.colorTokens,
    opacity: 0.16,
    blurRadius: 24,
    offset: const Offset(0, 8),
  );

  static List<BoxShadow> _shadow(
    AppColorTokens tokens, {
    required double opacity,
    required double blurRadius,
    required Offset offset,
  }) {
    return [
      BoxShadow(
        color: _overlayColor(tokens, opacity),
        blurRadius: blurRadius,
        offset: offset,
        spreadRadius: 0,
      ),
    ];
  }

  static Color _overlayColor(AppColorTokens tokens, double alpha) {
    final Color base = tokens.overlayStrong.withValues(alpha: 1.0);
    return base.withValues(alpha: alpha.clamp(0.0, 1.0));
  }
}

/// Typography scale following Conduit design tokens - Enhanced for production
class AppTypography {
  // Primary UI font now uses the platform default system font
  static const String fontFamily = '';
  static const String monospaceFontFamily = 'monospace';

  // Letter spacing values - Enhanced for better readability
  static const double letterSpacingTight = -0.5;
  static const double letterSpacingNormal = 0.0;
  static const double letterSpacingWide = 0.5;
  static const double letterSpacingExtraWide = 1.0;

  // Font sizes - Enhanced scale for better hierarchy
  static const double displayLarge = 48;
  static const double displayMedium = 36;
  static const double displaySmall = 32;
  static const double headlineLarge = 28;
  static const double headlineMedium = 24;
  static const double headlineSmall = 20;
  static const double bodyLarge = 18;
  static const double bodyMedium = 16;
  static const double bodySmall = 14;
  static const double labelLarge = 16;
  static const double labelMedium = 14;
  static const double labelSmall = 12;

  // Text styles following Conduit design - Enhanced for production
  static final TextStyle displayLargeStyle = const TextStyle(
    fontWeight: FontWeight.w700,
    letterSpacing: -0.8,
    height: 1.1,
  ).copyWith(fontSize: displayLarge);

  static final TextStyle displayMediumStyle = const TextStyle(
    fontWeight: FontWeight.w700,
    letterSpacing: -0.6,
    height: 1.2,
  ).copyWith(fontSize: displayMedium);

  static final TextStyle bodyLargeStyle = const TextStyle(
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.6,
  ).copyWith(fontSize: bodyLarge);

  static final TextStyle bodyMediumStyle = const TextStyle(
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.6,
  ).copyWith(fontSize: bodyMedium);

  static final TextStyle codeStyle = const TextStyle(
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.5,
    fontFamily: monospaceFontFamily,
  ).copyWith(fontSize: bodySmall);

  // Additional styled text getters for convenience - Enhanced
  static TextStyle get headlineLargeStyle => const TextStyle(
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
    height: 1.3,
  ).copyWith(fontSize: headlineLarge);

  static TextStyle get headlineMediumStyle => const TextStyle(
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    height: 1.3,
  ).copyWith(fontSize: headlineMedium);

  static TextStyle get headlineSmallStyle => const TextStyle(
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    height: 1.4,
  ).copyWith(fontSize: headlineSmall);

  static TextStyle get bodySmallStyle => const TextStyle(
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.5,
  ).copyWith(fontSize: bodySmall);

  // Enhanced text styles for chat messages
  static TextStyle get chatMessageStyle => const TextStyle(
    fontWeight: FontWeight.w400,
    letterSpacing: 0.0,
    height: 1.4,
  ).copyWith(fontSize: bodyMedium);

  static TextStyle get chatCodeStyle => const TextStyle(
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.5,
    fontFamily: monospaceFontFamily,
  ).copyWith(fontSize: bodySmall);

  // Enhanced label styles
  static TextStyle get labelStyle => const TextStyle(
    fontWeight: FontWeight.w500,
    letterSpacing: 0.2,
    height: 1.4,
  ).copyWith(fontSize: labelMedium);

  // Enhanced caption styles
  static TextStyle get captionStyle => const TextStyle(
    fontWeight: FontWeight.w500,
    letterSpacing: 0.5,
    height: 1.3,
  ).copyWith(fontSize: labelSmall);

  // Enhanced typography for better hierarchy
  static TextStyle get micro => const TextStyle(
    fontWeight: FontWeight.w400,
    letterSpacing: 0.1,
    height: 1.4,
  ).copyWith(fontSize: 10);

  static TextStyle get tiny => const TextStyle(
    fontWeight: FontWeight.w400,
    letterSpacing: 0.1,
    height: 1.4,
  ).copyWith(fontSize: 12);

  static TextStyle get small => const TextStyle(
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.5,
  ).copyWith(fontSize: 14);

  static TextStyle get standard => const TextStyle(
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.6,
  ).copyWith(fontSize: 16);

  static TextStyle get large => const TextStyle(
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.6,
  ).copyWith(fontSize: 18);

  static TextStyle get extraLarge => const TextStyle(
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.5,
  ).copyWith(fontSize: 20);

  static TextStyle get huge => const TextStyle(
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    height: 1.3,
  ).copyWith(fontSize: 24);

  static TextStyle get massive => const TextStyle(
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
    height: 1.2,
  ).copyWith(fontSize: 32);
}

/// Consistent icon sizes - Enhanced for production with better hierarchy
class IconSize {
  static const double xs = 12.0;
  static const double sm = 16.0;
  static const double md = 20.0;
  static const double lg = 24.0;
  static const double xl = 32.0;
  static const double xxl = 48.0;

  // Enhanced icon sizes for specific components with better hierarchy
  static const double button = 20.0;
  static const double card = 24.0;
  static const double input = 20.0;
  static const double modal = 24.0;
  static const double message = 18.0;
  static const double navigation = 24.0;
  static const double avatar = 40.0;
  static const double badge = 16.0;
  static const double chip = 18.0;
  static const double tooltip = 16.0;

  // Icon sizes for different contexts with improved hierarchy
  static const double micro = 12.0;
  static const double small = 16.0;
  static const double medium = 20.0;
  static const double large = 24.0;
  static const double extraLarge = 32.0;
  static const double huge = 48.0;

  // Specific component icon sizes with better consistency
  static const double chatBubble = 18.0;
  static const double actionButton = 20.0;
  static const double floatingButton = 24.0;
  static const double bottomSheet = 24.0;
  static const double dialog = 24.0;
  static const double snackbar = 20.0;
  static const double tabBar = 24.0;
  static const double appBar = 24.0;
  static const double listItem = 20.0;
  static const double formField = 20.0;
}

/// Alpha values for opacity/transparency - Enhanced for production with better hierarchy
class Alpha {
  static const double subtle = 0.1;
  static const double light = 0.3;
  static const double medium = 0.5;
  static const double strong = 0.7;
  static const double intense = 0.9;

  // Enhanced alpha values for specific use cases with better hierarchy
  static const double disabled = 0.38;
  static const double overlay = 0.5;
  static const double backdrop = 0.6;
  static const double highlight = 0.12;
  static const double pressed = 0.2;
  static const double hover = 0.08;
  static const double focus = 0.12;
  static const double selected = 0.16;
  static const double active = 0.24;
  static const double inactive = 0.6;

  // Alpha values for different states with improved hierarchy
  static const double primary = 1.0;
  static const double secondary = 0.7;
  static const double tertiary = 0.5;
  static const double quaternary = 0.3;
  static const double disabledText = 0.38;
  static const double disabledIcon = 0.38;
  static const double disabledBackground = 0.12;

  // Specific component alpha values with better consistency
  static const double buttonPressed = 0.2;
  static const double buttonHover = 0.08;
  static const double cardHover = 0.04;
  static const double inputFocus = 0.12;
  static const double modalBackdrop = 0.6;
  static const double snackbarBackground = 0.95;
  static const double tooltipBackground = 0.9;
  static const double badgeBackground = 0.1;
  static const double chipBackground = 0.08;
  static const double avatarBorder = 0.2;

  // Enhanced alpha values for better visual hierarchy
  static const double micro = 0.05;
  static const double tiny = 0.1;
  static const double small = 0.2;
  static const double standard = 0.3;
  static const double large = 0.5;
  static const double extraLarge = 0.7;
  static const double huge = 0.9;
}

/// Touch target sizes for accessibility compliance - Enhanced for production with better hierarchy
class TouchTarget {
  static const double minimum = 44.0;
  static const double comfortable = 48.0;
  static const double large = 56.0;

  // Enhanced touch targets for specific components with better hierarchy
  static const double button = 48.0;
  static const double card = 48.0;
  static const double input = 48.0;
  static const double modal = 48.0;
  static const double message = 44.0;
  static const double navigation = 48.0;
  static const double avatar = 48.0;
  static const double badge = 32.0;
  static const double chip = 32.0;
  static const double tooltip = 32.0;

  // Touch targets for different contexts with improved hierarchy
  static const double micro = 32.0;
  static const double small = 40.0;
  static const double medium = 48.0;
  static const double standard = 56.0;
  static const double extraLarge = 64.0;
  static const double huge = 80.0;

  // Specific component touch targets with better consistency
  static const double chatBubble = 44.0;
  static const double actionButton = 48.0;
  static const double floatingButton = 56.0;
  static const double bottomSheet = 48.0;
  static const double dialog = 48.0;
  static const double snackbar = 48.0;
  static const double tabBar = 48.0;
  static const double appBar = 48.0;
  static const double listItem = 48.0;
  static const double formField = 48.0;
  static const double iconButton = 48.0;
  static const double textButton = 44.0;
  static const double toggle = 48.0;
  static const double slider = 48.0;
  static const double checkbox = 48.0;
  static const double radio = 48.0;
}

/// Animation durations for consistent motion design - Enhanced for production with better hierarchy
class AnimationDuration {
  static const Duration instant = Duration(milliseconds: 100);
  static const Duration fast = Duration(milliseconds: 200);
  static const Duration medium = Duration(milliseconds: 300);
  static const Duration slow = Duration(milliseconds: 500);
  static const Duration slower = Duration(milliseconds: 800);
  static const Duration slowest = Duration(milliseconds: 1000);
  static const Duration extraSlow = Duration(milliseconds: 1200);
  static const Duration ultra = Duration(milliseconds: 1500);
  static const Duration extended = Duration(seconds: 2);
  static const Duration long = Duration(seconds: 4);

  // Enhanced durations for specific interactions with better hierarchy
  static const Duration microInteraction = Duration(milliseconds: 150);
  static const Duration buttonPress = Duration(milliseconds: 100);
  static const Duration cardHover = Duration(milliseconds: 200);
  static const Duration pageTransition = Duration(milliseconds: 400);
  static const Duration modalPresentation = Duration(milliseconds: 500);
  static const Duration typingIndicator = Duration(milliseconds: 800);
  static const Duration messageAppear = Duration(milliseconds: 350);
  static const Duration messageSlide = Duration(milliseconds: 400);

  // Enhanced durations for better visual hierarchy
  static const Duration micro = Duration(milliseconds: 50);
  static const Duration tiny = Duration(milliseconds: 100);
  static const Duration small = Duration(milliseconds: 200);
  static const Duration standard = Duration(milliseconds: 300);
  static const Duration large = Duration(milliseconds: 500);
  static const Duration extraLarge = Duration(milliseconds: 800);
  static const Duration huge = Duration(milliseconds: 1200);
}

/// Animation curves for consistent motion design - Enhanced for production with better hierarchy
class AnimationCurves {
  static const Curve easeIn = Curves.easeIn;
  static const Curve easeOut = Curves.easeOut;
  static const Curve easeInOut = Curves.easeInOut;
  static const Curve bounce = Curves.bounceOut;
  static const Curve elastic = Curves.elasticOut;
  static const Curve fastOutSlowIn = Curves.fastOutSlowIn;
  static const Curve linear = Curves.linear;

  // Enhanced curves for specific interactions with better hierarchy
  static const Curve buttonPress = Curves.easeOutCubic;
  static const Curve cardHover = Curves.easeInOutCubic;
  static const Curve messageSlide = Curves.easeOutCubic;
  static const Curve typingIndicator = Curves.easeInOut;
  static const Curve modalPresentation = Curves.easeOutBack;
  static const Curve pageTransition = Curves.easeInOutCubic;
  static const Curve microInteraction = Curves.easeOutQuart;
  static const Curve spring = Curves.elasticOut;

  // Enhanced curves for better visual hierarchy
  static const Curve micro = Curves.easeOutQuart;
  static const Curve tiny = Curves.easeOutCubic;
  static const Curve small = Curves.easeInOutCubic;
  static const Curve standard = Curves.easeInOut;
  static const Curve large = Curves.easeOutBack;
  static const Curve extraLarge = Curves.elasticOut;
  static const Curve huge = Curves.bounceOut;
}

/// Common animation values - Enhanced for production with better hierarchy
class AnimationValues {
  static const double fadeInOpacity = 0.0;
  static const double fadeOutOpacity = 1.0;
  static const Offset slideInFromTop = Offset(0, -0.05);
  static const Offset slideInFromBottom = Offset(0, 0.05);
  static const Offset slideInFromLeft = Offset(-0.05, 0);
  static const Offset slideInFromRight = Offset(0.05, 0);
  static const Offset slideCenter = Offset.zero;
  static const double scaleMin = 0.0;
  static const double scaleMax = 1.0;
  static const double shimmerBegin = -1.0;
  static const double shimmerEnd = 2.0;

  // Enhanced values for specific interactions with better hierarchy
  static const double buttonScalePressed = 0.95;
  static const double buttonScaleHover = 1.02;
  static const double cardScaleHover = 1.01;
  static const double messageSlideDistance = 0.1;
  static const double typingIndicatorScale = 0.8;
  static const double modalScale = 0.9;
  static const double pageSlideDistance = 0.15;
  static const double microInteractionScale = 0.98;

  // Enhanced values for better visual hierarchy
  static const double micro = 0.95;
  static const double tiny = 0.98;
  static const double small = 1.01;
  static const double standard = 1.02;
  static const double large = 1.05;
  static const double extraLarge = 1.1;
  static const double huge = 1.2;
}

/// Delay values for staggered animations - Enhanced for production with better hierarchy
class AnimationDelay {
  static const Duration none = Duration.zero;
  static const Duration short = Duration(milliseconds: 100);
  static const Duration medium = Duration(milliseconds: 200);
  static const Duration long = Duration(milliseconds: 400);
  static const Duration extraLong = Duration(milliseconds: 600);
  static const Duration ultra = Duration(milliseconds: 800);

  // Enhanced delays for specific interactions with better hierarchy
  static const Duration microDelay = Duration(milliseconds: 50);
  static const Duration buttonDelay = Duration(milliseconds: 75);
  static const Duration cardDelay = Duration(milliseconds: 150);
  static const Duration messageDelay = Duration(milliseconds: 100);
  static const Duration typingDelay = Duration(milliseconds: 200);
  static const Duration modalDelay = Duration(milliseconds: 300);
  static const Duration pageDelay = Duration(milliseconds: 250);
  static const Duration staggeredDelay = Duration(milliseconds: 50);

  // Enhanced delays for better visual hierarchy
  static const Duration micro = Duration(milliseconds: 25);
  static const Duration tiny = Duration(milliseconds: 50);
  static const Duration small = Duration(milliseconds: 100);
  static const Duration standard = Duration(milliseconds: 200);
  static const Duration large = Duration(milliseconds: 400);
  static const Duration extraLarge = Duration(milliseconds: 600);
  static const Duration huge = Duration(milliseconds: 800);
}
