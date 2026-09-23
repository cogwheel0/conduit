import 'package:checks/checks.dart';
import 'package:conduit/shared/widgets/horizontal_overflow_fade.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const double _viewportWidth = 200;

Future<ScrollController> _pumpRow(
  WidgetTester tester, {
  required double contentWidth,
  TextDirection textDirection = TextDirection.ltr,
}) async {
  final controller = ScrollController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    Directionality(
      textDirection: textDirection,
      child: Center(
        child: SizedBox(
          width: _viewportWidth,
          height: 40,
          child: HorizontalOverflowFade(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              controller: controller,
              child: SizedBox(width: contentWidth, height: 40),
            ),
          ),
        ),
      ),
    ),
  );
  // The scroll view reports its metrics in a microtask after layout.
  await tester.pump();
  return controller;
}

/// Every way the cue can paint: a mask over the row's own pixels, or a
/// gradient drawn on top of it.
Iterable<Object> _fadePaints(WidgetTester tester) => [
  ...find.byType(ShaderMask).evaluate(),
  ...tester
      .widgetList<DecoratedBox>(find.byType(DecoratedBox))
      .map((box) => box.decoration)
      .whereType<BoxDecoration>()
      .where((decoration) => decoration.gradient != null),
];

void main() {
  testWidgets('no fade is painted when the row fits (issue #745)', (
    tester,
  ) async {
    await _pumpRow(tester, contentWidth: _viewportWidth - 40);

    check(_fadePaints(tester)).isEmpty();
  });

  testWidgets('the fade appears while content sits past the trailing edge', (
    tester,
  ) async {
    await _pumpRow(tester, contentWidth: _viewportWidth * 2);

    check(find.byType(ShaderMask).evaluate()).length.equals(1);
  });

  testWidgets('the fade clears once the row is scrolled to its end', (
    tester,
  ) async {
    final controller = await _pumpRow(
      tester,
      contentWidth: _viewportWidth * 2,
    );
    final end = controller.position.maxScrollExtent;

    controller.jumpTo(end);
    await tester.pump();

    check(_fadePaints(tester)).isEmpty();
    // Dropping the mask must not rebuild the row out from under the scrollable.
    check(controller.offset).equals(end);
  });

  testWidgets('a right-to-left row still reports its overflow', (
    tester,
  ) async {
    await _pumpRow(
      tester,
      contentWidth: _viewportWidth * 2,
      textDirection: TextDirection.rtl,
    );

    check(find.byType(ShaderMask).evaluate()).length.equals(1);
  });

  test('the gradient starts at the edge the row scrolls away from', () {
    final forward = horizontalOverflowFadeGradient(
      extent: 200,
      width: 28,
      axisDirection: AxisDirection.right,
    );
    check(forward.begin).equals(Alignment.centerLeft);
    check(forward.end).equals(Alignment.centerRight);

    // A right-to-left or reversed row clips its content at the physical left.
    final reversed = horizontalOverflowFadeGradient(
      extent: 200,
      width: 28,
      axisDirection: AxisDirection.left,
    );
    check(reversed.begin).equals(Alignment.centerRight);
    check(reversed.end).equals(Alignment.centerLeft);

    check(reversed.stops).isNotNull().deepEquals([1 - 28 / 200, 1.0]);
  });

  test('a row no wider than the cue fades across its whole width', () {
    final gradient = horizontalOverflowFadeGradient(
      extent: 20,
      width: 28,
      axisDirection: AxisDirection.right,
    );

    check(gradient.stops).isNotNull().deepEquals([0.0, 1.0]);
  });
}
