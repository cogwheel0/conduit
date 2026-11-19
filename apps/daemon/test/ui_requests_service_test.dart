@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart'
    show HermesHeldModelSwitch;
import 'package:conduit_core/ports/ui_request_port.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:conduitd/src/ports/ui_requests.dart';
import 'package:fake_async/fake_async.dart';
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
    // On fake time: the prompt waits five minutes, as in the app.
    UiRequestsService patient() =>
        UiRequestsService(events, promptTimeout: const Duration(minutes: 5));

    test('is its chat\'s question, with the model and Hermes\' reason: '
        'switch or keep', () {
      fakeAsync((async) {
        final broker = patient();
        openWindow();
        bool? switched;
        broker
            .askHermesModelSwitch(
              model: 'Heron Large',
              chatId: 'local:hermes_s-1',
              reason: 'Heron Large costs more per message.',
            )
            .then((v) => switched = v);
        final request = lastRequest();
        expect(request.kind, UiRequestKind.hermesModelSwitch);
        expect(request.messageCode, 'hermes.modelSwitch');
        expect(request.messageArgs, <String, String>{
          'model': 'Heron Large',
          'reason': 'Heron Large costs more per message.',
        });
        expect(request.detail, <String, dynamic>{'chatId': 'local:hermes_s-1'});
        expect(request.defaultChoice, 'cancel');
        expect(request.timeoutMs, isNotNull);
        broker.respond(
          UiResponse(requestId: request.requestId, choice: 'allow'),
        );
        async.flushMicrotasks();
        expect(switched, isTrue);

        bool? kept = true;
        broker
            .askHermesModelSwitch(
              model: 'Heron Large',
              chatId: 'local:hermes_s-1',
            )
            .then((v) => kept = v);
        expect(lastRequest().messageArgs.containsKey('reason'), isFalse);
        broker.respond(
          UiResponse(requestId: lastRequest().requestId, choice: 'deny'),
        );
        async.flushMicrotasks();
        expect(kept, isFalse);
      });
    });

    test('nobody to ask, no answer in time, or a stopped send refuses it', () {
      fakeAsync((async) {
        final broker = patient();
        final answers = <bool?>[];
        void ask({Future<void>? until}) => broker
            .askHermesModelSwitch(
              model: 'Heron Large',
              chatId: 'local:hermes_s-1',
              until: until,
            )
            .then(answers.add);

        ask();
        async.flushMicrotasks();
        expect(answers, <bool?>[null], reason: 'asked with no window open');

        openWindow();
        ask();
        async.elapse(const Duration(minutes: 4));
        expect(answers, hasLength(1), reason: 'gave up before its time');
        async.elapse(const Duration(minutes: 2));
        expect(answers, <bool?>[null, null]);

        final stop = Completer<void>();
        ask(until: stop.future);
        async.flushMicrotasks();
        expect(broker.pending, hasLength(1));
        stop.complete();
        async.flushMicrotasks();
        expect(answers, <bool?>[null, null, null]);
        expect(broker.pending, isEmpty, reason: 'the card stayed up');
      });
    });

    test('the core\'s port asks it as the question of the chat holding the '
        'session, and only then', () {
      fakeAsync((async) {
        final broker = patient();
        final port = DaemonUiRequestPort();
        const held = HermesHeldModelSwitch(
          model: 'Heron Large',
          sessionId: 's-1',
        );
        final answers = <bool?>[];
        port.confirmHermesModelSwitch(held).then(answers.add);
        async.flushMicrotasks();
        port.attach(broker);
        openWindow();
        // No chat holds the session: nothing is asked, the switch refused.
        port.confirmHermesModelSwitch(held).then(answers.add);
        async.flushMicrotasks();
        expect(answers, <bool?>[null, null]);
        expect(seen.where((e) => e.event == ConduitEvents.uiRequest), isEmpty);

        port.hermesChatOf = (session) =>
            session == 's-1' ? 'local:hermes_s-1' : null;
        port.confirmHermesModelSwitch(held).then(answers.add);
        expect(lastRequest().detail['chatId'], 'local:hermes_s-1');
        broker.respond(
          UiResponse(requestId: lastRequest().requestId, choice: 'deny'),
        );
        async.flushMicrotasks();
        expect(answers.last, isFalse);
      });
    });
  });
}
