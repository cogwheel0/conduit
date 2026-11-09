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
}
