import 'contrast.dart';
import 'palette.dart';

/// The desktop's layered surface tokens, in the order they are written.
///
/// The desktop window is built from frames on a backdrop, and it separates
/// layers by background contrast before borders, and borders before
/// shadows. The shared tweakcn tokens name
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

/// The surface tokens text is drawn on, when they are opaque: the frames,
/// menus and their hovered row, tooltips and tabs. The translucent ones
/// (`surface`, `hover`, `selected`) sit on these.
const List<String> kTextLayerSurfaces = <String>[
  'window',
  'panel',
  'header',
  'menu',
  'menuHover',
  'tooltip',
  'tab',
  'tabActive',
];

/// [variant]'s surface tokens: its own [ThemeVariant.surfaces], with any it
/// leaves out derived from its colours.
///
/// Text tokens are then held to WCAG AA whatever their source:
/// `foregroundSubtle` reads at 4.5:1 on every opaque layer (hovered menu
/// rows and tooltips included), and
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

  // Every opaque layer text sits on, hovered menu rows and tooltips included.
  final layers = <int>[
    for (final token in const <String>[
      'background',
      'card',
      'popover',
      'muted',
    ])
      c[token]!,
    for (final token in kTextLayerSurfaces)
      if (surfaces[token]! >> 24 & 0xFF == 0xFF) surfaces[token]!,
  ];
  // A translucent text override is held to contrast as it is drawn on the
  // main layer.
  int opaque(int argb) =>
      argb >> 24 & 0xFF == 0xFF ? argb : compositeOver(argb, c['background']!);
  surfaces['foregroundSubtle'] = _towardContrast(
    opaque(surfaces['foregroundSubtle']!),
    fg,
    layers,
    4.5,
  );
  surfaces['foregroundSubtlest'] = _towardContrast(
    opaque(surfaces['foregroundSubtlest']!),
    fg,
    layers,
    3,
  );
  return <String, int>{
    for (final token in kSurfaceTokens) token: surfaces[token]!,
  };
}

/// Moves [color] toward [foreground] until it has [ratio] against every one
/// of [layers]. When [foreground] itself falls short of [ratio], or a step
/// toward it no longer changes the colour (the two are a rounding step
/// apart), it moves toward black or white instead, whichever reads on the
/// layers, and keeps going that way, to the end itself once a step rounds
/// to no change.
int _towardContrast(int color, int foreground, List<int> layers, double ratio) {
  bool reads(int c) => layers.every((l) => contrastRatio(c, l) >= ratio);
  final endpoint = contrastEndpoint(layers);
  var target = reads(foreground) ? foreground : endpoint;
  var value = color;
  for (var step = 0; step < 60 && !reads(value); step++) {
    var next = mixColor(value, target, 0.08);
    if (next == value && target != endpoint) {
      target = endpoint;
      next = mixColor(value, target, 0.08);
    }
    value = next == value ? endpoint : next;
  }
  return value;
}
