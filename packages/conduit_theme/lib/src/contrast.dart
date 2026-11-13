import 'dart:math' as math;

import 'palette.dart';

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

/// [variant]'s colours for the desktop window, with the destructive red
/// moved until it meets WCAG AA (4.5:1) where the window uses it: as text
/// on the surfaces, and as a fill under its own foreground.
///
/// On a light variant both needs point the same way, so the red darkens
/// until both are met. On a dark one they pull apart -- text wants it
/// lighter, the fill under white text darker -- so it lightens for text
/// only as far as the fill keeps its contrast. The phone app reads the
/// palettes directly and is unaffected.
Map<String, int> accessibleColors(ThemeVariant variant) {
  final colors = Map<String, int>.of(variant.colors);
  final surfaces = <int>[
    for (final token in const <String>[
      'background',
      'card',
      'muted',
      'secondary',
    ])
      ?colors[token],
  ];
  final foreground = colors['destructiveForeground'];
  var red = colors['destructive'];
  if (red == null || foreground == null || surfaces.isEmpty) return colors;
  bool readable(int c) => surfaces.every((s) => contrastRatio(c, s) >= 4.5);
  bool filled(int c) => contrastRatio(foreground, c) >= 4.5;
  final light = relativeLuminance(colors['background'] ?? surfaces.first) > 0.5;
  for (var step = 0; step < 40 && !(readable(red!) && filled(red)); step++) {
    final next = mixColor(red, light ? 0xFF000000 : 0xFFFFFFFF, 0.04);
    if (!light && !filled(next)) break;
    red = next;
  }
  colors['destructive'] = red!;
  return colors;
}
