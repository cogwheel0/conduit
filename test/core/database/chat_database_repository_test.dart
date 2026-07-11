import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/chat_database_repository.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/sync/id_remapper.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late bool previousDontWarnAboutMultipleDatabases;
  late AppDatabase serverDatabase;
  late AppDatabase localDatabase;
  late ChatDatabaseRepository repository;

  setUpAll(() {
    previousDontWarnAboutMultipleDatabases =
        driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  tearDownAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases =
        previousDontWarnAboutMultipleDatabases;
  });

  setUp(() {
    serverDatabase = AppDatabase(NativeDatabase.memory());
    localDatabase = AppDatabase(NativeDatabase.memory());
    repository = ChatDatabaseRepository(
      openWebUiDatabase: serverDatabase,
      directLocalDatabase: localDatabase,
    );
  });

  tearDown(() async {
    await serverDatabase.close();
    await localDatabase.close();
  });

  group('storage selection and resolution', () {
    test('chooses the preferred store and falls back when OWUI is absent', () {
      check(
        repository
            .chooseForNewDirectChat(DirectChatSyncPreference.localOnly)
            .storage,
      ).equals(ChatStorageKind.directLocal);
      check(
        repository
            .chooseForNewDirectChat(
              DirectChatSyncPreference.syncWithOpenWebUiWhenAvailable,
            )
            .storage,
      ).equals(ChatStorageKind.openWebUi);

      final localOnlyRepository = ChatDatabaseRepository(
        openWebUiDatabase: null,
        directLocalDatabase: localDatabase,
      );
      check(
        localOnlyRepository
            .chooseForNewDirectChat(
              DirectChatSyncPreference.syncWithOpenWebUiWhenAvailable,
            )
            .storage,
      ).equals(ChatStorageKind.directLocal);
    });

    test('resolves an id and requires provenance for collisions', () async {
      await localDatabase.chatsDao.upsertLocalOnlyChat(
        rows: _chatRows(id: 'local-chat', updatedAt: 10),
      );
      await serverDatabase.chatsDao.upsertServerChat(
        rows: _chatRows(id: 'server-chat', updatedAt: 20),
      );

      check(
        (await repository.resolveChat('local-chat'))!.storage,
      ).equals(ChatStorageKind.directLocal);
      check(
        (await repository.resolveChat('server-chat'))!.storage,
      ).equals(ChatStorageKind.openWebUi);
      check(await repository.resolveChat('missing')).isNull();

      await serverDatabase.chatsDao.upsertServerChat(
        rows: _chatRows(id: 'duplicate', updatedAt: 30),
      );
      await localDatabase.chatsDao.upsertLocalOnlyChat(
        rows: _chatRows(id: 'duplicate', updatedAt: 40),
      );

      await check(
        repository.resolveChat('duplicate'),
      ).throws<AmbiguousChatStorageException>();
      check(
        (await repository.resolveChat(
          'duplicate',
          preferred: ChatStorageKind.directLocal,
        ))!.storage,
      ).equals(ChatStorageKind.directLocal);
    });
  });

  group('local-only DAO writes', () {
    test('remain clean and never create outbox work', () async {
      final initial = _chatRows(id: 'direct-1', updatedAt: 100);
      await localDatabase.chatsDao.upsertLocalOnlyChat(rows: initial);

      var chat = await localDatabase.chatsDao.getChat('direct-1');
      check(chat).isNotNull();
      check(chat!.serverUpdatedAt).isNull();
      check(chat.dirty).isFalse();
      check(chat.bodySynced).isTrue();
      check(await localDatabase.outboxDao.pendingForChat('direct-1')).isEmpty();
      check(
        (await localDatabase.messagesDao.getForChat('direct-1')).single.dirty,
      ).isFalse();

      final assistant = _message(
        chatId: 'direct-1',
        id: 'assistant-2',
        role: 'assistant',
        content: 'direct response',
        createdAt: 200,
      );
      await localDatabase.chatsDao.appendLocalOnlyMessages(
        chatId: 'direct-1',
        messages: [assistant],
        currentMessageId: assistant.id,
        updatedAt: 200,
      );
      await localDatabase.chatsDao.updateLocalOnlyEnvelope(
        'direct-1',
        title: const Value('Renamed'),
      );

      chat = await localDatabase.chatsDao.getChat('direct-1');
      check(chat!.title).equals('Renamed');
      check(chat.currentMessageId).equals('assistant-2');
      check(chat.updatedAt).equals(200);
      check(chat.dirty).isFalse();
      final messages = await localDatabase.messagesDao.getForChat('direct-1');
      check(
        messages.map((message) => message.id).toList(),
      ).deepEquals(['message-direct-1', 'assistant-2']);
      check(messages.every((message) => !message.dirty)).isTrue();
      check(await localDatabase.outboxDao.pendingForChat('direct-1')).isEmpty();

      await localDatabase.chatsDao.deleteLocalOnlyChat('direct-1');
      check(await localDatabase.chatsDao.getChat('direct-1')).isNull();
      check(await localDatabase.messagesDao.getForChat('direct-1')).isEmpty();
      check(await localDatabase.outboxDao.pendingForChat('direct-1')).isEmpty();
    });
  });

  group('merged reads', () {
    test('lists, loads, and searches with no Open WebUI database', () async {
      final localOnlyRepository = ChatDatabaseRepository(
        openWebUiDatabase: null,
        directLocalDatabase: localDatabase,
      );
      await localDatabase.chatsDao.upsertLocalOnlyChat(
        rows: _chatRows(
          id: 'standalone',
          updatedAt: 25,
          content: 'standalone needle',
        ),
      );

      final list = await localOnlyRepository.watchMergedChatList().first;
      check(list.single.entry.id).equals('standalone');
      check(list.single.storage).equals(ChatStorageKind.directLocal);

      final loaded = await localOnlyRepository.loadConversation('standalone');
      check(loaded).isNotNull();
      check(loaded!.location.storage).equals(ChatStorageKind.directLocal);

      final hits = await localOnlyRepository.searchMergedChats('needle');
      check(hits.single.hit.chatId).equals('standalone');
      check(hits.single.storage).equals(ChatStorageKind.directLocal);
    });

    test('watches both stores with provenance and global ordering', () async {
      await serverDatabase.chatsDao.upsertServerChat(
        rows: _chatRows(id: 'server-old', updatedAt: 10),
      );
      await localDatabase.chatsDao.upsertLocalOnlyChat(
        rows: _chatRows(id: 'local-new', updatedAt: 20),
      );

      final entries = await repository.watchMergedChatList().first;
      check(
        entries.map((item) => item.entry.id).toList(),
      ).deepEquals(['local-new', 'server-old']);
      check(
        entries.map((item) => item.storage).toList(),
      ).deepEquals([ChatStorageKind.directLocal, ChatStorageKind.openWebUi]);
      check(
        ChatStorageIdentity.parse(entries.first.scopedId).rawId,
      ).equals('local-new');
      check(
        ChatStorageIdentity.parse(entries.first.scopedId).storage,
      ).equals(ChatStorageKind.directLocal);
      final summary = entries.first.toConversation();
      check(
        chatStorageFromConversation(summary),
      ).equals(ChatStorageKind.directLocal);
      check(
        summary.metadata[kChatStorageKindMetadataKey],
      ).equals('directLocal');
    });

    test('loads the full conversation from its owning store', () async {
      await localDatabase.chatsDao.upsertLocalOnlyChat(
        rows: _chatRows(
          id: 'load-local',
          updatedAt: 50,
          content: 'loaded body',
        ),
      );

      final loaded = await repository.loadConversation(
        'load-local',
        preferred: ChatStorageKind.directLocal,
      );
      check(loaded).isNotNull();
      check(loaded!.location.storage).equals(ChatStorageKind.directLocal);
      check(loaded.conversation.id).equals('load-local');
      check(loaded.conversation.messages.single.content).equals('loaded body');
      check(
        chatStorageFromConversation(loaded.conversation),
      ).equals(ChatStorageKind.directLocal);
    });

    test('merges full-text hits from both stores', () async {
      // Open WebUI normally builds FTS after its first sync. The local store is
      // intentionally left unbuilt; the repository owns that lazy gate.
      await serverDatabase.buildFtsIfNeeded();
      await serverDatabase.chatsDao.upsertServerChat(
        rows: _chatRows(
          id: 'server-search',
          updatedAt: 10,
          content: 'needle on server',
        ),
      );
      await localDatabase.chatsDao.upsertLocalOnlyChat(
        rows: _chatRows(
          id: 'local-search',
          updatedAt: 20,
          content: 'needle stored locally',
        ),
      );

      final hits = await repository.searchMergedChats('needle');
      check(
        hits.map((item) => item.hit.chatId).toSet(),
      ).deepEquals({'server-search', 'local-search'});
      check(
        hits.map((item) => item.storage).toSet(),
      ).deepEquals({ChatStorageKind.openWebUi, ChatStorageKind.directLocal});
    });

    test(
      'can search direct-local independently of a cached server limit',
      () async {
        await serverDatabase.buildFtsIfNeeded();
        for (var index = 0; index < 55; index++) {
          await serverDatabase.chatsDao.upsertServerChat(
            rows: _chatRows(
              id: 'server-$index',
              updatedAt: 1000 + index,
              content: 'needle needle needle server $index',
            ),
          );
        }
        await localDatabase.chatsDao.upsertLocalOnlyChat(
          rows: _chatRows(
            id: 'direct-result',
            updatedAt: 1,
            content: 'needle on device',
          ),
        );

        final hits = await repository.searchChatsInStorage(
          'needle',
          storage: ChatStorageKind.directLocal,
          limit: 50,
        );

        check(
          hits.map((hit) => hit.hit.chatId).toList(),
        ).deepEquals(['direct-result']);
        check(hits.single.storage).equals(ChatStorageKind.directLocal);
      },
    );

    test(
      'keeps colliding raw ids distinct in list and search results',
      () async {
        await serverDatabase.buildFtsIfNeeded();
        await serverDatabase.chatsDao.upsertServerChat(
          rows: _chatRows(
            id: 'collision',
            updatedAt: 10,
            content: 'shared collision needle',
            title: 'Server copy',
          ),
        );
        await localDatabase.chatsDao.upsertLocalOnlyChat(
          rows: _chatRows(
            id: 'collision',
            updatedAt: 20,
            content: 'shared collision needle',
            title: 'Device copy',
          ),
        );

        final entries = await repository.watchMergedChatList().first;
        check(entries.length).equals(2);
        check(
          entries.map((entry) => entry.entry.id).toSet(),
        ).deepEquals({'collision'});
        check(entries.map((entry) => entry.scopedId).toSet().length).equals(2);

        final hits = await repository.searchMergedChats('collision needle');
        check(hits.length).equals(2);
        check(
          hits.map((hit) => hit.hit.chatId).toSet(),
        ).deepEquals({'collision'});
        check(hits.map((hit) => hit.scopedId).toSet().length).equals(2);
      },
    );
  });

  group('direct-provider persistence facade', () {
    test('resolves a completion owner after a pre-listener id remap', () async {
      final location = repository.chooseForNewDirectChat(
        DirectChatSyncPreference.syncWithOpenWebUiWhenAvailable,
      );
      const localId = 'local:remap-before-listener';
      const serverId = 'server-remapped';
      const assistantId = 'message-local:remap-before-listener';
      await repository.persistNewDirectChat(
        location,
        _chatRows(id: localId, updatedAt: 100),
        openWebUiContentHash: 'stable-hash',
      );
      final remapper = IdRemapper(serverDatabase);
      addTearDown(remapper.dispose);

      // The remap completes before any direct-run event listener is installed.
      await remapper.remapChat(
        localId: localId,
        serverId: serverId,
        serverCreatedAt: 100,
        serverUpdatedAt: 101,
      );

      check(
        await repository.resolveCurrentChatIdForMessage(
          location,
          recordedChatId: localId,
          messageId: assistantId,
        ),
      ).equals(serverId);
    });

    test('never enqueues a completion operation in either store', () async {
      final localLocation = repository.chooseForNewDirectChat(
        DirectChatSyncPreference.localOnly,
      );
      await repository.persistNewDirectChat(
        localLocation,
        _chatRows(id: 'direct-local', updatedAt: 100),
      );
      await repository.persistDirectMessages(
        localLocation,
        chatId: 'direct-local',
        messages: [
          _message(
            chatId: 'direct-local',
            id: 'direct-answer',
            role: 'assistant',
            content: 'done',
            createdAt: 101,
          ),
        ],
        currentMessageId: 'direct-answer',
        updatedAt: 101,
      );
      check(
        await localDatabase.outboxDao.pendingForChat('direct-local'),
      ).isEmpty();

      final serverLocation = repository.chooseForNewDirectChat(
        DirectChatSyncPreference.syncWithOpenWebUiWhenAvailable,
      );
      await repository.persistNewDirectChat(
        serverLocation,
        _chatRows(id: 'local:direct-sync', updatedAt: 200),
        openWebUiContentHash: 'stable-hash',
      );
      await repository.persistDirectMessages(
        serverLocation,
        chatId: 'local:direct-sync',
        messages: [
          _message(
            chatId: 'local:direct-sync',
            id: 'sync-answer',
            role: 'assistant',
            content: 'done',
            createdAt: 201,
          ),
        ],
        currentMessageId: 'sync-answer',
        updatedAt: 201,
      );

      final ops = await serverDatabase.outboxDao.pendingForChat(
        'local:direct-sync',
      );
      check(ops).isNotEmpty();
      check(ops.any((op) => op.kind == 'requestCompletion')).isFalse();
    });
  });
}

ChatRows _chatRows({
  required String id,
  required int updatedAt,
  String? title,
  String content = 'hello',
}) {
  final message = _message(
    chatId: id,
    id: 'message-$id',
    role: 'user',
    content: content,
    createdAt: updatedAt,
  );
  return ChatRows(
    chat: ChatRowData(
      id: id,
      title: title ?? 'Chat $id',
      currentMessageId: message.id,
      createdAt: updatedAt,
      updatedAt: updatedAt,
    ),
    messages: [message],
    blobHadTitle: true,
    blobTitleValue: title ?? 'Chat $id',
    blobHadHistory: true,
    historyHadMessages: true,
    historyHadCurrentId: true,
  );
}

MessageRowData _message({
  required String chatId,
  required String id,
  required String role,
  required String content,
  required int createdAt,
}) {
  return MessageRowData(
    id: id,
    chatId: chatId,
    role: role,
    content: content,
    createdAt: createdAt,
    orderIndex: 0,
    payload: <String, dynamic>{
      'id': id,
      'role': role,
      'content': content,
      'timestamp': createdAt,
      'parentId': null,
      'childrenIds': <String>[],
    },
  );
}
