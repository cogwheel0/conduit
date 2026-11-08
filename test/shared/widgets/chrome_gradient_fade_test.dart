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
      // text, sharp or blurred, behind or beside the glass.
      for (final d in [0.0, 30.0, 62.0, 86.0, 108.0]) {
        expect(top.tintOpacityAt(d), 1);
      }
      // Text right beside the glass has already settled into the
      // background, blurred out, rather than half-legible.
      expect(top.settledExtent, greaterThan(108 + 6));
      for (final d in [110.0, 114.0]) {
        expect(top.tintOpacityAt(d), 1);
        expect(top.sigmaAt(d), kConduitScrollEdgeMaxSigma);
      }
      // Then it eases out: clear at the end, with no step on the way.
      expect(top.tintOpacityAt(top.extent), 0);
      expect(
        top.tintOpacityAt((top.settledExtent + top.extent) / 2),
        closeTo(0.5, 1e-9),
      );
      var previous = 1.0;
      for (var d = 0.0; d <= top.extent; d += 0.5) {
        final alpha = top.tintOpacityAt(d);
        expect(alpha, lessThanOrEqualTo(previous + 1e-9));
        expect(previous - alpha, lessThan(0.05));
        previous = alpha;
      }
    });

    test('the strip spans 24 to 32 pt below the chrome', () {
      expect(kConduitScrollEdgeSoftExtent, inInclusiveRange(24, 32));
    });

    test('blurs hardest at the cover and eases out to sharp', () {
      expect(top.sigmaAt(108), kConduitScrollEdgeMaxSigma);
      expect(top.sigmaAt(top.extent), 0);
      // Text just inside the strip is soft but not smeared.
      expect(top.sigmaAt(top.extent - 4), lessThan(1.5));
      var previous = top.sigmaAt(108);
      for (var d = 108.0; d <= top.extent; d += 0.5) {
        final sigma = top.sigmaAt(d);
        expect(sigma, lessThanOrEqualTo(previous + 1e-9));
        expect(previous - sigma, lessThan(0.5), reason: 'no visible band');
        previous = sigma;
      }
    });

    test('with nothing under the edge the strip is gone', () {
      const resting = ConduitScrollEdgeEffect.top(
        coverExtent: 108,
        engagement: 0,
      );
      expect(resting.extent, 108);
      // A first message resting 22 pt under the buttons is untouched.
      expect(resting.tintOpacityAt(130), 0);
      expect(resting.sigmaAt(130), 0);
      // Fully engaged (a message pinned there after a send), it is all but
      // untouched too.
      expect(top.tintOpacityAt(130), lessThan(0.05));
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
      expect(
        engaged.tintOpacityAt((engaged.settledExtent + engaged.extent) / 2),
        closeTo(0.5, 1e-9),
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
      // Opaque from the screen's bottom past the composer's top.
      expect(gradient.colors[1].a, 1);
      expect(
        gradient.stops![1],
        greaterThan(90 / (90 + kConduitScrollEdgeSoftExtent)),
      );
      expect(gradient.colors.last.a, 0);
    });
  });
}
