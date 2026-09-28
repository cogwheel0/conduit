@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

/// The broker between the core's questions and whichever window answers.
///
/// Nearly every rule here is about the case where nobody answers. The
/// conservative choice has to win in all of them, or a tool can run because
/// a window happened to be closed.
void main() {
  late EventBus events;
  late List<EventEnvelope> seen;
  late UiRequestsService broker;

  setUp(() {
    events = EventBus();
    seen = <EventEnvelope>[];
    broker = UiRequestsService(
      events,
      promptTimeout: const Duration(milliseconds: 50),
    );
  });

  void openWindow([String id = 'w1']) => events.attach(id, seen.add);

  UiRequest lastRequest() => UiRequest.fromJson(
    seen.lastWhere((e) => e.event == ConduitEvents.uiRequest).payload,
  );

  test('with no window open, a confirmation is declined at once', () async {
    // Waiting would hang the turn on a question nobody can see.
    expect(await broker.confirm(title: 'Run tool?'), isFalse);
  });

  test('with no window open, a prompt answers nothing', () async {
    expect(await broker.promptForText(title: 'Name?'), isNull);
  });

  test('a confirmation goes to the windows and waits for them', () async {
    openWindow();
    final answer = broker.confirm(title: 'Run tool?', message: 'rm -rf');
    await pumpEventQueue();

    final request = lastRequest();
    expect(request.kind, UiRequestKind.confirm);
    expect(request.messageArgs['message'], 'rm -rf');
    // No timeout: an unanswered approval stays unanswered.
    expect(request.timeoutMs, isNull);

    expect(
      broker.respond(UiResponse(requestId: request.requestId, choice: 'allow')),
      isTrue,
    );
    expect(await answer, isTrue);
  });

  test('anything but allow is a decline', () async {
    openWindow();
    final answer = broker.confirm(title: 'Run tool?');
    await pumpEventQueue();
    broker.respond(UiResponse(requestId: lastRequest().requestId, choice: 'x'));
    expect(await answer, isFalse);
  });

  test('the first answer wins, and the others hear it is settled', () async {
    openWindow('w1');
    openWindow('w2');
    final answer = broker.confirm(title: 'Run tool?');
    await pumpEventQueue();
    final id = lastRequest().requestId;

    expect(broker.respond(UiResponse(requestId: id, choice: 'allow')), isTrue);
    expect(broker.respond(UiResponse(requestId: id, choice: 'deny')), isFalse);
    expect(await answer, isTrue);
    expect(
      seen
          .where((e) => e.event == ConduitEvents.uiSettled)
          .map((e) => e.payload['requestId']),
      contains(id),
    );
  });

  test(
    'the last window closing settles what is waiting, as a decline',
    () async {
      openWindow();
      final answer = broker.confirm(title: 'Run tool?');
      await pumpEventQueue();

      events.detach('w1');
      broker.onWindowsChanged();

      expect(await answer, isFalse);
      expect(broker.pending, isEmpty);
    },
  );

  test('a prompt times out to nothing rather than hanging', () async {
    openWindow();
    expect(await broker.promptForText(title: 'Name?'), isNull);
    expect(broker.pending, isEmpty);
  });

  test('a prompt answer is trimmed, and a blank one is nothing', () async {
    openWindow();
    var answer = broker.promptForText(title: 'Name?');
    await pumpEventQueue();
    broker.respond(
      UiResponse(
        requestId: lastRequest().requestId,
        choice: 'allow',
        text: '  Ada  ',
      ),
    );
    expect(await answer, 'Ada');

    answer = broker.promptForText(title: 'Name?');
    await pumpEventQueue();
    broker.respond(
      UiResponse(
        requestId: lastRequest().requestId,
        choice: 'allow',
        text: ' ',
      ),
    );
    expect(await answer, isNull);
  });

  test('a window that opens later still sees what is waiting', () async {
    openWindow();
    unawaited(broker.confirm(title: 'Run tool?'));
    await pumpEventQueue();
    expect(broker.pending.single.messageArgs['title'], 'Run tool?');
  });
}
