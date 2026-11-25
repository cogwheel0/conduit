@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/features/librechat/models/librechat_tools.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduit_services/conduit_services.dart';
import 'package:conduit_services/src/librechat_pauses.dart';
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

  /// Waits on [action] in chat-1 until [ended] completes, recording what
  /// it resumes with.
  ({
    Future<LibreChatPauseOutcome> outcome,
    List<Map<String, LibreChatToolDecisionInput>?> decisions,
    List<Map<String, String>?> answers,
  })
  pause(
    LibreChatPendingAction action, {
    Completer<void>? ended,
    Object? Function()? failWith,
  }) {
    final over = ended ?? Completer<void>();
    addTearDown(() {
      if (!over.isCompleted) over.complete();
    });
    final sent = <Map<String, LibreChatToolDecisionInput>?>[];
    final sentAnswers = <Map<String, String>?>[];
    final outcome = answerLibreChatPause(
      action,
      windows: windows,
      chatId: 'chat-1',
      asking: () => !over.isCompleted,
      until: over.future,
      resume: ({decisions, answers}) async {
        sent.add(decisions);
        sentAnswers.add(answers);
        final failure = failWith?.call();
        if (failure != null) throw failure;
      },
    );
    return (outcome: outcome, decisions: sent, answers: sentAnswers);
  }

  void answer(UiRequest card, String choice, [String? text]) => expect(
    windows.respond(
      UiResponse(requestId: card.requestId, choice: choice, text: text),
    ),
    isTrue,
  );

  test("a question is answered with its options' values, never their "
      "labels: by label (as the phone answers), or by place (as the Mac does: "
      "a padded label, several picked, two labels alike)", () async {
    // Whether the pause went on with the answer, or put the card again.
    Future<String> after(Future<LibreChatPauseOutcome> outcome) {
      final again = nextCard();
      return Future.any([
        outcome.then((_) => 'resumed'),
        again.then((card) => 'again: ${card.detail['refusal']}'),
      ]);
    }

    final card = nextCard();
    final (:outcome, :decisions, :answers) = pause(_valued);
    final request = await card;
    expect(request.kind, UiRequestKind.libreChatQuestion);
    expect(request.detail['options'], [
      {'label': 'North Ridge', 'value': 'north-ridge'},
      {'label': 'Lake Loop', 'value': 'lake-loop'},
    ]);
    // The window answers with the label it showed.
    answer(request, 'answer', 'North Ridge');
    expect(await outcome, LibreChatPauseOutcome.resumed);
    expect(answers, [
      {'call-v': 'north-ridge'},
    ]);

    for (final (multi, picks, sent) in [
      (false, '[0]', 'north-ridge'),
      (true, '[0, 1]', 'north-ridge, lake-loop'),
      (false, '[3]', 'ridge-south'),
    ]) {
      final card = nextCard();
      final (:outcome, :decisions, :answers) = pause(_placed(multi: multi));
      final shown = await card;
      expect(shown.detail['options'], hasLength(4));
      answer(shown, 'options', picks);
      expect(await after(outcome), 'resumed', reason: picks);
      expect(answers, [
        {'call-p': sent},
      ], reason: picks);
    }

    // A place no option has is not taken: the card comes back.
    final placed = nextCard();
    final unknown = pause(_placed(multi: false));
    answer(await placed, 'options', '[9]');
    expect(await after(unknown.outcome), 'again: empty');
    expect(unknown.answers, isEmpty);
  });

  test(
    'a tool call offers every decision its server allows, and only those',
    () async {
      var card = nextCard();
      final (:outcome, :decisions, :answers) = pause(
        _toolCall(const ['respond', 'reject'], arguments: '{"trail": "ridge"}'),
      );
      final first = await card;
      expect(first.kind, UiRequestKind.libreChatToolCall);
      expect(first.messageArgs['chatId'], 'chat-1');
      expect(first.detail['allowedDecisions'], ['respond', 'reject']);
      expect(first.detail['arguments'], '{"trail": "ridge"}');

      // Approve is not one of them: the card comes back saying so.
      card = nextCard();
      answer(first, 'approve');
      final refused = await card;
      expect(refused.detail['refusal'], 'notAllowed');
      // Nor is an empty response taken.
      card = nextCard();
      answer(refused, 'respond', '   ');
      final empty = await card;
      expect(empty.detail['refusal'], 'empty');
      expect(decisions, isEmpty);

      answer(empty, 'respond', ' Closed for the season. ');
      expect(await outcome, LibreChatPauseOutcome.resumed);
      final decided = decisions.single!['call-2']!;
      expect(decided.decision, LibreChatToolDecision.respond);
      expect(decided.responseText, 'Closed for the season.');
    },
  );

  test('an edit that is not a JSON object comes back with the reason and '
      'what was typed; an object runs the call with it', () async {
    var card = nextCard();
    final (:outcome, :decisions, :answers) = pause(
      _toolCall(const ['approve', 'edit'], arguments: '{"trail": "ridge"}'),
    );
    final first = await card;
    expect(first.detail['editableArguments'], '{\n  "trail": "ridge"\n}');
    card = nextCard();
    answer(first, 'edit', '["lake"]');
    final again = await card;
    expect(again.detail['refusal'], 'invalidArguments');
    expect(again.detail['typed'], '["lake"]');
    expect(decisions, isEmpty);

    answer(again, 'edit', '{"trail": "lake"}');
    expect(await outcome, LibreChatPauseOutcome.resumed);
    final decided = decisions.single!['call-2']!;
    expect(decided.decision, LibreChatToolDecision.edit);
    expect(decided.editedArguments, {'trail': 'lake'});
  });

  test('a question the window dismisses waits: its card comes back, and '
      'nothing is sent or stopped', () async {
    var card = nextCard();
    final (:outcome, :decisions, :answers) = pause(_question);
    final first = await card;
    card = nextCard();
    answer(first, 'cancel');
    final again = await card;
    expect(again.detail['refusal'], 'empty');
    expect(await _settledYet(outcome), isFalse, reason: 'the pause ended');
    answer(again, 'answer', 'Lake');
    expect(await outcome, LibreChatPauseOutcome.resumed);
    expect(answers, [
      {'call-1': 'Lake'},
    ]);
  });

  test('a resume that fails puts the last card back, marked, to be answered '
      'again', () async {
    var failing = true;
    var card = nextCard();
    final (:outcome, :decisions, :answers) = pause(
      _question,
      failWith: () => failing ? StateError('unreachable') : null,
    );
    final first = await card;
    expect(first.detail.containsKey('failed'), isFalse);
    card = nextCard();
    answer(first, 'answer', 'Ridge');
    final again = await card;
    expect(again.detail['failed'], isTrue);
    failing = false;
    answer(again, 'answer', 'Lake');
    expect(await outcome, LibreChatPauseOutcome.resumed);
    expect(answers, [
      {'call-1': 'Ridge'},
      {'call-1': 'Lake'},
    ]);
  });

  test('with no window the pause waits for one, refusing nothing, and puts '
      'its card to the first that comes', () async {
    events.detach('w1');
    final card = nextCard();
    final (:outcome, :decisions, :answers) = pause(
      _toolCall(const ['approve', 'reject']),
    );
    await events.waiting;
    expect(await _settledYet(outcome), isFalse, reason: 'it did not wait');
    expect(decisions, isEmpty, reason: 'something was decided unasked');
    events.attach('w2', (envelope) {
      if (envelope.event != ConduitEvents.uiRequest) return;
      cards.add(UiRequest.fromJson(envelope.payload));
    });
    answer(await card, 'approve');
    expect(await outcome, LibreChatPauseOutcome.resumed);
    expect(
      decisions.single!['call-2']!.decision,
      LibreChatToolDecision.approve,
    );
  });

  test('a card every window closed decides nothing, and comes back when a '
      'window does', () async {
    var card = nextCard();
    final (:outcome, :decisions, :answers) = pause(
      _toolCall(const ['approve', 'reject']),
    );
    final first = await card;
    events
      ..detach('w1')
      ..rearm();
    windows.onWindowsChanged();
    await events.waiting;
    expect(decisions, isEmpty);
    expect(
      windows.respond(UiResponse(requestId: first.requestId, choice: 'reject')),
      isFalse,
      reason: 'the closed card still took an answer',
    );
    card = nextCard();
    events.attach('w2', (envelope) {
      if (envelope.event != ConduitEvents.uiRequest) return;
      cards.add(UiRequest.fromJson(envelope.payload));
    });
    answer(await card, 'reject');
    expect(await outcome, LibreChatPauseOutcome.resumed);
    expect(decisions.single!['call-2']!.decision, LibreChatToolDecision.reject);
  });

  test('the card goes when its turn ends, and an answer after that sends '
      'nothing', () async {
    final ended = Completer<void>();
    final card = nextCard();
    final (:outcome, :decisions, :answers) = pause(_question, ended: ended);
    final shown = await card;
    ended.complete();
    expect(await outcome, LibreChatPauseOutcome.left);
    expect(windows.pending, isEmpty);
    expect(
      windows.respond(
        UiResponse(requestId: shown.requestId, choice: 'answer', text: 'Lake'),
      ),
      isFalse,
    );
    expect(answers, isEmpty);
  });

  test('several tool calls are put one at a time, numbered, and sent '
      'together', () async {
    var card = nextCard();
    final (:outcome, :decisions, :answers) = pause(_twoCalls);
    final first = await card;
    expect(first.messageArgs['progress'], '1/2');
    card = nextCard();
    answer(first, 'approve');
    final second = await card;
    expect(second.messageArgs['progress'], '2/2');
    expect(second.messageArgs['title'], 'weather');
    expect(decisions, isEmpty);
    answer(second, 'reject');
    expect(await outcome, LibreChatPauseOutcome.resumed);
    expect(decisions.single!.keys, ['call-a', 'call-b']);
  });

  test('a pause whose turn ended while it still reads as asking ends, '
      'never putting its card over and over', () async {
    final ended = Completer<void>()..complete();
    var checks = 0;
    final outcome = answerLibreChatPause(
      _question,
      windows: windows,
      chatId: 'chat-1',
      // Bounded, so a loop that never stops fails rather than starving the
      // event loop.
      asking: () => checks++ < 50,
      until: ended.future,
      resume: ({decisions, answers}) async => fail('sent for an ended turn'),
    );
    expect(await outcome, LibreChatPauseOutcome.left);
    expect(checks, lessThan(5), reason: 'put over and over');
    expect(windows.pending, isEmpty);
  });

  test('a pause with nothing to ask puts no card and sends nothing', () async {
    final (:outcome, :decisions, :answers) = pause(
      const LibreChatPendingAction(<String, dynamic>{
        'actionId': 'act-0',
        'payload': <String, dynamic>{'type': 'ask_user_question'},
      }),
    );
    expect(await outcome, LibreChatPauseOutcome.left);
    expect(asked, isEmpty);
    expect(answers, isEmpty);
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
      {'tool_call_id': 'call-2', 'name': 'trail_map', 'arguments': arguments},
    ],
    'review_configs': <Map<String, dynamic>>[
      {'tool_call_id': 'call-2', 'allowed_decisions': allowed},
    ],
  },
});

/// A run paused on two tool calls.
const _twoCalls = LibreChatPendingAction(<String, dynamic>{
  'actionId': 'act-3',
  'payload': <String, dynamic>{
    'type': 'tool_approval',
    'action_requests': <Map<String, dynamic>>[
      {'tool_call_id': 'call-a', 'name': 'trail_map'},
      {'tool_call_id': 'call-b', 'name': 'weather'},
    ],
    'review_configs': <Map<String, dynamic>>[
      {
        'tool_call_id': 'call-a',
        'allowed_decisions': ['approve', 'reject'],
      },
      {
        'tool_call_id': 'call-b',
        'allowed_decisions': ['approve', 'reject'],
      },
    ],
  },
});

/// A run paused on one question whose labels a window could confuse: one
/// padded, and two alike once trimmed.
LibreChatPendingAction _placed({required bool multi}) =>
    LibreChatPendingAction(<String, dynamic>{
      'actionId': 'act-p',
      'payload': <String, dynamic>{
        'type': 'ask_user_question',
        'tool_call_id': 'call-p',
        'question': <String, dynamic>{
          'question': 'Which trail?',
          'multiSelect': multi,
          'options': <Object>[
            // Nothing to pick by, ahead of the rest: the card never offers
            // them, so places count only what it shows.
            '',
            {'label': '  ', 'value': 'blank'},
            {'label': 7, 'value': 'seven'},
            {'label': ' North Ridge ', 'value': 'north-ridge'},
            {'label': 'Lake Loop', 'value': 'lake-loop'},
            {'label': 'Ridge', 'value': 'ridge-north'},
            {'label': ' Ridge ', 'value': 'ridge-south'},
          ],
        },
      },
    });

/// A run paused on one question whose options answer with values unlike
/// their labels.
const _valued = LibreChatPendingAction(<String, dynamic>{
  'actionId': 'act-v',
  'payload': <String, dynamic>{
    'type': 'ask_user_question',
    'tool_call_id': 'call-v',
    'question': <String, dynamic>{
      'question': 'Which trail?',
      'options': <Map<String, dynamic>>[
        {'label': 'North Ridge', 'value': 'north-ridge'},
        {'label': 'Lake Loop', 'value': 'lake-loop'},
      ],
    },
  },
});
