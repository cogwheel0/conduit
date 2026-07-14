import 'dart:async';

import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/chat_database_repository.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/sync/chat_locks.dart';
import 'package:conduit/core/sync/id_remapper.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/services/historical_message_regeneration.dart';
import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit/features/direct_connections/services/direct_provider_adapter.dart';
import 'package:conduit/features/direct_connections/services/direct_run_registry.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

final class _TestActiveConversationNotifier extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

final class _FakeApiService extends Fake implements ApiService {}

final class _FixedDirectProfilesController
    extends DirectConnectionProfilesController {
  _FixedDirectProfilesController(this.profile);

  final DirectConnectionProfile profile;

  @override
  Future<List<DirectConnectionProfile>> build() async => [profile];
}

final class _GatedDirectProfilesController
    extends DirectConnectionProfilesController {
  _GatedDirectProfilesController(this.profile);

  final DirectConnectionProfile profile;
  final Completer<void> started = Completer<void>();
  final Completer<List<DirectConnectionProfile>> gate =
      Completer<List<DirectConnectionProfile>>();

  @override
  Future<List<DirectConnectionProfile>> build() {
    if (!started.isCompleted) started.complete();
    return gate.future;
  }
}

final class _FailingDirectAdapter implements DirectProviderAdapter {
  @override
  String get key => kOllamaAdapterKey;

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async => const [];

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async =>
      const DirectConnectionProbe(reachable: true);

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) => DirectCompletionRun(
    id: 'failing-run',
    profileId: profile.id,
    remoteModelId: request.remoteModelId,
    events: Stream<DirectStreamEvent>.error(
      StateError('direct transport failed'),
    ),
    cancelToken: CancelToken(),
    done: Future<void>.value(),
  );
}

final class _RecordingDirectAdapter implements DirectProviderAdapter {
  var startCount = 0;

  @override
  String get key => kOllamaAdapterKey;

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async => const [];

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async =>
      const DirectConnectionProbe(reachable: true);

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) {
    startCount++;
    return DirectCompletionRun(
      id: 'recording-run',
      profileId: profile.id,
      remoteModelId: request.remoteModelId,
      events: Stream<DirectStreamEvent>.value(const DirectStreamDone()),
      cancelToken: CancelToken(),
      done: Future<void>.value(),
    );
  }
}

final class _ControlledDirectRun {
  _ControlledDirectRun({
    required this.id,
    required String profileId,
    required String remoteModelId,
  }) {
    run = DirectCompletionRun(
      id: id,
      profileId: profileId,
      remoteModelId: remoteModelId,
      events: _events.stream,
      cancelToken: cancelToken,
      done: _done.future,
    );
  }

  final String id;
  final CancelToken cancelToken = CancelToken();
  final StreamController<DirectStreamEvent> _events =
      StreamController<DirectStreamEvent>(sync: true);
  final Completer<void> _done = Completer<void>();
  late final DirectCompletionRun run;

  void add(DirectStreamEvent event) => _events.add(event);

  void fail(Object error) => _events.addError(error);

  Future<void> close() async {
    await _events.close();
    if (!_done.isCompleted) _done.complete();
  }
}

final class _ControlledDirectAdapter implements DirectProviderAdapter {
  final List<_ControlledDirectRun> runs = [];
  final StreamController<_ControlledDirectRun> _started =
      StreamController<_ControlledDirectRun>.broadcast(sync: true);

  @override
  String get key => kOllamaAdapterKey;

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async => const [];

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async =>
      const DirectConnectionProbe(reachable: true);

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) {
    final controlled = _ControlledDirectRun(
      id: 'controlled-${runs.length + 1}',
      profileId: profile.id,
      remoteModelId: request.remoteModelId,
    );
    runs.add(controlled);
    _started.add(controlled);
    return controlled.run;
  }

  Future<_ControlledDirectRun> nextRun() => _started.stream.first;

  Future<void> dispose() => _started.close();
}

({
  ProviderContainer container,
  DirectConnectionProfile profile,
  Model model,
  DirectRunRegistry runRegistry,
})
_makeDirectRegenerationContainer({
  required DirectProviderAdapter adapter,
  String remoteModelId = 'model-one',
  bool isMultimodal = false,
  DirectConnectionProfilesController Function(DirectConnectionProfile)?
  profilesController,
  DirectRunRegistry? runRegistry,
  List<Override> extraOverrides = const <Override>[],
}) {
  final profile = DirectConnectionProfile(
    id: 'profile-one',
    name: 'Local provider',
    adapterKey: kOllamaAdapterKey,
    baseUrl: 'http://localhost:11434',
  );
  final modelRegistry = DirectModelRegistry();
  final model = modelRegistry.replaceProfileModels(profile, [
    DirectRemoteModel(id: remoteModelId, isMultimodal: isMultimodal),
  ]).single;
  final effectiveRunRegistry = runRegistry ?? DirectRunRegistry();
  final container = ProviderContainer(
    overrides: [
      activeConversationProvider.overrideWith(
        _TestActiveConversationNotifier.new,
      ),
      selectedModelProvider.overrideWithValue(model),
      reviewerModeProvider.overrideWithValue(false),
      apiServiceProvider.overrideWithValue(null),
      socketServiceProvider.overrideWithValue(null),
      directConnectionProfilesProvider.overrideWith(
        () =>
            profilesController?.call(profile) ??
            _FixedDirectProfilesController(profile),
      ),
      directModelRegistryProvider.overrideWithValue(modelRegistry),
      directRunRegistryProvider.overrideWithValue(effectiveRunRegistry),
      directProviderAdapterRegistryProvider.overrideWithValue(
        DirectProviderAdapterRegistry([adapter]),
      ),
      ...extraOverrides,
    ],
  );
  addTearDown(container.dispose);
  return (
    container: container,
    profile: profile,
    model: model,
    runRegistry: effectiveRunRegistry,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('direct-local regeneration rejects a non-direct model', () async {
    const openWebUiModel = Model(id: 'remote-model', name: 'Remote model');
    final container = ProviderContainer(
      overrides: [
        activeConversationProvider.overrideWith(
          _TestActiveConversationNotifier.new,
        ),
        selectedModelProvider.overrideWithValue(openWebUiModel),
        reviewerModeProvider.overrideWithValue(false),
        apiServiceProvider.overrideWithValue(_FakeApiService()),
      ],
    );
    addTearDown(container.dispose);
    final now = DateTime.utc(2026, 7, 11);
    container
        .read(activeConversationProvider.notifier)
        .set(
          Conversation(
            id: 'direct-local:regenerate-guard',
            title: 'Local direct chat',
            createdAt: now,
            updatedAt: now,
            metadata: const {'conduit.chatStorageKind': 'directLocal'},
          ),
        );

    await expectLater(
      regenerateMessage(container, 'retry', null),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'direct regeneration cannot retarget after route resolution await',
    () async {
      late _GatedDirectProfilesController profiles;
      final adapter = _RecordingDirectAdapter();
      final setup = _makeDirectRegenerationContainer(
        adapter: adapter,
        profilesController: (profile) =>
            profiles = _GatedDirectProfilesController(profile),
      );
      final container = setup.container;
      final model = setup.model;

      final now = DateTime.utc(2026, 7, 13);
      final userA = ChatMessage(
        id: 'user-a',
        role: 'user',
        content: 'Regenerate A',
        timestamp: now,
      );
      final assistantA = ChatMessage(
        id: 'assistant-a',
        role: 'assistant',
        content: 'Old A',
        timestamp: now,
        model: model.id,
      );
      final conversationA = Conversation(
        id: 'direct-local:a',
        title: 'A',
        createdAt: now,
        updatedAt: now,
        messages: [userA, assistantA],
        metadata: const {'conduit.chatStorageKind': 'directLocal'},
      );
      final messagesB = <ChatMessage>[
        ChatMessage(
          id: 'assistant-b',
          role: 'assistant',
          content: 'B remains',
          timestamp: now,
          model: model.id,
          isStreaming: true,
        ),
      ];
      final conversationB = Conversation(
        id: 'direct-local:b',
        title: 'B',
        createdAt: now,
        updatedAt: now,
        messages: messagesB,
        metadata: const {'conduit.chatStorageKind': 'directLocal'},
      );
      container.read(activeConversationProvider.notifier).set(conversationA);
      container
          .read(chatMessagesProvider.notifier)
          .setMessages(conversationA.messages);

      final regeneration = regenerateMessage(container, userA.content, null);
      await profiles.started.future.timeout(const Duration(seconds: 1));
      container.read(activeConversationProvider.notifier).set(conversationB);
      container.read(chatMessagesProvider.notifier).setMessages(messagesB);
      final visibleB = container.read(chatMessagesProvider);
      profiles.gate.complete([setup.profile]);

      await expectLater(regeneration, throwsA(isA<StateError>()));
      expect(identical(container.read(chatMessagesProvider), visibleB), isTrue);
      expect(container.read(chatMessagesProvider).single.isStreaming, isTrue);
      expect(adapter.startCount, 0);
      container.read(chatMessagesProvider.notifier).setMessages([
        messagesB.single.copyWith(isStreaming: false),
      ]);
    },
  );

  test('direct completion owner follows chat id remaps', () async {
    final remaps = StreamController<RemapEvent>.broadcast(sync: true);
    addTearDown(remaps.close);
    var ownerId = 'local:one';
    final subscription = trackDirectConversationRemaps(
      events: remaps.stream,
      currentId: () => ownerId,
      setId: (id) => ownerId = id,
    );
    addTearDown(subscription.cancel);

    remaps.add(
      const RemapEvent(
        fromId: 'local:one',
        toId: 'server-one',
        entityKind: 'chat',
      ),
    );
    expect(ownerId, 'server-one');

    remaps.add(
      const RemapEvent(
        fromId: 'server-one',
        toId: 'folder-one',
        entityKind: 'folder',
      ),
    );
    expect(ownerId, 'server-one');
  });

  test(
    'direct completion retries persistence under a remapped id lock',
    () async {
      final resolvedIds = <String>[];
      String? persistedId;

      final currentId = await persistWithResolvedDirectConversationOwner(
        locks: ChatLocks(),
        recordedChatId: 'local:one',
        resolveCurrentId: (recordedId) async {
          resolvedIds.add(recordedId);
          return recordedId == 'local:one' ? 'server-one' : recordedId;
        },
        persist: (resolvedId) async => persistedId = resolvedId,
      );

      expect(resolvedIds, ['local:one', 'server-one']);
      expect(currentId, 'server-one');
      expect(persistedId, 'server-one');
    },
  );

  test(
    'failed direct regeneration finalizes the reused assistant with error',
    () async {
      final runRegistry = DirectRunRegistry();
      final setup = _makeDirectRegenerationContainer(
        adapter: _FailingDirectAdapter(),
        runRegistry: runRegistry,
      );
      final container = setup.container;
      final model = setup.model;

      final now = DateTime.utc(2026, 7, 11);
      final user = ChatMessage(
        id: 'user-one',
        role: 'user',
        content: 'Try again',
        timestamp: now,
      );
      final previousAssistant = ChatMessage(
        id: 'assistant-one',
        role: 'assistant',
        content: 'Previous answer',
        timestamp: now,
        model: model.id,
      );
      final conversation = Conversation(
        id: 'local:direct-regeneration',
        title: 'Direct chat',
        createdAt: now,
        updatedAt: now,
        messages: [user, previousAssistant],
        metadata: const {'backend': kDirectTransport},
      );
      final notifier = container.read(chatMessagesProvider.notifier);
      container.read(activeConversationProvider.notifier).set(conversation);
      notifier.setMessages([user, previousAssistant]);

      await expectLater(
        regenerateMessage(container, user.content, null),
        throwsA(
          isA<DirectProviderException>().having(
            (error) => error.message,
            'message',
            'The provider request failed.',
          ),
        ),
      );

      final failed = container.read(chatMessagesProvider).last;
      expect(failed.id, previousAssistant.id);
      expect(failed.isStreaming, isFalse);
      expect(failed.error, isNotNull);
      expect(failed.versions, hasLength(1));
      expect(failed.versions.single.content, previousAssistant.content);
      final key = (
        ownerConversationId: chatMutationOwnerScopeForConversation(
          conversation,
        ),
        assistantMessageId: previousAssistant.id,
      );
      expect(runRegistry.runFor(key), isNull);
      expect(runRegistry.cancel(key), isNull);
    },
  );

  test(
    'direct regeneration fails closed when a historical image is unavailable',
    () async {
      final adapter = _RecordingDirectAdapter();
      final setup = _makeDirectRegenerationContainer(
        adapter: adapter,
        remoteModelId: 'vision-model',
        isMultimodal: true,
      );
      final container = setup.container;
      final model = setup.model;

      final now = DateTime.utc(2026, 7, 11);
      final user = ChatMessage(
        id: 'user-with-image',
        role: 'user',
        content: 'Describe this image',
        timestamp: now,
        attachmentIds: const ['openwebui-image'],
        files: const [
          {
            'type': 'image',
            'id': 'openwebui-image',
            'url': 'openwebui-image',
            'content_type': 'image/png',
          },
        ],
      );
      final previousAssistant = ChatMessage(
        id: 'assistant-with-image',
        role: 'assistant',
        content: 'Previous image description',
        timestamp: now,
        model: model.id,
      );
      final conversation = Conversation(
        id: 'local:direct-image-regeneration',
        title: 'Direct image chat',
        createdAt: now,
        updatedAt: now,
        messages: [user, previousAssistant],
        metadata: const {'backend': kDirectTransport},
      );
      container.read(activeConversationProvider.notifier).set(conversation);
      container.read(chatMessagesProvider.notifier).setMessages([
        user,
        previousAssistant,
      ]);

      await expectLater(
        regenerateMessage(container, user.content, null),
        throwsA(
          isA<DirectChatInputException>().having(
            (error) => error.message,
            'message',
            'This direct model does not support this attachment.',
          ),
        ),
      );

      expect(adapter.startCount, 0);
      final failed = container.read(chatMessagesProvider).last;
      expect(failed.id, previousAssistant.id);
      expect(failed.isStreaming, isFalse);
      expect(
        failed.error?.content,
        'This direct model does not support this attachment.',
      );
      expect(failed.versions, hasLength(1));
      expect(failed.versions.single.content, previousAssistant.content);
    },
  );

  test(
    'stopping a reasoning-only direct run settles its reasoning block',
    () async {
      final adapter = _ControlledDirectAdapter();
      addTearDown(adapter.dispose);
      final setup = _makeDirectRegenerationContainer(adapter: adapter);
      final container = setup.container;
      final model = setup.model;

      final now = DateTime.utc(2026, 7, 13);
      final user = ChatMessage(
        id: 'user-one',
        role: 'user',
        content: 'Think carefully',
        timestamp: now,
      );
      final previousAssistant = ChatMessage(
        id: 'assistant-one',
        role: 'assistant',
        content: 'Previous answer',
        timestamp: now,
        model: model.id,
      );
      final conversation = Conversation(
        id: 'local:direct-stop-reasoning',
        title: 'Direct chat',
        createdAt: now,
        updatedAt: now,
        messages: [user, previousAssistant],
        metadata: const {'backend': kDirectTransport},
      );
      container.read(activeConversationProvider.notifier).set(conversation);
      container.read(chatMessagesProvider.notifier).setMessages([
        user,
        previousAssistant,
      ]);

      final started = adapter.nextRun();
      final regeneration = regenerateMessage(container, user.content, null);
      final run = await started.timeout(const Duration(seconds: 1));
      run.add(const DirectReasoningDelta('A partial thought'));
      await Future<void>.delayed(Duration.zero);

      container.read(stopGenerationProvider)();
      await run.close();
      await regeneration.timeout(const Duration(seconds: 1));

      final stopped = container.read(chatMessagesProvider).last;
      expect(stopped.isStreaming, isFalse);
      expect(stopped.content, contains('done="true"'));
      expect(stopped.content, isNot(contains('done="false"')));
    },
  );

  test(
    'stop resolves the direct run by message when active owner changed',
    () async {
      final adapter = _ControlledDirectAdapter();
      addTearDown(adapter.dispose);
      final setup = _makeDirectRegenerationContainer(adapter: adapter);
      final container = setup.container;
      final model = setup.model;
      final now = DateTime.utc(2026, 7, 14);
      final user = ChatMessage(
        id: 'identity-user',
        role: 'user',
        content: 'Keep generating',
        timestamp: now,
      );
      final previousAssistant = ChatMessage(
        id: 'identity-assistant',
        role: 'assistant',
        content: 'Previous answer',
        timestamp: now,
        model: model.id,
      );
      final owner = Conversation(
        id: 'local:direct-owner-a',
        title: 'Owner A',
        createdAt: now,
        updatedAt: now,
        messages: [user, previousAssistant],
        metadata: const {'backend': kDirectTransport},
      );
      container.read(activeConversationProvider.notifier).set(owner);
      container.read(chatMessagesProvider.notifier).setMessages(owner.messages);

      final started = adapter.nextRun();
      final regeneration = regenerateMessage(container, user.content, null);
      final run = await started.timeout(const Duration(seconds: 1));
      run.add(const DirectContentDelta('Partial answer'));
      await Future<void>.delayed(Duration.zero);
      final staleVisibleRow = container.read(chatMessagesProvider).last;

      final other = Conversation(
        id: 'local:direct-owner-b',
        title: 'Owner B',
        createdAt: now,
        updatedAt: now,
        metadata: const {'backend': kDirectTransport},
      );
      container.read(activeConversationProvider.notifier).set(other);
      container.read(chatMessagesProvider.notifier).setMessages([
        staleVisibleRow,
      ]);

      container.read(stopGenerationProvider)();

      expect(run.cancelToken.isCancelled, isTrue);
      expect(container.read(chatMessagesProvider).single.isStreaming, isFalse);
      await run.close();
      await regeneration.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'a cancelled direct generation cannot finalize its same-id replacement',
    () async {
      final adapter = _ControlledDirectAdapter();
      addTearDown(adapter.dispose);
      final setup = _makeDirectRegenerationContainer(adapter: adapter);
      final container = setup.container;
      final model = setup.model;

      final now = DateTime.utc(2026, 7, 13);
      final user = ChatMessage(
        id: 'user-one',
        role: 'user',
        content: 'Try again',
        timestamp: now,
      );
      final previousAssistant = ChatMessage(
        id: 'assistant-one',
        role: 'assistant',
        content: 'Previous answer',
        timestamp: now,
        model: model.id,
      );
      final conversation = Conversation(
        id: 'local:direct-generation-race',
        title: 'Direct chat',
        createdAt: now,
        updatedAt: now,
        messages: [user, previousAssistant],
        metadata: const {'backend': kDirectTransport},
      );
      container.read(activeConversationProvider.notifier).set(conversation);
      container.read(chatMessagesProvider.notifier).setMessages([
        user,
        previousAssistant,
      ]);

      final firstStarted = adapter.nextRun();
      final firstRegeneration = regenerateMessage(
        container,
        user.content,
        null,
      );
      final first = await firstStarted.timeout(const Duration(seconds: 1));
      first.add(const DirectContentDelta('stale response'));
      await Future<void>.delayed(Duration.zero);
      container.read(stopGenerationProvider)();

      final secondStarted = adapter.nextRun();
      final secondRegeneration = regenerateMessage(
        container,
        user.content,
        null,
      );
      final second = await secondStarted.timeout(const Duration(seconds: 1));
      second.add(const DirectContentDelta('replacement response'));
      await Future<void>.delayed(Duration.zero);

      first.add(const DirectContentDelta(' from the old run'));
      first.add(const DirectStreamDone());
      await first.close();
      await firstRegeneration.timeout(const Duration(seconds: 1));

      second.add(const DirectContentDelta(' completed'));
      second.add(const DirectStreamDone());
      await second.close();
      await secondRegeneration.timeout(const Duration(seconds: 1));

      final completed = container.read(chatMessagesProvider).last;
      expect(completed.isStreaming, isFalse);
      expect(completed.content, 'replacement response completed');
      expect(completed.content, isNot(contains('old run')));
    },
  );

  test(
    'late historical failure for A cannot cancel or restore over streaming B',
    () async {
      final adapter = _ControlledDirectAdapter();
      addTearDown(adapter.dispose);
      final openWebUiDatabase = AppDatabase(NativeDatabase.memory());
      addTearDown(openWebUiDatabase.close);
      final setup = _makeDirectRegenerationContainer(
        adapter: adapter,
        extraOverrides: [
          appDatabaseProvider.overrideWithValue(openWebUiDatabase),
        ],
      );
      final container = setup.container;
      final model = setup.model;
      container.read(openWebUiDatabaseAccessProvider.notifier).open();

      final now = DateTime.utc(2026, 7, 13);
      ChatMessage user(String id, String content) =>
          ChatMessage(id: id, role: 'user', content: content, timestamp: now);
      ChatMessage assistant(
        String content, {
        List<Map<String, dynamic>>? files,
      }) => ChatMessage(
        id: 'assistant-collision',
        role: 'assistant',
        content: content,
        timestamp: now,
        model: model.id,
        files: files,
      );
      Conversation conversation(
        String id,
        ChatMessage userMessage,
        ChatMessage assistantMessage,
        ChatStorageKind storage,
      ) => withChatStorageProvenance(
        Conversation(
          id: id,
          title: id,
          createdAt: now,
          updatedAt: now,
          messages: [userMessage, assistantMessage],
        ),
        storage,
      );

      final userA = user('user-a', 'Regenerate A');
      final assistantA = assistant(
        'Original A',
        files: const <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'image',
            'url': 'data:image/png;base64,AA==',
          },
        ],
      );
      final conversationA = conversation(
        'local:conversation-collision',
        userA,
        assistantA,
        ChatStorageKind.openWebUi,
      );
      container.read(activeConversationProvider.notifier).set(conversationA);
      container.read(chatMessagesProvider.notifier).setMessages([
        userA,
        assistantA,
      ]);
      container.read(imageGenerationEnabledProvider.notifier).set(false);
      container.read(temporaryChatEnabledProvider.notifier).set(true);

      final aStarted = adapter.nextRun();
      final regenerationA = regenerateHistoricalMessageById(
        container,
        assistantA.id,
      );
      final runA = await aStarted.timeout(const Duration(seconds: 1));
      // Image replay is a request-scoped OpenWebUI option. Direct transport
      // must never mutate the persisted/global composer preference.
      expect(container.read(imageGenerationEnabledProvider), isFalse);
      final aFailure = expectLater(
        regenerationA,
        throwsA(
          isA<DirectProviderException>().having(
            (error) => error.message,
            'message',
            'The provider request failed.',
          ),
        ),
      );

      final userB = user('user-b', 'Regenerate B');
      final assistantB = assistant('Original B');
      final conversationB = conversation(
        'local:conversation-collision',
        userB,
        assistantB,
        ChatStorageKind.directLocal,
      );
      container.read(activeConversationProvider.notifier).set(conversationB);
      container.read(chatMessagesProvider.notifier).setMessages([
        userB,
        assistantB,
      ]);
      container.read(imageGenerationEnabledProvider.notifier).set(false);

      final bStarted = adapter.nextRun();
      final regenerationB = regenerateMessage(container, userB.content, null);
      final runB = await bStarted.timeout(const Duration(seconds: 1));
      runB.add(const DirectContentDelta('B is still streaming'));
      await Future<void>.delayed(Duration.zero);
      final visibleBeforeAFailure = container.read(chatMessagesProvider);

      runA.fail(StateError('late failure from A'));
      await runA.close();
      await aFailure.timeout(const Duration(seconds: 1));

      final activeAfterAFailure = container.read(activeConversationProvider);
      expect(activeAfterAFailure?.id, conversationB.id);
      expect(
        chatStorageKindOf(activeAfterAFailure),
        ChatStorageKind.directLocal,
      );
      final visibleB = container.read(chatMessagesProvider);
      expect(visibleB, same(visibleBeforeAFailure));
      expect(visibleB.map((message) => message.id), [userB.id, assistantB.id]);
      expect(visibleB.last.isStreaming, isTrue);
      expect(visibleB.last.error, isNull);
      expect(container.read(imageGenerationEnabledProvider), isFalse);

      runB.add(const DirectStreamDone());
      await runB.close();
      await regenerationB.timeout(const Duration(seconds: 1));
    },
  );
}
