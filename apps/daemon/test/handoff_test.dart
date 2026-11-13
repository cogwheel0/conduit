import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

void main() {
  group('HandoffService', () {
    late EventBus events;
    late List<EventEnvelope> heard;
    late HandoffService handoff;

    setUp(() {
      events = EventBus();
      heard = <EventEnvelope>[];
      events.attach('window-a', heard.add);
      events.attach('window-b', (_) {});
      handoff = HandoffService(
        events,
        claims: (chatId) => chatId == 'chat-1',
        timeout: const Duration(milliseconds: 200),
      );
    });

    Future<bool> ask() => handoff.confirm(
      chatId: 'chat-1',
      modelId: 'fake-model-b',
      modelName: 'Fake Model B',
      prompt: 'Carry on with the pond plan.',
    );

    String requestId() => HandoffRequest.fromJson(
      heard
          .firstWhere((e) => e.event == ConduitEvents.handoffRequested)
          .payload,
    ).requestId;

    test('claims only the chats it is told the user is in', () {
      expect(handoff.claims('chat-1'), isTrue);
      expect(handoff.claims('chat-2'), isFalse);
    });

    test('asks every window, and the one that agrees opens the chat', () async {
      final agreed = ask();
      await Future<void>.delayed(Duration.zero);
      final request = HandoffRequest.fromJson(heard.single.payload);
      expect(request.modelName, 'Fake Model B');
      expect(request.chatId, 'chat-1');
      expect(handoff.pending, hasLength(1));

      final answered = handoff.answer(
        HandoffAnswer(requestId: request.requestId, accept: true),
      );
      expect(await agreed, isTrue);
      // The core lets it open.
      handoff.opened('fake-model-b', 'Carry on with the pond plan.');
      final reply = await answered;
      expect(reply.open, isTrue);
      expect(reply.modelId, 'fake-model-b');
      expect(reply.prompt, 'Carry on with the pond plan.');
      // The others close their question.
      expect(
        heard.map((e) => e.event),
        contains(ConduitEvents.handoffSettled),
      );
      expect(handoff.pending, isEmpty);
    });

    test('a second answer opens nothing', () async {
      final agreed = ask();
      await Future<void>.delayed(Duration.zero);
      final id = requestId();
      final first = handoff.answer(HandoffAnswer(requestId: id, accept: true));
      final second = await handoff.answer(
        HandoffAnswer(requestId: id, accept: true),
      );
      expect(second.open, isFalse);
      expect(await agreed, isTrue);
      handoff.opened('fake-model-b', '');
      expect((await first).open, isTrue);
    });

    test('declining, or the core refusing after, opens nothing', () async {
      final declined = ask();
      await Future<void>.delayed(Duration.zero);
      final reply = await handoff.answer(
        HandoffAnswer(requestId: requestId(), accept: false),
      );
      expect(reply.open, isFalse);
      expect(await declined, isFalse);

      heard.clear();
      final agreed = ask();
      await Future<void>.delayed(Duration.zero);
      final answered = handoff.answer(
        HandoffAnswer(requestId: requestId(), accept: true),
      );
      expect(await agreed, isTrue);
      // The user left the chat meanwhile: the handoff ends unopened.
      handoff.ended();
      expect((await answered).open, isFalse);
    });

    test('unanswered, it is declined and closed everywhere', () async {
      expect(await ask(), isFalse);
      expect(
        heard.map((e) => e.event),
        containsAllInOrder(<String>[
          ConduitEvents.handoffRequested,
          ConduitEvents.handoffSettled,
        ]),
      );
    });

    test('with no window open, nobody is asked', () async {
      events
        ..detach('window-a')
        ..detach('window-b');
      expect(await ask(), isFalse);
      expect(heard, isEmpty);
    });

    test('the last window closing declines what waits', () async {
      final asked = ask();
      await Future<void>.delayed(Duration.zero);
      events
        ..detach('window-a')
        ..detach('window-b');
      handoff.onWindowsChanged();
      expect(await asked, isFalse);
    });
  });

  group('the daemon coordinator', () {
    test('refuses a chat no window or scope has, as the core does', () async {
      final port = DaemonHandoffPort();
      final events = EventBus()..attach('window', (_) {});
      port.attach(HandoffService(events, claims: (_) => false));
      // Without a container the coordinator cannot be built here; the port's
      // own answers are what it reads.
      expect(port.claims('chat-1'), isFalse);
      expect(await port.confirm('Fake Model B'), isFalse);
    });
  });
}
