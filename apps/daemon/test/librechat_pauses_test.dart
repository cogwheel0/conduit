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
