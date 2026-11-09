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
    // bar, so they span 64 to 108 pt down.
    const top = ConduitScrollEdgeEffect.top(coverExtent: 108);
    double ink(double distance, [ConduitScrollEdgeEffect edge = top]) =>
        1 - edge.tintOpacityAt(distance);

    test('covers the status bar, leaves a trace behind the buttons and '
        'clears below them', () {
      expect(top.solidExtent, 108 - kConduitScrollEdgeCoverInset);
      expect(top.extent, 108 + kConduitScrollEdgeSoftExtent);
      // The page background, fully, over the status bar and the upper part
      // of the buttons.
      for (final d in [0.0, 30.0, 62.0, top.solidExtent]) {
        expect(top.tintOpacityAt(d), 1);
      }
      // Behind the lower part of the buttons the text is at most a trace,
      // too faint to read through the glass or between the buttons ...
      expect(ink(92), lessThan(0.01));
      expect(ink(108), inInclusiveRange(0.02, 0.05));
      // ... half its ink a little below them, and clear at the end.
      expect(ink(108 + kConduitScrollEdgeFadeMidpoint), closeTo(0.5, 0.01));
      expect(ink(108 + 50), greaterThan(0.9));
      expect(top.tintOpacityAt(top.extent), 0);
    });

    test('the fade has no step or crease', () {
      var previous = 1.0;
      var steepest = 0.0;
      for (var d = top.solidExtent; d <= top.extent + 1; d += 0.25) {
        final alpha = top.tintOpacityAt(d);
        expect(alpha, lessThanOrEqualTo(previous + 1e-9));
        steepest = math.max(steepest, (previous - alpha) / 0.25);
        previous = alpha;
      }
      // Gentler than the 44 pt smoothstep it replaces.
      expect(steepest, lessThan(1.5 / 44));
      // It eases in from the cover and out to clear.
      expect(ink(top.solidExtent + 0.5), lessThan(0.01));
      expect(top.tintOpacityAt(top.extent - 0.5), lessThan(0.01));
    });

    test('a line under the edge dims as a whole, never cut', () {
      // A 17 pt line's letters stand about 16 pt tall. Wherever the line
      // sits, once its foot (the lower half's centre) shows enough to read,
      // its top (the upper half's centre, 8 pt higher) keeps a good share
      // of that ink: no line shows a solid foot under a vanished top.
      for (var t = 40.0; t <= top.extent; t += 0.25) {
        final foot = ink(t + 8);
        if (foot < 0.1) continue;
        expect(ink(t) / foot, greaterThan(0.4), reason: 'line top at $t');
      }
      // And when the top of a line's letters is gone, its foot is a trace.
      for (var t = 40.0; t <= top.extent; t += 0.25) {
        if (ink(t) >= 0.02) continue;
        expect(ink(t + 16), lessThan(0.12), reason: 'line top at $t');
      }
    });

    test('a sent message resting under the header stays crisp', () {
      // 92 pt below the transcript's top, which is a few points below the
      // buttons: well past the fade.
      expect(108 + kConduitScrollEdgeSoftExtent, lessThan(108 + 92));
    });

    test('with nothing under the edge the fade stays behind the chrome', () {
      const resting = ConduitScrollEdgeEffect.top(
        coverExtent: 108,
        engagement: 0,
      );
      expect(resting.extent, 108);
      // A first message resting just under the buttons is untouched.
      expect(resting.tintOpacityAt(108), 0);
      expect(resting.tintOpacityAt(130), 0);
      // The covered part never moves.
      expect(resting.solidExtent, top.solidExtent);
      expect(resting.tintOpacityAt(top.solidExtent), 1);
    });

    test('a scroll toward the edge meets the fade at its clear end', () {
      const engaged = ConduitScrollEdgeEffect.top(
        coverExtent: 108,
        engagement: 0.25,
      );
      expect(engaged.extent, 108 + kConduitScrollEdgeSoftExtent * 0.25);
      expect(engaged.tintOpacityAt(engaged.extent), 0);
      expect(engaged.tintOpacityAt(engaged.extent - 0.5), lessThan(0.02));
      // More content under the edge, more of it faded at any one place.
      for (final d in [100.0, 108.0, 116.0]) {
        expect(engaged.tintOpacityAt(d), lessThan(top.tintOpacityAt(d)));
      }
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
      // Opaque from the screen's bottom to the middle of the composer, then
      // easing out from there without a crease.
      expect(gradient.colors[1].a, 1);
      expect(
        gradient.stops![1],
        closeTo(
          (90 - kConduitScrollEdgeCoverInset) /
              (90 + kConduitScrollEdgeSoftExtent),
          1e-9,
        ),
      );
      expect(gradient.colors[2].a, greaterThan(0.98));
      expect(gradient.colors.last.a, 0);
    });
  });
}
