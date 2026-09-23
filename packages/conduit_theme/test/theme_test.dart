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

  group('css', () {
    final css = generateThemeCss();

    test('aliases Tailwind tokens with @theme inline', () {
      // Without `inline`, Tailwind bakes the current value into every utility
      // and runtime palette switching stops working. Guard the keyword.
      expect(css, contains('@theme inline {'));
      expect(css, contains('--color-background: var(--conduit-background);'));
      expect(css, contains('--radius: var(--conduit-radius);'));
    });

    test('emits light, dark and system rules for every palette', () {
      for (final palette in kConduitPalettes) {
        final selector = '[data-palette="${palette.id}"]';
        expect(css, contains('$selector,\n$selector[data-mode="light"] {'));
        expect(css, contains('$selector[data-mode="dark"] {'));
        expect(css, contains('$selector[data-mode="system"] {'));
      }
      // `system` must sit inside a prefers-color-scheme block, or following
      // the OS would need JavaScript.
      expect(css, contains('@media (prefers-color-scheme: dark) {'));
    });

    test('defaults are Zai before any data-palette is set', () {
      expect(css, contains(':root {\n  --conduit-background: #ffffff;'));
      expect(css, contains('--conduit-window: #f8f8f8;'));
    });

    test('aliases the surface tokens too', () {
      expect(css, contains('--color-window: var(--conduit-window);'));
      expect(
        css,
        contains(
          '--color-foreground-subtle: var(--conduit-foreground-subtle);',
        ),
      );
    });

    test('kebab-cases compound token names', () {
      expect(
        css,
        contains(
          '--color-sidebar-primary-foreground: '
          'var(--conduit-sidebar-primary-foreground);',
        ),
      );
    });

    test('writes every token of every variant', () {
      // Each palette's light, dark and system rules, plus the :root
      // defaults in both modes. Counting catches a generator that silently
      // drops a rule.
      for (final token in <String>[
        'background',
        'window',
        'tooltip-foreground',
      ]) {
        expect(
          '--conduit-$token:'.allMatches(css).length,
          (kDesktopPalettes.length * 3) + 2,
          reason: token,
        );
      }
    });
  });

  group('cssColor', () {
    test('renders opaque colours as hex', () {
      expect(cssColor(0xFFFFFFFF), '#ffffff');
      expect(cssColor(0xFF000000), '#000000');
      expect(cssColor(0xFF10A37F), '#10a37f');
      // Single-digit channels must stay zero-padded, or #0a becomes #a and
      // the colour shifts.
      expect(cssColor(0xFF010203), '#010203');
    });

    test('renders translucent colours as rgb() with an alpha channel', () {
      expect(cssColor(0x80102030), startsWith('rgb(16 32 48 / '));
      expect(cssColor(0x00FFFFFF), contains('/ 0'));
    });
  });

  group('accessibleColors (WP-10.2)', () {
    test(
      'a light variant\'s red reads as text and under its own foreground',
      () {
        for (final palette in kDesktopPalettes) {
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
      for (final palette in kDesktopPalettes) {
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
    test('Zai comes first, then the shared registry', () {
      expect(kDesktopPalettes.first.id, 'zai');
      expect(
        kDesktopPalettes.skip(1).map((p) => p.id),
        kConduitPalettes.map((p) => p.id),
      );
      // The phone's list must not grow a desktop-only palette.
      expect(kConduitPalettes.map((p) => p.id), isNot(contains('zai')));
    });

    test('an unknown id falls back to Zai', () {
      expect(desktopPaletteById('claude').id, 'claude');
      expect(desktopPaletteById(null).id, 'zai');
      expect(desktopPaletteById('gone').id, 'zai');
    });

    test('Zai defines every colour token, opaque, in both modes', () {
      final expected = kConduitPalettes.first.light.colors.keys.toSet();
      for (final variant in <ThemeVariant>[
        kZaiPalette.light,
        kZaiPalette.dark,
      ]) {
        expect(variant.colors.keys.toSet(), expected);
        for (final entry in variant.colors.entries) {
          expect(entry.value >> 24 & 0xFF, 0xFF, reason: entry.key);
        }
        expect(variant.surfaces.keys.toSet(), kSurfaceTokens.toSet());
      }
    });
  });

  group('desktopSurfaces', () {
    test('every variant gets every surface token', () {
      for (final palette in kDesktopPalettes) {
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
      expect(desktopSurfaces(kZaiPalette.light)['window'], 0xFFF8F8F8);
      expect(desktopSurfaces(kZaiPalette.dark)['menuHover'], 0xFF363636);
    });

    test('subtle text reads at AA on every opaque layer', () {
      for (final palette in kDesktopPalettes) {
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
              reason: '${palette.id} subtle on ${cssColor(layer)}',
            );
            expect(
              contrastRatio(s['foregroundSubtlest']!, layer),
              greaterThanOrEqualTo(3),
              reason: '${palette.id} subtlest on ${cssColor(layer)}',
            );
          }
        }
      }
    });

    test('hover and selected are translucent, so they work on any layer', () {
      for (final palette in kDesktopPalettes) {
        final s = desktopSurfaces(palette.light);
        expect(s['hover']! >> 24 & 0xFF, lessThan(0xFF), reason: palette.id);
        expect(s['selected']! >> 24 & 0xFF, lessThan(0xFF), reason: palette.id);
      }
    });
  });
}
