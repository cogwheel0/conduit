import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

/// `intents.*` over a scripted send and chat list: what Shortcuts gets back
/// for each way an answer can end, and which chats Open Chat offers.
void main() {
  late EventBus bus;

  setUp(() => bus = EventBus());

  /// A send that accepts at once and then plays [events] on the bus, as the
  /// turns service would; [beforeReply] plays before the send returns (a
  /// fast answer).
  Future<SendTurnAccepted> Function(SendTurn) scriptedSend({
    List<(String, Object)> beforeReply = const <(String, Object)>[],
    List<(String, Object)> events = const <(String, Object)>[],
    void Function(SendTurn request)? onSend,
  }) {
    return (request) async {
      onSend?.call(request);
      for (final (name, payload) in beforeReply) {
        bus.publish(name, payload: encodeDto(payload));
      }
      // After the send returns: the answer's events come once its reply is
      // read, as a turn's do.
      scheduleMicrotask(() {
        for (final (name, payload) in events) {
          bus.publish(name, payload: encodeDto(payload));
        }
      });
      return const SendTurnAccepted(
        chatId: 'local:new',
        userMessageId: 'u1',
        assistantMessageId: 'a1',
      );
    };
  }

  ChatDetail detail(String id, String title) => ChatDetail(
    summary: ChatSummary(id: id, title: title, updatedAtMs: 1),
  );

  IntentsService service({
    required Future<SendTurnAccepted> Function(SendTurn) send,
    List<ChatSummary> chats = const <ChatSummary>[],
    List<ChatSearchHit> hits = const <ChatSearchHit>[],
    Map<String, String> stored = const <String, String>{},
  }) => IntentsService(
    send: send,
    list: () async => ChatList(chats: chats),
    search: (query) async => ChatSearchResults(hits: hits),
    get: (id) async {
      final title = stored[id];
      if (title == null) {
        throw const RpcError(code: ConduitErrorCodes.notFound);
      }
      return detail(id, title);
    },
    events: bus,
  );

  group('ask', () {
    test(
      'gives back the answer as Copy copies it, with the chat it is in',
      () async {
        SendTurn? sent;
        final intents = service(
          send: scriptedSend(
            onSend: (r) => sent = r,
            events: <(String, Object)>[
              (
                ConduitEvents.turnDelta,
                const TurnDelta(
                  chatId: 'local:new',
                  messageId: 'a1',
                  text: 'Thy',
                ),
              ),
              // The server's id replaces the local one while it answers.
              (
                ConduitEvents.turnCompleted,
                const TurnCompleted(
                  chatId: 'chat-9',
                  messageId: 'a1',
                  text:
                      '<details type="reasoning" done="true">\n<summary>Thought'
                      '</summary>\nhmm\n</details>\nThyme &amp; chives.',
                ),
              ),
              (
                ConduitEvents.turnFinished,
                const TurnFinished(chatId: 'chat-9', messageId: 'a1', ok: true),
              ),
            ],
          ),
          stored: <String, String>{'chat-9': 'Windowsill herbs'},
        );

        final answer = await intents.ask(
          const IntentAsk(text: '  Which herbs grow indoors?  ', model: 'm1'),
        );

        expect(sent?.text, 'Which herbs grow indoors?');
        expect(sent?.model, 'm1');
        expect(sent?.chatId, isNull);
        expect(answer.outcome, IntentAskOutcome.answered);
        expect(answer.text, 'Thyme & chives.');
        expect(answer.chatId, 'chat-9');
        expect(answer.messageId, 'a1');
        expect(answer.title, 'Windowsill herbs');
        expect(answer.detail, isNull);
      },
    );

    test('an answer that ends before the send returns is not missed', () async {
      final intents = service(
        send: scriptedSend(
          beforeReply: <(String, Object)>[
            (
              ConduitEvents.turnCompleted,
              const TurnCompleted(chatId: 'c1', messageId: 'a1', text: 'Fast.'),
            ),
            (
              ConduitEvents.turnFinished,
              const TurnFinished(chatId: 'c1', messageId: 'a1', ok: true),
            ),
          ],
        ),
      );
      final answer = await intents.ask(const IntentAsk(text: 'Quick one'));
      expect(
        (answer.outcome, answer.text),
        (IntentAskOutcome.answered, 'Fast.'),
      );
      // No stored copy to read a title from: none rather than a guess.
      expect(answer.title, isNull);
    });

    test("another chat's answer is not taken for this one", () async {
      final intents = service(
        send: scriptedSend(
          events: <(String, Object)>[
            (
              ConduitEvents.turnCompleted,
              const TurnCompleted(
                chatId: 'c2',
                messageId: 'other',
                text: 'No.',
              ),
            ),
            (
              ConduitEvents.turnFinished,
              const TurnFinished(chatId: 'c2', messageId: 'other', ok: true),
            ),
            (
              ConduitEvents.turnCompleted,
              const TurnCompleted(chatId: 'c1', messageId: 'a1', text: 'Yes.'),
            ),
            (
              ConduitEvents.turnFinished,
              const TurnFinished(chatId: 'c1', messageId: 'a1', ok: true),
            ),
          ],
        ),
      );
      final answer = await intents.ask(const IntentAsk(text: 'Mine?'));
      expect((answer.chatId, answer.text), ('c1', 'Yes.'));
    });

    test("a failed answer carries the server's words and what came", () async {
      final intents = service(
        send: scriptedSend(
          events: <(String, Object)>[
            (
              ConduitEvents.turnFailed,
              const TurnFailed(
                chatId: 'c1',
                messageId: 'a1',
                code: ConduitErrorCodes.serverError,
                args: <String, String>{'detail': ' This model needs a plan. '},
                partialText: 'Half',
              ),
            ),
            (
              ConduitEvents.turnFinished,
              const TurnFinished(
                chatId: 'c1',
                messageId: 'a1',
                ok: false,
                code: ConduitErrorCodes.serverError,
              ),
            ),
          ],
        ),
      );
      final answer = await intents.ask(const IntentAsk(text: 'Try'));
      expect(answer.outcome, IntentAskOutcome.failed);
      expect(answer.detail, 'This model needs a plan.');
      expect(answer.text, 'Half');
    });

    test('a question sent while offline is reported as queued', () async {
      final intents = service(
        send: scriptedSend(
          events: <(String, Object)>[
            (
              ConduitEvents.turnFinished,
              const TurnFinished(
                chatId: 'c1',
                messageId: 'a1',
                ok: true,
                queued: true,
              ),
            ),
          ],
        ),
      );
      final answer = await intents.ask(const IntentAsk(text: 'Later'));
      expect(answer.outcome, IntentAskOutcome.queued);
    });

    test(
      'an answer slower than the wait gives the chat and the text so far',
      () {
        fakeAsync((time) {
          final intents = service(
            send: scriptedSend(
              events: <(String, Object)>[
                (
                  ConduitEvents.turnDelta,
                  const TurnDelta(
                    chatId: 'c1',
                    messageId: 'a1',
                    text: 'Still ',
                  ),
                ),
              ],
            ),
            stored: <String, String>{'c1': 'Long answer'},
          );
          IntentAnswer? answer;
          intents
              // Below the floor: waits the floor's one second, not zero.
              .ask(const IntentAsk(text: 'Slow', timeoutMs: 10))
              .then((value) => answer = value);
          time.elapse(
            const Duration(milliseconds: IntentsService.minTimeoutMs - 1),
          );
          expect(answer, isNull, reason: 'gave up before the floor');
          time.elapse(const Duration(milliseconds: 1));
          expect(answer?.outcome, IntentAskOutcome.timedOut);
          expect(answer?.chatId, 'c1');
          expect(answer?.text, 'Still');
          expect(answer?.title, 'Long answer');
        });
      },
    );

    test('a finished answer waits only so long for its chat\'s title', () {
      fakeAsync((time) {
        final intents = IntentsService(
          send: scriptedSend(
            events: <(String, Object)>[
              (
                ConduitEvents.turnFinished,
                const TurnFinished(chatId: 'c1', messageId: 'a1', ok: true),
              ),
            ],
          ),
          list: () async => const ChatList(chats: <ChatSummary>[]),
          search: (query) async => const ChatSearchResults(),
          // A chat read that never answers.
          get: (id) => Completer<ChatDetail?>().future,
          events: bus,
        );
        IntentAnswer? answer;
        intents
            .ask(const IntentAsk(text: 'Quick one'))
            .then((value) => answer = value);
        time.elapse(const Duration(milliseconds: IntentsService.titleWaitMs));
        expect(answer, isNotNull, reason: 'the title kept Shortcuts waiting');
        expect(answer?.outcome, IntentAskOutcome.answered);
        expect(answer?.chatId, 'c1');
        expect(answer?.title, isNull);
      });
    });

    test(
      'stops listening once it has its answer, or its send failed',
      () async {
        final intents = service(
          send: (request) async =>
              throw const RpcError(code: ConduitErrorCodes.unauthenticated),
        );
        await expectLater(
          intents.ask(const IntentAsk(text: 'Hello')),
          throwsA(
            isA<RpcError>().having(
              (e) => e.code,
              'code',
              ConduitErrorCodes.unauthenticated,
            ),
          ),
        );
        // A later answer reaches no one: the tap is gone (publishing would
        // throw in a listener that outlived its question if it were not).
        expect(bus.publish(ConduitEvents.turnFinished), 0);
      },
    );

    test('an empty question is refused before anything is sent', () async {
      var sends = 0;
      final intents = service(send: scriptedSend(onSend: (_) => sends++));
      await expectLater(
        intents.ask(const IntentAsk(text: '   ')),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.invalidParams,
          ),
        ),
      );
      expect(sends, 0);
    });
  });

  group('chats', () {
    final list = <ChatSummary>[
      const ChatSummary(id: 'old', title: 'Bread starter', updatedAtMs: 10),
      const ChatSummary(id: 'new', title: 'Herb garden', updatedAtMs: 30),
      const ChatSummary(
        id: 'pin',
        title: 'Trip packing',
        updatedAtMs: 5,
        pinned: true,
      ),
      const ChatSummary(
        id: 'gone',
        title: 'Herb archive',
        updatedAtMs: 40,
        archived: true,
      ),
    ];
    Future<SendTurnAccepted> noSend(SendTurn _) async =>
        throw StateError('no sends here');

    test(
      'suggests pinned chats first, then the most recent, never archived',
      () async {
        final chats = await service(
          send: noSend,
          chats: list,
        ).chats(const IntentChatsQuery(limit: 2));
        expect(chats.chats.map((c) => c.id), <String>['pin', 'new']);
        expect(chats.chats.first.pinned, isTrue);
      },
    );

    test('finds chats by title first, then by what the search finds', () async {
      final chats = await service(
        send: noSend,
        chats: list,
        hits: <ChatSearchHit>[
          const ChatSearchHit(
            chatId: 'old',
            title: 'Bread starter',
            updatedAtMs: 10,
          ),
          const ChatSearchHit(
            chatId: 'new',
            title: 'Herb garden',
            updatedAtMs: 30,
          ),
          const ChatSearchHit(
            chatId: 'far',
            title: 'Beyond the page',
            updatedAtMs: 1,
          ),
        ],
      ).chats(const IntentChatsQuery(query: ' HERB '));
      expect(chats.chats.map((c) => c.id), <String>['new', 'old', 'far']);
    });

    test(
      'names the chats asked for by id, from the stored copy when not listed',
      () async {
        final chats = await service(
          send: noSend,
          chats: list,
          stored: <String, String>{'far': 'Beyond the page'},
        ).chats(const IntentChatsQuery(ids: <String>['far', 'pin', 'missing']));
        expect(chats.chats.map((c) => (c.id, c.title)), <(String, String)>[
          ('far', 'Beyond the page'),
          ('pin', 'Trip packing'),
        ]);
      },
    );
  });

  group('the event bus tap', () {
    test('hears every event, scoped or not, and is not a window', () {
      final heard = <(String, String?)>[];
      final untap = bus.tap((event, scope, _) => heard.add((event, scope)));
      bus.attach('w', (_) {});
      bus
        ..publish(ConduitEvents.turnDelta, scope: 'c1')
        ..publish(ConduitEvents.turnFinished);
      expect(heard, <(String, String?)>[
        (ConduitEvents.turnDelta, 'c1'),
        (ConduitEvents.turnFinished, null),
      ]);
      // Not counted: with it alone, nobody is there to answer a question.
      expect(bus.subscriberCount, 1);
      expect(bus.watches('c1'), isFalse);
      expect(bus.lastSeqFor('w'), 1);

      untap();
      bus.publish(ConduitEvents.turnFinished);
      expect(heard, hasLength(2));
    });
  });
}
