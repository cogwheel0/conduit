import 'package:conduit/features/chat/widgets/chat_send_motion.dart';
import 'package:flutter/rendering.dart';
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

Widget _bubble() => SizedBox(
  key: _bubbleKey,
  width: 200,
  height: 40,
  child: CustomPaint(painter: _CountingPainter()),
);

double _paintedTop(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(_bubbleKey)).dy;

/// Counts the frames that actually painted the bubble.
int _bubblePaints = 0;

class _CountingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) => _bubblePaints++;

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// The bubble's painted opacity: the alpha of the entrance's opacity layer,
/// or 1 when it paints without one. Check [_bubblePaints] for "not painted".
double _paintedOpacity(WidgetTester tester) {
  final layers = tester.layers.whereType<OpacityLayer>().toList();
  if (layers.isEmpty) return 1;
  return (layers.last.alpha ?? 255) / 255;
}

void main() {
  setUp(() {
    _bubblePaints = 0;
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

  test('the spring keeps position and velocity continuous as it steps', () {
    // Stepping 10 ms ten times lands where one 100 ms step does.
    var state = (displacement: 600.0, velocity: 0.0);
    for (var i = 0; i < 10; i++) {
      state = ChatSendEntrance.step(
        displacement: state.displacement,
        velocity: state.velocity,
        dt: 0.01,
      );
    }
    final once = ChatSendEntrance.step(displacement: 600, velocity: 0, dt: 0.1);
    expect(state.displacement, closeTo(once.displacement, 1e-6));
    expect(state.velocity, closeTo(once.velocity, 1e-6));
    // Released at rest it matches the closed form and never overshoots.
    expect(
      once.displacement / 600,
      closeTo(ChatSendEntrance.remainingAt(0.1), 1e-9),
    );
    var s2 = (displacement: 600.0, velocity: 0.0);
    for (var i = 0; i < 100; i++) {
      s2 = ChatSendEntrance.step(
        displacement: s2.displacement,
        velocity: s2.velocity,
        dt: 0.016,
      );
      expect(s2.displacement, greaterThanOrEqualTo(0));
    }
  });

  testWidgets('a place that jumps mid-flight never makes the bubble jump', (
    tester,
  ) async {
    // One frame of travel, with or without the layout moving the bubble's
    // place 300 pt in that frame.
    Future<double> frameTravel(String id, {required double jump}) async {
      ChatSendOrigin.record(const Rect.fromLTWH(20, 700, 360, 44));
      var top = 0.0;
      late StateSetter rebuild;
      await tester.pumpWidget(
        _harness(
          StatefulBuilder(
            key: ValueKey(id),
            builder: (context, setState) {
              rebuild = setState;
              return Padding(
                padding: EdgeInsets.only(top: top),
                child: ChatSendEntrance(
                  messageId: id,
                  timestamp: DateTime.now(),
                  child: _bubble(),
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final before = _paintedTop(tester);
      rebuild(() => top = jump);
      await tester.pump(const Duration(milliseconds: 16));
      final travel = _paintedTop(tester) - before;
      await tester.pumpAndSettle();
      expect(_paintedTop(tester), closeTo(jump, 0.01));
      return travel;
    }

    final steady = await frameTravel('steady-turn', jump: 0);
    final settling = await frameTravel('settling-turn', jump: 300);
    // The spring's state is where the bubble is, not where its place was:
    // a 300 pt jump of the place changes this frame's travel by only the
    // spring's response to the new aim (about 11 pt), never by the jump.
    expect((settling - steady).abs(), lessThan(20));
  });

  testWidgets('the bubble is visible from its first frame', (tester) async {
    ChatSendOrigin.record(const Rect.fromLTWH(20, 700, 360, 44));
    await tester.pumpWidget(
      _harness(
        ChatSendEntrance(
          messageId: 'visible-at-once',
          timestamp: DateTime.now(),
          child: _bubble(),
        ),
      ),
    );
    // Painted in the very frame it mounts, already partly opaque.
    expect(_bubblePaints, greaterThan(0));
    expect(
      _paintedOpacity(tester),
      closeTo(ChatSendEntrance.initialOpacity, 0.01),
    );
    await tester.pumpAndSettle();
    expect(_paintedOpacity(tester), 1);
  });

  testWidgets('Reduce Motion fades the bubble in where it lands', (
    tester,
  ) async {
    ChatSendOrigin.record(const Rect.fromLTWH(20, 700, 360, 44));
    await tester.pumpWidget(
      _harness(
        ChatSendEntrance(
          messageId: 'reduced-fade',
          timestamp: DateTime.now(),
          child: _bubble(),
        ),
        disableAnimations: true,
      ),
    );
    expect(_paintedTop(tester), 0);
    // Fully transparent at first: not painted at all.
    expect(_bubblePaints, 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_bubblePaints, greaterThan(0));
    expect(_paintedTop(tester), 0);
    expect(_paintedOpacity(tester), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(_paintedOpacity(tester), 1);
    // The origin was this send's and is spent.
    expect(ChatSendOrigin.take(), isNull);
  });

  testWidgets('the greeting fades out as the first message arrives', (
    tester,
  ) async {
    var done = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChatGreetingExit(
          onDone: () => done++,
          child: const Text('Hello, Avery'),
        ),
      ),
    );
    double opacity() => tester
        .widget<FadeTransition>(
          find
              .ancestor(
                of: find.text('Hello, Avery'),
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity
        .value;
    expect(opacity(), 1);
    // Never takes touches meant for the transcript underneath.
    expect(
      find.ancestor(
        of: find.text('Hello, Avery'),
        matching: find.byWidgetPredicate(
          (widget) => widget is IgnorePointer && widget.ignoring,
        ),
      ),
      findsWidgets,
    );
    // The clock starts with the frame after the first one that shows it,
    // as the rising message's does, so a slow first frame spends neither.
    await tester.pump(const Duration(milliseconds: 300));
    expect(opacity(), 1);
    await tester.pump(const Duration(milliseconds: 90));
    expect(opacity(), inExclusiveRange(0, 1));
    await tester.pump(ChatGreetingExit.duration);
    await tester.pump();
    expect(opacity(), 0);
    expect(done, 1);
  });
}
