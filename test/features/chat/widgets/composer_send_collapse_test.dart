import 'package:conduit/features/chat/widgets/composer_send_collapse.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _box = ValueKey('collapse');
const _content = ValueKey('content');

Widget _harness({
  required int token,
  required double contentHeight,
  bool disableAnimations = false,
  bool holding = false,
  VoidCallback? onDone,
}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ComposerSendCollapse(
          key: _box,
          token: token,
          holding: holding,
          onDone: onDone,
          child: SizedBox(key: _content, width: 300, height: contentHeight),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a send shrinks the composer on a spring, content at the '
      'bottom', (tester) async {
    var done = 0;
    await tester.pumpWidget(
      _harness(token: 0, contentHeight: 96, onDone: () => done++),
    );
    expect(tester.getSize(find.byKey(_box)).height, 96);

    await tester.pumpWidget(
      _harness(token: 1, contentHeight: 44, onDone: () => done++),
    );
    // The frame of the send keeps the old height; the one-line content
    // already sits at the bottom, where the buttons were.
    expect(tester.getSize(find.byKey(_box)).height, 96);
    expect(
      tester.getBottomLeft(find.byKey(_content)).dy,
      tester.getBottomLeft(find.byKey(_box)).dy,
    );

    await tester.pump(const Duration(milliseconds: 80));
    final midway = tester.getSize(find.byKey(_box)).height;
    expect(midway, inExclusiveRange(44, 96));

    var previous = midway;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      final height = tester.getSize(find.byKey(_box)).height;
      // Critically damped: it only ever closes, never overshoots.
      expect(height, lessThanOrEqualTo(previous));
      expect(height, greaterThanOrEqualTo(44));
      previous = height;
    }
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(_box)).height, 44);
    expect(done, 1);
  });

  testWidgets('while the sent words are still in it, it keeps its height '
      'even as its field clears, then closes from there', (tester) async {
    await tester.pumpWidget(_harness(token: 0, contentHeight: 96));
    await tester.pumpWidget(
      _harness(token: 0, contentHeight: 96, holding: true),
    );
    // The field clears under the flying words: the composer holds.
    await tester.pumpWidget(
      _harness(token: 0, contentHeight: 44, holding: true),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getSize(find.byKey(_box)).height, 96);
    expect(
      tester.getBottomLeft(find.byKey(_content)).dy,
      tester.getBottomLeft(find.byKey(_box)).dy,
    );

    // The words have left: it closes on the spring from the held height.
    await tester.pumpWidget(_harness(token: 1, contentHeight: 44));
    expect(tester.getSize(find.byKey(_box)).height, 96);
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getSize(find.byKey(_box)).height, inExclusiveRange(44, 96));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(_box)).height, 44);
  });

  testWidgets('typing changes the height directly', (tester) async {
    await tester.pumpWidget(_harness(token: 0, contentHeight: 44));
    await tester.pumpWidget(_harness(token: 0, contentHeight: 66));
    expect(tester.getSize(find.byKey(_box)).height, 66);
    await tester.pumpWidget(_harness(token: 0, contentHeight: 44));
    expect(tester.getSize(find.byKey(_box)).height, 44);
  });

  testWidgets('Reduce Motion shrinks it at once', (tester) async {
    var done = 0;
    await tester.pumpWidget(
      _harness(
        token: 0,
        contentHeight: 96,
        disableAnimations: true,
        onDone: () => done++,
      ),
    );
    await tester.pumpWidget(
      _harness(
        token: 1,
        contentHeight: 44,
        disableAnimations: true,
        onDone: () => done++,
      ),
    );
    expect(tester.getSize(find.byKey(_box)).height, 44);
    await tester.pump();
    expect(done, 1);
  });
}
