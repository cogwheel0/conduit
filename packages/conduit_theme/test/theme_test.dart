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
}
