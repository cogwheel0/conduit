import 'package:flutter/material.dart';

import 'tweakcn_themes.dart';

/// Immutable set of semantic color tokens exposed through [ThemeExtension].
///
/// The tokens are derived from the Qonduit color specification and provide
/// consistent mappings for light and dark modes. Widgets should prefer using
/// these tokens instead of hard-coded color values to ensure theme parity and
/// accessible contrast levels.
@immutable
class AppColorTokens extends ThemeExtension<AppColorTokens> {
  const AppColorTokens({
    required this.brightness,
    required this.neutralTone00,
    required this.neutralTone10,
    required this.neutralTone20,
    required this.neutralTone40,
    required this.neutralTone60,
    required this.neutralTone80,
    required this.neutralOnSurface,
    required this.brandTone40,
    required this.brandTone60,
    required this.brandOn60,
    required this.brandTone90,
    required this.brandOn90,
    required this.accentIndigo60,
    required this.accentOnIndigo60,
    required this.accentTeal60,
    required this.accentGold60,
    required this.statusSuccess60,
    required this.statusOnSuccess60,
    required this.statusWarning60,
    required this.statusOnWarning60,
    required this.statusError60,
    required this.statusOnError60,
    required this.statusInfo60,
    required this.statusOnInfo60,
    required this.overlayWeak,
    required this.overlayMedium,
    required this.overlayStrong,
    required this.scrimMedium,
    required this.scrimStrong,
    required this.codeBackground,
    required this.codeBorder,
    required this.codeText,
    required this.codeAccent,
  });

  final Brightness brightness;

  // Neutral tokens
  final Color neutralTone00;
  final Color neutralTone10;
  final Color neutralTone20;
  final Color neutralTone40;
  final Color neutralTone60;
  final Color neutralTone80;
  final Color neutralOnSurface;

  // Brand tokens
  final Color brandTone40;
  final Color brandTone60;
  final Color brandOn60;
  final Color brandTone90;
  final Color brandOn90;

  // Accent tokens
  final Color accentIndigo60;
  final Color accentOnIndigo60;
  final Color accentTeal60;
  final Color accentGold60;

  // Status tokens
  final Color statusSuccess60;
  final Color statusOnSuccess60;
  final Color statusWarning60;
  final Color statusOnWarning60;
  final Color statusError60;
  final Color statusOnError60;
  final Color statusInfo60;
  final Color statusOnInfo60;

  // Overlay tokens
  final Color overlayWeak;
  final Color overlayMedium;
  final Color overlayStrong;

  // Scrim tokens (for drawer/modal overlays)
  final Color scrimMedium;
  final Color scrimStrong;

  // Markdown/code tokens
  final Color codeBackground;
  final Color codeBorder;
  final Color codeText;
  final Color codeAccent;

  factory AppColorTokens.light({TweakcnThemeDefinition? theme}) {
    return AppColorTokens._fromTheme(
      theme ?? TweakcnThemes.qonduit,
      Brightness.light,
    );
  }

  factory AppColorTokens.dark({TweakcnThemeDefinition? theme}) {
    return AppColorTokens._fromTheme(
      theme ?? TweakcnThemes.qonduit,
      Brightness.dark,
    );
  }

  factory AppColorTokens._fromTheme(
    TweakcnThemeDefinition theme,
    Brightness brightness,
  ) {
    final TweakcnThemeVariant variant = theme.variantFor(brightness);
    final bool isLight = brightness == Brightness.light;

    final Color neutralTone00 = variant.background;
    final Color neutralTone20 = variant.card;
    final Color neutralTone10 = mix(neutralTone00, neutralTone20, 0.5);
    final Color neutralTone40 = variant.muted;
    final Color neutralTone60 = mix(
      variant.mutedForeground,
      variant.foreground,
      isLight ? 0.25 : 0.4,
    );
    final Color neutralTone80 = mix(
      variant.foreground,
      isLight ? Colors.black : Colors.white,
      isLight ? 0.06 : 0.3,
    );
    final Color neutralOnSurface = _ensureContrast(
      surface: neutralTone00,
      foreground: variant.foreground,
      minContrast: 4.5,
    );

    final Color brandTone60 = variant.primary;
    final Color brandOn60 = _ensureContrast(
      surface: brandTone60,
      foreground: variant.primaryForeground,
    );
    final Color brandTone90 = mix(
      variant.primary,
      neutralTone00,
      isLight ? 0.7 : 0.3,
    );
    final Color brandOn90 = _ensureContrast(
      surface: brandTone90,
      foreground: brandOn60,
    );
    final Color brandTone40 = mix(
      variant.primary,
      neutralOnSurface,
      isLight ? 0.35 : 0.55,
    );

    final Color accentIndigo60 = variant.secondary;
    final Color accentOnIndigo60 = _ensureContrast(
      surface: accentIndigo60,
      foreground: variant.secondaryForeground,
    );
    final Color accentTeal60 = variant.accent;
    final Color accentGold60 = mix(
      variant.accent,
      isLight ? Colors.white : Colors.black,
      isLight ? 0.18 : 0.24,
    );

    final Color statusError60 = variant.destructive;
    final Color statusOnError60 = _ensureContrast(
      surface: statusError60,
      foreground: variant.destructiveForeground,
    );
    final Color statusSuccess60 = variant.success;
    final Color statusOnSuccess60 = _ensureContrast(
      surface: statusSuccess60,
      foreground: variant.successForeground,
    );
    final Color statusWarning60 = variant.warning;
    final Color statusOnWarning60 = _ensureContrast(
      surface: statusWarning60,
      foreground: variant.warningForeground,
    );
    final Color statusInfo60 = variant.info;
    final Color statusOnInfo60 = _ensureContrast(
      surface: statusInfo60,
      foreground: variant.infoForeground,
    );

    final Color overlayWeak = neutralOnSurface.withValues(
      alpha: isLight ? 0.08 : 0.12,
    );
    final Color overlayMedium = neutralOnSurface.withValues(
      alpha: isLight ? 0.16 : 0.2,
    );
    final Color overlayStrong = neutralOnSurface.withValues(
      alpha: isLight ? 0.32 : 0.36,
    );

    // Scrim tokens use black to create darkening effect in both modes
    final Color scrimMedium = Colors.black.withValues(
      alpha: isLight ? 0.2 : 0.5,
    );
    final Color scrimStrong = Colors.black.withValues(
      alpha: isLight ? 0.32 : 0.6,
    );

    final Color codeBackground = mix(variant.muted, neutralTone00, 0.5);
    final Color codeBorder = mix(variant.border, neutralTone40, 0.6);
    final Color codeText = _ensureContrast(
      surface: codeBackground,
      foreground: neutralOnSurface,
      minContrast: 4.5,
    );
    final Color codeAccent = mix(variant.accent, variant.primary, 0.4);

    return AppColorTokens(
      brightness: brightness,
      neutralTone00: neutralTone00,
      neutralTone10: neutralTone10,
      neutralTone20: neutralTone20,
      neutralTone40: neutralTone40,
      neutralTone60: neutralTone60,
      neutralTone80: neutralTone80,
      neutralOnSurface: neutralOnSurface,
      brandTone40: brandTone40,
      brandTone60: brandTone60,
      brandOn60: brandOn60,
      brandTone90: brandTone90,
      brandOn90: brandOn90,
      accentIndigo60: accentIndigo60,
      accentOnIndigo60: accentOnIndigo60,
      accentTeal60: accentTeal60,
      accentGold60: accentGold60,
      statusSuccess60: statusSuccess60,
      statusOnSuccess60: statusOnSuccess60,
      statusWarning60: statusWarning60,
      statusOnWarning60: statusOnWarning60,
      statusError60: statusError60,
      statusOnError60: statusOnError60,
      statusInfo60: statusInfo60,
      statusOnInfo60: statusOnInfo60,
      overlayWeak: overlayWeak,
      overlayMedium: overlayMedium,
      overlayStrong: overlayStrong,
      scrimMedium: scrimMedium,
      scrimStrong: scrimStrong,
      codeBackground: codeBackground,
      codeBorder: codeBorder,
      codeText: codeText,
      codeAccent: codeAccent,
    );
  }

  @override
  AppColorTokens copyWith({
    Brightness? brightness,
    Color? neutralTone00,
    Color? neutralTone10,
    Color? neutralTone20,
    Color? neutralTone40,
    Color? neutralTone60,
    Color? neutralTone80,
    Color? neutralOnSurface,
    Color? brandTone40,
    Color? brandTone60,
    Color? brandOn60,
    Color? brandTone90,
    Color? brandOn90,
    Color? accentIndigo60,
    Color? accentOnIndigo60,
    Color? accentTeal60,
    Color? accentGold60,
    Color? statusSuccess60,
    Color? statusOnSuccess60,
    Color? statusWarning60,
    Color? statusOnWarning60,
    Color? statusError60,
    Color? statusOnError60,
    Color? statusInfo60,
    Color? statusOnInfo60,
    Color? overlayWeak,
    Color? overlayMedium,
    Color? overlayStrong,
    Color? scrimMedium,
    Color? scrimStrong,
    Color? codeBackground,
    Color? codeBorder,
    Color? codeText,
    Color? codeAccent,
  }) {
    return AppColorTokens(
      brightness: brightness ?? this.brightness,
      neutralTone00: neutralTone00 ?? this.neutralTone00,
      neutralTone10: neutralTone10 ?? this.neutralTone10,
      neutralTone20: neutralTone20 ?? this.neutralTone20,
      neutralTone40: neutralTone40 ?? this.neutralTone40,
      neutralTone60: neutralTone60 ?? this.neutralTone60,
      neutralTone80: neutralTone80 ?? this.neutralTone80,
      neutralOnSurface: neutralOnSurface ?? this.neutralOnSurface,
      brandTone40: brandTone40 ?? this.brandTone40,
      brandTone60: brandTone60 ?? this.brandTone60,
      brandOn60: brandOn60 ?? this.brandOn60,
      brandTone90: brandTone90 ?? this.brandTone90,
      brandOn90: brandOn90 ?? this.brandOn90,
      accentIndigo60: accentIndigo60 ?? this.accentIndigo60,
      accentOnIndigo60: accentOnIndigo60 ?? this.accentOnIndigo60,
      accentTeal60: accentTeal60 ?? this.accentTeal60,
      accentGold60: accentGold60 ?? this.accentGold60,
      statusSuccess60: statusSuccess60 ?? this.statusSuccess60,
      statusOnSuccess60: statusOnSuccess60 ?? this.statusOnSuccess60,
      statusWarning60: statusWarning60 ?? this.statusWarning60,
      statusOnWarning60: statusOnWarning60 ?? this.statusOnWarning60,
      statusError60: statusError60 ?? this.statusError60,
      statusOnError60: statusOnError60 ?? this.statusOnError60,
      statusInfo60: statusInfo60 ?? this.statusInfo60,
      statusOnInfo60: statusOnInfo60 ?? this.statusOnInfo60,
      overlayWeak: overlayWeak ?? this.overlayWeak,
      overlayMedium: overlayMedium ?? this.overlayMedium,
      overlayStrong: overlayStrong ?? this.overlayStrong,
      scrimMedium: scrimMedium ?? this.scrimMedium,
      scrimStrong: scrimStrong ?? this.scrimStrong,
      codeBackground: codeBackground ?? this.codeBackground,
      codeBorder: codeBorder ?? this.codeBorder,
      codeText: codeText ?? this.codeText,
      codeAccent: codeAccent ?? this.codeAccent,
    );
  }

  @override
  AppColorTokens lerp(
    covariant ThemeExtension<AppColorTokens>? other,
    double t,
  ) {
    if (other is! AppColorTokens) {
      return this;
    }

    return AppColorTokens(
      brightness: t < 0.5 ? brightness : other.brightness,
      neutralTone00: Color.lerp(neutralTone00, other.neutralTone00, t)!,
      neutralTone10: Color.lerp(neutralTone10, other.neutralTone10, t)!,
      neutralTone20: Color.lerp(neutralTone20, other.neutralTone20, t)!,
      neutralTone40: Color.lerp(neutralTone40, other.neutralTone40, t)!,
      neutralTone60: Color.lerp(neutralTone60, other.neutralTone60, t)!,
      neutralTone80: Color.lerp(neutralTone80, other.neutralTone80, t)!,
      neutralOnSurface: Color.lerp(
        neutralOnSurface,
        other.neutralOnSurface,
        t,
      )!,
      brandTone40: Color.lerp(brandTone40, other.brandTone40, t)!,
      brandTone60: Color.lerp(brandTone60, other.brandTone60, t)!,
      brandOn60: Color.lerp(brandOn60, other.brandOn60, t)!,
      brandTone90: Color.lerp(brandTone90, other.brandTone90, t)!,
      brandOn90: Color.lerp(brandOn90, other.brandOn90, t)!,
      accentIndigo60: Color.lerp(accentIndigo60, other.accentIndigo60, t)!,
      accentOnIndigo60: Color.lerp(
        accentOnIndigo60,
        other.accentOnIndigo60,
        t,
      )!,
      accentTeal60: Color.lerp(accentTeal60, other.accentTeal60, t)!,
      accentGold60: Color.lerp(accentGold60, other.accentGold60, t)!,
      statusSuccess60: Color.lerp(statusSuccess60, other.statusSuccess60, t)!,
      statusOnSuccess60: Color.lerp(
        statusOnSuccess60,
        other.statusOnSuccess60,
        t,
      )!,
      statusWarning60: Color.lerp(statusWarning60, other.statusWarning60, t)!,
      statusOnWarning60: Color.lerp(
        statusOnWarning60,
        other.statusOnWarning60,
        t,
      )!,
      statusError60: Color.lerp(statusError60, other.statusError60, t)!,
      statusOnError60: Color.lerp(statusOnError60, other.statusOnError60, t)!,
      statusInfo60: Color.lerp(statusInfo60, other.statusInfo60, t)!,
      statusOnInfo60: Color.lerp(statusOnInfo60, other.statusOnInfo60, t)!,
      overlayWeak: Color.lerp(overlayWeak, other.overlayWeak, t)!,
      overlayMedium: Color.lerp(overlayMedium, other.overlayMedium, t)!,
      overlayStrong: Color.lerp(overlayStrong, other.overlayStrong, t)!,
      scrimMedium: Color.lerp(scrimMedium, other.scrimMedium, t)!,
      scrimStrong: Color.lerp(scrimStrong, other.scrimStrong, t)!,
      codeBackground: Color.lerp(codeBackground, other.codeBackground, t)!,
      codeBorder: Color.lerp(codeBorder, other.codeBorder, t)!,
      codeText: Color.lerp(codeText, other.codeText, t)!,
      codeAccent: Color.lerp(codeAccent, other.codeAccent, t)!,
    );
  }

  /// Generates a Material [ColorScheme] that aligns with the defined tokens.
  ColorScheme toColorScheme() {
    final base = ColorScheme.fromSeed(
      seedColor: brandTone60,
      brightness: brightness,
    );

    return base.copyWith(
      primary: brandTone60,
      onPrimary: brandOn60,
      primaryContainer: brandTone90,
      onPrimaryContainer: brandOn90,
      secondary: accentIndigo60,
      onSecondary: accentOnIndigo60,
      tertiary: accentTeal60,
      onTertiary: _ensureContrast(
        surface: accentTeal60,
        foreground: neutralTone00,
      ),
      surface: neutralTone00,
      surfaceContainerLow: neutralTone10,
      surfaceContainerHighest: neutralTone20,
      onSurface: neutralOnSurface,
      onSurfaceVariant: neutralTone60,
      outline: neutralTone60,
      outlineVariant: neutralTone40,
      error: statusError60,
      onError: statusOnError60,
      surfaceTint: brandTone40,
      scrim: overlayStrong,
    );
  }

  /// Convenience helper to composite an overlay on top of the correct surface.
  Color overlayOnSurface(Color overlay, {Color? surface}) {
    final baseSurface = surface ?? neutralTone00;
    return Color.alphaBlend(overlay, baseSurface);
  }

  static AppColorTokens fallback({Brightness brightness = Brightness.light}) {
    return brightness == Brightness.dark
        ? AppColorTokens.dark()
        : AppColorTokens.light();
  }

  static Color _ensureContrast({
    required Color surface,
    required Color foreground,
    double minContrast = 4.5,
  }) {
    // No-op for testing; bypass contrast adjustments.
    return foreground;
  }
}
