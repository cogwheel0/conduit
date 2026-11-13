import 'dart:math' as math;

import 'package:conduit_theme/conduit_theme.dart';
import 'package:test/test.dart';

void main() {
  group('registry', () {
    test('ships the five documented palettes in picker order', () {
      expect(kConduitPalettes.map((p) => p.id).toList(), <String>[
        'conduit',
        'claude',
        't3_chat',
        'catppuccin',
        'tangerine',
      ]);
    });

    test('every palette defines all 33 colour tokens in both modes', () {
      final expected = kConduitPalettes.first.light.colors.keys.toSet();
      expect(expected, hasLength(33));
      for (final palette in kConduitPalettes) {
        for (final variant in <ThemeVariant>[palette.light, palette.dark]) {
          expect(
            variant.colors.keys.toSet(),
            expected,
            reason: '${palette.id} is missing a token',
          );
          // A token left at 0 is transparent black, which renders as an
          // invisible control rather than as an obvious mistake.
          for (final entry in variant.colors.entries) {
            expect(
              entry.value >> 24 & 0xFF,
              0xFF,
              reason: '${palette.id}.${entry.key} is not fully opaque',
            );
          }
        }
        expect(palette.preview, hasLength(3));
        expect(palette.light.radius, greaterThan(0));
      }
    });

    test('palette ids are unique and stable', () {
      final ids = kConduitPalettes.map((p) => p.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      // Stored in user settings: renaming one silently resets a preference.
      expect(ids, contains('t3_chat'));
    });

    test('an unknown id falls back instead of throwing', () {
      expect(paletteById('conduit').id, 'conduit');
      expect(paletteById('no_such_palette').id, kDefaultPalette.id);
      expect(paletteById(null).id, kDefaultPalette.id);
    });

    test('variantFor picks the requested brightness', () {
      final palette = paletteById('conduit');
      expect(palette.variantFor(dark: false), same(palette.light));
      expect(palette.variantFor(dark: true), same(palette.dark));
    });
  });

  group('accessibleColors', () {
    test(
      'a light variant\'s red reads as text and under its own foreground',
      () {
        for (final palette in kConduitPalettes) {
          final colors = accessibleColors(palette.light);
          final red = colors['destructive']!;
          for (final surface in <String>['background', 'card', 'muted']) {
            expect(
              contrastRatio(red, colors[surface]!),
              greaterThanOrEqualTo(4.5),
              reason: '${palette.id} red on $surface',
            );
          }
          expect(
            contrastRatio(colors['destructiveForeground']!, red),
            greaterThanOrEqualTo(4.5),
            reason: '${palette.id} text on red',
          );
        }
      },
    );

    test('a dark variant never loses the fill\'s contrast', () {
      for (final palette in kConduitPalettes) {
        final before = palette.dark.colors;
        final after = accessibleColors(palette.dark);
        final fill = contrastRatio(
          after['destructiveForeground']!,
          after['destructive']!,
        );
        expect(
          fill,
          greaterThanOrEqualTo(
            math.min(
              4.5,
              contrastRatio(
                before['destructiveForeground']!,
                before['destructive']!,
              ),
            ),
          ),
          reason: palette.id,
        );
      }
    });

    test('only the red changes', () {
      final palette = kConduitPalettes.first;
      final after = accessibleColors(palette.light);
      for (final entry in palette.light.colors.entries) {
        if (entry.key == 'destructive') continue;
        expect(after[entry.key], entry.value, reason: entry.key);
      }
    });
  });

  group('desktop palettes', () {
    test('the desktop offers the phone\'s palettes, Conduit first', () {
      expect(kConduitPalettes.map((p) => p.id), <String>[
        'conduit',
        'claude',
        't3_chat',
        'catppuccin',
        'tangerine',
      ]);
      expect(kDefaultPalette.id, 'conduit');
    });

    test('an unknown id, such as the retired zai, falls back to Conduit', () {
      expect(paletteById('claude').id, 'claude');
      expect(paletteById(null).id, 'conduit');
      expect(paletteById('zai').id, 'conduit');
    });
  });

  group('desktopSurfaces', () {
    test('every variant gets every surface token', () {
      for (final palette in kConduitPalettes) {
        for (final variant in <ThemeVariant>[palette.light, palette.dark]) {
          expect(
            desktopSurfaces(variant).keys,
            kSurfaceTokens,
            reason: palette.id,
          );
        }
      }
    });

    test('a variant\'s own values win over derived ones', () {
      const variant = ThemeVariant(
        background: 0xFFFFFFFF,
        foreground: 0xFF000000,
        card: 0xFFF4F4F4,
        cardForeground: 0xFF000000,
        popover: 0xFFFFFFFF,
        popoverForeground: 0xFF000000,
        primary: 0xFF000000,
        primaryForeground: 0xFFFFFFFF,
        secondary: 0xFFF4F4F4,
        secondaryForeground: 0xFF000000,
        muted: 0xFFF4F4F4,
        mutedForeground: 0xFF6E6E80,
        accent: 0xFFECECEC,
        accentForeground: 0xFF000000,
        destructive: 0xFFEF4444,
        destructiveForeground: 0xFFFFFFFF,
        border: 0xFFE5E5E5,
        input: 0xFFE5E5E5,
        ring: 0xFF8E8EA0,
        sidebarBackground: 0xFFF4F4F4,
        sidebarForeground: 0xFF000000,
        sidebarPrimary: 0xFF000000,
        sidebarPrimaryForeground: 0xFFFFFFFF,
        sidebarAccent: 0xFFECECEC,
        sidebarAccentForeground: 0xFF000000,
        sidebarBorder: 0xFFE5E5E5,
        sidebarRing: 0xFF8E8EA0,
        success: 0xFF10A37F,
        successForeground: 0xFFFFFFFF,
        warning: 0xFFF59E0B,
        warningForeground: 0xFF000000,
        info: 0xFF10A37F,
        infoForeground: 0xFFFFFFFF,
        radius: 10,
        surfaces: <String, int>{'window': 0xFFF8F8F8},
      );
      expect(desktopSurfaces(variant)['window'], 0xFFF8F8F8);
      expect(
        desktopSurfaces(kDefaultPalette.light)['window'],
        isNot(0xFFF8F8F8),
      );
    });

    test('subtle text reads at AA on every opaque layer', () {
      for (final palette in kConduitPalettes) {
        for (final variant in <ThemeVariant>[palette.light, palette.dark]) {
          final s = desktopSurfaces(variant);
          final layers = <int>[
            variant.background,
            variant.card,
            variant.popover,
            s['window']!,
            s['panel']!,
            s['menu']!,
          ];
          for (final layer in layers) {
            expect(
              contrastRatio(s['foregroundSubtle']!, layer),
              greaterThanOrEqualTo(4.5),
              reason: '${palette.id} subtle on ${_hex(layer)}',
            );
            expect(
              contrastRatio(s['foregroundSubtlest']!, layer),
              greaterThanOrEqualTo(3),
              reason: '${palette.id} subtlest on ${_hex(layer)}',
            );
          }
        }
      }
    });

    test('hover and selected are translucent, so they work on any layer', () {
      for (final palette in kConduitPalettes) {
        final s = desktopSurfaces(palette.light);
        expect(s['hover']! >> 24 & 0xFF, lessThan(0xFF), reason: palette.id);
        expect(s['selected']! >> 24 & 0xFF, lessThan(0xFF), reason: palette.id);
      }
    });
  });
}

String _hex(int argb) => '0x${argb.toRadixString(16).padLeft(8, '0')}';
