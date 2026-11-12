import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/chat/models/chat_context_attachment.dart';
import 'package:conduit_core/features/chat/providers/chat_model_choice.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/providers/context_attachments_provider.dart';
import 'package:conduit_core/features/chat/providers/openwebui_chat_prompt_provider.dart';
import 'package:conduit_core/features/chat/providers/reasoning_effort_provider.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/sync/sync_api_client.dart';
import 'package:conduit_core/testing.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// Two chats open in [ChatSessionScope]s at once share nothing a chat owns:
/// not the transcript, the composer, the model, the reasoning effort, the
/// terminal session or the Hermes navigation epoch.
void main() {
  late AppDatabase directDb;
  late bool previousWarn;

  setUpAll(() {
    previousWarn = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  tearDownAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousWarn;
  });

  setUp(() => directDb = AppDatabase(NativeDatabase.memory()));
  tearDown(() => directDb.close());

  ProviderContainer root() {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => null),
        directLocalDatabaseProvider.overrideWithValue(directDb),
        apiServiceProvider.overrideWithValue(null),
        socketServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  ChatSessionScope open(ProviderContainer parent) {
    final scope = ChatSessionScope.open(parent);
    addTearDown(scope.dispose);
    return scope;
  }

  test('each scope has its own conversation and transcript', () {
    final parent = root();
    final a = open(parent);
    final b = open(parent);

    a.container.read(activeConversationProvider.notifier).set(_chat('chat-a'));
    b.container.read(activeConversationProvider.notifier).set(_chat('chat-b'));

    expect(a.conversation?.id, 'chat-a');
    expect(b.conversation?.id, 'chat-b');
    expect(parent.read(activeConversationProvider), isNull);
    expect(a.messages.single.content, 'question in chat-a');
    expect(b.messages.single.content, 'question in chat-b');
    expect(parent.read(chatMessagesProvider), isEmpty);
  });

  // Riverpod stops rebuilding a derived provider whose only listeners belong
  // to a provider nobody listens to, until that provider is read again. What
  // a scope's transcript follows -- the account's sign-in, its API client
  // and socket -- must stay current between a host's reads.
  //
  // Here the root's session epoch has one listener that keeps it awake: the
  // scope's transcript. The weak listener below does not count, so the epoch
  // rebuilds on sign-in only while the scope holds its transcript; without
  // that hold, the transcript's listener is switched off after the read
  // above and the count stays at zero.
  test('a scope follows the account between its host\'s reads', () async {
    final signedIn = NotifierProvider<_Flag, bool>(_Flag.new);
    final parent = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => null),
        directLocalDatabaseProvider.overrideWithValue(directDb),
        apiServiceProvider.overrideWithValue(null),
        socketServiceProvider.overrideWithValue(null),
        isAuthenticatedProvider2.overrideWith((ref) => ref.watch(signedIn)),
      ],
    );
    addTearDown(parent.dispose);
    final scope = open(parent);
    expect(scope.messages, isEmpty);

    var sessions = 0;
    parent.listen<Object>(
      openWebUiAuthSessionEpochProvider,
      (_, _) => sessions++,
      weak: true,
    );
    parent.read(signedIn.notifier).value = true;
    await Future<void>.delayed(Duration.zero);

    expect(sessions, 1);
  });

  test('two answers stream at once without reaching each other', () {
    final parent = root();
    final a = open(parent);
    final b = open(parent);
    a.container.read(activeConversationProvider.notifier).set(_chat('chat-a'));
    b.container.read(activeConversationProvider.notifier).set(_chat('chat-b'));

    final notifierA = a.container.read(chatMessagesProvider.notifier);
    final notifierB = b.container.read(chatMessagesProvider.notifier);
    notifierA.addMessage(_streaming('answer-a'));
    notifierB.addMessage(_streaming('answer-b'));
    expect(a.isStreaming, isTrue);
    expect(b.isStreaming, isTrue);
    expect(parent.read(isChatStreamingProvider), isFalse);

    for (final word in ['alpha ', 'beta ', 'gamma']) {
      notifierA.replaceLastMessageContent('A: $word');
      notifierB.replaceLastMessageContent('B: $word');
    }
    notifierA.appendStatusUpdate(
      'answer-a',
      const ChatStatusUpdate(action: 'web_search', description: 'searching'),
    );
    notifierB.appendSourceReference(
      'answer-b',
      const ChatSourceReference(url: 'https://example.test/b', title: 'B'),
    );

    final answerA = a.messages.last;
    final answerB = b.messages.last;
    expect(answerA.id, 'answer-a');
    expect(answerA.content, 'A: gamma');
    expect(answerA.statusHistory.single.description, 'searching');
    expect(answerA.sources, isEmpty);
    expect(answerB.id, 'answer-b');
    expect(answerB.content, 'B: gamma');
    expect(answerB.statusHistory, isEmpty);
    expect(answerB.sources.single.url, 'https://example.test/b');

    notifierA.finishStreamingMessage('answer-a');
    expect(a.isStreaming, isFalse);
    expect(b.isStreaming, isTrue);
  });

  test('stopping one scope leaves the other streaming', () async {
    final parent = root();
    final a = open(parent);
    final b = open(parent);
    a.container.read(activeConversationProvider.notifier).set(_chat('chat-a'));
    b.container.read(activeConversationProvider.notifier).set(_chat('chat-b'));
    a.container
        .read(chatMessagesProvider.notifier)
        .addMessage(_streaming('answer-a'));
    b.container
        .read(chatMessagesProvider.notifier)
        .addMessage(_streaming('answer-b'));

    await a.container.read(stopGenerationSettledProvider)();

    expect(a.isStreaming, isFalse);
    expect(b.isStreaming, isTrue);
    expect(b.messages.last.isStreaming, isTrue);
  });

  test('the composer, model and reasoning are each scope\'s own', () {
    final parent = root();
    final a = open(parent);
    final b = open(parent);
    final modelA = _model('model-a');
    final modelB = _model('model-b', rejectsReasoning: true);

    a.container.read(selectedModelProvider.notifier).set(modelA);
    a.container.read(isManualModelSelectionProvider.notifier).set(true);
    b.container.read(selectedModelProvider.notifier).set(modelB);
    a.container.read(webSearchEnabledProvider.notifier).set(true);
    a.container.read(imageGenerationEnabledProvider.notifier).set(true);
    // Refused without an Open WebUI server, in that scope alone.
    b.container.read(codeInterpreterEnabledProvider.notifier).set(true);
    a.container.read(selectedToolIdsProvider.notifier).set(['tool-a']);
    b.container.read(selectedToolIdsProvider.notifier).set(['tool-b']);
    a.container.read(temporaryChatEnabledProvider.notifier).set(true);
    b.container.read(temporaryChatEnabledProvider.notifier).set(false);
    a.container.read(pendingFolderIdProvider.notifier).set('folder-a');
    b.container
        .read(contextAttachmentsProvider.notifier)
        .addKnowledge(fileId: 'kb-b', displayName: 'Knowledge B');
    a.container.read(pendingOpenWebUiChatSettingsProvider.notifier).replace(
      const {'temperature': 0.2},
    );

    expect(a.container.read(selectedModelProvider)?.id, 'model-a');
    expect(b.container.read(selectedModelProvider)?.id, 'model-b');
    expect(a.container.read(isManualModelSelectionProvider), isTrue);
    expect(b.container.read(isManualModelSelectionProvider), isFalse);
    expect(parent.read(selectedModelProvider), isNull);

    expect(a.container.read(webSearchEnabledProvider), isTrue);
    expect(b.container.read(webSearchEnabledProvider), isFalse);
    expect(a.container.read(imageGenerationEnabledProvider), isTrue);
    expect(b.container.read(imageGenerationEnabledProvider), isFalse);
    expect(b.container.read(codeInterpreterEnabledProvider), isFalse);
    expect(
      b.container.read(codeInterpreterBlockProvider),
      CodeInterpreterBlock.notOpenWebUi,
    );
    expect(a.container.read(selectedToolIdsProvider), ['tool-a']);
    expect(b.container.read(selectedToolIdsProvider), ['tool-b']);
    expect(parent.read(selectedToolIdsProvider), isEmpty);
    expect(a.container.read(temporaryChatEnabledProvider), isTrue);
    expect(b.container.read(temporaryChatEnabledProvider), isFalse);
    expect(a.container.read(pendingFolderIdProvider), 'folder-a');
    expect(b.container.read(pendingFolderIdProvider), isNull);
    expect(a.container.read(contextAttachmentsProvider), isEmpty);
    expect(
      b.container.read(contextAttachmentsProvider).single.type,
      ChatContextAttachmentType.knowledge,
    );
    expect(
      a.container.read(pendingOpenWebUiChatSettingsProvider)['temperature'],
      0.2,
    );
    expect(b.container.read(pendingOpenWebUiChatSettingsProvider), isEmpty);

    // Reasoning follows each scope's own model: B's refuses the parameter.
    expect(
      a.container.read(reasoningEffortPolicyProvider),
      ReasoningEffortPolicy.generic,
    );
    expect(
      b.container.read(reasoningEffortPolicyProvider),
      ReasoningEffortPolicy.unsupported,
    );
    expect(a.container.read(reasoningEffortAllowsCustomProvider), isTrue);
    expect(b.container.read(reasoningEffortAllowsCustomProvider), isFalse);
  });

  test('terminal session and selected terminal follow the scope', () {
    final parent = root();
    final a = open(parent);
    final b = open(parent);
    a.container.read(activeConversationProvider.notifier).set(_chat('chat-a'));
    b.container.read(activeConversationProvider.notifier).set(_chat('chat-b'));
    a.container.read(selectedTerminalIdProvider.notifier).set('terminal-a');

    expect(a.container.read(terminalSessionScopeIdProvider), 'chat-a');
    expect(b.container.read(terminalSessionScopeIdProvider), 'chat-b');
    expect(parent.read(terminalSessionScopeIdProvider), 'sidebar-terminal');
    expect(a.container.read(selectedTerminalIdProvider), 'terminal-a');
    expect(b.container.read(selectedTerminalIdProvider), isNull);
    expect(parent.read(selectedTerminalIdProvider), isNull);
  });

  // Regenerating an answer of a multi-model turn uses the model picked in
  // that chat since; a pick in another chat must not replace it.
  test('a model picked in one scope stays that chat\'s pick', () {
    final parent = root();
    final a = open(parent);
    final b = open(parent);
    a.container
        .read(chatModelPickProvider.notifier)
        .record(
          chatId: 'chat-a',
          modelId: 'model-a',
          promptIds: const {'question-chat-a'},
        );
    b.container
        .read(chatModelPickProvider.notifier)
        .record(
          chatId: 'chat-b',
          modelId: 'model-b',
          promptIds: const {'question-chat-b'},
        );

    expect(a.container.read(chatModelPickProvider)?.modelId, 'model-a');
    expect(b.container.read(chatModelPickProvider)?.modelId, 'model-b');
    expect(parent.read(chatModelPickProvider), isNull);
  });

  test('a coding agent and its controls are the scope\'s own', () {
    final parent = root();
    final a = open(parent);
    final b = open(parent);
    a.container.read(selectedModelProvider.notifier).set(_agent);
    b.container.read(selectedModelProvider.notifier).set(_model('model-b'));

    expect(a.container.read(activeChatUsesTerminalAgentProvider), isTrue);
    expect(b.container.read(activeChatUsesTerminalAgentProvider), isFalse);
    expect(parent.read(activeChatUsesTerminalAgentProvider), isFalse);
    expect(
      a.container.read(selectedModelControlStatesProvider).single.value,
      'medium',
    );
    expect(b.container.read(selectedModelControlStatesProvider), isEmpty);
    expect(parent.read(selectedModelControlStatesProvider), isEmpty);
  });

  test('opening a chat in one scope does not bump another\'s Hermes epoch', () {
    final parent = root();
    final a = open(parent);
    final b = open(parent);
    final epochB = b.container.read(hermesSessionNavigationEpochProvider);
    final epochRoot = parent.read(hermesSessionNavigationEpochProvider);

    a.container.read(activeConversationProvider.notifier).set(_chat('chat-a'));
    a.container.read(hermesActiveSessionProvider.notifier).set('session-a');

    expect(
      a.container.read(hermesSessionNavigationEpochProvider),
      greaterThan(epochB),
    );
    expect(b.container.read(hermesSessionNavigationEpochProvider), epochB);
    expect(parent.read(hermesSessionNavigationEpochProvider), epochRoot);
    expect(a.container.read(hermesActiveSessionProvider), 'session-a');
    expect(b.container.read(hermesActiveSessionProvider), isNull);
    expect(parent.read(hermesActiveSessionProvider), isNull);
  });

  test('an Open WebUI prompt waits in its own chat', () {
    final parent = root();
    final a = open(parent);
    final b = open(parent);
    final answers = <String, Object?>{};
    a.container
        .read(openWebUiLivePromptProvider.notifier)
        .handleSocketRequest(
          conversationId: 'chat-a',
          type: 'confirmation',
          data: const {'title': 'Run it?', 'message': 'In chat A'},
          acknowledge: (response) => answers['a'] = response,
        );
    b.container
        .read(openWebUiLivePromptProvider.notifier)
        .handleSocketRequest(
          conversationId: 'chat-b',
          type: 'confirmation',
          data: const {'title': 'Run it?', 'message': 'In chat B'},
          acknowledge: (response) => answers['b'] = response,
        );

    // B's prompt did not cancel A's, as one shared slot would have.
    final promptA = a.container.read(openWebUiLivePromptProvider)!;
    final promptB = b.container.read(openWebUiLivePromptProvider)!;
    expect(promptA.conversationId, 'chat-a');
    expect(promptB.conversationId, 'chat-b');
    expect(answers, isEmpty);
    expect(parent.read(openWebUiLivePromptProvider), isNull);

    a.container
        .read(openWebUiLivePromptProvider.notifier)
        .decide(promptA.prompt.identity, true);
    expect(answers, {'a': true});
    expect(b.container.read(openWebUiLivePromptProvider), isNotNull);

    // A scope closed with its prompt still waiting declines it.
    b.dispose();
    expect(answers, {'a': true, 'b': false});
  });

  test('a terminal file request belongs to its chat', () {
    final parent = root();
    final a = open(parent);
    final b = open(parent);
    a.container.read(terminalDisplayFileProvider.notifier).handleEvent(
      'terminal:display_file',
      const {'path': '/work/a.txt'},
    );

    expect(a.container.read(terminalDisplayFileProvider)?.path, '/work/a.txt');
    expect(b.container.read(terminalDisplayFileProvider), isNull);
    expect(parent.read(terminalDisplayFileProvider), isNull);
  });

  test('the registry lists open scopes until they are disposed', () {
    final parent = root();
    final registry = parent.read(chatSessionRegistryProvider);
    final a = ChatSessionScope.open(parent);
    final b = ChatSessionScope.open(parent);
    expect(registry.scopes, [a, b]);

    a.dispose();
    a.dispose();
    expect(a.isDisposed, isTrue);
    expect(registry.scopes, [b]);

    b.dispose();
    expect(registry.scopes, isEmpty);
    // The root is untouched by its scopes going away.
    expect(parent.read(chatMessagesProvider), isEmpty);
  });

  test('a scope follows its chat from a local id to the server id', () async {
    final serverDb = AppDatabase(NativeDatabase.memory());
    addTearDown(serverDb.close);
    final client = FakeSyncApiClient(FakeOpenWebUiServer());
    final parent = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(database: serverDb),
        directLocalDatabaseProvider.overrideWithValue(directDb),
        apiServiceProvider.overrideWith((ref) => null),
        reviewerModeProvider.overrideWithValue(false),
        syncApiClientProvider.overrideWith((ref) => client),
        isAuthenticatedProvider2.overrideWith((ref) => true),
      ],
    );
    addTearDown(parent.dispose);
    final a = open(parent);
    final b = open(parent);
    a.container
        .read(activeConversationProvider.notifier)
        .set(_openWebUiChat('local:pending'));
    b.container
        .read(activeConversationProvider.notifier)
        .set(_openWebUiChat('local:other'));

    await serverDb
        .into(serverDb.chats)
        .insert(
          ChatsCompanion.insert(
            id: 'local:pending',
            title: 'T',
            createdAt: 1,
            updatedAt: 1,
            dirty: const Value(true),
            bodySynced: const Value(true),
          ),
        );
    final remapper = parent
        .read(syncEngineProvider.notifier)
        .remapperForTesting!;
    final delivered = remapper.remapEvents.first;
    await remapper.remapChat(
      localId: 'local:pending',
      serverId: 'server-1',
      serverCreatedAt: 1,
      serverUpdatedAt: 1,
    );
    await delivered.timeout(const Duration(seconds: 2));
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (a.conversation?.id != 'server-1' &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(a.conversation?.id, 'server-1');
    expect(b.conversation?.id, 'local:other');
    expect(parent.read(activeConversationProvider), isNull);
  });
}

/// A chat kept on this device, so a test root with no Open WebUI account
/// still opens it.
Conversation _chat(String id) =>
    withChatStorageProvenance(_openWebUiChat(id), ChatStorageKind.directLocal);

Conversation _openWebUiChat(String id) => Conversation(
  id: id,
  title: id,
  createdAt: DateTime.utc(2026, 11, 8),
  updatedAt: DateTime.utc(2026, 11, 8),
  messages: [
    ChatMessage(
      id: 'question-$id',
      role: 'user',
      content: 'question in $id',
      timestamp: DateTime.utc(2026, 11, 8),
    ),
  ],
);

ChatMessage _streaming(String id) => ChatMessage(
  id: id,
  role: 'assistant',
  content: '',
  timestamp: DateTime.utc(2026, 11, 8),
  isStreaming: true,
);

/// A coding agent on a terminal, with one control of its own.
const _agent = Model(
  id: 'agent:terminal-a:codex:gpt-test',
  name: 'Codex',
  metadata: {
    'info': {
      'params': {
        'model_controls': {
          'effort': {
            'options': {
              'low': {'label': 'Low'},
              'medium': {'label': 'Medium'},
            },
            'default': 'medium',
          },
        },
      },
    },
  },
);

Model _model(String id, {bool rejectsReasoning = false}) => Model(
  id: id,
  name: id,
  capabilities: rejectsReasoning ? const {'reasoning_effort': false} : null,
);

class _Flag extends Notifier<bool> {
  @override
  bool build() => false;

  set value(bool next) => state = next;
}
