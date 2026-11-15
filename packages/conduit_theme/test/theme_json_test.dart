import 'dart:convert';
import 'dart:io';

import 'package:conduit_theme/conduit_theme.dart';
import 'package:conduit_theme/src/theme_json.dart';
import 'package:test/test.dart';

void main() {
  // `dart test` runs from the package directory.
  final committed = File('../../$kDesktopThemeJsonPath');

  test('the committed desktop palettes.json is up to date', () {
    expect(
      committed.existsSync(),
      isTrue,
      reason: '$kDesktopThemeJsonPath is missing',
    );
    expect(
      committed.readAsStringSync(),
      desktopThemeJson(),
      reason:
          'palettes.json is stale: run '
          'dart run packages/conduit_theme/bin/export_theme_json.dart',
    );
  });

  test('every palette carries every token in both modes', () {
    final doc = jsonDecode(desktopThemeJson()) as Map<String, dynamic>;
    expect(doc['version'], kDesktopThemeJsonVersion);
    expect(doc['defaultPalette'], 'conduit');
    final colorTokens = (doc['colorTokens'] as List).cast<String>();
    final surfaceTokens = (doc['surfaceTokens'] as List).cast<String>();
    expect(colorTokens, hasLength(33));
    expect(surfaceTokens, kSurfaceTokens);
    final palettes = (doc['palettes'] as List).cast<Map<String, dynamic>>();
    // Exactly the phone's palettes, in the phone's order.
    expect(palettes.map((p) => p['id']), kConduitPalettes.map((p) => p.id));
    final hex = RegExp(r'^#[0-9A-F]{8}$');
    for (final palette in palettes) {
      for (final mode in <String>['light', 'dark']) {
        final variant = palette[mode] as Map<String, dynamic>;
        final colors = (variant['colors'] as Map).cast<String, String>();
        final surfaces = (variant['surfaces'] as Map).cast<String, String>();
        final accessible = (variant['accessible'] as Map)
            .cast<String, String>();
        expect(colors.keys, colorTokens, reason: '${palette['id']} $mode');
        expect(surfaces.keys, surfaceTokens, reason: '${palette['id']} $mode');
        for (final value in <String>[
          ...colors.values,
          ...surfaces.values,
          ...accessible.values,
          variant['destructiveFill'] as String,
        ]) {
          expect(value, matches(hex));
        }
        expect(colorTokens, containsAll(accessible.keys));
        expect(variant['radius'], greaterThan(0));
      }
    }
  });

  test('colours are written as #RRGGBBAA', () {
    expect(cssHex(0xFF102030), '#102030FF');
    expect(cssHex(0x0D0D0D0D), '#0D0D0D0D');
  });

  test('accessible lists only the colours accessibleColors moved', () {
    for (final palette in kConduitPalettes) {
      for (final variant in <ThemeVariant>[palette.light, palette.dark]) {
        final moved = accessibleColors(variant);
        final doc = jsonDecode(desktopThemeJson()) as Map<String, dynamic>;
        final entry = (doc['palettes'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((p) => p['id'] == palette.id);
        final json =
            ((entry[identical(variant, palette.light) ? 'light' : 'dark']
                        as Map)['accessible']
                    as Map)
                .cast<String, String>();
        for (final token in variant.colors.keys) {
          final changed = moved[token] != variant.colors[token];
          expect(json.containsKey(token), changed, reason: token);
          if (changed) expect(json[token], cssHex(moved[token]!));
        }
      }
    }
  });
}
