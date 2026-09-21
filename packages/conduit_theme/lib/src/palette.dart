import 'package:meta/meta.dart';

/// One palette in one brightness, as plain ARGB integers.
///
/// Integers rather than `Color` so this package stays pure Dart: the Flutter
/// app wraps each value in a `Color`, the desktop UI formats it as CSS, and
/// neither front-end owns the numbers. That is what keeps the two from
/// drifting apart a shade at a time.
///
/// The field set and order mirror the tweakcn registry exactly; adding a token
/// here means adding it to both renderers.
@immutable
class ThemeVariant {
  const ThemeVariant({
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
  });

  final int background;
  final int foreground;
  final int card;
  final int cardForeground;
  final int popover;
  final int popoverForeground;
  final int primary;
  final int primaryForeground;
  final int secondary;
  final int secondaryForeground;
  final int muted;
  final int mutedForeground;
  final int accent;
  final int accentForeground;
  final int destructive;
  final int destructiveForeground;
  final int border;
  final int input;
  final int ring;
  final int sidebarBackground;
  final int sidebarForeground;
  final int sidebarPrimary;
  final int sidebarPrimaryForeground;
  final int sidebarAccent;
  final int sidebarAccentForeground;
  final int sidebarBorder;
  final int sidebarRing;
  final int success;
  final int successForeground;
  final int warning;
  final int warningForeground;
  final int info;
  final int infoForeground;

  /// Corner radius in logical pixels. CSS gets it as `px`.
  final double radius;

  /// Every colour token keyed by its camelCase name, in declaration order.
  ///
  /// Drives CSS generation and the completeness tests, so neither has to
  /// repeat the field list and fall behind it.
  Map<String, int> get colors => <String, int>{
    'background': background,
    'foreground': foreground,
    'card': card,
    'cardForeground': cardForeground,
    'popover': popover,
    'popoverForeground': popoverForeground,
    'primary': primary,
    'primaryForeground': primaryForeground,
    'secondary': secondary,
    'secondaryForeground': secondaryForeground,
    'muted': muted,
    'mutedForeground': mutedForeground,
    'accent': accent,
    'accentForeground': accentForeground,
    'destructive': destructive,
    'destructiveForeground': destructiveForeground,
    'border': border,
    'input': input,
    'ring': ring,
    'sidebarBackground': sidebarBackground,
    'sidebarForeground': sidebarForeground,
    'sidebarPrimary': sidebarPrimary,
    'sidebarPrimaryForeground': sidebarPrimaryForeground,
    'sidebarAccent': sidebarAccent,
    'sidebarAccentForeground': sidebarAccentForeground,
    'sidebarBorder': sidebarBorder,
    'sidebarRing': sidebarRing,
    'success': success,
    'successForeground': successForeground,
    'warning': warning,
    'warningForeground': warningForeground,
    'info': info,
    'infoForeground': infoForeground,
  };
}

/// A palette with both brightness variants.
@immutable
class ThemePalette {
  const ThemePalette({
    required this.id,
    required this.labelKey,
    required this.descriptionKey,
    required this.light,
    required this.dark,
    required this.preview,
  });

  /// Stable identifier persisted in settings, e.g. `t3_chat`. Never localized
  /// and never renumbered — a stored preference has to survive upgrades.
  final String id;

  /// ARB key for the display name. The registry stores the *key*, not the
  /// string, because it has no locale; each front-end resolves it with its own
  /// localization stack.
  final String labelKey;
  final String descriptionKey;

  final ThemeVariant light;
  final ThemeVariant dark;

  /// Three swatches for the palette picker, in the order they are shown.
  final List<int> preview;

  ThemeVariant variantFor({required bool dark}) => dark ? this.dark : light;
}
