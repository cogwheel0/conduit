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
      expect(kDefaultPalette.id, 'conduit');
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
      // The retired desktop-only palette too.
      expect(paletteById('zai').id, kDefaultPalette.id);
    });

    test('variantFor picks the requested brightness', () {
      final palette = paletteById('conduit');
      expect(palette.variantFor(dark: false), same(palette.light));
      expect(palette.variantFor(dark: true), same(palette.dark));
    });
  });

  group('accessibleColors', () {
    test('every variant\'s red reads as text on every opaque layer', () {
      for (final palette in kConduitPalettes) {
        for (final (mode, variant) in <(String, ThemeVariant)>[
          ('light', palette.light),
          ('dark', palette.dark),
        ]) {
          final red = accessibleColors(variant)['destructive']!;
          for (final (name, layer) in _opaqueLayers(variant)) {
            expect(
              contrastRatio(red, layer),
              greaterThanOrEqualTo(4.5),
              reason: '${palette.id} $mode red on $name',
            );
          }
        }
      }
    });

    test('every variant\'s fill reads under its own foreground', () {
      for (final palette in kConduitPalettes) {
        for (final (mode, variant) in <(String, ThemeVariant)>[
          ('light', palette.light),
          ('dark', palette.dark),
        ]) {
          final colors = accessibleColors(variant);
          expect(
            contrastRatio(
              colors['destructiveForeground']!,
              destructiveFill(variant),
            ),
            greaterThanOrEqualTo(4.5),
            reason: '${palette.id} $mode text on the fill',
          );
        }
        // On a light variant one red does both.
        expect(
          destructiveFill(palette.light),
          accessibleColors(palette.light)['destructive'],
          reason: palette.id,
        );
      }
    });

    test(
      'a mid-grey foreground or background moves the way that can reach AA',
      () {
        // A #999999 window is darker than mid-luminance, yet only dark text
        // reads on it; under a #AAAAAA label only a darker fill reads.
        final variant = _variant(
          background: 0xFF999999,
          card: 0xFF999999,
          popover: 0xFF999999,
          muted: 0xFF999999,
          destructive: 0xFF888888,
          destructiveForeground: 0xFFAAAAAA,
        );
        final red = accessibleColors(variant)['destructive']!;
        for (final (name, layer) in _opaqueLayers(variant)) {
          expect(
            contrastRatio(red, layer),
            greaterThanOrEqualTo(4.5),
            reason: name,
          );
        }
        expect(
          contrastRatio(0xFFAAAAAA, destructiveFill(variant)),
          greaterThanOrEqualTo(4.5),
        );
      },
    );

    test('only the red changes', () {
      final palette = kConduitPalettes.first;
      final after = accessibleColors(palette.light);
      for (final entry in palette.light.colors.entries) {
        if (entry.key == 'destructive') continue;
        expect(after[entry.key], entry.value, reason: entry.key);
      }
    });
  });

  group('desktopSurfaces', () {
    test('secondary text and icons read on every opaque layer', () {
      for (final palette in kConduitPalettes) {
        for (final (mode, variant) in <(String, ThemeVariant)>[
          ('light', palette.light),
          ('dark', palette.dark),
        ]) {
          final s = desktopSurfaces(variant);
          for (final (name, layer) in _opaqueLayers(variant)) {
            expect(
              contrastRatio(s['foregroundSubtle']!, layer),
              greaterThanOrEqualTo(4.5),
              reason: '${palette.id} $mode foregroundSubtle on $name',
            );
            expect(
              contrastRatio(s['foregroundSubtlest']!, layer),
              greaterThanOrEqualTo(3),
              reason: '${palette.id} $mode foregroundSubtlest on $name',
            );
          }
        }
      }
    });

    test('secondary text reaches AA when the foreground itself cannot', () {
      // Text and its grey both #888888 on white: the foreground gives
      // 3.5:1 at best, so the grey has to go past it toward black.
      final s = desktopSurfaces(
        _variant(foreground: 0xFF888888, mutedForeground: 0xFF888888),
      );
      expect(
        contrastRatio(s['foregroundSubtle']!, 0xFFFFFFFF),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrastRatio(s['foregroundSubtlest']!, 0xFFFFFFFF),
        greaterThanOrEqualTo(3),
      );
    });

    test('a translucent text override is checked as it is drawn', () {
      final s = desktopSurfaces(
        _variant(
          surfaces: <String, int>{
            'foregroundSubtle': 0x00000000,
            'foregroundSubtlest': 0x33000000,
          },
        ),
      );
      for (final token in <String>['foregroundSubtle', 'foregroundSubtlest']) {
        expect(s[token]! >> 24 & 0xFF, 0xFF, reason: token);
      }
      expect(
        contrastRatio(s['foregroundSubtle']!, 0xFFFFFFFF),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrastRatio(s['foregroundSubtlest']!, 0xFFFFFFFF),
        greaterThanOrEqualTo(3),
      );
    });

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
      final variant = _variant(surfaces: <String, int>{'window': 0xFFF8F8F8});
      expect(desktopSurfaces(variant)['window'], 0xFFF8F8F8);
      expect(
        desktopSurfaces(kDefaultPalette.light)['window'],
        isNot(0xFFF8F8F8),
      );
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

/// The opaque layers text is drawn on in the desktop window: the shared
/// tokens and the desktop's own surfaces.
List<(String, int)> _opaqueLayers(ThemeVariant variant) {
  final surfaces = desktopSurfaces(variant);
  return <(String, int)>[
    for (final token in const <String>[
      'background',
      'card',
      'popover',
      'muted',
    ])
      (token, variant.colors[token]!),
    for (final token in kTextLayerSurfaces)
      if (surfaces[token]! >> 24 & 0xFF == 0xFF) (token, surfaces[token]!),
  ];
}

/// A light variant on white with every token set, for edge cases.
ThemeVariant _variant({
  int background = 0xFFFFFFFF,
  int foreground = 0xFF000000,
  int card = 0xFFF4F4F4,
  int popover = 0xFFFFFFFF,
  int muted = 0xFFF4F4F4,
  int mutedForeground = 0xFF6E6E80,
  int destructive = 0xFFEF4444,
  int destructiveForeground = 0xFFFFFFFF,
  Map<String, int> surfaces = const <String, int>{},
}) => ThemeVariant(
  background: background,
  foreground: foreground,
  card: card,
  cardForeground: foreground,
  popover: popover,
  popoverForeground: foreground,
  primary: 0xFF000000,
  primaryForeground: 0xFFFFFFFF,
  secondary: 0xFFF4F4F4,
  secondaryForeground: 0xFF000000,
  muted: muted,
  mutedForeground: mutedForeground,
  accent: 0xFFECECEC,
  accentForeground: 0xFF000000,
  destructive: destructive,
  destructiveForeground: destructiveForeground,
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
  surfaces: surfaces,
);
