import 'package:conduit_theme/conduit_theme.dart';
import 'package:test/test.dart';

void main() {
  group('registry', () {
    test('ships the five documented palettes in picker order', () {
      expect(
        kConduitPalettes.map((p) => p.id).toList(),
        <String>['conduit', 'claude', 't3_chat', 'catppuccin', 'tangerine'],
      );
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

    test('defaults are present before any data-palette is set', () {
      expect(css, contains(':root {'));
      final defaults = kDefaultPalette.light;
      expect(css, contains(cssColor(defaults.background)));
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
      // 5 palettes x 2 modes x 33 tokens, plus the :root defaults in both
      // modes. Counting catches a generator that silently drops a rule.
      final occurrences = '--conduit-background:'.allMatches(css).length;
      expect(occurrences, (kConduitPalettes.length * 3) + 2);
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
}
