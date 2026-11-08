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
    // An iPhone header: status bar 62, bar 48 (buttons 44 tall, 2 below).
    const top = ConduitScrollEdgeEffect.top(
      chromeExtent: 110,
      chromeThickness: 48,
      solidExtent: 56,
    );

    test('covers the status bar, hazes the chrome, clears past it', () {
      expect(top.extent, 110 + kConduitScrollEdgeSoftExtent);
      // Fully covered behind the clock.
      for (final d in [0.0, 20.0, 56.0]) {
        expect(top.tintOpacityAt(d), 1);
      }
      // Mostly washed out behind the buttons, never fully opaque there, so
      // the edge reads as a dissolve rather than a band.
      expect(top.tintOpacityAt(86), closeTo(0.85, 0.001));
      expect(top.tintOpacityAt(110), closeTo(0.7, 0.001));
      // Clear at the end, with no step anywhere on the way.
      expect(top.tintOpacityAt(top.extent), 0);
      var previous = 1.0;
      for (var d = 0.0; d <= top.extent; d += 0.5) {
        final alpha = top.tintOpacityAt(d);
        expect(alpha, lessThanOrEqualTo(previous + 1e-9));
        expect(previous - alpha, lessThan(0.05));
        previous = alpha;
      }
    });

    test('blurs hardest behind the chrome and eases out to sharp', () {
      expect(top.sigmaAt(0), kConduitScrollEdgeMaxSigma);
      expect(top.sigmaAt(top.fullBlurExtent), kConduitScrollEdgeMaxSigma);
      expect(top.sigmaAt(top.extent), 0);
      // Text just past the buttons is soft but not smeared.
      expect(top.sigmaAt(118), lessThan(1.5));
      var previous = top.sigmaAt(top.fullBlurExtent);
      for (var d = top.fullBlurExtent; d <= top.extent; d += 0.5) {
        final sigma = top.sigmaAt(d);
        expect(sigma, lessThanOrEqualTo(previous + 1e-9));
        expect(previous - sigma, lessThan(0.5), reason: 'no visible band');
        previous = sigma;
      }
    });

    testWidgets('lays its tint from the chrome edge, ignoring touches', (
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
                  child: ConduitScrollEdgeEffect.bottom(
                    chromeExtent: 90,
                    chromeThickness: 48,
                    solidExtent: 42,
                  ),
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
      expect(gradient.colors.first.a, 1);
      expect(gradient.colors.last.a, 0);
    });
  });
}
