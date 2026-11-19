import 'dart:math' as math;

import 'palette.dart';
import 'surfaces.dart';

/// WCAG's relative luminance of an ARGB colour.
double relativeLuminance(int argb) {
  double channel(int value) {
    final c = value / 255;
    return c <= 0.03928
        ? c / 12.92
        : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel((argb >> 16) & 0xFF) +
      0.7152 * channel((argb >> 8) & 0xFF) +
      0.0722 * channel(argb & 0xFF);
}

/// WCAG's contrast ratio between two colours, from 1 to 21.
double contrastRatio(int a, int b) {
  final la = relativeLuminance(a);
  final lb = relativeLuminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// [argb] moved [amount] of the way toward [toward], keeping its alpha.
int mixColor(int argb, int toward, double amount) {
  int channel(int shift) {
    final from = (argb >> shift) & 0xFF;
    final to = (toward >> shift) & 0xFF;
    return (from + (to - from) * amount).round().clamp(0, 255);
  }

  return (argb & 0xFF000000) |
      (channel(16) << 16) |
      (channel(8) << 8) |
      channel(0);
}

/// Black or white, whichever reads better on every one of [colors] (by the
/// lowest contrast against any of them): the way to move a colour so it can
/// reach a ratio against them, whatever their luminance.
int contrastEndpoint(Iterable<int> colors) {
  double worst(int end) =>
      colors.map((c) => contrastRatio(end, c)).reduce(math.min);
  return worst(0xFF000000) >= worst(0xFFFFFFFF) ? 0xFF000000 : 0xFFFFFFFF;
}

/// [argb] drawn over the opaque [background]: what it looks like there,
/// fully opaque.
int compositeOver(int argb, int background) {
  final a = ((argb >> 24) & 0xFF) / 255;
  int channel(int shift) {
    final top = (argb >> shift) & 0xFF;
    final under = (background >> shift) & 0xFF;
    return (top * a + under * (1 - a)).round().clamp(0, 255);
  }

  return 0xFF000000 | (channel(16) << 16) | (channel(8) << 8) | channel(0);
}

/// [variant]'s colours for the desktop window, with the destructive red
/// moved until it reads as text at WCAG AA (4.5:1) on every opaque layer the
/// window draws: the shared surfaces and the desktop's own (window, panels,
/// menus, their hovered row, tooltips).
///
/// On a light variant the red darkens, which also keeps its fill readable
/// under its own foreground. On a dark one the two pull apart -- text wants
/// it lighter, a fill under white text darker -- so this red is the text
/// colour, and [destructiveFill] is the fill. The phone app reads the
/// palettes directly and is unaffected.
Map<String, int> accessibleColors(ThemeVariant variant) {
  final colors = Map<String, int>.of(variant.colors);
  final surfaces = desktopSurfaces(variant);
  final layers = <int>[
    for (final token in const <String>[
      'background',
      'card',
      'popover',
      'muted',
    ])
      ?colors[token],
    for (final token in kTextLayerSurfaces)
      if (surfaces[token]! >> 24 & 0xFF == 0xFF) surfaces[token]!,
  ];
  final foreground = colors['destructiveForeground'];
  var red = colors['destructive'];
  if (red == null || foreground == null || layers.isEmpty) return colors;
  bool readable(int c) => layers.every((s) => contrastRatio(c, s) >= 4.5);
  bool filled(int c) => contrastRatio(foreground, c) >= 4.5;
  // Toward whichever end reads on the layers; darkening (a light variant)
  // also keeps the fill under a light foreground readable.
  final toward = contrastEndpoint(layers);
  final light = toward == 0xFF000000;
  for (
    var step = 0;
    step < 100 && !(readable(red!) && (!light || filled(red)));
    step++
  ) {
    final next = mixColor(red, toward, 0.04);
    // Near the end a 4% step rounds to no change: take the end itself.
    red = next == red ? toward : next;
  }
  colors['destructive'] = red!;
  return colors;
}

/// The fill of a destructive button in [variant]: the red from
/// [accessibleColors], moved toward black or white, whichever reads better
/// under the foreground, until the foreground reads on it at 4.5:1. On a
/// light variant that is the red itself.
int destructiveFill(ThemeVariant variant) {
  final colors = accessibleColors(variant);
  final foreground = colors['destructiveForeground']!;
  final toward = contrastEndpoint(<int>[foreground]);
  var fill = colors['destructive']!;
  for (
    var step = 0;
    step < 100 && contrastRatio(foreground, fill) < 4.5;
    step++
  ) {
    final next = mixColor(fill, toward, 0.04);
    fill = next == fill ? toward : next;
  }
  return fill;
}
