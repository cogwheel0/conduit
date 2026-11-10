import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_copied_history_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_queued_answer.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

final class _OpenDatabaseAccess extends OpenWebUiDatabaseAccessNotifier {
  @override
  OpenWebUiDatabaseAccessPhase build() => OpenWebUiDatabaseAccessPhase.open;
}

final class _FixedHermesConfig extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig(
    enabled: true,
    baseUrl: 'https://hermes.example',
    apiKey: 'key',
    sessionKey: 'memory',
  );

  @override
  Future<String> ensureSessionKey() async => 'memory';
}

const _before = <Map<String, dynamic>>[
  {'id': 'row-1', 'role': 'user', 'content': 'Plan the tide walk'},
  {'id': 'row-2', 'role': 'assistant', 'content': 'Low tide is at four.'},
];
const _answered = <Map<String, dynamic>>[
  ..._before,
  {'id': 'row-3', 'role': 'user', 'content': 'And the high tide?'},
  {
    'id': 'row-4',
    'role': 'assistant',
    'response_id': 'resp-2',
    'content': [
      {'type': 'text', 'text': 'High tide is at ten.'},
      {
        'type': 'image_url',
        'image_url': {'url': 'https://hermes.example/tide-chart.png'},
      },
    ],
  },
];

/// A Hermes that saves the turn during a restart, then shows the session's
/// rows one read at a time from [reads], the last read repeating.
final class _RestartingHermesApi extends HermesApiService {
  _RestartingHermesApi(this.reads)
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          apiKey: 'key',
        ),
        dio: Dio(),
      );

  final List<List<Map<String, dynamic>>> reads;
  var turns = 0;
  var sessionReads = 0;

  @override
  Future<HermesResponseStream> streamResponseWithReasoning(
    HermesChatInput input, {
    String? instructions,
    String? sessionId,
    String? conversation,
    String? previousResponseId,
    List<Map<String, dynamic>>? conversationHistory,
    String? reasoningEffort,
    CancelToken? cancelToken,
  }) async {
    turns++;
    throw HermesApiException(
      requestOptions: RequestOptions(path: '/v1/responses'),
      statusCode: 503,
      code: HermesApiErrorCode.admissionQueued,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> getSessionMessages(
    String id, {
    CancelToken? cancelToken,
  }) async {
    final read =
        reads[sessionReads < reads.length ? sessionReads : reads.length - 1];
    sessionReads++;
    return read;
  }
}

void main() {
  setUp(() {
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    HermesLocalDocumentTrustStore.debugResetRuntimeState();
    HermesMixedSessionBindingTrustStore.debugResetRuntimeState();
  });
  tearDown(() {
    HermesLocalDocumentTrustStore.debugResetRuntimeState();
    HermesMixedSessionBindingTrustStore.debugResetRuntimeState();
    PreferencesStore.debugReset();
  });

  /// Sends a turn into the open Hermes chat `tide-1`, which Hermes saves
  /// during a restart, and returns its container and placeholder id.
  (ProviderContainer, String) send(HermesBackendService service) {
    final database = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        openWebUiDatabaseAccessProvider.overrideWith(_OpenDatabaseAccess.new),
        appDatabaseProvider.overrideWithValue(database),
        apiServiceProvider.overrideWithValue(null),
        socketServiceProvider.overrideWithValue(null),
        hermesConfigProvider.overrideWith(_FixedHermesConfig.new),
        hermesApiServiceProvider.overrideWithValue(service),
        hermesCopiedHistoryStoreProvider.overrideWithValue(
          HermesCopiedHistoryStore(database),
        ),
      ],
    );
    final earlier = ChatMessage(
      id: 'earlier',
      role: 'assistant',
      content: 'Low tide is at four.',
      timestamp: DateTime.utc(2026, 7, 14),
      metadata: const <String, dynamic>{
        'transport': kHermesTransport,
        'hermesResponseId': 'resp-1',
      },
    );
    final placeholder = ChatMessage(
      id: 'placeholder',
      role: 'assistant',
      content: '',
      timestamp: DateTime.utc(2026, 7, 14),
      isStreaming: true,
      metadata: const <String, dynamic>{'transport': kHermesTransport},
    );
    final shown = <ChatMessage>[earlier, placeholder];
    container
        .read(activeConversationProvider.notifier)
        .set(
          markNativeHermesConversation(
            Conversation(
              id: 'local:hermes_tide-1',
              title: 'Tides',
              createdAt: DateTime.utc(2026, 7, 14),
              updatedAt: DateTime.utc(2026, 7, 14),
              messages: shown,
              metadata: const <String, dynamic>{
                'backend': 'hermes',
                'hermesSessionId': 'tide-1',
              },
            ),
          ),
        );
    container.read(chatMessagesProvider.notifier).setMessages(shown);
    unawaited(
      dispatchHermesRunFromChatForTest(
        container,
        assistantMessageId: placeholder.id,
        assistantSeed: placeholder,
        input: 'And the high tide?',
        existingMessages: <ChatMessage>[earlier],
        responseInput: HermesChatInput.text('And the high tide?'),
      ),
    );
    return (container, placeholder.id);
  }

  ChatStatusUpdate? waiting(ChatMessage message) => message.statusHistory
      .where((status) => status.action == kHermesQueuedAnswerAction)
      .firstOrNull;

  // A message saved during a restart came back without anything to follow,
  // so its answer showed only once the chat was opened again.
  test('the answer to a message saved during a restart shows in the chat', () {
    fakeAsync((async) {
      final service = _RestartingHermesApi([_before, _before, _answered]);
      final (container, id) = send(service);
      async.flushMicrotasks();
      ChatMessage reply() =>
          container.read(chatMessagesProvider).singleWhere((m) => m.id == id);
      // Shown on the settled turn while it waits, so marked done.
      check(waiting(reply())).isNotNull()
        ..has((it) => it.done, 'done').equals(true)
        ..has(
          (it) => it.description,
          'description',
        ).equals(kHermesQueuedAnswerWaitingMessage);
      check(reply().isStreaming).isFalse();

      async.elapse(const Duration(minutes: 1));

      check(reply().content).equals('High tide is at ten.');
      check(waiting(reply())).isNotNull()
        ..has((it) => it.done, 'done').equals(true)
        ..has(
          (it) => it.description,
          'description',
        ).equals(kHermesQueuedAnswerArrivedMessage);
      // With the answer's picture, and its response id for the next turn
      // to continue from.
      check(
        reply().files,
      ).isNotNull().has((it) => it.single['url'], 'url').equals(
        'https://hermes.example/tide-chart.png',
      );
      check(reply().metadata?['hermesResponseId']).equals('resp-2');
      // The open conversation shows it too.
      check(
        container
            .read(activeConversationProvider)!
            .messages
            .singleWhere((m) => m.id == id)
            .content,
      ).equals('High tide is at ten.');
      // Saved, so never sent again.
      check(service.turns).equals(1);
      container.dispose();
      async.flushMicrotasks();
    });
  });

  // With its turn gone, settling the wait still rewrote the conversation
  // and its summary, moving it in the chat list.
  test('a turn gone from the chat leaves the conversation as it is', () {
    fakeAsync((async) {
      final service = _RestartingHermesApi([_before]);
      final (container, id) = send(service);
      async.elapse(const Duration(seconds: 3));
      container.read(chatMessagesProvider.notifier).removeMessageById(id);
      final before = container.read(activeConversationProvider);

      async.elapse(const Duration(minutes: 11));

      check(identical(container.read(activeConversationProvider), before))
          .isTrue();
      container.dispose();
      async.flushMicrotasks();
    });
  });

  test('a chat that sends something else stops waiting for the answer', () {
    fakeAsync((async) {
      final service = _RestartingHermesApi([_before]);
      final (container, id) = send(service);
      async.elapse(const Duration(seconds: 3));
      final readsBefore = service.sessionReads;
      container
          .read(chatMessagesProvider.notifier)
          .addMessage(
            ChatMessage(
              id: 'next',
              role: 'user',
              content: 'Never mind',
              timestamp: DateTime.utc(2026, 7, 14),
            ),
          );

      async.elapse(const Duration(minutes: 11));

      check(service.sessionReads).isLessOrEqual(readsBefore + 1);
      final reply = container
          .read(chatMessagesProvider)
          .singleWhere((m) => m.id == id);
      check(reply.content).isEmpty();
      check(waiting(reply)).isNotNull()
        ..has((it) => it.done, 'done').equals(true)
        ..has(
          (it) => it.description,
          'description',
        ).equals(kHermesQueuedAnswerLateMessage);
      container.dispose();
      async.flushMicrotasks();
    });
  });
}
