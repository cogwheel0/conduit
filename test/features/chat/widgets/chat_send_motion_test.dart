import 'package:conduit/features/chat/widgets/chat_send_motion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _harness(Widget child, {bool disableAnimations = false}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(400, 800),
        disableAnimations: disableAnimations,
      ),
      child: Scaffold(
        body: Align(alignment: Alignment.topCenter, child: child),
      ),
    ),
  );
}

const _bubbleKey = ValueKey('bubble');

Widget _bubble() => const SizedBox(key: _bubbleKey, width: 200, height: 40);

double _paintedTop(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(_bubbleKey)).dy;

void main() {
  setUp(() {
    debugResetChatSendEntrances();
    ChatSendOrigin.debugReset();
  });

  test('a critically damped spring never overshoots and settles', () {
    var previous = ChatSendEntrance.remainingAt(0);
    expect(previous, 1);
    for (var ms = 10; ms <= 560; ms += 10) {
      final value = ChatSendEntrance.remainingAt(ms / 1000);
      expect(value, inInclusiveRange(0, previous));
      previous = value;
    }
    // Under half a pixel left of a full-screen (800 pt) travel.
    expect(ChatSendEntrance.remainingAt(0.56) * 800, lessThan(0.5));
  });

  test('send origins expire', () {
    final at = DateTime(2026, 11, 8, 12);
    ChatSendOrigin.record(const Rect.fromLTWH(0, 700, 300, 40));
    expect(
      ChatSendOrigin.take(now: DateTime.now().add(const Duration(seconds: 5))),
      isNull,
    );
    ChatSendOrigin.record(const Rect.fromLTWH(0, 700, 300, 40));
    expect(ChatSendOrigin.take(), isNotNull);
    // Taken once.
    expect(ChatSendOrigin.take(), isNull);
    expect(
      isFreshChatContent(at, now: at.add(const Duration(seconds: 2))),
      isTrue,
    );
    expect(
      isFreshChatContent(at, now: at.add(const Duration(seconds: 4))),
      isFalse,
    );
  });

  testWidgets('a just-sent bubble rises from the composer into place', (
    tester,
  ) async {
    ChatSendOrigin.record(const Rect.fromLTWH(20, 700, 360, 44));
    await tester.pumpWidget(
      _harness(
        ChatSendEntrance(
          messageId: 'sent',
          timestamp: DateTime.now(),
          child: _bubble(),
        ),
      ),
    );
    // First frame: painted where the composer's text was (bottom-aligned).
    expect(_paintedTop(tester), closeTo(700 + 44 - 40, 1));

    // The clock starts with the first frame that shows the bubble.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final midway = _paintedTop(tester);
    expect(midway, lessThan(704));
    expect(midway, greaterThan(0));

    await tester.pumpAndSettle();
    expect(_paintedTop(tester), closeTo(0, 0.01));
  });

  testWidgets('never replays when the same message mounts again', (
    tester,
  ) async {
    final timestamp = DateTime.now();
    ChatSendOrigin.record(const Rect.fromLTWH(20, 700, 360, 44));
    await tester.pumpWidget(
      _harness(
        ChatSendEntrance(
          key: const ValueKey('first'),
          messageId: 'once',
          timestamp: timestamp,
          child: _bubble(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    ChatSendOrigin.record(const Rect.fromLTWH(20, 700, 360, 44));
    await tester.pumpWidget(
      _harness(
        ChatSendEntrance(
          key: const ValueKey('second'),
          messageId: 'once',
          timestamp: timestamp,
          child: _bubble(),
        ),
      ),
    );
    expect(_paintedTop(tester), 0);
  });

  testWidgets(
    'a bubble first mounted under the settle cover still enters when shown',
    (tester) async {
      final timestamp = DateTime.now();
      ChatSendOrigin.record(const Rect.fromLTWH(20, 700, 360, 44));
      // The timeline hides a new turn while its position settles, and may
      // replace the row before it is ever painted.
      await tester.pumpWidget(
        _harness(
          Opacity(
            opacity: 0,
            child: ChatSendEntrance(
              key: const ValueKey('hidden'),
              messageId: 'settling',
              timestamp: timestamp,
              child: _bubble(),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      await tester.pumpWidget(
        _harness(
          Opacity(
            opacity: 1,
            child: ChatSendEntrance(
              key: const ValueKey('shown'),
              messageId: 'settling',
              timestamp: timestamp,
              child: _bubble(),
            ),
          ),
        ),
      );
      // Starts at the composer, not in place.
      expect(_paintedTop(tester), closeTo(704, 1));
      await tester.pumpAndSettle();
      expect(_paintedTop(tester), closeTo(0, 0.01));
    },
  );

  testWidgets('history and Reduce Motion appear in place', (tester) async {
    ChatSendOrigin.record(const Rect.fromLTWH(20, 700, 360, 44));
    await tester.pumpWidget(
      _harness(
        ChatSendEntrance(
          messageId: 'old',
          timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
          child: _bubble(),
        ),
      ),
    );
    expect(_paintedTop(tester), 0);

    await tester.pumpWidget(
      _harness(
        ChatSendEntrance(
          messageId: 'reduced',
          timestamp: DateTime.now(),
          child: _bubble(),
        ),
        disableAnimations: true,
      ),
    );
    expect(_paintedTop(tester), 0);
  });
}
