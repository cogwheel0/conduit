import 'dart:async';

import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/sync/chat_locks.dart';
import 'package:conduit/core/sync/id_remapper.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit/features/direct_connections/services/direct_provider_adapter.dart';
import 'package:conduit/features/direct_connections/services/direct_run_registry.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

void main() {
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
      final profile = DirectConnectionProfile(
        id: 'profile-one',
        name: 'Local provider',
        adapterKey: kOllamaAdapterKey,
        baseUrl: 'http://localhost:11434',
      );
      final modelRegistry = DirectModelRegistry();
      final model = modelRegistry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model-one'),
      ]).single;
      final runRegistry = DirectRunRegistry();
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
            () => _FixedDirectProfilesController(profile),
          ),
          directModelRegistryProvider.overrideWithValue(modelRegistry),
          directRunRegistryProvider.overrideWithValue(runRegistry),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([_FailingDirectAdapter()]),
          ),
        ],
      );
      addTearDown(container.dispose);

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
      );
      final notifier = container.read(chatMessagesProvider.notifier);
      container.read(activeConversationProvider.notifier).set(conversation);
      notifier.setMessages([user, previousAssistant]);

      await expectLater(
        regenerateMessage(container, user.content, null),
        throwsA(isA<StateError>()),
      );

      final failed = container.read(chatMessagesProvider).last;
      expect(failed.id, previousAssistant.id);
      expect(failed.isStreaming, isFalse);
      expect(failed.error, isNotNull);
      expect(failed.versions, hasLength(1));
      expect(failed.versions.single.content, previousAssistant.content);
      expect(runRegistry.runFor(previousAssistant.id), isNull);
      expect(runRegistry.cancel(previousAssistant.id), isNull);
    },
  );

  test(
    'direct regeneration fails closed when a historical image is unavailable',
    () async {
      final profile = DirectConnectionProfile(
        id: 'profile-one',
        name: 'Local provider',
        adapterKey: kOllamaAdapterKey,
        baseUrl: 'http://localhost:11434',
      );
      final modelRegistry = DirectModelRegistry();
      final model = modelRegistry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'vision-model', isMultimodal: true),
      ]).single;
      final adapter = _RecordingDirectAdapter();
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
            () => _FixedDirectProfilesController(profile),
          ),
          directModelRegistryProvider.overrideWithValue(modelRegistry),
          directRunRegistryProvider.overrideWithValue(DirectRunRegistry()),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
        ],
      );
      addTearDown(container.dispose);

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
}
