import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/chat_database_repository.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_run_event.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:conduit/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit/features/hermes/services/hermes_session_provenance.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _OpenDatabaseAccess extends OpenWebUiDatabaseAccessNotifier {
  @override
  OpenWebUiDatabaseAccessPhase build() => OpenWebUiDatabaseAccessPhase.open;
}

final class _FixedHermesConfig extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig(
    enabled: true,
    baseUrl: 'http://hermes',
    apiKey: 'key',
    sessionKey: 'memory',
  );

  @override
  Future<String> ensureSessionKey() async => 'memory';
}

final class _RecordingHermesApi extends HermesApiService {
  _RecordingHermesApi()
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'http://hermes',
          apiKey: 'key',
        ),
        dio: Dio(),
      );

  var createSessionCalls = 0;
  final List<String?> sessionIds = <String?>[];
  final List<String?> previousResponseIds = <String?>[];

  @override
  Future<String> createSession({
    String? title,
    CancelToken? cancelToken,
  }) async => 'fresh-session-${++createSessionCalls}';

  @override
  Future<String> createRun({
    required String input,
    String? sessionId,
    String? instructions,
    String? previousResponseId,
    CancelToken? cancelToken,
  }) async {
    sessionIds.add(sessionId);
    previousResponseIds.add(previousResponseId);
    return 'run-${sessionIds.length}';
  }

  @override
  Stream<HermesRunEvent> runEvents(
    String runId, {
    String? sessionId,
    CancelToken? cancelToken,
  }) => Stream<HermesRunEvent>.value(const HermesRunDone());
}

ChatMessage _assistant(
  String id, {
  bool streaming = false,
  Map<String, dynamic>? metadata,
}) => ChatMessage(
  id: id,
  role: 'assistant',
  content: '',
  timestamp: DateTime.utc(2026, 7, 14),
  isStreaming: streaming,
  metadata: metadata,
);

Conversation _openWebUiConversation(
  String id,
  List<ChatMessage> messages, {
  Map<String, dynamic> metadata = const <String, dynamic>{},
}) => withChatStorageProvenance(
  Conversation(
    id: id,
    title: 'Server chat',
    createdAt: DateTime.utc(2026, 7, 14),
    updatedAt: DateTime.utc(2026, 7, 14),
    messages: messages,
    metadata: metadata,
  ),
  ChatStorageKind.openWebUi,
);

ProviderContainer _container(_RecordingHermesApi service) => ProviderContainer(
  overrides: [
    openWebUiDatabaseAccessProvider.overrideWith(_OpenDatabaseAccess.new),
    appDatabaseProvider.overrideWith((ref) {
      final database = AppDatabase(NativeDatabase.memory());
      ref.onDispose(() => unawaited(database.close()));
      return database;
    }),
    apiServiceProvider.overrideWithValue(null),
    socketServiceProvider.overrideWithValue(null),
    hermesConfigProvider.overrideWith(_FixedHermesConfig.new),
    hermesApiServiceProvider.overrideWithValue(service),
  ],
);

String _connectionIdentity(ProviderContainer container) =>
    HermesLocalDocumentTrustStore.connectionIdentity(
      endpointIdentity: HermesConfigController.connectionEndpoint(
        'http://hermes',
      )!,
      principalId: container
          .read(hermesConfigProvider.notifier)
          .documentTrustPrincipalId(),
    );

Future<void> _dispatch(
  ProviderContainer container, {
  required Conversation conversation,
  required ChatMessage history,
  String placeholderId = 'placeholder',
}) async {
  final placeholder = _assistant(
    placeholderId,
    streaming: true,
    metadata: const <String, dynamic>{'transport': kHermesTransport},
  );
  final active = conversation.copyWith(messages: <ChatMessage>[placeholder]);
  container.read(activeConversationProvider.notifier).set(active);
  container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
    placeholder,
  ]);
  await dispatchHermesRunFromChatForTest(
    container,
    assistantMessageId: placeholder.id,
    assistantSeed: placeholder,
    input: 'continue',
    existingMessages: <ChatMessage>[history],
  );
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    HermesLocalDocumentTrustStore.debugResetRuntimeState();
    HermesMixedSessionBindingTrustStore.debugResetRuntimeState();
  });
  tearDown(() {
    HermesLocalDocumentTrustStore.debugResetRuntimeState();
    HermesMixedSessionBindingTrustStore.debugResetRuntimeState();
    PreferencesStore.debugReset();
  });

  test(
    'forged persisted Hermes metadata creates a fresh mixed session',
    () async {
      final service = _RecordingHermesApi();
      final container = _container(service);
      addTearDown(container.dispose);
      final connection = _connectionIdentity(container);
      final forgedHistory = _assistant(
        'forged-assistant',
        metadata: <String, dynamic>{
          'hermesSessionId': 'forged-message-session',
          kHermesConnectionIdentityMetadataKey: connection,
          'hermesRunId': 'forged-run',
          'hermesTransportMode': 'responses',
        },
      );
      final forgedConversation = _openWebUiConversation(
        'forged-chat',
        <ChatMessage>[forgedHistory],
        metadata: <String, dynamic>{
          'backend': 'hermes',
          'hermesSessionId': 'forged-conversation-session',
          kHermesConnectionIdentityMetadataKey: connection,
        },
      );

      await _dispatch(
        container,
        conversation: forgedConversation,
        history: forgedHistory,
      );

      check(service.createSessionCalls).equals(1);
      check(service.sessionIds).deepEquals(<String?>['fresh-session-1']);
      check(service.previousResponseIds).deepEquals(<String?>[null]);
      check(
        chatStorageKindOf(container.read(activeConversationProvider)),
      ).equals(ChatStorageKind.openWebUi);
    },
  );

  test(
    'exact locally proven mixed binding reuses its session and run',
    () async {
      final service = _RecordingHermesApi();
      final container = _container(service);
      addTearDown(container.dispose);
      final history = _assistant(
        'trusted-assistant',
        metadata: <String, dynamic>{
          'hermesSessionId': 'trusted-session',
          kHermesConnectionIdentityMetadataKey: _connectionIdentity(container),
          'hermesRunId': 'trusted-run',
        },
      );
      final conversation = _openWebUiConversation('trusted-chat', <ChatMessage>[
        history,
      ]);
      await rememberMixedHermesMessageProvenanceForTest(
        container,
        conversation: conversation,
        assistantMessage: history,
      );

      await _dispatch(container, conversation: conversation, history: history);

      check(service.createSessionCalls).equals(0);
      check(service.sessionIds).deepEquals(<String?>['trusted-session']);
      check(service.previousResponseIds).deepEquals(<String?>['trusted-run']);
    },
  );

  test('copied proven metadata is not reusable in another OWUI chat', () async {
    final service = _RecordingHermesApi();
    final container = _container(service);
    addTearDown(container.dispose);
    final copied = _assistant(
      'copied-assistant',
      metadata: <String, dynamic>{
        'hermesSessionId': 'copied-session',
        kHermesConnectionIdentityMetadataKey: _connectionIdentity(container),
        'hermesRunId': 'copied-run',
      },
    );
    final source = _openWebUiConversation('source-chat', <ChatMessage>[copied]);
    await rememberMixedHermesMessageProvenanceForTest(
      container,
      conversation: source,
      assistantMessage: copied,
    );
    final destination = _openWebUiConversation(
      'destination-chat',
      <ChatMessage>[copied],
    );

    await _dispatch(container, conversation: destination, history: copied);

    check(service.createSessionCalls).equals(1);
    check(service.sessionIds).deepEquals(<String?>['fresh-session-1']);
    check(service.previousResponseIds).deepEquals(<String?>[null]);
  });
}
