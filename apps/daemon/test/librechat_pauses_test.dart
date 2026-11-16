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
  late EventBus events;
  late UiRequestsService windows;
  late List<UiRequest> asked;
  late StreamController<UiRequest> cards;

  setUp(() {
    events = EventBus();
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
LibreChatPendingAction _toolCall(List<String> allowed) =>
    LibreChatPendingAction(<String, dynamic>{
      'actionId': 'act-2',
      'payload': <String, dynamic>{
        'type': 'tool_approval',
        'action_requests': <Map<String, dynamic>>[
          {'tool_call_id': 'call-2', 'name': 'trail_map', 'arguments': '{}'},
        ],
        'review_configs': <Map<String, dynamic>>[
          {'tool_call_id': 'call-2', 'allowed_decisions': allowed},
        ],
      },
    });
