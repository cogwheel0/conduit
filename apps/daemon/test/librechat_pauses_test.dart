@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/features/librechat/models/librechat_tools.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:conduitd/src/librechat_pauses.dart';
import 'package:test/test.dart';

/// What a LibreChat run paused on, put to a window and answered.
void main() {
  late _Bus events;
  late UiRequestsService windows;
  late List<UiRequest> asked;
  late StreamController<UiRequest> cards;

  setUp(() {
    events = _Bus();
    windows = UiRequestsService(events);
    asked = <UiRequest>[];
    cards = StreamController<UiRequest>.broadcast();
    addTearDown(cards.close);
    events.attach('w1', (envelope) {
      if (envelope.event != ConduitEvents.uiRequest) return;
      final request = UiRequest.fromJson(envelope.payload);
      asked.add(request);
      cards.add(request);
    });
  });

  /// The next card the window is shown.
  Future<UiRequest> nextCard() => cards.stream.first;

  test('a dismissed question stops only the turn that asked', () async {
    var asking = true;
    var stops = 0;
    final card = nextCard();
    final outcome = answerLibreChatPause(
      _question,
      windows: windows,
      chatId: 'chat-1',
      asking: () => asking,
      resume: ({decisions, answers}) async {},
      stop: () async => stops++,
    );
    final request = await card;
    // The reply was stopped and another one runs in the chat when the old
    // card is dismissed.
    asking = false;
    windows.respond(
      UiResponse(requestId: request.requestId, choice: 'cancel'),
    );
    expect(await outcome, LibreChatPauseOutcome.left);
    expect(stops, 0, reason: 'the newer reply was stopped');

    // The card goes once its turn ends, and stops nothing.
    final ended = Completer<void>();
    final second = nextCard();
    final withdrawn = answerLibreChatPause(
      _question,
      windows: windows,
      chatId: 'chat-1',
      asking: () => !ended.isCompleted,
      until: ended.future,
      resume: ({decisions, answers}) async {},
      stop: () async => stops++,
    );
    await second;
    ended.complete();
    expect(await withdrawn, LibreChatPauseOutcome.left);
    expect(stops, 0);
  });

  test('a resume that fails puts the card back, to be answered again', () async {
    var resumes = 0;
    final sent = <Map<String, String>?>[];
    var card = nextCard();
    final outcome = answerLibreChatPause(
      _question,
      windows: windows,
      chatId: 'chat-1',
      asking: () => true,
      resume: ({decisions, answers}) async {
        sent.add(answers);
        if (++resumes == 1) throw StateError('the server could not be reached');
      },
      stop: () async => fail('nothing was to stop'),
    );
    final first = await card;
    card = nextCard();
    windows.respond(
      UiResponse(requestId: first.requestId, choice: 'allow', text: 'Ridge'),
    );
    // The resume fails: the card comes back, or the pause is given up.
    final again = await Future.any<UiRequest?>([
      card,
      outcome.then((_) => null),
    ]);
    expect(again, isNotNull, reason: 'the card was not put back');
    windows.respond(
      UiResponse(requestId: again!.requestId, choice: 'allow', text: 'Lake'),
    );
    expect(await outcome, LibreChatPauseOutcome.resumed);
    expect(sent, [
      {'call-1': 'Ridge'},
      {'call-1': 'Lake'},
    ]);

    // Reject or respond only, and reject only: the first refusal goes out
    // without a card, as the pause allows. When it fails, nothing more is
    // sent until the window answers; each failure puts the card back once.
    for (final allowed in const [
      ['reject', 'respond'],
      ['reject'],
    ]) {
      var refusals = 0;
      var next = nextCard();
      final refusing = answerLibreChatPause(
        _toolCall(allowed),
        windows: windows,
        chatId: 'chat-1',
        asking: () => true,
        resume: ({decisions, answers}) async {
          // Fails twice, then goes through (so a runaway loop ends too).
          if (++refusals <= 2) {
            throw StateError('the server could not be reached');
          }
        },
        stop: () async => fail('nothing was to stop'),
      );
      for (final sentSoFar in [1, 2]) {
        final card = await Future.any<UiRequest?>([
          next,
          refusing.then((_) => null),
        ]);
        expect(card, isNotNull, reason: '$allowed: refused with nobody asked');
        expect(refusals, sentSoFar, reason: '$allowed: sent again unasked');
        next = nextCard();
        windows.respond(UiResponse(requestId: card!.requestId, choice: 'deny'));
      }
      expect(await refusing, LibreChatPauseOutcome.resumed);
      expect(refusals, 3);
      next.ignore(); // Sent: no further card comes.
    }

    // With no window to answer, a failed resume is given up at once (the
    // turn offers the pause again later), not tried over and over.
    var tries = 0;
    final alone = await answerLibreChatPause(
      _toolCall(const ['approve', 'reject']),
      windows: UiRequestsService(EventBus()),
      chatId: 'chat-1',
      asking: () => true,
      resume: ({decisions, answers}) async {
        tries++;
        throw StateError('the server could not be reached');
      },
      stop: () async => fail('nothing was to stop'),
    );
    expect(alone, LibreChatPauseOutcome.failed);
    expect(tries, 1);
  });

  test('a failed resume with no window waits for one, and puts the card to it', () async {
    var resumes = 0;
    final sent = <Map<String, String>?>[];
    final ended = Completer<void>();
    addTearDown(() {
      if (!ended.isCompleted) ended.complete();
    });
    var card = nextCard();
    final outcome = answerLibreChatPause(
      _question,
      windows: windows,
      chatId: 'chat-1',
      asking: () => !ended.isCompleted,
      until: ended.future,
      resume: ({decisions, answers}) async {
        sent.add(answers);
        if (++resumes == 1) {
          // The window goes away (a reconnect) as the send fails.
          events.detach('w1');
          throw StateError('the server could not be reached');
        }
      },
      stop: () async => fail('nothing was to stop'),
    );
    final first = await card;
    card = nextCard();
    windows.respond(
      UiResponse(requestId: first.requestId, choice: 'allow', text: 'Ridge'),
    );
    // The resume fails with nobody to ask: the pause waits for a window,
    // still pending. The window comes back: the pause is put to it, rather
    // than left with no card to answer.
    await events.waiting;
    expect(await _settledYet(outcome), isFalse, reason: 'the pause gave up');
    events.attach('w2', (envelope) {
      if (envelope.event != ConduitEvents.uiRequest) return;
      cards.add(UiRequest.fromJson(envelope.payload));
    });
    final again = await Future.any<UiRequest?>([
      card,
      outcome.then((_) => null),
    ]);
    expect(again, isNotNull, reason: 'the pause was given up');
    windows.respond(
      UiResponse(requestId: again!.requestId, choice: 'allow', text: 'Lake'),
    );
    expect(await outcome, LibreChatPauseOutcome.resumed);
    expect(sent, [
      {'call-1': 'Ridge'},
      {'call-1': 'Lake'},
    ]);

    // The turn ends while no window is there: the wait ends with it, and
    // leaves nothing waiting for a window.
    events
      ..detach('w2')
      ..rearm();
    final over = Completer<void>();
    var tries = 0;
    final waiting = answerLibreChatPause(
      _toolCall(const ['approve', 'reject']),
      windows: windows,
      chatId: 'chat-1',
      asking: () => !over.isCompleted,
      until: over.future,
      resume: ({decisions, answers}) async {
        tries++;
        throw StateError('the server could not be reached');
      },
      stop: () async => fail('nothing was to stop'),
    );
    await events.waiting;
    expect(tries, 1);
    expect(await _settledYet(waiting), isFalse, reason: 'it did not wait');
    over.complete();
    expect(await waiting, LibreChatPauseOutcome.failed);
    expect(tries, 1);
    expect(events.attachWaiters, 0, reason: 'a wait was left behind');
  });

  test('a card no window answered after a failed resume refuses nothing', () async {
    final sent = <Map<String, LibreChatToolDecisionInput>?>[];
    final ended = Completer<void>();
    addTearDown(() {
      if (!ended.isCompleted) ended.complete();
    });
    var card = nextCard();
    final outcome = answerLibreChatPause(
      _toolCall(const ['approve', 'reject']),
      windows: windows,
      chatId: 'chat-1',
      asking: () => !ended.isCompleted,
      until: ended.future,
      resume: ({decisions, answers}) async {
        sent.add(decisions);
        if (sent.length == 1) {
          throw StateError('the server could not be reached');
        }
      },
      stop: () async => fail('nothing was to stop'),
    );
    final first = await card;
    card = nextCard();
    windows.respond(UiResponse(requestId: first.requestId, choice: 'allow'));
    // The send fails; the card is put back, and the window goes away (a
    // reconnect) before answering it: it settles with its default.
    await card;
    events.rearm();
    card = nextCard();
    events.detach('w1');
    windows.onWindowsChanged();
    await Future.any<Object?>([events.waiting, outcome]);
    expect(sent, hasLength(1), reason: 'a refusal went out nobody gave');
    expect(await _settledYet(outcome), isFalse, reason: 'the pause gave up');

    // A window comes back: the card is put to it, and its answer is sent.
    events.attach('w2', (envelope) {
      if (envelope.event != ConduitEvents.uiRequest) return;
      cards.add(UiRequest.fromJson(envelope.payload));
    });
    final again = await card;
    windows.respond(UiResponse(requestId: again.requestId, choice: 'allow'));
    expect(await outcome, LibreChatPauseOutcome.resumed);
    expect(sent.map((d) => d?['call-2']?.decision), [
      LibreChatToolDecision.approve,
      LibreChatToolDecision.approve,
    ]);
  });

  test('a tool call is refused only where the pause allows refusing', () async {
    // Approve only: the window says no, and no `reject` goes out; the
    // reply stops instead.
    final sent = <Map<String, LibreChatToolDecisionInput>?>[];
    var stops = 0;
    final card = nextCard();
    final approveOnly = answerLibreChatPause(
      _toolCall(const ['approve']),
      windows: windows,
      chatId: 'chat-1',
      asking: () => true,
      resume: ({decisions, answers}) async => sent.add(decisions),
      stop: () async => stops++,
    );
    final request = await card;
    windows.respond(UiResponse(requestId: request.requestId, choice: 'deny'));
    expect(await approveOnly, LibreChatPauseOutcome.stopped);
    // A reply to write (respond only): no card here can answer it.
    final respondOnly = await answerLibreChatPause(
      _toolCall(const ['respond']),
      windows: windows,
      chatId: 'chat-1',
      asking: () => true,
      resume: ({decisions, answers}) async => sent.add(decisions),
      stop: () async => stops++,
    );
    expect(respondOnly, LibreChatPauseOutcome.stopped);
    expect(sent, isEmpty, reason: 'a decision the pause does not allow went out');
    expect(stops, 2);
  });

  test('a pause with nothing to ask ends once, never sent over and over', () async {
    // The fake gives up failing after a few sends, so a loop ends (and
    // fails the test) rather than hanging it.
    var sends = 0;
    Future<void> failing({decisions, answers}) async {
      if (++sends <= 3) throw ArgumentError('nothing to answer');
    }

    // A question action with no questions: the reply stops, as when a
    // question goes unanswered; nothing is sent.
    var stops = 0;
    final empty = await answerLibreChatPause(
      const LibreChatPendingAction(<String, dynamic>{
        'actionId': 'act-3',
        'payload': <String, dynamic>{'type': 'ask_user_question'},
      }),
      windows: windows,
      chatId: 'chat-1',
      asking: () => true,
      resume: failing,
      stop: () async => stops++,
    );
    expect(empty, LibreChatPauseOutcome.stopped);
    expect((sends, stops), (0, 1));

    // A failed send with no card put to anyone is not tried again on its
    // own: only a window's answer sends again.
    final nothingAsked = await answerLibreChatPause(
      const LibreChatPendingAction(<String, dynamic>{
        'actionId': 'act-4',
        'payload': <String, dynamic>{'type': 'tool_approval'},
      }),
      windows: windows,
      chatId: 'chat-1',
      asking: () => true,
      resume: failing,
      stop: () async => fail('nothing was to stop'),
    );
    expect(nothingAsked, LibreChatPauseOutcome.failed);
    expect(sends, 1, reason: 'sent over and over with nobody asked');
    expect(asked, isEmpty);
  });

  test('a card that cannot be put up ends the reply once, never spinning', () async {
    // Each round checks the turn; a loop that never waits runs out of
    // checks and ends (failing the test) rather than hanging it.
    var checks = 0;
    bool asking() => ++checks < 50;

    // Arguments that decode but cannot be pretty-printed (an infinite
    // number): the card shows them as sent, and the answer goes out.
    var sends = 0;
    final card = nextCard();
    final infinite = answerLibreChatPause(
      _toolCall(const ['approve', 'reject'], arguments: '{"limit":1e999}'),
      windows: windows,
      chatId: 'chat-1',
      asking: asking,
      resume: ({decisions, answers}) async => sends++,
      stop: () async => fail('nothing was to stop'),
    );
    final shown = await Future.any<UiRequest?>([
      card,
      infinite.then((_) => null),
    ]);
    expect(shown, isNotNull, reason: 'no card for arguments it could not format');
    expect(shown!.detail['arguments'], '{"limit":1e999}');
    windows.respond(UiResponse(requestId: shown.requestId, choice: 'allow'));
    expect(await infinite, LibreChatPauseOutcome.resumed);
    expect(sends, 1);

    // Anything else that throws before a card is up ends the reply once,
    // and is not tried again.
    checks = 0;
    var stops = 0;
    final broken = await answerLibreChatPause(
      LibreChatPendingAction(<String, dynamic>{
        'actionId': 'act-5',
        'payload': <String, dynamic>{
          'type': 'ask_user_question',
          'tool_call_id': 'call-5',
          'question': <String, dynamic>{
            'question': 'Which trail?',
            'options': [
              {'label': _Unreadable()},
            ],
          },
        },
      }),
      windows: windows,
      chatId: 'chat-1',
      asking: asking,
      resume: ({decisions, answers}) async => sends++,
      stop: () async => stops++,
    );
    expect(broken, LibreChatPauseOutcome.stopped);
    expect(stops, 1);
    expect(checks, lessThan(5), reason: 'tried over and over with no card up');
    expect(sends, 1, reason: 'something went out for a card never shown');
  });
}

/// The event bus, telling the test when a pause starts waiting for a
/// window to attach, and how many such waits are left.
final class _Bus extends EventBus {
  Completer<void> _waiting = Completer<void>();
  int attachWaiters = 0;

  /// Completes once a pause waits for a window (since the last [rearm]).
  Future<void> get waiting => _waiting.future;

  void rearm() => _waiting = Completer<void>();

  @override
  Future<bool> attachBefore(Future<void> until) {
    attachWaiters++;
    final wait = super.attachBefore(until);
    if (!_waiting.isCompleted) _waiting.complete();
    return wait.whenComplete(() => attachWaiters--);
  }
}

/// Whether [future] has completed once everything already queued has run.
Future<bool> _settledYet(Future<Object?> future) async {
  var settled = false;
  unawaited(future.then((_) => settled = true));
  await pumpEventQueue();
  return settled;
}

/// A value whose text cannot be read (any throw before a card is up).
final class _Unreadable {
  @override
  String toString() => throw StateError('unreadable');
}

/// A run paused on one question.
const _question = LibreChatPendingAction(<String, dynamic>{
  'actionId': 'act-1',
  'payload': <String, dynamic>{
    'type': 'ask_user_question',
    'tool_call_id': 'call-1',
    'question': <String, dynamic>{
      'question': 'Which trail?',
      'options': <Map<String, dynamic>>[
        {'label': 'Ridge'},
        {'label': 'Lake'},
      ],
    },
  },
});

/// A run paused on one tool call, allowing [allowed].
LibreChatPendingAction _toolCall(
  List<String> allowed, {
  String arguments = '{}',
}) => LibreChatPendingAction(<String, dynamic>{
      'actionId': 'act-2',
      'payload': <String, dynamic>{
        'type': 'tool_approval',
        'action_requests': <Map<String, dynamic>>[
          {
            'tool_call_id': 'call-2',
            'name': 'trail_map',
            'arguments': arguments,
          },
        ],
        'review_configs': <Map<String, dynamic>>[
          {'tool_call_id': 'call-2', 'allowed_decisions': allowed},
        ],
      },
    });
