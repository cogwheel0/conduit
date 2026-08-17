import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/chat_database_repository.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/services/conversation_parsing.dart';
import 'package:conduit/features/chat/services/chat_history_reader.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a 50-row presentation window reads all 500 durable messages', () async {
    final localDatabase = AppDatabase(NativeDatabase.memory());
    addTearDown(localDatabase.close);
    final repository = ChatDatabaseRepository(
      openWebUiDatabase: null,
      directLocalDatabase: localDatabase,
    );
    const chatId = 'complete-history';
    final rows = [
      for (var index = 0; index < 500; index += 1)
        MessageRowData(
          id: 'm$index',
          chatId: chatId,
          parentId: index == 0 ? null : 'm${index - 1}',
          role: index.isEven ? 'user' : 'assistant',
          content: 'message $index',
          createdAt: index,
          orderIndex: index,
          payload: {
            'id': 'm$index',
            'parentId': index == 0 ? null : 'm${index - 1}',
            'role': index.isEven ? 'user' : 'assistant',
            'content': 'message $index',
            'timestamp': index,
          },
        ),
    ];
    await localDatabase.chatsDao.upsertLocalOnlyChat(
      rows: ChatRows(
        chat: const ChatRowData(
          id: chatId,
          title: 'Complete',
          currentMessageId: 'm499',
          createdAt: 0,
          updatedAt: 499,
        ),
        messages: rows,
        blobHadTitle: true,
        blobTitleValue: 'Complete',
        blobHadHistory: true,
        historyHadMessages: true,
        historyHadCurrentId: true,
      ),
    );
    final window = await repository.loadConversationWindow(
      chatId,
      preferred: ChatStorageKind.directLocal,
    );
    check(window).isNotNull();
    check(window!.conversation.messages.length).equals(50);

    final visibleOverlay = [
      ...window.conversation.messages.take(49),
      window.conversation.messages.last.copyWith(content: 'streamed update'),
    ];
    final reader = ChatHistoryReader(
      repository: repository,
      offload: (envelope) =>
          Future.value(parseFullConversationModelWorker(envelope)),
    );

    final complete = await reader.readCompleteActiveBranch(
      conversation: window.conversation,
      visibleOverlay: visibleOverlay,
      ownerIsCurrent: () => true,
    );

    check(complete.messages.length).equals(500);
    check(complete.messages.first.id).equals('m0');
    check(complete.messages.last.id).equals('m499');
    check(complete.messages.last.content).equals('streamed update');
  });

  test('owner changes reject an otherwise valid complete read', () async {
    final localDatabase = AppDatabase(NativeDatabase.memory());
    addTearDown(localDatabase.close);
    final repository = ChatDatabaseRepository(
      openWebUiDatabase: null,
      directLocalDatabase: localDatabase,
    );
    final reader = ChatHistoryReader(
      repository: repository,
      offload: (envelope) =>
          Future.value(parseFullConversationModelWorker(envelope)),
    );

    await check(
      reader.readCompleteActiveBranch(
        conversation: _runtimeConversation(),
        visibleOverlay: const [],
        ownerIsCurrent: () => false,
      ),
    ).throws<StateError>();
  });

  test('unmaterialized durable history uses the authoritative loader, not its window', () async {
    final localDatabase = AppDatabase(NativeDatabase.memory());
    addTearDown(localDatabase.close);
    final repository = ChatDatabaseRepository(
      openWebUiDatabase: null,
      directLocalDatabase: localDatabase,
    );
    final now = DateTime(2026);
    final completeMessages = [
      for (var index = 0; index < 500; index += 1)
        ChatMessage(
          id: 'm$index',
          role: index.isEven ? 'user' : 'assistant',
          content: 'message $index',
          timestamp: now.add(Duration(seconds: index)),
        ),
    ];
    final window = annotateConversationStorage(
      Conversation(
        id: 'pending-server-body',
        title: 'Pending',
        createdAt: now,
        updatedAt: now,
        messages: completeMessages.sublist(450),
      ),
      ChatStorageKind.openWebUi,
    );
    var authoritativeReads = 0;
    final reader = ChatHistoryReader(
      repository: repository,
      authoritativeLoader: (conversation) async {
        authoritativeReads += 1;
        return annotateConversationStorage(
          conversation.copyWith(messages: completeMessages),
          ChatStorageKind.openWebUi,
        );
      },
      offload: (envelope) =>
          Future.value(parseFullConversationModelWorker(envelope)),
    );

    final complete = await reader.readCompleteActiveBranch(
      conversation: window,
      visibleOverlay: [
        ...window.messages.take(49),
        window.messages.last.copyWith(content: 'unflushed tail'),
      ],
      ownerIsCurrent: () => true,
    );

    check(authoritativeReads).equals(1);
    check(complete.messages.length).equals(500);
    check(complete.messages.last.content).equals('unflushed tail');
  });
}

Conversation _runtimeConversation() {
  return Conversation(
    id: 'runtime',
    title: 'Runtime',
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
  );
}
