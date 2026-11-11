import 'package:conduit/features/chat/widgets/composer_prominent_button.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _fill = Color(0xFF000000);
const _page = Color(0xFFFFFFFF);

Widget _harness({VoidCallback? onPressed, bool reduceMotion = false}) {
  return MaterialApp(
    theme: ThemeData(scaffoldBackgroundColor: _page),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Scaffold(
        backgroundColor: _page,
        body: Center(
          child: ComposerProminentButton(
            onPressed: onPressed,
            targetSize: 44,
            visualSize: 32,
            fill: _fill,
            glyph: const Icon(Icons.arrow_upward, size: 16),
          ),
        ),
      ),
    ),
  );
}

Color _discFill(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(
    find.descendant(
      of: find.byType(ComposerProminentButton),
      matching: find.byType(DecoratedBox),
    ),
  );
  return (box.decoration as BoxDecoration).color!;
}

double _discScale(WidgetTester tester) => tester
    .widget<Transform>(
      find.descendant(
        of: find.byType(ComposerProminentButton),
        matching: find.byType(Transform),
      ),
    )
    .transform
    .entry(0, 0);

void main() {
  testWidgets('a press shrinks and dims the disc, never tints it', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(_harness(onPressed: () => taps++));
    expect(_discFill(tester), _fill);
    expect(_discScale(tester), 1);
    expect(
      tester.getSize(find.byType(ComposerProminentButton)),
      const Size.square(44),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ComposerProminentButton)),
    );
    await tester.pumpAndSettle();
    expect(
      _discScale(tester),
      closeTo(ComposerProminentButton.pressedScale, 0.001),
    );
    final pressed = _discFill(tester);
    // Monochrome: a shade between the fill and the page, no hue of its own.
    expect(pressed.r, pressed.g);
    expect(pressed.g, pressed.b);
    expect(pressed, isNot(_fill));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(_discScale(tester), closeTo(1, 0.001));
    expect(_discFill(tester).toARGB32(), _fill.toARGB32());
  });

  testWidgets('the target edge outside the disc still sends', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_harness(onPressed: () => taps++));
    final target = tester.getRect(find.byType(ComposerProminentButton));
    await tester.tapAt(target.topLeft + const Offset(2, 2));
    expect(taps, 1);
  });

  testWidgets('Reduce Motion keeps the dimming and drops the scale', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(onPressed: () {}, reduceMotion: true));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ComposerProminentButton)),
    );
    await tester.pumpAndSettle();
    expect(_discScale(tester), 1);
    expect(_discFill(tester), isNot(_fill));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a disabled disc is quiet and ignores presses', (tester) async {
    await tester.pumpWidget(_harness());
    expect(_discFill(tester), isNot(_fill));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ComposerProminentButton)),
    );
    await tester.pumpAndSettle();
    expect(_discScale(tester), 1);
    await gesture.up();
  });
}
