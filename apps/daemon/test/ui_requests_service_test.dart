@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart'
    show HermesHeldModelSwitch;
import 'package:conduit_core/ports/ui_request_port.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:conduitd/src/ports/ui_requests.dart';
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

  test(
    'a prompt answer comes back unchanged, and an empty one is nothing',
    () async {
      openWindow();
      var answer = broker.promptForText(title: 'Name?');
      await pumpEventQueue();
      // Plain text is the default, so the request leaves the type out.
      expect(lastRequest().inputType, isNull);
      expect(lastRequest().options, isNull);
      broker.respond(
        UiResponse(
          requestId: lastRequest().requestId,
          choice: 'allow',
          text: '  Ada  ',
        ),
      );
      expect(await answer, '  Ada  ');

      answer = broker.promptForText(title: 'Name?');
      await pumpEventQueue();
      broker.respond(
        UiResponse(
          requestId: lastRequest().requestId,
          choice: 'allow',
          text: '',
        ),
      );
      expect(await answer, isNull);
    },
  );

  test('a password prompt says so, and keeps its spaces', () async {
    openWindow();
    final answer = broker.promptForText(
      title: 'Passphrase?',
      inputType: UiTextInputType.password,
    );
    await pumpEventQueue();
    expect(lastRequest().inputType, UiInputType.password);
    expect(lastRequest().options, isNull);
    broker.respond(
      UiResponse(
        requestId: lastRequest().requestId,
        choice: 'allow',
        text: ' open sesame ',
      ),
    );
    expect(await answer, ' open sesame ');
  });

  test(
    'a select prompt carries its options and takes only one of them',
    () async {
      openWindow();
      const options = <UiSelectOption>[
        UiSelectOption(value: 'eu', label: 'Europe'),
        UiSelectOption(value: 'us', label: 'United States'),
      ];
      var answer = broker.promptForText(
        title: 'Region?',
        inputType: UiTextInputType.select,
        options: options,
      );
      await pumpEventQueue();
      expect(lastRequest().inputType, UiInputType.select);
      expect(lastRequest().options, const <UiInputOption>[
        UiInputOption(value: 'eu', label: 'Europe'),
        UiInputOption(value: 'us', label: 'United States'),
      ]);
      broker.respond(
        UiResponse(
          requestId: lastRequest().requestId,
          choice: 'allow',
          text: 'us',
        ),
      );
      expect(await answer, 'us');

      answer = broker.promptForText(
        title: 'Region?',
        inputType: UiTextInputType.select,
        options: options,
      );
      await pumpEventQueue();
      broker.respond(
        UiResponse(
          requestId: lastRequest().requestId,
          choice: 'allow',
          text: 'mars',
        ),
      );
      expect(await answer, isNull);
    },
  );

  test('a window that opens later still sees what is waiting', () async {
    openWindow();
    unawaited(broker.confirm(title: 'Run tool?'));
    await pumpEventQueue();
    expect(broker.pending.single.messageArgs['title'], 'Run tool?');
  });

  group('a Hermes model switch', () {
    test('asks with the model and Hermes\' reason, switch or keep', () async {
      openWindow();
      final switched = broker.askHermesModelSwitch(
        model: 'Heron Large',
        reason: 'Heron Large costs more per message.',
      );
      await pumpEventQueue();
      final request = lastRequest();
      expect(request.kind, UiRequestKind.hermesModelSwitch);
      expect(request.messageCode, 'hermes.modelSwitch');
      expect(request.messageArgs, <String, String>{
        'model': 'Heron Large',
        'reason': 'Heron Large costs more per message.',
      });
      expect(request.defaultChoice, 'cancel');
      expect(request.timeoutMs, isNotNull);
      broker.respond(UiResponse(requestId: request.requestId, choice: 'allow'));
      expect(await switched, isTrue);

      final kept = broker.askHermesModelSwitch(model: 'Heron Large');
      await pumpEventQueue();
      expect(lastRequest().messageArgs.containsKey('reason'), isFalse);
      broker.respond(
        UiResponse(requestId: lastRequest().requestId, choice: 'deny'),
      );
      expect(await kept, isFalse);
    });

    test('nobody to ask, or no answer in time, refuses it', () async {
      expect(await broker.askHermesModelSwitch(model: 'Heron Large'), isNull);
      openWindow();
      expect(await broker.askHermesModelSwitch(model: 'Heron Large'), isNull);
    });

    test('the core\'s port asks once the broker is attached', () async {
      final port = DaemonUiRequestPort();
      const held = HermesHeldModelSwitch(model: 'Heron Large');
      expect(await port.confirmHermesModelSwitch(held), isNull);
      port.attach(broker);
      openWindow();
      final answer = port.confirmHermesModelSwitch(held);
      await pumpEventQueue();
      broker.respond(
        UiResponse(requestId: lastRequest().requestId, choice: 'deny'),
      );
      expect(await answer, isFalse);
    });
  });
}
