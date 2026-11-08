import 'package:conduit/features/chat/widgets/chat_send_motion.dart';
import 'package:conduit/features/chat/widgets/chat_timeline_viewport.dart';
import 'package:conduit_core/database/models/chat_transcript_window.dart';
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

const _flightText = ValueKey('flight-text');

/// A transcript of [historyCount] 52 pt rows in a 400 × 600 view, at its end
/// or scrolled to its top, whose [send] appends a user turn that leaves
/// from its typed words.
Future<
  ({
    ChatTimelineViewportController controller,
    Future<void> Function() send,
    double Function(String id, {bool bottom}) rowTop,
    Future<void> Function() dispose,
  })
>
_pumpTimeline(
  WidgetTester tester, {
  required int historyCount,
  String? anchorId,
  double lastReplyHeight = 52,
}) async {
  final scrolledUp = anchorId != null;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(400, 600);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final controller = ChatTimelineViewportController();
  final history = List<String>.generate(
    historyCount,
    (index) => 'history-$index',
  );
  var ids = history;
  String? pinned;
  late StateSetter rebuild;
  Widget row(BuildContext context, int index) {
    final id = ids[index];
    if (id == 'user') {
      return ChatSendEntrance(
        messageId: 'sent-into-chat',
        timestamp: DateTime.now(),
        flightBuilder: (context, morph) => const Align(
          alignment: Alignment.topRight,
          child: Text('Picnic plans', key: _flightText),
        ),
        child: _bubble(),
      );
    }
    return SizedBox(
      height: id == 'assistant'
          ? 72
          : id == 'history-${historyCount - 1}'
          ? lastReplyHeight
          : 52,
    );
  }

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return ChatTimelineViewport(
              controller: controller,
              ownerGeneration: 1,
              messageIds: ids,
              initialAnchor: scrolledUp
                  ? ChatScrollAnchor(
                      messageId: anchorId,
                      offsetWithinMessage: 0,
                      loadedCount: historyCount,
                    )
                  : null,
              pinnedUserMessageId: pinned,
              topContentInset: 32,
              bottomPadding: 80,
              horizontalPadding: 16,
              cacheExtent: 600,
              physics: const AlwaysScrollableScrollPhysics(),
              isLoadingOlder: false,
              maintainVisibleAnchor: false,
              followLatest: pinned == null && !scrolledUp,
              pinAutomatic: pinned != null,
              onPointerDown: () {},
              onUserDragStart: () {},
              onUserDragEnd: () {},
              onMetricsChanged: (_) {},
              onPinEndSpaceChanged: (_) {},
              onOldestThresholdReached: () {},
              onTrailingRefresh: () async {},
              onNativeScrollToTop: () async {},
              rowBuilder: row,
            );
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (
    controller: controller,
    send: () async {
      rebuild(() {
        ids = [...history, 'user', 'assistant'];
        pinned = 'user';
      });
      await tester.pump();
    },
    rowTop: (String id, {bool bottom = false}) {
      final rect = controller.rowRect(id)!;
      return bottom ? rect.bottom : rect.top;
    },
    dispose: () async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
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

  testWidgets('a text message leaves from the typed words, above the '
      'composer, and hands over to its row when it lands', (tester) async {
    const flightText = ValueKey('flight-text');
    final morphs = <double>[];
    Animation<double>? morph;
    ChatSendOrigin.record(const Rect.fromLTWH(20, 700, 360, 44));
    await tester.pumpWidget(
      _harness(
        ChatSendEntrance(
          messageId: 'sent-text',
          timestamp: DateTime.now(),
          flightBuilder: (context, animation) {
            morph = animation;
            return const Align(
              alignment: Alignment.topRight,
              child: Text('Picnic plans', key: flightText),
            );
          },
          child: _bubble(),
        ),
      ),
    );
    // First frame: the stand-in's words sit exactly where the typed words
    // were, fully drawn, and the row itself paints nothing yet.
    expect(find.byKey(flightText), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(flightText)), const Offset(20, 700));
    expect(_bubblePaints, 0);
    morphs.add(morph!.value);
    expect(morphs.single, 0);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // On its way up, its bubble growing out from the words.
    final midway = tester.getTopLeft(find.byKey(flightText));
    expect(midway.dy, inExclusiveRange(0, 700));
    expect(morph!.value, inExclusiveRange(0, 1));
    expect(_bubblePaints, 0);

    await tester.pumpAndSettle();
    // Landed: the stand-in is gone and the row shows itself in its place.
    expect(find.byKey(flightText), findsNothing);
    expect(_bubblePaints, greaterThan(0));
    expect(_paintedTop(tester), closeTo(0, 0.01));
    expect(ChatSendOrigin.take(), isNull);
  });

  testWidgets('without a send origin the row moves itself', (tester) async {
    const flightText = ValueKey('flight-text');
    await tester.pumpWidget(
      _harness(
        ChatSendEntrance(
          messageId: 'from-elsewhere',
          timestamp: DateTime.now(),
          flightBuilder: (context, animation) =>
              const Text('Picnic plans', key: flightText),
          child: _bubble(),
        ),
      ),
    );
    expect(find.byKey(flightText), findsNothing);
    expect(_bubblePaints, greaterThan(0));
    await tester.pumpAndSettle();
    expect(_paintedTop(tester), closeTo(0, 0.01));
  });

  testWidgets('the leaving greeting holds still while the page changes', (
    tester,
  ) async {
    Widget page(String greeting) => MaterialApp(
      home: ChatGreetingExit(onDone: () {}, child: Text(greeting)),
    );
    await tester.pumpWidget(page('Hello, Avery'));
    // A rebuild (a new composer height, the keyboard leaving) would place a
    // fresh greeting elsewhere; the leaving one stays as it was.
    await tester.pumpWidget(page('Hello again'));
    expect(find.text('Hello, Avery'), findsOneWidget);
    expect(find.text('Hello again'), findsNothing);
    // Quick and front-loaded: nearly gone by the time a rising message
    // could reach its line.
    expect(
      ChatGreetingExit.duration,
      lessThanOrEqualTo(const Duration(milliseconds: 150)),
    );
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

  testWidgets('a message sent into a chat rides up with its turn, closing '
      'the gap to its row and never crossing the reply above', (tester) async {
    final timeline = await _pumpTimeline(tester, historyCount: 12);
    // Sent from the composer's field, just under the end of the reply.
    ChatSendOrigin.record(const Rect.fromLTWH(24, 540, 352, 24));
    await timeline.send();
    final arrival = timeline.controller.springMessageToTop(
      'user',
      spring: ChatSendEntrance.spring,
    );
    final gaps = <double>[];
    for (var frame = 0; frame < 40; frame += 1) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byKey(_flightText).evaluate().isEmpty) break;
      final message = tester.getTopLeft(find.byKey(_flightText)).dy;
      // It never rises into the reply above its row.
      expect(
        message,
        greaterThanOrEqualTo(timeline.rowTop('history-11', bottom: true) - 0.5),
      );
      gaps.add(message - timeline.rowTop('user'));
    }
    expect(gaps.length, greaterThan(10));
    // The gap to its row only ever closes: the message moves with the
    // transcript instead of trailing behind it.
    for (var index = 1; index < gaps.length; index += 1) {
      expect(gaps[index], lessThanOrEqualTo(gaps[index - 1] + 0.5));
    }
    expect(await arrival, isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(_flightText), findsNothing);
    expect(_paintedTop(tester), closeTo(32, 0.5));
    await timeline.dispose();
  });

  testWidgets('under a reply that runs on below the composer, the words '
      'stay in view from the send and wait for their row', (tester) async {
    // The reply's top is in view and its end is 430 pt below the screen:
    // the new row is laid out there, in the scroll cache, but not painted.
    final timeline = await _pumpTimeline(
      tester,
      historyCount: 4,
      anchorId: 'history-3',
      lastReplyHeight: 1000,
    );
    ChatSendOrigin.record(const Rect.fromLTWH(24, 540, 352, 24));
    await timeline.send();
    // Its row is still below the screen, so the stand-in counts as off
    // stage for finders; it is painted all the same.
    final flight = find.byKey(_flightText, skipOffstage: false);
    // The frame of the send already shows the words where they were typed.
    expect(flight, findsOneWidget);
    expect(tester.getTopLeft(flight).dy, closeTo(540, 0.5));
    expect(timeline.rowTop('user'), greaterThan(600));
    final writtenAt = tester.getTopLeft(flight).dx;

    final arrival = timeline.controller.springMessageToTop(
      'user',
      spring: ChatSendEntrance.spring,
    );
    for (var frame = 0; frame < 60; frame += 1) {
      await tester.pump(const Duration(milliseconds: 16));
      if (flight.evaluate().isEmpty) break;
      final message = tester.getTopLeft(flight).dy;
      final row = timeline.rowTop('user');
      expect(message, greaterThanOrEqualTo((row < 540 ? row : 540) - 0.5));
      expect(message, lessThanOrEqualTo(540.5));
      // Waiting for its row, it waits as a whole: it never slides along
      // the composer towards its buttons.
      if (message > 539.5) {
        expect(tester.getTopLeft(flight).dx, closeTo(writtenAt, 0.5));
      }
    }
    expect(await arrival, isTrue);
    await tester.pumpAndSettle();
    expect(flight, findsNothing);
    expect(_paintedTop(tester), closeTo(32, 0.5));
    await timeline.dispose();
  });

  testWidgets('sent from far up the history, the message waits where it was '
      'written until its row comes up to carry it', (tester) async {
    final timeline = await _pumpTimeline(
      tester,
      historyCount: 60,
      anchorId: 'history-0',
    );
    ChatSendOrigin.record(const Rect.fromLTWH(24, 540, 352, 24));
    await timeline.send();
    final arrival = timeline.controller.springMessageToTop(
      'user',
      spring: ChatSendEntrance.spring,
    );
    var flew = 0;
    for (var frame = 0; frame < 90; frame += 1) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byKey(_flightText).evaluate().isEmpty) continue;
      flew += 1;
      final message = tester.getTopLeft(find.byKey(_flightText)).dy;
      // It holds where it was written until its row comes up to it, and
      // from then on is never above the row: nothing it passes is crossed.
      final row = timeline.rowTop('user');
      expect(message, greaterThanOrEqualTo((row < 540 ? row : 540) - 0.5));
      expect(message, lessThanOrEqualTo(540.5));
    }
    expect(flew, greaterThan(3));
    expect(await arrival, isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(_flightText), findsNothing);
    expect(_paintedTop(tester), closeTo(32, 0.5));
    await timeline.dispose();
  });

  testWidgets('the flying words start on the typed text\'s last line of '
      'letters, so a narrower wrap grows upwards', (tester) async {
    const flightText = ValueKey('flight-text');
    // The field's last line of letters ends at y = 744.
    ChatSendOrigin.record(
      const Rect.fromLTWH(20, 700, 360, 44),
      line: (y: 744, last: true),
    );
    await tester.pumpWidget(
      _harness(
        ChatSendEntrance(
          messageId: 'last-line',
          timestamp: DateTime.now(),
          flightBuilder: (context, morph) => const Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              width: 120,
              child: Text('Picnic plans for Saturday', key: flightText),
            ),
          ),
          child: _bubble(),
        ),
      ),
    );
    final paragraph = tester.renderObject<RenderBox>(find.byKey(flightText));
    final glyphs = chatTextLineExtent(paragraph, last: true)!;
    final top = tester.getTopLeft(find.byKey(flightText));
    // Its last line sits on the field's last line; its leading edge on the
    // field's; its extra lines are above, never below over the buttons.
    expect(top.dy + glyphs.bottom, closeTo(744, 0.5));
    expect(top.dx, closeTo(20, 0.5));
    expect(top.dy, lessThan(744 - 14));
    await tester.pumpAndSettle();
  });

  testWidgets('the composer hears that the words have left once they have '
      'risen above its top edge, before they land', (tester) async {
    var departed = 0;
    final departure = ChatSendDeparture(() => departed++);
    ChatSendOrigin.record(
      const Rect.fromLTWH(20, 700, 360, 44),
      clearanceTop: 680,
      departure: departure,
    );
    await tester.pumpWidget(
      _harness(
        ChatSendEntrance(
          messageId: 'leaves-composer',
          timestamp: DateTime.now(),
          flightBuilder: (context, morph) => const Align(
            alignment: Alignment.topRight,
            child: Text('Picnic plans', key: _flightText),
          ),
          child: _bubble(),
        ),
      ),
    );
    // Still inside the composer: it keeps its shape.
    await tester.pump();
    expect(departed, 0);
    var frames = 0;
    while (departed == 0 && frames < 30) {
      await tester.pump(const Duration(milliseconds: 16));
      frames++;
    }
    expect(departed, 1);
    // Told while still on the way, not on landing.
    expect(find.byKey(_flightText), findsOneWidget);
    expect(
      tester.getBottomLeft(find.byKey(_flightText)).dy,
      lessThanOrEqualTo(680.5),
    );
    await tester.pumpAndSettle();
    expect(departed, 1);
  });

  testWidgets('a row that rises by itself, or a send that cannot fly, lets '
      'the composer close up at once', (tester) async {
    var departed = 0;
    ChatSendOrigin.record(
      const Rect.fromLTWH(20, 700, 360, 44),
      clearanceTop: 680,
      departure: ChatSendDeparture(() => departed++),
    );
    await tester.pumpWidget(
      _harness(
        ChatSendEntrance(
          messageId: 'rises-in-transcript',
          timestamp: DateTime.now(),
          child: _bubble(),
        ),
      ),
    );
    await tester.pump();
    expect(departed, 1);
    await tester.pumpAndSettle();

    // A newer send replacing one that never left lets the first go.
    var first = 0;
    ChatSendOrigin.record(
      const Rect.fromLTWH(20, 700, 360, 44),
      departure: ChatSendDeparture(() => first++),
    );
    ChatSendOrigin.record(const Rect.fromLTWH(20, 700, 360, 44));
    expect(first, 1);
  });

  testWidgets('obsolete content gives up its room at once and fades out', (
    tester,
  ) async {
    const leaving = ValueKey('leaving');
    var taps = 0;
    Widget page({required bool show}) => MaterialApp(
      home: Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ChatLeavingContent(
              child: show
                  ? GestureDetector(
                      onTap: () => taps++,
                      child: const SizedBox(
                        key: leaving,
                        width: 200,
                        height: 120,
                      ),
                    )
                  : null,
            ),
            const SizedBox(key: ValueKey('below'), height: 40, width: 40),
          ],
        ),
      ),
    );
    double opacity() => tester
        .widget<FadeTransition>(
          find
              .ancestor(
                of: find.byKey(leaving),
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity
        .value;

    await tester.pumpWidget(page(show: true));
    expect(tester.getTopLeft(find.byKey(const ValueKey('below'))).dy, 120);
    expect(opacity(), 1);

    await tester.pumpWidget(page(show: false));
    // Layout moves on in the same frame; the content is still drawn.
    expect(tester.getTopLeft(find.byKey(const ValueKey('below'))).dy, 0);
    expect(find.byKey(leaving), findsOneWidget);
    // Front-loaded: mostly gone within the first two frames, before a
    // message rising from the composer can reach its lines.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(opacity(), inExclusiveRange(0, 0.5));
    // A leaving suggestion is not a target any more.
    await tester.tapAt(const Offset(100, 100));
    expect(taps, 0);
    await tester.pumpAndSettle();
    expect(find.byKey(leaving), findsNothing);
  });
}
