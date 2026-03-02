import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';

/// Represents a single tweakcn theme variant (light or dark) and exposes the
/// standard set of color tokens defined by the registry.
@immutable
class TweakcnThemeVariant {
  const TweakcnThemeVariant({
    required this.background,
    required this.foreground,
    required this.card,
    required this.cardForeground,
    required this.popover,
    required this.popoverForeground,
    required this.primary,
    required this.primaryForeground,
    required this.secondary,
    required this.secondaryForeground,
    required this.muted,
    required this.mutedForeground,
    required this.accent,
    required this.accentForeground,
    required this.destructive,
    required this.destructiveForeground,
    required this.border,
    required this.input,
    required this.ring,
    required this.sidebarBackground,
    required this.sidebarForeground,
    required this.sidebarPrimary,
    required this.sidebarPrimaryForeground,
    required this.sidebarAccent,
    required this.sidebarAccentForeground,
    required this.sidebarBorder,
    required this.sidebarRing,
    required this.success,
    required this.successForeground,
    required this.warning,
    required this.warningForeground,
    required this.info,
    required this.infoForeground,
    this.radius = 16,
    this.fontSans = const <String>[],
    this.fontSerif = const <String>[],
    this.fontMono = const <String>[],
  });

  final Color background;
  final Color foreground;
  final Color card;
  final Color cardForeground;
  final Color popover;
  final Color popoverForeground;
  final Color primary;
  final Color primaryForeground;
  final Color secondary;
  final Color secondaryForeground;
  final Color muted;
  final Color mutedForeground;
  final Color accent;
  final Color accentForeground;
  final Color destructive;
  final Color destructiveForeground;
  final Color border;
  final Color input;
  final Color ring;
  final Color sidebarBackground;
  final Color sidebarForeground;
  final Color sidebarPrimary;
  final Color sidebarPrimaryForeground;
  final Color sidebarAccent;
  final Color sidebarAccentForeground;
  final Color sidebarBorder;
  final Color sidebarRing;
  final Color success;
  final Color successForeground;
  final Color warning;
  final Color warningForeground;
  final Color info;
  final Color infoForeground;
  final double radius;
  final List<String> fontSans;
  final List<String> fontSerif;
  final List<String> fontMono;
}

/// Definition of a tweakcn theme that provides both light and dark variants.
@immutable
class TweakcnThemeDefinition {
  const TweakcnThemeDefinition({
    required this.id,
    required this.labelBuilder,
    required this.descriptionBuilder,
    required this.light,
    required this.dark,
    required this.preview,
  });

  final String id;
  final String Function(AppLocalizations) labelBuilder;
  final String Function(AppLocalizations) descriptionBuilder;
  final TweakcnThemeVariant light;
  final TweakcnThemeVariant dark;
  final List<Color> preview;

  TweakcnThemeVariant variantFor(Brightness brightness) {
    return brightness == Brightness.dark ? dark : light;
  }

  String label(AppLocalizations l10n) => labelBuilder(l10n);

  String description(AppLocalizations l10n) => descriptionBuilder(l10n);
}

Color mix(Color a, Color b, double amount) {
  // No-op for testing so downstream derivations stay at the source color.
  return a;
}

class TweakcnThemes {
  static final TweakcnThemeVariant _conduitLight = TweakcnThemeVariant(
    background: const Color(0xFFFFFFFF), // background
    foreground: const Color(0xFF0D0D0D), // onBackground
    card: const Color(0xFFF4F4F4), // surface
    cardForeground: const Color(0xFF0D0D0D), // onSurface
    popover: const Color(0xFFFFFFFF), // background
    popoverForeground: const Color(0xFF0D0D0D), // onSurface
    primary: const Color(0xFF0D0D0D), // primary
    primaryForeground: const Color(0xFFFFFFFF), // onPrimary
    secondary: const Color(0xFFF4F4F4), // secondary
    secondaryForeground: const Color(0xFF0D0D0D), // onSecondary
    muted: const Color(0xFFF4F4F4), // surface
    mutedForeground: const Color(0xFF6E6E80), // onSurfaceVariant
    accent: const Color(0xFFECECEC), // surfaceVariant
    accentForeground: const Color(0xFF0D0D0D), // onSurface
    destructive: const Color(0xFFEF4444), // error
    destructiveForeground: const Color(0xFFFFFFFF), // onError
    border: const Color(0xFFE5E5E5), // outlineVariant
    input: const Color(0xFFE5E5E5), // outlineVariant
    ring: const Color(0xFF8E8EA0), // outline
    sidebarBackground: const Color(0xFFF4F4F4), // surface
    sidebarForeground: const Color(0xFF0D0D0D), // onSurface
    sidebarPrimary: const Color(0xFF0D0D0D), // primary
    sidebarPrimaryForeground: const Color(0xFFFFFFFF), // onPrimary
    sidebarAccent: const Color(0xFFECECEC), // surfaceVariant
    sidebarAccentForeground: const Color(0xFF0D0D0D), // onSurface
    sidebarBorder: const Color(0xFFE5E5E5), // outlineVariant
    sidebarRing: const Color(0xFF8E8EA0), // outline
    success: const Color(0xFF10A37F), // success / tertiary
    successForeground: const Color(0xFFFFFFFF), // onTertiary
    warning: const Color(0xFFF59E0B), // warning
    warningForeground: const Color(0xFF0D0D0D), // onBackground
    info: const Color(0xFF10A37F), // tertiary (reuse as info)
    infoForeground: const Color(0xFFFFFFFF), // onTertiary
    radius: 10,
    fontSans: const <String>[
      'ui-sans-serif',
      'system-ui',
      '-apple-system',
      'BlinkMacSystemFont',
      'Segoe UI',
      'Roboto',
      'Helvetica Neue',
      'Arial',
      'Noto Sans',
      'sans-serif',
      'Apple Color Emoji',
      'Segoe UI Emoji',
      'Segoe UI Symbol',
      'Noto Color Emoji',
    ],
    fontSerif: const <String>[
      'ui-serif',
      'Georgia',
      'Cambria',
      'Times New Roman',
      'Times',
      'serif',
    ],
    fontMono: const <String>[
      'ui-monospace',
      'SFMono-Regular',
      'SF Mono',
      'Menlo',
      'Monaco',
      'Consolas',
      'Liberation Mono',
      'Courier New',
      'monospace',
    ],
  );

  static final TweakcnThemeVariant _conduitDark = TweakcnThemeVariant(
    background: const Color(0xFF0D0D0D), // background
    foreground: const Color(0xFFECECEC), // onBackground
    card: const Color(0xFF141414), // surface
    cardForeground: const Color(0xFFECECEC), // onSurface
    popover: const Color(0xFF1A1A1A), // surfaceVariant
    popoverForeground: const Color(0xFFECECEC), // onSurface
    primary: const Color(0xFFECECEC), // primary
    primaryForeground: const Color(0xFF0D0D0D), // onPrimary
    secondary: const Color(0xFF1A1A1A), // secondary
    secondaryForeground: const Color(0xFFECECEC), // onSecondary
    muted: const Color(0xFF1A1A1A), // surfaceVariant
    mutedForeground: const Color(0xFF8E8EA0), // onSurfaceVariant
    accent: const Color(0xFF232323), // secondaryContainer
    accentForeground: const Color(0xFFECECEC), // onSecondaryContainer
    destructive: const Color(0xFFEF4444), // error
    destructiveForeground: const Color(0xFFFFFFFF), // onError
    border: const Color(0xFF1E1E1E), // outlineVariant
    input: const Color(0xFF1E1E1E), // outlineVariant
    ring: const Color(0xFF6E6E80), // outline
    sidebarBackground: const Color(0xFF0D0D0D), // background
    sidebarForeground: const Color(0xFFECECEC), // onSurface
    sidebarPrimary: const Color(0xFFECECEC), // primary
    sidebarPrimaryForeground: const Color(0xFF0D0D0D), // onPrimary
    sidebarAccent: const Color(0xFF1A1A1A), // surfaceVariant
    sidebarAccentForeground: const Color(0xFFECECEC), // onSurface
    sidebarBorder: const Color(0xFF1E1E1E), // outlineVariant
    sidebarRing: const Color(0xFF6E6E80), // outline
    success: const Color(0xFF10A37F), // success / tertiary
    successForeground: const Color(0xFFFFFFFF), // onTertiary
    warning: const Color(0xFFF59E0B), // warning
    warningForeground: const Color(0xFFECECEC), // onBackground
    info: const Color(0xFF10A37F), // tertiary (reuse as info)
    infoForeground: const Color(0xFFECECEC), // onBackground
    radius: 10,
    fontSans: const <String>[
      'ui-sans-serif',
      'system-ui',
      '-apple-system',
      'BlinkMacSystemFont',
      'Segoe UI',
      'Roboto',
      'Helvetica Neue',
      'Arial',
      'Noto Sans',
      'sans-serif',
      'Apple Color Emoji',
      'Segoe UI Emoji',
      'Segoe UI Symbol',
      'Noto Color Emoji',
    ],
    fontSerif: const <String>[
      'ui-serif',
      'Georgia',
      'Cambria',
      'Times New Roman',
      'Times',
      'serif',
    ],
    fontMono: const <String>[
      'ui-monospace',
      'SFMono-Regular',
      'SF Mono',
      'Menlo',
      'Monaco',
      'Consolas',
      'Liberation Mono',
      'Courier New',
      'monospace',
    ],
  );

  static final TweakcnThemeVariant _t3ChatLight = TweakcnThemeVariant(
    background: const Color(0xFFFAF5FA),
    foreground: const Color(0xFF501854),
    card: const Color(0xFFFAF5FA),
    cardForeground: const Color(0xFF501854),
    popover: const Color(0xFFFFFFFF),
    popoverForeground: const Color(0xFF501854),
    primary: const Color(0xFFA84370),
    primaryForeground: const Color(0xFFFFFFFF),
    secondary: const Color(0xFFF1C4E6),
    secondaryForeground: const Color(0xFF77347C),
    muted: const Color(0xFFF6E5F3),
    mutedForeground: const Color(0xFF834588),
    accent: const Color(0xFFF1C4E6),
    accentForeground: const Color(0xFF77347C),
    destructive: const Color(0xFFAB4347),
    destructiveForeground: const Color(0xFFFFFFFF),
    border: const Color(0xFFEFBDEB),
    input: const Color(0xFFE7C1DC),
    ring: const Color(0xFFDB2777),
    sidebarBackground: const Color(0xFFF3E4F6),
    sidebarForeground: const Color(0xFFAC1668),
    sidebarPrimary: const Color(0xFF454554),
    sidebarPrimaryForeground: const Color(0xFFFAF1F7),
    sidebarAccent: const Color(0xFFF8F8F7),
    sidebarAccentForeground: const Color(0xFF454554),
    sidebarBorder: const Color(0xFFECEAE9),
    sidebarRing: const Color(0xFFDB2777),
    success: const Color(0xFFF4A462),
    successForeground: const Color(0xFF501854),
    warning: const Color(0xFFE8C468),
    warningForeground: const Color(0xFF501854),
    info: const Color(0xFF6C12B9),
    infoForeground: const Color(0xFFF8F1F5),
    radius: 8,
  );

  static final TweakcnThemeVariant _t3ChatDark = TweakcnThemeVariant(
    background: const Color(0xFF221D27),
    foreground: const Color(0xFFD2C4DE),
    card: const Color(0xFF2C2632),
    cardForeground: const Color(0xFFDBC5D2),
    popover: const Color(0xFF100A0E),
    popoverForeground: const Color(0xFFF8F1F5),
    primary: const Color(0xFFA3004C),
    primaryForeground: const Color(0xFFEFC0D8),
    secondary: const Color(0xFF362D3D),
    secondaryForeground: const Color(0xFFD4C7E1),
    muted: const Color(0xFF28222D),
    mutedForeground: const Color(0xFFC2B6CF),
    accent: const Color(0xFF463753),
    accentForeground: const Color(0xFFF8F1F5),
    destructive: const Color(0xFF301015),
    destructiveForeground: const Color(0xFFFFFFFF),
    border: const Color(0xFF3B3237),
    input: const Color(0xFF3E343C),
    ring: const Color(0xFFDB2777),
    sidebarBackground: const Color(0xFF181117),
    sidebarForeground: const Color(0xFFE0CAD6),
    sidebarPrimary: const Color(0xFF1D4ED8),
    sidebarPrimaryForeground: const Color(0xFFFFFFFF),
    sidebarAccent: const Color(0xFF261922),
    sidebarAccentForeground: const Color(0xFFF4F4F5),
    sidebarBorder: const Color(0xFF000000),
    sidebarRing: const Color(0xFFDB2777),
    success: const Color(0xFFE88C30),
    successForeground: const Color(0xFF181117),
    warning: const Color(0xFFAF57DB),
    warningForeground: const Color(0xFF181117),
    info: const Color(0xFF934DCB),
    infoForeground: const Color(0xFFF8F1F5),
    radius: 8,
  );

  static final TweakcnThemeVariant _claudeLight = TweakcnThemeVariant(
    background: const Color(0xFFFAF9F5),
    foreground: const Color(0xFF3D3929),
    card: const Color(0xFFFAF9F5),
    cardForeground: const Color(0xFF141413),
    popover: const Color(0xFFFFFFFF),
    popoverForeground: const Color(0xFF28261B),
    primary: const Color(0xFFC96442),
    primaryForeground: const Color(0xFFFFFFFF),
    secondary: const Color(0xFFE9E6DC),
    secondaryForeground: const Color(0xFF535146),
    muted: const Color(0xFFEDE9DE),
    mutedForeground: const Color(0xFF83827D),
    accent: const Color(0xFFE9E6DC),
    accentForeground: const Color(0xFF28261B),
    destructive: const Color(0xFF141413),
    destructiveForeground: const Color(0xFFFFFFFF),
    border: const Color(0xFFDAD9D4),
    input: const Color(0xFFB4B2A7),
    ring: const Color(0xFFC96442),
    sidebarBackground: const Color(0xFFF5F4EE),
    sidebarForeground: const Color(0xFF3D3D3A),
    sidebarPrimary: const Color(0xFFC96442),
    sidebarPrimaryForeground: const Color(0xFFFBFBFB),
    sidebarAccent: const Color(0xFFE9E6DC),
    sidebarAccentForeground: const Color(0xFF343434),
    sidebarBorder: const Color(0xFFEBEBEB),
    sidebarRing: const Color(0xFFB5B5B5),
    success: const Color(0xFF4C7A63),
    successForeground: const Color(0xFFFAF9F5),
    warning: const Color(0xFFD4A645),
    warningForeground: const Color(0xFF141413),
    info: const Color(0xFF9C87F5),
    infoForeground: const Color(0xFF141413),
    radius: 8,
    fontSans: const <String>[
      'ui-sans-serif',
      'system-ui',
      '-apple-system',
      'BlinkMacSystemFont',
      'Segoe UI',
      'Roboto',
      'Helvetica Neue',
      'Arial',
      'Noto Sans',
      'sans-serif',
      'Apple Color Emoji',
      'Segoe UI Emoji',
      'Segoe UI Symbol',
      'Noto Color Emoji',
    ],
    fontSerif: const <String>[
      'ui-serif',
      'Georgia',
      'Cambria',
      'Times New Roman',
      'Times',
      'serif',
    ],
    fontMono: const <String>[
      'ui-monospace',
      'SFMono-Regular',
      'Menlo',
      'Monaco',
      'Consolas',
      'Liberation Mono',
      'Courier New',
      'monospace',
    ],
  );

  static final TweakcnThemeVariant _claudeDark = TweakcnThemeVariant(
    background: const Color(0xFF262624),
    foreground: const Color(0xFFC3C0B6),
    card: const Color(0xFF262624),
    cardForeground: const Color(0xFFFAF9F5),
    popover: const Color(0xFF30302E),
    popoverForeground: const Color(0xFFE5E5E2),
    primary: const Color(0xFFD97757),
    primaryForeground: const Color(0xFFFFFFFF),
    secondary: const Color(0xFFFAF9F5),
    secondaryForeground: const Color(0xFF30302E),
    muted: const Color(0xFF1B1B19),
    mutedForeground: const Color(0xFFB7B5A9),
    accent: const Color(0xFF1A1915),
    accentForeground: const Color(0xFFF5F4EE),
    destructive: const Color(0xFFEF4444),
    destructiveForeground: const Color(0xFFFFFFFF),
    border: const Color(0xFF3E3E38),
    input: const Color(0xFF52514A),
    ring: const Color(0xFFD97757),
    sidebarBackground: const Color(0xFF1F1E1D),
    sidebarForeground: const Color(0xFFC3C0B6),
    sidebarPrimary: const Color(0xFF343434),
    sidebarPrimaryForeground: const Color(0xFFFBFBFB),
    sidebarAccent: const Color(0xFF0F0F0E),
    sidebarAccentForeground: const Color(0xFFC3C0B6),
    sidebarBorder: const Color(0xFFEBEBEB),
    sidebarRing: const Color(0xFFB5B5B5),
    success: const Color(0xFF6AA884),
    successForeground: const Color(0xFF1B1B19),
    warning: const Color(0xFFE0B456),
    warningForeground: const Color(0xFF1B1B19),
    info: const Color(0xFFB39CFF),
    infoForeground: const Color(0xFF1B1B19),
    radius: 8,
    fontSans: const <String>[
      'ui-sans-serif',
      'system-ui',
      '-apple-system',
      'BlinkMacSystemFont',
      'Segoe UI',
      'Roboto',
      'Helvetica Neue',
      'Arial',
      'Noto Sans',
      'sans-serif',
      'Apple Color Emoji',
      'Segoe UI Emoji',
      'Segoe UI Symbol',
      'Noto Color Emoji',
    ],
    fontSerif: const <String>[
      'ui-serif',
      'Georgia',
      'Cambria',
      'Times New Roman',
      'Times',
      'serif',
    ],
    fontMono: const <String>[
      'ui-monospace',
      'SFMono-Regular',
      'Menlo',
      'Monaco',
      'Consolas',
      'Liberation Mono',
      'Courier New',
      'monospace',
    ],
  );

  // Catppuccin (from @catppuccin.css)
  static final TweakcnThemeVariant _catppuccinLight = TweakcnThemeVariant(
    background: const Color(0xFFEFF1F5),
    foreground: const Color(0xFF4C4F69),
    card: const Color(0xFFFFFFFF),
    cardForeground: const Color(0xFF4C4F69),
    popover: const Color(0xFFCCD0DA),
    popoverForeground: const Color(0xFF4C4F69),
    primary: const Color(0xFF8839EF),
    primaryForeground: const Color(0xFFFFFFFF),
    secondary: const Color(0xFFCCD0DA),
    secondaryForeground: const Color(0xFF4C4F69),
    muted: const Color(0xFFDCE0E8),
    mutedForeground: const Color(0xFF6C6F85),
    accent: const Color(0xFF04A5E5),
    accentForeground: const Color(0xFFFFFFFF),
    destructive: const Color(0xFFD20F39),
    destructiveForeground: const Color(0xFFFFFFFF),
    border: const Color(0xFFBCC0CC),
    input: const Color(0xFFCCD0DA),
    ring: const Color(0xFF8839EF),
    sidebarBackground: const Color(0xFFE6E9EF),
    sidebarForeground: const Color(0xFF4C4F69),
    sidebarPrimary: const Color(0xFF8839EF),
    sidebarPrimaryForeground: const Color(0xFFFFFFFF),
    sidebarAccent: const Color(0xFFDCE0E8),
    sidebarAccentForeground: const Color(0xFF4C4F69),
    sidebarBorder: const Color(0xFFBCC0CC),
    sidebarRing: const Color(0xFF8839EF),
    success: const Color(0xFF40A02B), // chart-3
    successForeground: const Color(0xFF4C4F69),
    warning: const Color(0xFFFE640B), // chart-4
    warningForeground: const Color(0xFF4C4F69),
    info: const Color(0xFF04A5E5), // chart-2
    infoForeground: const Color(0xFFFFFFFF),
    radius: 6,
    fontSans: const <String>[
      'Montserrat',
      'ui-sans-serif',
      'system-ui',
      '-apple-system',
      'BlinkMacSystemFont',
      'Segoe UI',
      'Roboto',
      'Helvetica Neue',
      'Arial',
      'Noto Sans',
      'sans-serif',
      'Apple Color Emoji',
      'Segoe UI Emoji',
      'Segoe UI Symbol',
      'Noto Color Emoji',
    ],
    fontSerif: const <String>[
      'Georgia',
      'ui-serif',
      'Cambria',
      'Times New Roman',
      'Times',
      'serif',
    ],
    fontMono: const <String>[
      'Fira Code',
      'ui-monospace',
      'SFMono-Regular',
      'Menlo',
      'Monaco',
      'Consolas',
      'Liberation Mono',
      'Courier New',
      'monospace',
    ],
  );

  static final TweakcnThemeVariant _catppuccinDark = TweakcnThemeVariant(
    background: const Color(0xFF181825),
    foreground: const Color(0xFFCDD6F4),
    card: const Color(0xFF1E1E2E),
    cardForeground: const Color(0xFFCDD6F4),
    popover: const Color(0xFF45475A),
    popoverForeground: const Color(0xFFCDD6F4),
    primary: const Color(0xFFCBA6F7),
    primaryForeground: const Color(0xFF1E1E2E),
    secondary: const Color(0xFF585B70),
    secondaryForeground: const Color(0xFFCDD6F4),
    muted: const Color(0xFF292C3C),
    mutedForeground: const Color(0xFFA6ADC8),
    accent: const Color(0xFF89DCEB),
    accentForeground: const Color(0xFF1E1E2E),
    destructive: const Color(0xFFF38BA8),
    destructiveForeground: const Color(0xFF1E1E2E),
    border: const Color(0xFF313244),
    input: const Color(0xFF313244),
    ring: const Color(0xFFCBA6F7),
    sidebarBackground: const Color(0xFF11111B),
    sidebarForeground: const Color(0xFFCDD6F4),
    sidebarPrimary: const Color(0xFFCBA6F7),
    sidebarPrimaryForeground: const Color(0xFF1E1E2E),
    sidebarAccent: const Color(0xFF292C3C),
    sidebarAccentForeground: const Color(0xFFCDD6F4),
    sidebarBorder: const Color(0xFF45475A),
    sidebarRing: const Color(0xFFCBA6F7),
    success: const Color(0xFFA6E3A1), // chart-3
    successForeground: const Color(0xFF181825),
    warning: const Color(0xFFFAB387), // chart-4
    warningForeground: const Color(0xFF181825),
    info: const Color(0xFF89DCEB), // chart-2
    infoForeground: const Color(0xFF181825),
    radius: 6,
    fontSans: const <String>[
      'Montserrat',
      'ui-sans-serif',
      'system-ui',
      '-apple-system',
      'BlinkMacSystemFont',
      'Segoe UI',
      'Roboto',
      'Helvetica Neue',
      'Arial',
      'Noto Sans',
      'sans-serif',
      'Apple Color Emoji',
      'Segoe UI Emoji',
      'Segoe UI Symbol',
      'Noto Color Emoji',
    ],
    fontSerif: const <String>[
      'Georgia',
      'ui-serif',
      'Cambria',
      'Times New Roman',
      'Times',
      'serif',
    ],
    fontMono: const <String>[
      'Fira Code',
      'ui-monospace',
      'SFMono-Regular',
      'Menlo',
      'Monaco',
      'Consolas',
      'Liberation Mono',
      'Courier New',
      'monospace',
    ],
  );

  // Tangerine (from @tangerine.css)
  static final TweakcnThemeVariant _tangerineLight = TweakcnThemeVariant(
    background: const Color(0xFFE8EBED),
    foreground: const Color(0xFF333333),
    card: const Color(0xFFFFFFFF),
    cardForeground: const Color(0xFF333333),
    popover: const Color(0xFFFFFFFF),
    popoverForeground: const Color(0xFF333333),
    primary: const Color(0xFFE05D38),
    primaryForeground: const Color(0xFFFFFFFF),
    secondary: const Color(0xFFF3F4F6),
    secondaryForeground: const Color(0xFF4B5563),
    muted: const Color(0xFFF9FAFB),
    mutedForeground: const Color(0xFF6B7280),
    accent: const Color(0xFFD6E4F0),
    accentForeground: const Color(0xFF1E3A8A),
    destructive: const Color(0xFFEF4444),
    destructiveForeground: const Color(0xFFFFFFFF),
    border: const Color(0xFFDCDFE2),
    input: const Color(0xFFF4F5F7),
    ring: const Color(0xFFE05D38),
    sidebarBackground: const Color(0xFFDDDFE2),
    sidebarForeground: const Color(0xFF333333),
    sidebarPrimary: const Color(0xFFE05D38),
    sidebarPrimaryForeground: const Color(0xFFFFFFFF),
    sidebarAccent: const Color(0xFFD6E4F0),
    sidebarAccentForeground: const Color(0xFF1E3A8A),
    sidebarBorder: const Color(0xFFE5E7EB),
    sidebarRing: const Color(0xFFE05D38),
    success: const Color(0xFF86A7C8),
    successForeground: const Color(0xFF333333),
    warning: const Color(0xFFEEA591),
    warningForeground: const Color(0xFF333333),
    info: const Color(0xFF334C82),
    infoForeground: const Color(0xFFFFFFFF),
    radius: 12,
    fontSans: const <String>[
      'Inter',
      'ui-sans-serif',
      'system-ui',
      '-apple-system',
      'BlinkMacSystemFont',
      'Segoe UI',
      'Roboto',
      'Helvetica Neue',
      'Arial',
      'Noto Sans',
      'sans-serif',
      'Apple Color Emoji',
      'Segoe UI Emoji',
      'Segoe UI Symbol',
      'Noto Color Emoji',
    ],
    fontSerif: const <String>[
      'Source Serif 4',
      'ui-serif',
      'Georgia',
      'Cambria',
      'Times New Roman',
      'Times',
      'serif',
    ],
    fontMono: const <String>[
      'JetBrains Mono',
      'ui-monospace',
      'SFMono-Regular',
      'Menlo',
      'Monaco',
      'Consolas',
      'Liberation Mono',
      'Courier New',
      'monospace',
    ],
  );

  static final TweakcnThemeVariant _tangerineDark = TweakcnThemeVariant(
    background: const Color(0xFF1C2433),
    foreground: const Color(0xFFE5E5E5),
    card: const Color(0xFF2A3040),
    cardForeground: const Color(0xFFE5E5E5),
    popover: const Color(0xFF262B38),
    popoverForeground: const Color(0xFFE5E5E5),
    primary: const Color(0xFFE05D38),
    primaryForeground: const Color(0xFFFFFFFF),
    secondary: const Color(0xFF2A303E),
    secondaryForeground: const Color(0xFFE5E5E5),
    muted: const Color(0xFF2A303E),
    mutedForeground: const Color(0xFFA3A3A3),
    accent: const Color(0xFF2A3656),
    accentForeground: const Color(0xFFBFDBFE),
    destructive: const Color(0xFFEF4444),
    destructiveForeground: const Color(0xFFFFFFFF),
    border: const Color(0xFF3D4354),
    input: const Color(0xFF3D4354),
    ring: const Color(0xFFE05D38),
    sidebarBackground: const Color(0xFF2A303F),
    sidebarForeground: const Color(0xFFE5E5E5),
    sidebarPrimary: const Color(0xFFE05D38),
    sidebarPrimaryForeground: const Color(0xFFFFFFFF),
    sidebarAccent: const Color(0xFF2A3656),
    sidebarAccentForeground: const Color(0xFFBFDBFE),
    sidebarBorder: const Color(0xFF3D4354),
    sidebarRing: const Color(0xFFE05D38),
    success: const Color(0xFF86A7C8),
    successForeground: const Color(0xFF1C2433),
    warning: const Color(0xFFE6A08F),
    warningForeground: const Color(0xFF1C2433),
    info: const Color(0xFF466494),
    infoForeground: const Color(0xFF1C2433),
    radius: 12,
    fontSans: const <String>[
      'Inter',
      'ui-sans-serif',
      'system-ui',
      '-apple-system',
      'BlinkMacSystemFont',
      'Segoe UI',
      'Roboto',
      'Helvetica Neue',
      'Arial',
      'Noto Sans',
      'sans-serif',
      'Apple Color Emoji',
      'Segoe UI Emoji',
      'Segoe UI Symbol',
      'Noto Color Emoji',
    ],
    fontSerif: const <String>[
      'Source Serif 4',
      'ui-serif',
      'Georgia',
      'Cambria',
      'Times New Roman',
      'Times',
      'serif',
    ],
    fontMono: const <String>[
      'JetBrains Mono',
      'ui-monospace',
      'SFMono-Regular',
      'Menlo',
      'Monaco',
      'Consolas',
      'Liberation Mono',
      'Courier New',
      'monospace',
    ],
  );

  static final TweakcnThemeDefinition claude = TweakcnThemeDefinition(
    id: 'claude',
    labelBuilder: (l10n) => l10n.themePaletteClaudeLabel,
    descriptionBuilder: (l10n) => l10n.themePaletteClaudeDescription,
    light: _claudeLight,
    dark: _claudeDark,
    preview: const <Color>[
      Color(0xFFC96442),
      Color(0xFFE9E6DC),
      Color(0xFF1A1915),
    ],
  );

  static final TweakcnThemeDefinition t3Chat = TweakcnThemeDefinition(
    id: 't3_chat',
    labelBuilder: (l10n) => l10n.themePaletteT3ChatLabel,
    descriptionBuilder: (l10n) => l10n.themePaletteT3ChatDescription,
    light: _t3ChatLight,
    dark: _t3ChatDark,
    preview: const <Color>[
      Color(0xFFA84370),
      Color(0xFFF1C4E6),
      Color(0xFFDB2777),
    ],
  );

  static final TweakcnThemeDefinition conduit = TweakcnThemeDefinition(
    id: 'conduit',
    labelBuilder: (l10n) => l10n.themePaletteConduitLabel,
    descriptionBuilder: (l10n) => l10n.themePaletteConduitDescription,
    light: _conduitLight,
    dark: _conduitDark,
    preview: const <Color>[
      Color(0xFF0D0D0D), // primary
      Color(0xFF10A37F), // tertiary / accent
      Color(0xFFF4F4F4), // surface
    ],
  );

  static final TweakcnThemeDefinition catppuccin = TweakcnThemeDefinition(
    id: 'catppuccin',
    labelBuilder: (l10n) => l10n.themePaletteCatppuccinLabel,
    descriptionBuilder: (l10n) => l10n.themePaletteCatppuccinDescription,
    light: _catppuccinLight,
    dark: _catppuccinDark,
    preview: const <Color>[
      Color(0xFF8839EF), // primary
      Color(0xFF04A5E5), // accent
      Color(0xFFEFF1F5), // background
    ],
  );

  static final TweakcnThemeDefinition tangerine = TweakcnThemeDefinition(
    id: 'tangerine',
    labelBuilder: (l10n) => l10n.themePaletteTangerineLabel,
    descriptionBuilder: (l10n) => l10n.themePaletteTangerineDescription,
    light: _tangerineLight,
    dark: _tangerineDark,
    preview: const <Color>[
      Color(0xFFE05D38), // primary
      Color(0xFFD6E4F0), // accent
      Color(0xFFE8EBED), // background
    ],
  );

  static List<TweakcnThemeDefinition> all = [
    conduit,
    claude,
    t3Chat,
    catppuccin,
    tangerine,
  ];

  static TweakcnThemeDefinition byId(String? id) {
    return all.firstWhere((theme) => theme.id == id, orElse: () => conduit);
  }
}

@immutable
class AppPaletteThemeExtension
    extends ThemeExtension<AppPaletteThemeExtension> {
  const AppPaletteThemeExtension({required this.palette});

  final TweakcnThemeDefinition palette;

  @override
  AppPaletteThemeExtension copyWith({TweakcnThemeDefinition? palette}) {
    return AppPaletteThemeExtension(palette: palette ?? this.palette);
  }

  @override
  AppPaletteThemeExtension lerp(
    covariant ThemeExtension<AppPaletteThemeExtension>? other,
    double t,
  ) {
    if (other is! AppPaletteThemeExtension) return this;
    return t < 0.5 ? this : other;
  }
}
