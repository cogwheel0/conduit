import 'dart:convert';

import 'contrast.dart';
import 'palette.dart';
import 'registry.dart';
import 'surfaces.dart';

/// Where `bin/export_theme_json.dart` writes [desktopThemeJson], relative to
/// the repository root. The native desktop app embeds this file.
const String kDesktopThemeJsonPath =
    'desktop/crates/components/assets/themes/palettes.json';

/// Bumped when the shape of [desktopThemeJson] changes, so the Rust reader
/// can refuse a file it does not understand.
const int kDesktopThemeJsonVersion = 1;

/// Every palette in both modes, computed, as the JSON the native desktop
/// app reads. The desktop offers exactly the phone's palettes, with Conduit's
/// own monochrome one as the default.
///
/// Each mode carries the 33 colour tokens as the palette defines them, the
/// 17 surface tokens after [desktopSurfaces] (derived where the palette
/// leaves them out, text tokens held to WCAG AA), the colours
/// [accessibleColors] moved (only those that differ), the
/// [destructiveFill] under `destructiveForeground`, and the radius.
/// Colours are `#RRGGBBAA`, the CSS order, so the alpha of a translucent
/// surface survives.
///
/// The output is deterministic: keys keep declaration order and the file
/// ends with a newline, so a regenerated file only differs when a palette
/// does.
String desktopThemeJson() {
  final colorTokens = kDefaultPalette.light.colors.keys.toList();
  final document = <String, Object>{
    'version': kDesktopThemeJsonVersion,
    'generatedBy': 'packages/conduit_theme/bin/export_theme_json.dart',
    'defaultPalette': kDefaultPalette.id,
    'colorTokens': colorTokens,
    'surfaceTokens': kSurfaceTokens,
    'palettes': <Object>[
      for (final palette in kConduitPalettes)
        <String, Object>{
          'id': palette.id,
          'labelKey': palette.labelKey,
          'descriptionKey': palette.descriptionKey,
          'preview': <String>[for (final c in palette.preview) cssHex(c)],
          'light': _variantJson(palette.light),
          'dark': _variantJson(palette.dark),
        },
    ],
  };
  return '${const JsonEncoder.withIndent('  ').convert(document)}\n';
}

Map<String, Object> _variantJson(ThemeVariant variant) {
  final colors = variant.colors;
  final accessible = accessibleColors(variant);
  return <String, Object>{
    'radius': variant.radius,
    'colors': <String, String>{
      for (final entry in colors.entries) entry.key: cssHex(entry.value),
    },
    'surfaces': <String, String>{
      for (final entry in desktopSurfaces(variant).entries)
        entry.key: cssHex(entry.value),
    },
    'accessible': <String, String>{
      for (final entry in accessible.entries)
        if (colors[entry.key] != entry.value) entry.key: cssHex(entry.value),
    },
    'destructiveFill': cssHex(destructiveFill(variant)),
  };
}

/// [argb] as `#RRGGBBAA`.
String cssHex(int argb) {
  String byte(int shift) =>
      ((argb >> shift) & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase();
  return '#${byte(16)}${byte(8)}${byte(0)}${byte(24)}';
}
