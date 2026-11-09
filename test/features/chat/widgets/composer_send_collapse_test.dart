import 'package:conduit/features/chat/widgets/chat_motion_spring.dart';
import 'package:conduit/features/chat/widgets/chat_send_motion.dart';
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
  VoidCallback? onNearlyClosed,
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
          onNearlyClosed: onNearlyClosed,
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
    // The frame the words start to rise already closes by one frame of the
    // spring, as their first step up does (no frame holds the empty
    // height); the one-line content already sits at the bottom, where the
    // buttons were.
    final firstStep = 44 + 52 * ChatSendEntrance.remainingAt(1 / 60);
    expect(tester.getSize(find.byKey(_box)).height, closeTo(firstStep, 0.01));
    expect(firstStep, lessThan(96));
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

  testWidgets('at the display\'s pace it closes one frame of the spring '
      'per frame, from the frame of the send on', (tester) async {
    await tester.pumpWidget(_harness(token: 0, contentHeight: 96));
    await tester.pumpWidget(_harness(token: 1, contentHeight: 44));
    const frame = Duration(microseconds: 16667);
    for (var k = 1; k <= 6; k++) {
      expect(
        tester.getSize(find.byKey(_box)).height,
        closeTo(44 + 52 * ChatSendEntrance.remainingAt(k / 60), 0.05),
        reason: 'frame $k',
      );
      await tester.pump(frame);
    }
  });

  testWidgets('a slow frame holds the collapse back with the rising '
      'message instead of skipping it', (tester) async {
    await tester.pumpWidget(_harness(token: 0, contentHeight: 96));
    await tester.pumpWidget(_harness(token: 1, contentHeight: 44));
    // A 300 ms frame right after the send (a new chat's transcript
    // mounting): the composer closes by two frames' worth of its spring
    // beyond its first step, as the message does, not most of the way in
    // one step.
    await tester.pump(const Duration(milliseconds: 300));
    final afterStall = tester.getSize(find.byKey(_box)).height;
    final twoFrames =
        44 +
        52 *
            ChatSendEntrance.remainingAt(1 / 60 + ChatMotionClock.maxFrameStep);
    expect(afterStall, closeTo(twoFrames, 0.5));
    // Then it plays on at the display's pace.
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.getSize(find.byKey(_box)).height, lessThan(afterStall));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(_box)).height, 44);
  });

  testWidgets('while the sent words wait in it, it keeps its height even '
      'as its field clears, then closes from there', (tester) async {
    var nearly = 0;
    Widget page(int token, double height, {bool holding = false}) => _harness(
      token: token,
      contentHeight: height,
      holding: holding,
      onNearlyClosed: () => nearly++,
    );
    await tester.pumpWidget(page(0, 96));
    await tester.pumpWidget(page(0, 96, holding: true));
    // The field clears under the waiting words: the composer holds.
    await tester.pumpWidget(page(0, 44, holding: true));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getSize(find.byKey(_box)).height, 96);
    expect(
      tester.getBottomLeft(find.byKey(_content)).dy,
      tester.getBottomLeft(find.byKey(_box)).dy,
    );
    expect(nearly, 0);

    // The words rise: it closes on the spring from the held height, from
    // that very frame.
    await tester.pumpWidget(page(1, 44));
    expect(
      tester.getSize(find.byKey(_box)).height,
      closeTo(44 + 52 * ChatSendEntrance.remainingAt(1 / 60), 0.01),
    );
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getSize(find.byKey(_box)).height, inExclusiveRange(44, 96));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(_box)).height, 44);
    expect(nearly, 1);
  });

  testWidgets('it says when it is about one line tall, once per send, and '
      'at once when there is nothing to close', (tester) async {
    var nearly = 0;
    await tester.pumpWidget(
      _harness(token: 0, contentHeight: 96, onNearlyClosed: () => nearly++),
    );
    // Typing and layout alone never report.
    await tester.pumpWidget(
      _harness(token: 0, contentHeight: 66, onNearlyClosed: () => nearly++),
    );
    await tester.pump();
    expect(nearly, 0);

    await tester.pumpWidget(
      _harness(token: 1, contentHeight: 44, onNearlyClosed: () => nearly++),
    );
    var frames = 0;
    while (nearly == 0 && frames < 60) {
      await tester.pump(const Duration(milliseconds: 16));
      frames++;
      if (nearly == 0) {
        // Not yet: still more than a sliver of a line too tall.
        expect(
          tester.getSize(find.byKey(_box)).height - 44,
          greaterThan(ComposerSendCollapse.nearlyClosedSlack),
        );
      }
    }
    expect(nearly, 1);
    // Reported well before the spring's last fraction of a point.
    expect(frames * 16, lessThan(ComposerSendCollapse.duration.inMilliseconds));
    await tester.pumpAndSettle();
    expect(nearly, 1);

    // A one-line composer has nothing to close: it reports straight away.
    await tester.pumpWidget(
      _harness(token: 2, contentHeight: 44, onNearlyClosed: () => nearly++),
    );
    await tester.pump();
    expect(nearly, 2);
    await tester.pumpAndSettle();
    expect(nearly, 2);
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

  testWidgets('Reduce Motion reports it is one line tall at once', (
    tester,
  ) async {
    var nearly = 0;
    Widget page(int token, double height) => _harness(
      token: token,
      contentHeight: height,
      disableAnimations: true,
      onNearlyClosed: () => nearly++,
    );
    await tester.pumpWidget(page(0, 96));
    await tester.pumpWidget(page(1, 44));
    await tester.pump();
    expect(nearly, 1);
  });
}
