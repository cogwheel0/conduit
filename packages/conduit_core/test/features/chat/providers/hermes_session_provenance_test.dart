import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';
import 'package:conduit_core/conduit_core.dart';

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

final class _RecordingHermesApi extends HermesApiService {
  _RecordingHermesApi()
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          apiKey: 'key',
        ),
        dio: Dio(),
      );

  var createSessionCalls = 0;
  final List<String?> sessionIds = <String?>[];
  final List<String?> previousResponseIds = <String?>[];
  final List<List<Map<String, dynamic>>?> conversationHistories =
      <List<Map<String, dynamic>>?>[];

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
    List<Map<String, dynamic>>? conversationHistory,
    CancelToken? cancelToken,
  }) async {
    sessionIds.add(sessionId);
    previousResponseIds.add(previousResponseId);
    conversationHistories.add(conversationHistory);
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
  String content = '',
  bool streaming = false,
  Map<String, dynamic>? metadata,
}) => ChatMessage(
  id: id,
  role: 'assistant',
  content: content,
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
        'https://hermes.example',
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
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
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
      check(chatStorageKindOf(container.read(activeConversationProvider)))
          .equals(ChatStorageKind.openWebUi);
    },
  );

  test(
    'exact locally proven mixed binding reuses its session with history',
    () async {
      final service = _RecordingHermesApi();
      final container = _container(service);
      addTearDown(container.dispose);
      final history = _assistant(
        'trusted-assistant',
        content: 'prior answer',
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
      check(service.previousResponseIds).deepEquals(<String?>[null]);
      expect(
        service.conversationHistories.single,
        equals(<Map<String, dynamic>>[
          <String, dynamic>{'role': 'assistant', 'content': 'prior answer'},
        ]),
      );
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

  group('mixed chat bound to another saved connection', () {
    const otherId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const otherPrincipal = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    final otherIdentity = HermesLocalDocumentTrustStore.connectionIdentity(
      endpointIdentity: HermesConfigController.connectionEndpoint(
        'https://other.example',
      )!,
      principalId: otherPrincipal,
    );

    Future<
      ({ProviderContainer container, _SwitchableHermesConfig config, List<String> asked})
    >
    bind({
      required bool accept,
      required String connectionIdentity,
    }) async {
      final asked = <String>[];
      late _SwitchableHermesConfig config;
      final container = ProviderContainer(
        overrides: [
          openWebUiDatabaseAccessProvider.overrideWith(_OpenDatabaseAccess.new),
          appDatabaseProvider.overrideWith((ref) {
            final database = AppDatabase(NativeDatabase.memory());
            ref.onDispose(() => unawaited(database.close()));
            return database;
          }),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          hermesConfigProvider.overrideWith(
            () => config = _SwitchableHermesConfig(
              HermesConnectionProfile(
                id: otherId,
                name: 'Other agent',
                baseUrl: 'https://other.example',
                documentTrustPrincipalId: otherPrincipal,
              ),
            ),
          ),
          hermesConnectionSwitchPromptProvider.overrideWithValue((name) async {
            asked.add(name);
            return accept;
          }),
        ],
      );
      container.read(hermesConfigProvider);
      final history = _assistant(
        'bound-assistant',
        metadata: <String, dynamic>{
          'hermesSessionId': 'other-session',
          kHermesConnectionIdentityMetadataKey: connectionIdentity,
          'hermesRunId': 'other-run',
        },
      );
      final conversation = _openWebUiConversation('bound-chat', <ChatMessage>[
        history,
      ]);
      await rememberMixedHermesMessageProvenanceForTest(
        container,
        conversation: conversation,
        assistantMessage: history,
      );
      container.read(activeConversationProvider.notifier).set(conversation);
      container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
        history,
      ]);
      return (container: container, config: config, asked: asked);
    }

    test('offers to switch, and switches when accepted', () async {
      final bound = await bind(
        accept: true,
        connectionIdentity: otherIdentity,
      );
      addTearDown(bound.container.dispose);

      await offerHermesConnectionSwitchForMixedChatForTest(bound.container);

      check(bound.asked).deepEquals(<String>['Other agent']);
      check(bound.config.switchedTo).deepEquals(<String>[otherId]);
    });

    test('keeps the active connection when declined', () async {
      final bound = await bind(
        accept: false,
        connectionIdentity: otherIdentity,
      );
      addTearDown(bound.container.dispose);

      await offerHermesConnectionSwitchForMixedChatForTest(bound.container);

      check(bound.asked).deepEquals(<String>['Other agent']);
      check(bound.config.switchedTo).isEmpty();
    });

    test('does not ask for an unknown or already active connection', () async {
      final unknown = await bind(
        accept: true,
        connectionIdentity: 'not-a-saved-connection',
      );
      addTearDown(unknown.container.dispose);
      await offerHermesConnectionSwitchForMixedChatForTest(unknown.container);
      check(unknown.asked).isEmpty();

      final active = await bind(
        accept: true,
        connectionIdentity: HermesLocalDocumentTrustStore.connectionIdentity(
          endpointIdentity: HermesConfigController.connectionEndpoint(
            'https://hermes.example',
          )!,
          principalId: _SwitchableHermesConfig.activePrincipal,
        ),
      );
      addTearDown(active.container.dispose);
      await offerHermesConnectionSwitchForMixedChatForTest(active.container);
      check(active.asked).isEmpty();
      check(active.config.switchedTo).isEmpty();
    });
  });
}

/// The active connection is the fixed `https://hermes.example` one; [other]
/// is a second saved connection reachable through [connectionForIdentity].
final class _SwitchableHermesConfig extends _FixedHermesConfig {
  _SwitchableHermesConfig(this.other);

  static const activePrincipal = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

  final HermesConnectionProfile other;
  final List<String> switchedTo = <String>[];

  @override
  String documentTrustPrincipalId() => activePrincipal;

  @override
  List<HermesConnectionProfile> get connections => [
    const HermesConnectionProfile(
      id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      name: 'Active agent',
      baseUrl: 'https://hermes.example',
      documentTrustPrincipalId: activePrincipal,
    ),
    other,
  ];

  @override
  HermesConnectionProfile? connectionForIdentity(String connectionIdentity) =>
      HermesConfigController.connectionIdentityFor(other) == connectionIdentity
      ? other
      : null;

  @override
  Future<void> setActiveConnection(String connectionId) async {
    switchedTo.add(connectionId);
  }
}
