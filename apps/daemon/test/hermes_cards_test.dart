@TestOn('vm')
library;

import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_error_surface.dart';
import 'package:conduit_core/features/hermes/models/hermes_inline_diff.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:conduitd/src/message_blocks.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// The Hermes agent's cards: what a question the agent waits on becomes for
/// the windows, and what an answer's blocks carry for its cards.
void main() {
  group('questions', () {
    late EventBus events;
    late List<EventEnvelope> seen;
    late UiRequestsService broker;
    late HermesCardsService cards;
    late ProviderContainer container;
    late List<String> held;

    setUp(() {
      events = EventBus();
      seen = <EventEnvelope>[];
      events.attach('w1', seen.add);
      broker = UiRequestsService(events);
      container = ProviderContainer();
      addTearDown(container.dispose);
      held = <String>[];
      cards = HermesCardsService(
        container,
        events,
        hold: (chatId) async {
          held.add(chatId);
          return container;
        },
        release: (chatId) => held.remove(chatId),
        uiRequests: broker,
      );
    });

    ChatMessage answer(Map<String, dynamic> decision) => ChatMessage(
      id: 'answer-1',
      role: 'assistant',
      content: '',
      timestamp: DateTime.utc(2026, 11, 11),
      metadata: <String, dynamic>{
        'transport': kHermesTransport,
        'hermesSessionId': 'session-1',
        kHermesDecisionMeta: <String, dynamic>{
          'requestId': 'srq-1',
          'runtimeId': 'runtime-1',
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(minutes: 5))
              .toIso8601String(),
          'state': 'pending',
          ...decision,
        },
      },
    );

    List<UiRequest> requests() => <UiRequest>[
      for (final e in seen)
        if (e.event == ConduitEvents.uiRequest) UiRequest.fromJson(e.payload),
    ];

    List<String> settled() => <String>[
      for (final e in seen)
        if (e.event == ConduitEvents.uiSettled)
          UiSettled.fromJson(e.payload).requestId,
    ];

    test('a secret request asks the windows once, for a value', () async {
      final message = answer(<String, dynamic>{
        'kind': 'secret',
        'prompt': 'Enter your Demo Weather API key',
      });
      cards.project('local:hermes_session-1', container, 'c1', message);
      // The same answer projected again asks nothing more.
      cards.project('local:hermes_session-1', container, 'c1', message);
      await pumpEventQueue();

      final asked = requests();
      expect(asked, hasLength(1));
      expect(asked.single.kind, UiRequestKind.hermesSecret);
      expect(
        asked.single.messageArgs['prompt'],
        'Enter your Demo Weather API key',
      );
      expect(asked.single.detail['chatId'], 'local:hermes_session-1');
      // It waits as long as Hermes does, no longer.
      expect(asked.single.timeoutMs, inInclusiveRange(1, 300000));
      // The chat's scope is held while the question waits.
      expect(held, <String>['local:hermes_session-1']);
    });

    test('a clarify form carries its questions, choices bare', () async {
      cards.project(
        'local:hermes_session-1',
        container,
        'c1',
        answer(<String, dynamic>{
          'kind': 'clarification',
          'questions': <Object>[
            <String, Object>{
              'qid': 'q0',
              'question': 'Which cuisine should the demo menu use?',
              'choices': <String>['Mediterranean (Recommended)', 'Japanese'],
            },
            <String, Object>{
              'qid': 'q1',
              'question': 'Which courses?',
              'choices': <String>['Starter', 'Main'],
              'multi_select': true,
            },
          ],
        }),
      );
      await pumpEventQueue();

      final request = requests().single;
      expect(request.kind, UiRequestKind.hermesClarify);
      final questions = (request.detail['questions'] as List).cast<Map>();
      expect(questions.map((q) => q['id']), <String>['q0', 'q1']);
      final first = (questions.first['choices'] as List).cast<Map>().first;
      expect(first['label'], 'Mediterranean');
      expect(first['value'], 'Mediterranean');
      expect(first['recommended'], isTrue);
      expect(questions.last['multiSelect'], isTrue);
    });

    test(
      'a question replayed under a new runtime keeps its card, answered anew',
      () async {
        // Reading a chat resumes its session, which replays the questions it
        // still waits on under the resumed runtime: the same question, new
        // ids. The card the user may be typing into stays.
        for (final kind in <String>['secret', 'sudo', 'clarification']) {
          seen.clear();
          final first = answer(<String, dynamic>{
            'kind': kind,
            'prompt': 'Enter your Demo Weather API key',
            'requestId': 'srq-$kind',
          });
          cards.project('local:hermes_session-1', container, 'c1', first);
          await pumpEventQueue();
          final request = requests().single;

          final replayed = first.copyWith(
            metadata: <String, dynamic>{
              ...first.metadata!,
              kHermesDecisionMeta: <String, dynamic>{
                ...(first.metadata![kHermesDecisionMeta] as Map)
                    .cast<String, dynamic>(),
                'requestId': 'srq-$kind-replayed',
                'runtimeId': 'runtime-2',
              },
            },
          );
          cards.project('local:hermes_session-1', container, 'c1', replayed);
          await pumpEventQueue();
          expect(settled(), isEmpty, reason: kind);
          expect(requests(), hasLength(1), reason: kind);

          // A different question is another card.
          final other = replayed.copyWith(
            metadata: <String, dynamic>{
              ...replayed.metadata!,
              kHermesDecisionMeta: <String, dynamic>{
                ...(replayed.metadata![kHermesDecisionMeta] as Map)
                    .cast<String, dynamic>(),
                'requestId': 'srq-$kind-other',
                'prompt': 'Enter your Demo Maps API key',
              },
            },
          );
          cards.project('local:hermes_session-1', container, 'c1', other);
          await pumpEventQueue();
          expect(settled(), <String>[request.requestId], reason: kind);
          expect(requests(), hasLength(2), reason: kind);
          cards.project(
            'local:hermes_session-1',
            container,
            'c1',
            other.copyWith(metadata: <String, dynamic>{}),
          );
          await pumpEventQueue();
        }
      },
    );

    test('a question answered elsewhere settles its card', () async {
      final waiting = answer(<String, dynamic>{'kind': 'sudo'});
      cards.project('local:hermes_session-1', container, 'c1', waiting);
      await pumpEventQueue();
      final request = requests().single;
      expect(request.kind, UiRequestKind.hermesSudo);

      final resolved = waiting.copyWith(
        metadata: <String, dynamic>{
          ...waiting.metadata!,
          kHermesDecisionMeta: <String, dynamic>{
            ...(waiting.metadata![kHermesDecisionMeta] as Map)
                .cast<String, dynamic>(),
            'state': 'resolved',
          },
        },
      );
      cards.project('local:hermes_session-1', container, 'c1', resolved);
      await pumpEventQueue();

      expect(settled(), <String>[request.requestId]);
      expect(held, isEmpty);
      // An answer arriving after it went away is told so.
      final late = await cards.answer(
        HermesDecisionAnswer(requestId: request.requestId, value: 'x'),
      );
      expect(late.status, HermesDecisionStatus.settled);
    });

    // A password typed for one gateway never goes to another: once the
    // connection changed, the card closes and nothing is sent.
    test(
      'a password asked by one connection is not sent to the next',
      () async {
        final connects = <String>[];
        HermesDesktopApiService gateway(String host) {
          final service = HermesDesktopApiService(
            config: HermesConfig(
              enabled: true,
              baseUrl: 'https://$host',
              mode: HermesBackendMode.desktopGateway,
              desktopAuthKind: HermesDesktopAuthKind.legacyToken,
              desktopCredentials: HermesDesktopCredentials(
                legacyToken: 'token',
              ),
            ),
            rpc: HermesDesktopRpcClient(
              channelFactory: (uri, _, {httpClient}) {
                connects.add(uri.host);
                throw StateError('No gateway in this test.');
              },
            ),
          );
          addTearDown(service.close);
          return service;
        }

        HermesBackendService current = gateway('hermes-a.example');
        final chat = ProviderContainer(
          overrides: [
            hermesApiServiceProvider.overrideWith((ref) => current),
            activeConversationProvider.overrideWith(
              () => _Chat(
                Conversation(
                  id: 'c1',
                  title: 'Garden shed',
                  createdAt: DateTime.utc(2026, 11, 11),
                  updatedAt: DateTime.utc(2026, 11, 11),
                  metadata: const <String, dynamic>{
                    'hermesSessionId': 'session-1',
                  },
                ),
              ),
            ),
          ],
        );
        addTearDown(chat.dispose);
        chat.read(hermesApiServiceProvider);
        cards.project(
          'local:hermes_session-1',
          chat,
          'c1',
          answer(<String, dynamic>{'kind': 'sudo'}),
        );
        await pumpEventQueue();
        final request = requests().single;

        current = gateway('hermes-b.example');
        chat.invalidate(hermesApiServiceProvider);
        final result = await cards.answer(
          HermesDecisionAnswer(requestId: request.requestId, value: 'hunter2'),
        );

        expect(connects, isNot(contains('hermes-b.example')));
        expect(result.status, HermesDecisionStatus.settled);
        expect(settled(), <String>[request.requestId]);
      },
    );

    // A replay keeps a card only for the connection that asked: asked again
    // by the next one, the card closes, a new one asks, and nothing typed
    // for the first goes to the next.
    test('a question replayed by the next connection is a new card', () async {
      final connects = <String>[];
      HermesDesktopApiService gateway(String host) {
        final service = HermesDesktopApiService(
          config: HermesConfig(
            enabled: true,
            baseUrl: 'https://$host',
            mode: HermesBackendMode.desktopGateway,
            desktopAuthKind: HermesDesktopAuthKind.legacyToken,
            desktopCredentials: HermesDesktopCredentials(legacyToken: 'token'),
          ),
          rpc: HermesDesktopRpcClient(
            channelFactory: (uri, _, {httpClient}) {
              connects.add(uri.host);
              throw StateError('No gateway in this test.');
            },
          ),
        );
        addTearDown(service.close);
        return service;
      }

      HermesBackendService current = gateway('hermes-a.example');
      final chat = ProviderContainer(
        overrides: [
          hermesApiServiceProvider.overrideWith((ref) => current),
          activeConversationProvider.overrideWith(
            () => _Chat(
              Conversation(
                id: 'c1',
                title: 'Garden shed',
                createdAt: DateTime.utc(2026, 11, 11),
                updatedAt: DateTime.utc(2026, 11, 11),
                metadata: const <String, dynamic>{
                  'hermesSessionId': 'session-1',
                },
              ),
            ),
          ),
        ],
      );
      addTearDown(chat.dispose);
      chat.read(hermesApiServiceProvider);
      final first = answer(<String, dynamic>{'kind': 'sudo'});
      cards.project('local:hermes_session-1', chat, 'c1', first);
      await pumpEventQueue();
      final request = requests().single;

      current = gateway('hermes-b.example');
      chat.invalidate(hermesApiServiceProvider);
      cards.project(
        'local:hermes_session-1',
        chat,
        'c1',
        first.copyWith(
          metadata: <String, dynamic>{
            ...first.metadata!,
            kHermesDecisionMeta: <String, dynamic>{
              ...(first.metadata![kHermesDecisionMeta] as Map)
                  .cast<String, dynamic>(),
              'requestId': 'srq-1-replayed',
              'runtimeId': 'runtime-2',
            },
          },
        ),
      );
      await pumpEventQueue();
      expect(settled(), <String>[request.requestId]);
      expect(requests(), hasLength(2));

      final result = await cards.answer(
        HermesDecisionAnswer(requestId: request.requestId, value: 'hunter2'),
      );
      expect(result.status, HermesDecisionStatus.settled);
      expect(connects, isNot(contains('hermes-b.example')));
    });

    test('an MCP set-up asks as a Hermes decision', () async {
      cards.project(
        'local:hermes_session-1',
        container,
        'c1',
        answer(<String, dynamic>{
          'kind': 'mcpSetup',
          'mcpServer': 'demo_shop',
          'mcpAction': 'Install',
        }),
      );
      await pumpEventQueue();
      final request = requests().single;
      expect(request.kind, UiRequestKind.hermesDecision);
      expect(request.messageCode, 'hermes.mcpSetup');
      expect(request.messageArgs['server'], 'demo_shop');
    });

    test('nothing is asked once the question has expired', () async {
      cards.project(
        'local:hermes_session-1',
        container,
        'c1',
        answer(<String, dynamic>{
          'kind': 'sudo',
          'expiresAt': DateTime.utc(2020).toIso8601String(),
        }),
      );
      await pumpEventQueue();
      expect(requests(), isEmpty);
    });

    test('a watch needs a chat it is told to watch', () async {
      expect(
        () => cards.steer(
          const HermesSteerSubagent(
            chatId: 'local:hermes_session-1',
            subagentId: 'sa-1',
            text: 'Only the north pier',
          ),
        ),
        throwsA(isA<RpcError>()),
      );
    });
  });

  group('blocks', () {
    test('a classified Hermes failure carries its card', () {
      final surface = HermesErrorSurface(
        layer: HermesErrorLayer.provider,
        code: 'rate_limit',
        retryable: true,
        providerLabel: 'Custom',
        model: 'demo-model',
        resetsAt: DateTime.utc(2030),
      );
      final dto = hermesErrorDto(surface, now: DateTime.utc(2029));
      expect(dto.kind, 'rateLimit');
      expect(dto.blocking, isFalse);
      expect(dto.provider, 'Custom');
      expect(dto.resetsAtMs, DateTime.utc(2030).millisecondsSinceEpoch);
      expect(dto.actions.first, 'retry');

      final overflow = hermesErrorDto(
        const HermesErrorSurface(
          layer: HermesErrorLayer.provider,
          code: 'context_overflow',
        ),
      );
      expect(overflow.kind, 'contextOverflow');
      expect(overflow.blocking, isTrue);
      expect(overflow.actions, <String>['compact', 'newChat']);

      final signedOut = hermesErrorDto(
        hermesApiErrorSurface(HermesGatewaySignInRequired())!,
      );
      expect(signedOut.kind, 'gatewaySignIn');
      expect(signedOut.actions, isEmpty);
    });

    test("an answer's edits come as changed files", () {
      final message = ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'Done.',
        timestamp: DateTime.utc(2026, 11, 11),
        statusHistory: <ChatStatusUpdate>[
          ChatStatusUpdate(
            action: 'tool',
            done: true,
            items: <ChatStatusItem>[
              hermesInlineDiffItem(
                'a/demo/notes.md → b/demo/notes.md\n'
                '@@ -1,2 +1,2 @@\n'
                ' Line one\n'
                '-Line two\n'
                '+Line two, edited\n',
              ),
            ],
          ),
        ],
      );
      final blocks = MessageBlocks().forMessage(message);
      final changed = blocks.singleWhere(
        (b) => b.kind == MessageBlockKind.changedFiles,
      );
      final file = changed.changedFiles!.single;
      expect(file.path, 'demo/notes.md');
      expect((file.added, file.removed), (1, 1));
      expect(file.lines.map((l) => l.kind), contains(DiffLineKind.hunk));
    });
  });
}

final class _Chat extends ActiveConversationNotifier {
  _Chat(this.conversation);

  final Conversation conversation;

  @override
  Conversation? build() => conversation;
}
