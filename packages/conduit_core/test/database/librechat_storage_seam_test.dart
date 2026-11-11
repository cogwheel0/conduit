import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/database/account_storage_isolation.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

/// The LibreChat account store: a third chat database the repository routes
/// to, owning the Chats tab the way Open WebUI's does.
void main() {
  late bool previousDontWarn;
  late AppDatabase libreChatDatabase;
  late AppDatabase localDatabase;
  late ChatDatabaseRepository repository;

  setUpAll(() {
    previousDontWarn = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDownAll(
    () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousDontWarn,
  );

  setUp(() {
    // Each closes even when a later step of the setup throws.
    libreChatDatabase = AppDatabase(NativeDatabase.memory());
    addTearDown(libreChatDatabase.close);
    localDatabase = AppDatabase(NativeDatabase.memory());
    addTearDown(localDatabase.close);
    repository = ChatDatabaseRepository(
      openWebUiDatabase: null,
      directLocalDatabase: localDatabase,
      libreChatDatabase: libreChatDatabase,
    );
  });

  test('a scoped LibreChat selection round-trips', () {
    final scoped = const ChatStorageIdentity(
      rawId: 'c/1 ?',
      storage: ChatStorageKind.libreChat,
    ).scopedId;
    final parsed = ChatStorageIdentity.parse(scoped);
    check(parsed.rawId).equals('c/1 ?');
    check(parsed.storage).equals(ChatStorageKind.libreChat);

    final conversation = annotateConversationStorage(
      Conversation(
        id: 'c1',
        title: 'Chat',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
      ChatStorageKind.libreChat,
    );
    check(chatStorageFromConversation(conversation)).equals(
      ChatStorageKind.libreChat,
    );
    check(isLibreChatConversation(conversation)).isTrue();
    // Never Open WebUI's: isolation and context readers keep it out.
    check(conversationUsesOpenWebUiStorage(conversation)).isFalse();
    final selection = conversationScopedId(conversation);
    check(
      ChatStorageIdentity.parse(selection).storage,
    ).equals(ChatStorageKind.libreChat);
    check(conversationMatchesScopedId(conversation, selection)).isTrue();
  });

  test('resolves, lists and searches the LibreChat store', () async {
    await libreChatDatabase.chatsDao.upsertServerChat(
      rows: _chatRows(id: 'lc-chat', updatedAt: 20, content: 'needle'),
    );
    await localDatabase.chatsDao.upsertLocalOnlyChat(
      rows: _chatRows(id: 'local-chat', updatedAt: 10),
    );

    check(repository.hasOpenWebUiDatabase).isFalse();
    check(repository.hasLibreChatDatabase).isTrue();
    check(
      repository.locationFor(ChatStorageKind.libreChat).database,
    ).identicalTo(libreChatDatabase);
    check((await repository.resolveChat('lc-chat'))!.storage).equals(
      ChatStorageKind.libreChat,
    );
    check(
      (await repository.loadConversation('lc-chat'))!.location.storage,
    ).equals(ChatStorageKind.libreChat);

    final list = await repository.watchMergedChatList().first;
    check(
      list.map((entry) => (entry.entry.id, entry.storage)),
    ).deepEquals([
      ('lc-chat', ChatStorageKind.libreChat),
      ('local-chat', ChatStorageKind.directLocal),
    ]);
    check(await repository.watchMergedArchivedChatCount().first).equals(0);

    await libreChatDatabase.buildFtsIfNeeded();
    final hits = await repository.searchMergedChats('needle');
    check(hits.map((hit) => hit.storage)).deepEquals([
      ChatStorageKind.libreChat,
    ]);
  });

  test('an id in both the LibreChat and device stores needs provenance',
      () async {
    await libreChatDatabase.chatsDao.upsertServerChat(
      rows: _chatRows(id: 'same', updatedAt: 20),
    );
    await localDatabase.chatsDao.upsertLocalOnlyChat(
      rows: _chatRows(id: 'same', updatedAt: 10),
    );
    await check(
      repository.resolveChat('same'),
    ).throws<AmbiguousChatStorageException>();
    check(
      (await repository.resolveChat(
        'same',
        preferred: ChatStorageKind.libreChat,
      ))!.storage,
    ).equals(ChatStorageKind.libreChat);
  });

  test('Direct chats never land in the LibreChat store', () async {
    final location = repository.locationFor(ChatStorageKind.libreChat);
    check(
      () => repository.persistNewDirectChat(
        location,
        _chatRows(id: 'direct', updatedAt: 1),
        openWebUiContentHash: 'hash',
      ),
    ).throws<StateError>();
    check(
      () => repository.persistDirectMessages(
        location,
        chatId: 'direct',
        messages: const [],
      ),
    ).throws<StateError>();
    // A new Direct chat still prefers the device over a LibreChat account.
    check(
      repository
          .chooseForNewDirectChat(
            DirectChatSyncPreference.syncWithOpenWebUiWhenAvailable,
          )
          .storage,
    ).equals(ChatStorageKind.directLocal);
  });

  test('a closed LibreChat store is absent, not a fallback', () async {
    final closed = ChatDatabaseRepository(
      openWebUiDatabase: null,
      directLocalDatabase: localDatabase,
    );
    check(
      () => closed.locationFor(ChatStorageKind.libreChat),
    ).throws<StateError>();
    check(
      await closed.resolveChat('x', preferred: ChatStorageKind.libreChat),
    ).isNull();
  });
}

ChatRows _chatRows({
  required String id,
  required int updatedAt,
  String content = 'hello',
}) {
  final message = MessageRowData(
    id: 'message-$id',
    chatId: id,
    role: 'user',
    content: content,
    createdAt: updatedAt,
    orderIndex: 0,
    payload: <String, dynamic>{
      'id': 'message-$id',
      'role': 'user',
      'content': content,
      'timestamp': updatedAt,
      'parentId': null,
      'childrenIds': <String>[],
    },
  );
  return ChatRows(
    chat: ChatRowData(
      id: id,
      title: 'Chat $id',
      currentMessageId: message.id,
      createdAt: updatedAt,
      updatedAt: updatedAt,
    ),
    messages: [message],
    blobHadTitle: true,
    blobTitleValue: 'Chat $id',
    blobHadHistory: true,
    historyHadMessages: true,
    historyHadCurrentId: true,
  );
}
