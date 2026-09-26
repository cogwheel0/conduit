// Palettes only the desktop window offers.
//
// The phone app reads kConduitPalettes; these are listed ahead of it for the
// desktop alone, so adding one here never reaches the phone.
//
// Zai is the desktop's default: a monochrome light and dark after ZCode's
// (github.com/zai-org/ZCode, Apache-2.0) Zai themes. White frames on a grey
// window in light, and graphite frames on near-black in dark; black or white
// as the one strong colour.

import 'palette.dart';
import 'registry.dart';

const ThemeVariant _zaiLight = ThemeVariant(
  background: 0xFFFFFFFF,
  foreground: 0xFF262626,
  card: 0xFFFFFFFF,
  cardForeground: 0xFF262626,
  popover: 0xFFFFFFFF,
  popoverForeground: 0xFF262626,
  primary: 0xFF000000,
  primaryForeground: 0xFFFFFFFF,
  secondary: 0xFFE6E6E6,
  secondaryForeground: 0xFF0D0D0D,
  muted: 0xFFF0F0F0,
  mutedForeground: 0xFF6B6B6B,
  accent: 0xFFF0F0F0,
  accentForeground: 0xFF0D0D0D,
  destructive: 0xFFE03131,
  destructiveForeground: 0xFFFFFFFF,
  border: 0xFFE7E7E7,
  input: 0xFFE7E7E7,
  ring: 0xFFA3A3A3,
  sidebarBackground: 0xFFF0F0F0,
  sidebarForeground: 0xFF262626,
  sidebarPrimary: 0xFF000000,
  sidebarPrimaryForeground: 0xFFFFFFFF,
  sidebarAccent: 0xFFE4E4E4,
  sidebarAccentForeground: 0xFF0D0D0D,
  sidebarBorder: 0xFFE4E4E4,
  sidebarRing: 0xFFA3A3A3,
  success: 0xFF1E8A3E,
  successForeground: 0xFFFFFFFF,
  warning: 0xFFE07B00,
  warningForeground: 0xFF000000,
  info: 0xFF0B7FFF,
  infoForeground: 0xFFFFFFFF,
  radius: 8,
  surfaces: <String, int>{
    'window': 0xFFF8F8F8,
    'panel': 0xFFFFFFFF,
    'header': 0xFFFFFFFF,
    'surface': 0x080D0D0D,
    'surfaceHover': 0x0D0D0D0D,
    'menu': 0xFFFFFFFF,
    'menuHover': 0xFFF0F0F0,
    'hover': 0x0D0D0D0D,
    'selected': 0x120D0D0D,
    'borderHover': 0xFFD9D9D9,
    'foregroundSubtle': 0xFF6B6B6B,
    'foregroundSubtlest': 0xFF8F8F8F,
    'tab': 0xFFF0F0F0,
    'tabActive': 0xFFFFFFFF,
    'brand': 0xFF000000,
    'tooltip': 0xFFF0F0F0,
    'tooltipForeground': 0xFF0D0D0D,
  },
);

const ThemeVariant _zaiDark = ThemeVariant(
  background: 0xFF202020,
  foreground: 0xFFD4D4D4,
  card: 0xFF2B2B2B,
  cardForeground: 0xFFD4D4D4,
  popover: 0xFF2B2B2B,
  popoverForeground: 0xFFD4D4D4,
  primary: 0xFFFFFFFF,
  primaryForeground: 0xFF000000,
  secondary: 0xFF363636,
  secondaryForeground: 0xFFE5E5E5,
  muted: 0xFF2B2B2B,
  mutedForeground: 0xFFA3A3A3,
  accent: 0xFF363636,
  accentForeground: 0xFFF0F0F0,
  destructive: 0xFFFF5C5C,
  destructiveForeground: 0xFFFFFFFF,
  border: 0xFF363636,
  input: 0xFF363636,
  ring: 0xFF737373,
  sidebarBackground: 0xFF161616,
  sidebarForeground: 0xFFD4D4D4,
  sidebarPrimary: 0xFFFFFFFF,
  sidebarPrimaryForeground: 0xFF000000,
  sidebarAccent: 0xFF2B2B2B,
  sidebarAccentForeground: 0xFFF0F0F0,
  sidebarBorder: 0xFF2B2B2B,
  sidebarRing: 0xFF737373,
  success: 0xFF46BF72,
  successForeground: 0xFF000000,
  warning: 0xFFFF8A30,
  warningForeground: 0xFF000000,
  info: 0xFF4DA3FF,
  infoForeground: 0xFF000000,
  radius: 8,
  surfaces: <String, int>{
    'window': 0xFF161616,
    'panel': 0xFF202020,
    'header': 0xFF202020,
    'surface': 0x0DFFFFFF,
    'surfaceHover': 0x1AFFFFFF,
    'menu': 0xFF2B2B2B,
    'menuHover': 0xFF363636,
    'hover': 0x0DFFFFFF,
    'selected': 0x1AFFFFFF,
    'borderHover': 0xFF474747,
    'foregroundSubtle': 0xFF999999,
    'foregroundSubtlest': 0xFF737373,
    'tab': 0xFF202020,
    'tabActive': 0xFF161616,
    'brand': 0xFFFFFFFF,
    'tooltip': 0xFF2B2B2B,
    'tooltipForeground': 0xFFF8F8F8,
  },
);

/// The desktop's own default palette.
const ThemePalette kZaiPalette = ThemePalette(
  id: 'zai',
  labelKey: 'themePaletteZaiLabel',
  descriptionKey: 'themePaletteZaiDescription',
  light: _zaiLight,
  dark: _zaiDark,
  preview: <int>[0xFF000000, 0xFFF8F8F8, 0xFF202020],
);

/// Every palette the desktop window offers, in picker order: its own first,
/// then the shared registry.
const List<ThemePalette> kDesktopPalettes = <ThemePalette>[
  kZaiPalette,
  ...kConduitPalettes,
];

/// Looks up a desktop palette by its stored [id], falling back to
/// [kZaiPalette].
ThemePalette desktopPaletteById(String? id) {
  for (final palette in kDesktopPalettes) {
    if (palette.id == id) return palette;
  }
  return kZaiPalette;
}
