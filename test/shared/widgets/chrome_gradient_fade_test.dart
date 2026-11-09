import 'dart:math' as math;

import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/chrome_gradient_fade.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('chrome fade uses the 4.0.3 gradient without a blur layer', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        home: const Scaffold(
          body: Stack(
            children: [
              Text('Scrolling content'),
              ConduitChromeGradientFade.top(contentHeight: 80),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(ShaderMask), findsNothing);
    expect(find.byType(DecoratedBox), findsWidgets);
    final fade = find.byType(ConduitChromeGradientFade);
    expect(tester.getSize(fade).height, 110);
    expect(
      find.descendant(of: fade, matching: find.byType(IgnorePointer)),
      findsOneWidget,
    );
  });

  testWidgets('behind floating chrome the fade is opaque, then eases out', (
    tester,
  ) async {
    Future<LinearGradient> pumpEdge(Widget fade) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          home: Scaffold(body: Stack(children: [fade])),
        ),
      );
      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(ConduitChromeGradientFade),
          matching: find.byType(DecoratedBox),
        ),
      );
      return (box.decoration as BoxDecoration).gradient! as LinearGradient;
    }

    for (final fade in const [
      ConduitChromeGradientFade.top(
        contentHeight: 90,
        fadeHeight: 30,
        solidBehindChrome: true,
      ),
      ConduitChromeGradientFade.bottom(
        contentHeight: 90,
        fadeHeight: 30,
        solidBehindChrome: true,
      ),
    ]) {
      final gradient = await pumpEdge(fade);
      final stops = gradient.stops!;
      final alphas = [for (final color in gradient.colors) color.a];
      // Fully opaque from the chrome's edge through the chrome itself.
      expect(stops[1], closeTo(0.75, 0.001));
      expect(alphas[0], 1);
      expect(alphas[1], 1);
      // Then it only ever clears, ending fully clear, with no hard step.
      for (var i = 1; i < alphas.length; i++) {
        expect(alphas[i], lessThanOrEqualTo(alphas[i - 1]));
        expect(alphas[i - 1] - alphas[i], lessThan(0.25));
      }
      expect(alphas.last, 0);
      // It always starts at the chrome's own edge.
      expect(
        gradient.begin,
        fade.edge == ConduitChromeFadeEdge.top
            ? Alignment.topCenter
            : Alignment.bottomCenter,
      );
    }
  });

  group('soft scroll edge', () {
    // An iPhone header: status bar 62, buttons 44 tall centred in a 48 pt
    // bar, so their bottom edge is 108 pt down.
    const top = ConduitScrollEdgeEffect.top(coverExtent: 108);

    test('covers the status bar and the buttons, then eases out', () {
      expect(top.extent, 108 + kConduitScrollEdgeSoftExtent);
      // The page background, fully, down to the buttons' bottom edge: no
      // text behind or beside the glass.
      for (final d in [0.0, 30.0, 62.0, 86.0, 108.0]) {
        expect(top.tintOpacityAt(d), 1);
      }
      // Then it eases out: clear at the end, half way at the middle.
      expect(top.tintOpacityAt(top.extent), 0);
      expect(
        top.tintOpacityAt(108 + kConduitScrollEdgeSoftExtent / 2),
        closeTo(0.5, 1e-9),
      );
    });

    test('the fade has no step or crease, even across one line of text', () {
      // Flat where it meets the cover and where it clears, and never
      // steeper than a smoothstep across the strip: a 17 pt line under it
      // fades from the top of its letters to their foot, without a seam.
      var previous = 1.0;
      var steepest = 0.0;
      for (var d = 108.0; d <= top.extent + 1; d += 0.25) {
        final alpha = top.tintOpacityAt(d);
        expect(alpha, lessThanOrEqualTo(previous + 1e-9));
        steepest = math.max(steepest, (previous - alpha) / 0.25);
        previous = alpha;
      }
      expect(
        steepest,
        lessThanOrEqualTo(1.5 / kConduitScrollEdgeSoftExtent + 1e-9),
      );
      expect(1 - top.tintOpacityAt(108.5), lessThan(0.01));
      expect(top.tintOpacityAt(top.extent - 0.5), lessThan(0.01));
    });

    test('a line caught across the cover edge dissolves, never sliced', () {
      // A 17 pt line's letters stand about 16 pt tall. Once half of them or
      // more are under the cover, what shows below it is under a tenth of
      // its ink: a fading ghost, not the foot of a cut line.
      for (var covered = 8.0; covered <= 16; covered += 0.5) {
        final foot = 108 - covered + 16;
        expect(1 - top.tintOpacityAt(foot), lessThan(0.1));
      }
      // Still short enough to clear a sent message resting under the
      // header (22 pt under the buttons plus the chat's 56 pt peek).
      expect(kConduitScrollEdgeSoftExtent, lessThanOrEqualTo(22 + 56));
    });

    test('with nothing under the edge the strip is gone', () {
      const resting = ConduitScrollEdgeEffect.top(
        coverExtent: 108,
        engagement: 0,
      );
      expect(resting.extent, 108);
      // A first message resting 22 pt under the buttons is untouched.
      expect(resting.tintOpacityAt(130), 0);
      // Fully engaged (a message sent in a longer chat, resting 56 pt lower
      // so the reply before it peeks out above), its bubble is untouched
      // too.
      expect(top.tintOpacityAt(130 + 56), 0);
      // The cover itself never moves.
      expect(resting.tintOpacityAt(108), 1);
    });

    test('a scroll toward the edge meets the strip at its clear end', () {
      // Scrolled 10 pt: the strip is 10 pt long, and a line that has moved
      // from 130 to 120 is still clear.
      const engaged = ConduitScrollEdgeEffect.top(
        coverExtent: 108,
        engagement: 10 / kConduitScrollEdgeSoftExtent,
      );
      expect(engaged.stripExtent, closeTo(10, 1e-9));
      expect(engaged.tintOpacityAt(120), 0);
      expect(engaged.tintOpacityAt(113), closeTo(0.5, 1e-9));
    });

    testWidgets('draws no backdrop filter', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          home: const Scaffold(
            body: Stack(
              children: [
                Text('Scrolling content'),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: ConduitScrollEdgeEffect.top(coverExtent: 108),
                ),
              ],
            ),
          ),
        ),
      );
      final edge = find.byType(ConduitScrollEdgeEffect);
      expect(
        find.descendant(of: edge, matching: find.byType(BackdropFilter)),
        findsNothing,
      );
    });

    testWidgets('lays its tint from the screen edge, ignoring touches', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          home: const Scaffold(
            body: Stack(
              children: [
                Text('Scrolling content'),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ConduitScrollEdgeEffect.bottom(coverExtent: 90),
                ),
              ],
            ),
          ),
        ),
      );
      final edge = find.byType(ConduitScrollEdgeEffect);
      expect(tester.getSize(edge).height, 90 + kConduitScrollEdgeSoftExtent);
      expect(
        find.descendant(of: edge, matching: find.byType(IgnorePointer)),
        findsWidgets,
      );
      final box = tester.widget<DecoratedBox>(
        find.descendant(of: edge, matching: find.byType(DecoratedBox)),
      );
      final gradient =
          (box.decoration as BoxDecoration).gradient! as LinearGradient;
      expect(gradient.begin, Alignment.bottomCenter);
      // Opaque from the screen's bottom to the composer's top, then easing
      // out from there without a crease.
      expect(gradient.colors[1].a, 1);
      expect(
        gradient.stops![1],
        closeTo(90 / (90 + kConduitScrollEdgeSoftExtent), 1e-9),
      );
      expect(gradient.colors[2].a, greaterThan(0.98));
      expect(gradient.colors.last.a, 0);
    });
  });
}
