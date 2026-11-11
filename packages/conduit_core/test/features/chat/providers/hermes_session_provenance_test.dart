import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit_core/features/hermes/services/hermes_copied_history_store.dart';
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
    int? lastEventId,
    void Function(int seq)? onSequence,
  }) => Stream<HermesRunEvent>.value(const HermesRunDone());
}

/// A REST copy whose first attachment starts a Responses chain: Hermes
/// answers it in a new session holding only that turn.
final class _ChainingHermesApi extends HermesApiService {
  final List<String?> previousResponseIds = [];
  final List<String> deletedSessions = [];

  /// When set, reading the copy's own turns fails.
  bool failReads = false;

  /// The copy's own turns, when not the default two.
  List<Map<String, dynamic>>? ownTurns;

  _ChainingHermesApi()
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          apiKey: 'key',
        ),
        dio: Dio(),
      );

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
    previousResponseIds.add(previousResponseId);
    return HermesResponseStream(
      events: Stream<HermesRunEvent>.value(const HermesRunDone()),
      sessionId: 'chain-2',
    );
  }

  @override
  Future<List<Map<String, dynamic>>> getSessionMessages(
    String id, {
    CancelToken? cancelToken,
  }) async => failReads
      ? throw StateError('unreachable')
      : id == 'copy-1'
      ? ownTurns ??
            const [
              {'id': 'own-1', 'role': 'user', 'content': 'Which shelf?'},
              {'id': 'own-2', 'role': 'assistant', 'content': 'The top one.'},
            ]
      : const [];

  @override
  Future<void> deleteSession(String id, {CancelToken? cancelToken}) async {
    deletedSessions.add(id);
  }
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

  ProviderContainer copyContainer(
    _ChainingHermesApi service,
    HermesCopiedHistoryStore copiedHistory,
  ) {
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
        hermesConfigProvider.overrideWith(_FixedHermesConfig.new),
        hermesApiServiceProvider.overrideWithValue(service),
        hermesCopiedHistoryStoreProvider.overrideWithValue(copiedHistory),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// A copy with its earlier messages saved, open in the chat, and a turn
  /// that moves it to a new Responses chain; answers its placeholder.
  /// [earlier] is a reply already in the chat, which the turn chains from.
  Future<ChatMessage> runCopyTurn(
    _ChainingHermesApi service,
    HermesCopiedHistoryStore copiedHistory,
    ProviderContainer container, {
    ChatMessage? earlier,
    Future<void> Function()? beforeTurn,
  }) async {
    await copiedHistory.save(
      connectionIdentity: _connectionIdentity(container),
      sessionId: 'copy-1',
      messages: const [
        {'id': 'earlier-1', 'role': 'user', 'content': 'Sort the books.'},
      ],
    );
    final placeholder = _assistant(
      'placeholder',
      streaming: true,
      metadata: const <String, dynamic>{'transport': kHermesTransport},
    );
    final shown = <ChatMessage>[?earlier, placeholder];
    container
        .read(activeConversationProvider.notifier)
        .set(
          markNativeHermesConversation(
            Conversation(
              id: 'local:hermes_copy-1',
              title: 'Copy',
              createdAt: DateTime.utc(2026, 7, 14),
              updatedAt: DateTime.utc(2026, 7, 14),
              messages: shown,
              metadata: const <String, dynamic>{
                'backend': 'hermes',
                'hermesSessionId': 'copy-1',
              },
            ),
          ),
        );
    container.read(chatMessagesProvider.notifier).setMessages(shown);
    await beforeTurn?.call();
    await dispatchHermesRunFromChatForTest(
      container,
      assistantMessageId: placeholder.id,
      assistantSeed: placeholder,
      input: 'Here is the shelf photo.',
      existingMessages: <ChatMessage>[?earlier],
      responseInput: HermesChatInput.text('Here is the shelf photo.'),
      // A first turn replays no history; a later one chains from [earlier].
      responseHistory: earlier == null ? const <Map<String, dynamic>>[] : null,
    );
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return container.read(chatMessagesProvider).last;
  }

  test('a copy moved to a Responses chain keeps earlier messages', () async {
    final service = _ChainingHermesApi();
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final copiedHistory = HermesCopiedHistoryStore(database);
    final container = copyContainer(service, copiedHistory);

    await runCopyTurn(service, copiedHistory, container);

    final carried = await copiedHistory.load(
      connectionIdentity: _connectionIdentity(container),
      sessionId: 'chain-2',
    );
    check(
      carried?.map((message) => message['content']).toList(),
    ).isNotNull().deepEquals([
      'Sort the books.',
      'Which shelf?',
      'The top one.',
    ]);
  });

  // When the copy's own turns could not be read, nothing was carried, and
  // the new session lost the earlier messages too.
  test('a copy whose own turns cannot be read still carries the earlier '
      'ones', () async {
    final service = _ChainingHermesApi()..failReads = true;
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final copiedHistory = HermesCopiedHistoryStore(database);
    final container = copyContainer(service, copiedHistory);

    await runCopyTurn(service, copiedHistory, container);

    final carried = await copiedHistory.load(
      connectionIdentity: _connectionIdentity(container),
      sessionId: 'chain-2',
    );
    check(
      carried?.map((message) => message['content']).toList(),
    ).isNotNull().deepEquals(['Sort the books.']);
  });

  // A carry that could not be saved was only logged: the chat moved to the
  // new session, which reopened without the copy's earlier messages.
  test('a copy whose earlier messages cannot follow it stays where they are',
      () async {
    final service = _ChainingHermesApi();
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final copiedHistory = HermesCopiedHistoryStore(database);
    final container = copyContainer(service, copiedHistory);

    final reply = await runCopyTurn(
      service,
      copiedHistory,
      container,
      // Saving them for the new session is the step that fails.
      beforeTurn: () => database.customStatement(
        'CREATE TRIGGER refuse_new_copy BEFORE INSERT ON app_cache '
        "BEGIN SELECT RAISE(ABORT, 'disk full'); END",
      ),
    );

    check(reply.error).isNotNull();
    check(service.deletedSessions).deepEquals(['chain-2']);
    check(
      container.read(activeConversationProvider)?.metadata['hermesSessionId'],
    ).equals('copy-1');
    check(
      await copiedHistory.load(
        connectionIdentity: _connectionIdentity(container),
        sessionId: 'copy-1',
      ),
    ).isNotNull();
  });

  // A copy's own message over the bound left nothing to keep, and the new
  // session reopened without even the earlier messages.
  test('a copy whose own turns are too large still carries the earlier ones',
      () async {
    final service = _ChainingHermesApi()
      ..ownTurns = [
        {'id': 'own-1', 'role': 'user', 'content': 'Which shelf?'},
        {
          'id': 'own-2',
          'role': 'assistant',
          'content': 'x' * (HermesCopiedHistoryStore.maxCopyBytes + 1),
        },
      ];
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final copiedHistory = HermesCopiedHistoryStore(database);
    final container = copyContainer(service, copiedHistory);

    final reply = await runCopyTurn(service, copiedHistory, container);

    check(reply.error).isNull();
    final carried = await copiedHistory.load(
      connectionIdentity: _connectionIdentity(container),
      sessionId: 'chain-2',
    );
    check(
      carried?.map((message) => message['content']).toList(),
    ).isNotNull().deepEquals(['Sort the books.']);
  });

  // A chained turn Hermes moved to another session (its own was deleted, or
  // compressed) left the copy's earlier messages under the old session.
  test('a copy whose chain Hermes moved keeps earlier messages', () async {
    final service = _ChainingHermesApi();
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final copiedHistory = HermesCopiedHistoryStore(database);
    final container = copyContainer(service, copiedHistory);

    await runCopyTurn(
      service,
      copiedHistory,
      container,
      earlier: _assistant(
        'earlier-assistant',
        content: 'The top one.',
        metadata: const <String, dynamic>{
          'transport': kHermesTransport,
          'hermesTransportMode': kHermesResponsesMode,
          'hermesResponseId': 'resp-earlier',
          'hermesSessionId': 'copy-1',
        },
      ),
    );

    check(service.previousResponseIds).deepEquals(<String?>['resp-earlier']);
    final carried = await copiedHistory.load(
      connectionIdentity: _connectionIdentity(container),
      sessionId: 'chain-2',
    );
    check(
      carried?.map((message) => message['content']).toList(),
    ).isNotNull().deepEquals([
      'Sort the books.',
      'Which shelf?',
      'The top one.',
    ]);
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

  // A reopened mixed chat finds its session by the stored binding, never by
  // the reply's server-held metadata alone.
  test('a reopened mixed chat names only its locally bound session', () async {
    final service = _RecordingHermesApi();
    final container = _container(service);
    addTearDown(container.dispose);
    ChatMessage reply(String id, String session) => _assistant(
      id,
      content: 'prior answer',
      metadata: <String, dynamic>{
        'hermesSessionId': session,
        kHermesConnectionIdentityMetadataKey: _connectionIdentity(container),
        'hermesRunId': 'run-$id',
      },
    );
    final trusted = reply('trusted-assistant', 'trusted-session');
    final conversation = _openWebUiConversation('trusted-chat', <ChatMessage>[
      trusted,
    ]);
    await rememberMixedHermesMessageProvenanceForTest(
      container,
      conversation: conversation,
      assistantMessage: trusted,
    );
    container.read(activeConversationProvider.notifier).set(conversation);
    container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
      trusted,
    ]);

    check(
      container.read(hermesTrustedMixedSessionProvider),
    ).equals('trusted-session');

    // A reply the server wrote, naming another session.
    container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
      trusted,
      reply('forged-assistant', 'forged-session'),
    ]);
    check(container.read(hermesTrustedMixedSessionProvider)).isNull();
  });

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
      ({
        ProviderContainer container,
        _SwitchableHermesConfig config,
        List<String> asked,
        _RecordingHermesApi service,
      })
    >
    bind({
      required bool accept,
      required String connectionIdentity,
    }) async {
      final asked = <String>[];
      late _SwitchableHermesConfig config;
      final service = _RecordingHermesApi();
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
          hermesApiServiceProvider.overrideWithValue(service),
          selectedModelProvider.overrideWith(_SelectedHermesModel.new),
          reviewerModeProvider.overrideWithValue(false),
          webSearchEnabledProvider.overrideWith(_NoWebSearch.new),
          imageGenerationEnabledProvider.overrideWith(_NoImageGeneration.new),
          codeInterpreterEnabledProvider.overrideWith(_NoCodeInterpreter.new),
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
      return (
        container: container,
        config: config,
        asked: asked,
        service: service,
      );
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

    test('does not send into a chat opened during the switch', () async {
      final bound = await bind(
        accept: true,
        connectionIdentity: otherIdentity,
      );
      addTearDown(bound.container.dispose);
      bound.config.onSwitch = () => bound.container
          .read(activeConversationProvider.notifier)
          .set(_openWebUiConversation('opened-chat', const <ChatMessage>[]));

      await check(
        sendMessageWithContainer(bound.container, 'for the bound chat', null),
      ).throws<StateError>();

      check(bound.config.switchedTo).deepEquals(<String>[otherId]);
      check(
        bound.container.read(activeConversationProvider)?.id,
      ).equals('opened-chat');
      check(
        bound.container.read(chatMessagesProvider).map((m) => m.content),
      ).not((it) => it.contains('for the bound chat'));
      check(bound.service.sessionIds).isEmpty();
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
  void Function()? onSwitch;

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
    onSwitch?.call();
  }
}

final class _SelectedHermesModel extends SelectedModel {
  @override
  Model build() => hermesSyntheticModel();
}

final class _NoWebSearch extends WebSearchEnabledNotifier {
  @override
  bool build() => false;
}

final class _NoImageGeneration extends ImageGenerationEnabledNotifier {
  @override
  bool build() => false;
}

final class _NoCodeInterpreter extends CodeInterpreterEnabledNotifier {
  @override
  bool build() => false;
}
