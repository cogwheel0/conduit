import 'css.dart';
import 'palette.dart';

/// The desktop's layered surface tokens, in the order they are written.
///
/// The desktop window is built from frames on a backdrop, and it separates
/// layers by background contrast before borders, and borders before
/// shadows (docs/desktop/REDESIGN.md). The shared tweakcn tokens name
/// too few layers for that, so these sit alongside them:
///
/// * `window` is the backdrop the frames sit on, and `panel` and `header`
///   are the frames;
/// * `surface` and `surfaceHover` are translucent fills for content blocks
///   inside a frame;
/// * `menu` and `menuHover` are overlays, `tooltip` their small cousin;
/// * `hover` and `selected` are row states, translucent so they work on
///   any layer;
/// * `foregroundSubtle` is secondary text and `foregroundSubtlest` icons and
///   hints;
/// * `tab` and `tabActive` are a tab strip and its current tab;
/// * `brand` is the one strong accent.
const List<String> kSurfaceTokens = <String>[
  'window',
  'panel',
  'header',
  'surface',
  'surfaceHover',
  'menu',
  'menuHover',
  'hover',
  'selected',
  'borderHover',
  'foregroundSubtle',
  'foregroundSubtlest',
  'tab',
  'tabActive',
  'brand',
  'tooltip',
  'tooltipForeground',
];

/// [variant]'s surface tokens: its own [ThemeVariant.surfaces], with any it
/// leaves out derived from its colours.
///
/// Text tokens are then held to WCAG AA whatever their source:
/// `foregroundSubtle` reads at 4.5:1 on every opaque layer, and
/// `foregroundSubtlest`, used for icons and hints rather than text, at 3:1.
Map<String, int> desktopSurfaces(ThemeVariant variant) {
  final c = variant.colors;
  final dark = relativeLuminance(c['background']!) < 0.5;
  final fg = c['foreground']!;
  int alpha(int argb, double a) =>
      ((a * 255).round() << 24) | (argb & 0x00FFFFFF);

  final derived = <String, int>{
    'window': mixColor(c['background']!, fg, dark ? 0.04 : 0.03),
    'panel': c['background']!,
    'header': c['background']!,
    'surface': alpha(fg, dark ? 0.05 : 0.03),
    'surfaceHover': alpha(fg, dark ? 0.1 : 0.05),
    'menu': c['popover']!,
    'menuHover': mixColor(c['popover']!, fg, dark ? 0.1 : 0.06),
    'hover': alpha(fg, 0.05),
    'selected': alpha(fg, dark ? 0.1 : 0.07),
    'borderHover': mixColor(c['border']!, fg, 0.15),
    'foregroundSubtle': c['mutedForeground']!,
    'foregroundSubtlest': mixColor(
      c['mutedForeground']!,
      c['background']!,
      0.3,
    ),
    'brand': c['primary']!,
    'tooltip': mixColor(c['popover']!, fg, dark ? 0.1 : 0.06),
    'tooltipForeground': fg,
  };
  final surfaces = <String, int>{...derived, ...variant.surfaces};
  surfaces['tab'] ??= surfaces['window']!;
  surfaces['tabActive'] ??= surfaces['panel']!;

  final layers = <int>[
    for (final token in const <String>['background', 'card', 'popover'])
      c[token]!,
    for (final token in const <String>['window', 'panel', 'menu'])
      surfaces[token]!,
  ];
  final subtle = _towardContrast(
    surfaces['foregroundSubtle']!,
    fg,
    layers,
    4.5,
  );
  surfaces['foregroundSubtle'] = subtle;
  surfaces['foregroundSubtlest'] = _towardContrast(
    surfaces['foregroundSubtlest']!,
    fg,
    layers,
    3,
  );
  return <String, int>{
    for (final token in kSurfaceTokens) token: surfaces[token]!,
  };
}

/// Moves [color] toward [foreground] until it has [ratio] against every one
/// of [layers].
int _towardContrast(int color, int foreground, List<int> layers, double ratio) {
  var value = color;
  for (
    var step = 0;
    step < 40 && layers.any((l) => contrastRatio(value, l) < ratio);
    step++
  ) {
    value = mixColor(value, foreground, 0.08);
  }
  return value;
}
