import 'dart:async';
import 'dart:convert';

import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/chat_database_repository.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit/features/direct_connections/services/direct_provider_adapter.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ActiveConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

final class _Profiles extends DirectConnectionProfilesController {
  _Profiles(this.profile);

  final DirectConnectionProfile profile;

  @override
  Future<List<DirectConnectionProfile>> build() async => [profile];
}

final class _Adapter implements DirectProviderAdapter {
  var startCalls = 0;

  @override
  String get key => 'test-adapter';

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async => [DirectRemoteModel(id: 'model')];

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async =>
      const DirectConnectionProbe(reachable: true);

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) {
    startCalls++;
    return DirectCompletionRun(
      id: 'run',
      profileId: profile.id,
      remoteModelId: request.remoteModelId,
      events: Stream<DirectStreamEvent>.fromIterable(const [
        DirectReasoningDelta('Review the prior context.'),
        DirectContentDelta('Follow-up answer'),
        DirectStreamDone(),
      ]),
      cancelToken: CancelToken(),
      done: Future<void>.value(),
    );
  }
}

final class _DeferredAttachmentApi extends ApiService {
  _DeferredAttachmentApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://example.test',
        ),
        workerManager: WorkerManager(),
      );

  final firstInfoStarted = Completer<void>();
  final firstInfoGate = Completer<void>();
  var getFileInfoCalls = 0;

  @override
  Future<Map<String, dynamic>> getFileInfo(String fileId) async {
    getFileInfoCalls++;
    if (getFileInfoCalls == 1) {
      firstInfoStarted.complete();
      await firstInfoGate.future;
    }
    return const {
      'meta': {'content_type': 'image/png'},
    };
  }

  @override
  Future<String> getFileContent(String fileId, {int? maxBytes}) async => 'AQID';
}

Future<Conversation> _seedDirectConversation({
  required AppDatabase db,
  required String chatId,
  required String modelId,
  required String suffix,
}) async {
  final now = DateTime.utc(2026, 7, 11);
  final user = ChatMessage(
    id: 'user-$suffix',
    role: 'user',
    content: 'Question $suffix',
    timestamp: now,
    metadata: {
      'parentId': null,
      'childrenIds': <String>['assistant-$suffix'],
    },
  );
  final assistant = ChatMessage(
    id: 'assistant-$suffix',
    role: 'assistant',
    content: 'Answer $suffix',
    timestamp: now,
    model: modelId,
    metadata: {
      'parentId': user.id,
      'childrenIds': const <String>[],
      'transport': 'direct',
    },
  );
  final rows = ChatBlobMapper.blobToRows(
    chatId: chatId,
    blob: {
      'title': 'Chat $suffix',
      'models': [modelId],
      'history': {
        'currentId': assistant.id,
        'messages': {
          user.id: {
            'id': user.id,
            'parentId': null,
            'childrenIds': [assistant.id],
            'role': 'user',
            'content': user.content,
            'timestamp': 1,
          },
          assistant.id: {
            'id': assistant.id,
            'parentId': user.id,
            'childrenIds': <String>[],
            'role': 'assistant',
            'content': assistant.content,
            'model': modelId,
            'timestamp': 2,
          },
        },
      },
    },
    title: 'Chat $suffix',
    createdAt: 1,
    updatedAt: 2,
  );
  await db.chatsDao.upsertLocalOnlyChat(rows: rows);
  return withChatStorageProvenance(
    Conversation(
      id: chatId,
      title: 'Chat $suffix',
      createdAt: now,
      updatedAt: now,
      model: modelId,
      messages: [user, assistant],
    ),
    ChatStorageKind.directLocal,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'direct follow-up settles reasoning and preserves linked history on reload',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: 'test-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final registry = DirectModelRegistry();
      final model = registry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model', isMultimodal: true),
      ]).single;
      final now = DateTime.utc(2026, 7, 11);
      final firstUser = ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'First question',
        timestamp: now,
        metadata: const {
          'parentId': null,
          'childrenIds': <String>['assistant-1'],
        },
      );
      final firstAssistant = ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: 'First answer',
        timestamp: now,
        model: model.id,
        metadata: const {
          'parentId': 'user-1',
          'childrenIds': <String>[],
          'transport': 'direct',
        },
      );
      const chatId = 'direct-local:history';
      final rows = ChatBlobMapper.blobToRows(
        chatId: chatId,
        blob: {
          'title': 'History',
          'models': [model.id],
          'history': {
            'currentId': firstAssistant.id,
            'messages': {
              firstUser.id: {
                'id': firstUser.id,
                'parentId': null,
                'childrenIds': [firstAssistant.id],
                'role': 'user',
                'content': firstUser.content,
                'timestamp': 1,
              },
              firstAssistant.id: {
                'id': firstAssistant.id,
                'parentId': firstUser.id,
                'childrenIds': <String>[],
                'role': 'assistant',
                'content': firstAssistant.content,
                'model': model.id,
                'timestamp': 2,
              },
            },
          },
        },
        title: 'History',
        createdAt: 1,
        updatedAt: 2,
      );
      await db.chatsDao.upsertLocalOnlyChat(rows: rows);
      final active = withChatStorageProvenance(
        Conversation(
          id: chatId,
          title: 'History',
          createdAt: now,
          updatedAt: now,
          model: model.id,
          messages: [firstUser, firstAssistant],
        ),
        ChatStorageKind.directLocal,
      );
      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(null),
          directLocalDatabaseProvider.overrideWithValue(db),
          directModelRegistryProvider.overrideWithValue(registry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([_Adapter()]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeConversationProvider.notifier).set(active);
      container
          .read(chatMessagesProvider.notifier)
          .setMessages(active.messages);

      const image = 'data:image/png;base64,AQID';
      await sendMessageWithContainer(container, 'Follow-up', const [image]);

      final completedAssistant = container
          .read(chatMessagesProvider)
          .lastWhere((message) => message.role == 'assistant');
      expect(completedAssistant.isStreaming, isFalse);
      expect(completedAssistant.content, contains('done="true"'));
      expect(completedAssistant.content, isNot(contains('done="false"')));

      final messageRows = await db.messagesDao.getForChat(chatId);
      final secondUser = messageRows.singleWhere(
        (row) => row.role == 'user' && row.id != firstUser.id,
      );
      final persistedParent = messageRows.singleWhere(
        (row) => row.id == firstAssistant.id,
      );
      final parentPayload =
          jsonDecode(persistedParent.payload) as Map<String, dynamic>;
      expect(parentPayload['childrenIds'], contains(secondUser.id));

      final inMemoryParent = container
          .read(chatMessagesProvider)
          .singleWhere((message) => message.id == firstAssistant.id);
      expect(inMemoryParent.metadata?['childrenIds'], contains(secondUser.id));

      final reloaded = await container
          .read(chatDatabaseRepositoryProvider)
          .loadConversation(chatId, preferred: ChatStorageKind.directLocal);
      expect(reloaded, isNotNull);
      final reloadedUser = reloaded!.conversation.messages.singleWhere(
        (message) => message.id == secondUser.id,
      );
      expect(reloadedUser.files, const [
        {'type': 'image', 'url': image},
      ]);
      final reloadedAssistant = reloaded.conversation.messages.singleWhere(
        (message) => message.id == completedAssistant.id,
      );
      expect(reloadedAssistant.isStreaming, isFalse);
      expect(reloadedAssistant.content, contains('done="true"'));
      expect(reloadedAssistant.content, isNot(contains('done="false"')));
    },
  );

  test(
    'navigation during direct attachment preflight cannot write into the new chat',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final profile = DirectConnectionProfile(
        id: 'profile',
        name: 'Provider',
        adapterKey: 'test-adapter',
        baseUrl: 'http://localhost:11434',
      );
      final registry = DirectModelRegistry();
      final model = registry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model', isMultimodal: true),
      ]).single;
      final adapter = _Adapter();
      final api = _DeferredAttachmentApi();
      final chatA = await _seedDirectConversation(
        db: db,
        chatId: 'direct-local:chat-a',
        modelId: model.id,
        suffix: 'a',
      );
      final chatB = await _seedDirectConversation(
        db: db,
        chatId: 'direct-local:chat-b',
        modelId: model.id,
        suffix: 'b',
      );
      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(api),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(null),
          directLocalDatabaseProvider.overrideWithValue(db),
          directModelRegistryProvider.overrideWithValue(registry),
          directConnectionProfilesProvider.overrideWith(
            () => _Profiles(profile),
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeConversationProvider.notifier).set(chatA);
      container.read(chatMessagesProvider.notifier).setMessages(chatA.messages);

      final send = sendMessageWithContainer(
        container,
        'Chat A follow-up',
        const ['server-image'],
      );
      await api.firstInfoStarted.future.timeout(const Duration(seconds: 1));
      container.read(activeConversationProvider.notifier).set(chatB);
      await Future<void>.delayed(Duration.zero);
      api.firstInfoGate.complete();
      await send.timeout(const Duration(seconds: 1));

      final chatAMessages = await db.messagesDao.getForChat(chatA.id);
      final chatBMessages = await db.messagesDao.getForChat(chatB.id);
      expect(
        chatAMessages.where((row) => row.content == 'Chat A follow-up'),
        isEmpty,
      );
      expect(
        chatBMessages.where((row) => row.content == 'Chat A follow-up'),
        isEmpty,
      );
      expect(adapter.startCalls, 0);
      expect(container.read(activeConversationProvider)?.id, chatB.id);
      expect(
        container.read(chatMessagesProvider).map((message) => message.id),
        chatB.messages.map((message) => message.id),
      );
    },
  );
}
