import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test(
    'account cleanup deletes only chats bound to that fingerprint',
    () async {
      await _insertChat(db, 'owned');
      await _insertChat(db, 'unrelated');
      await _insertChat(db, 'shared');
      await _insertMessage(db, chatId: 'owned', id: 'owned-message');
      await _insertMessage(db, chatId: 'unrelated', id: 'other-message');
      await _insertMessage(db, chatId: 'shared', id: 'shared-message');
      await db.directThreadBindingsDao.putBinding(
        DirectThreadBindingsCompanion.insert(
          localChatId: 'owned',
          profileId: 'chatgpt-account',
          headMessageId: 'owned-head',
          transportSessionId: 'session-owned',
          modelId: 'gpt-test',
          accountFingerprint: 'account-a',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      await db.directThreadBindingsDao.putBinding(
        DirectThreadBindingsCompanion.insert(
          localChatId: 'shared',
          profileId: 'chatgpt-account',
          headMessageId: 'shared-chatgpt-head',
          transportSessionId: 'session-shared-chatgpt',
          modelId: 'gpt-test',
          accountFingerprint: 'account-a',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      await db.directThreadBindingsDao.putBinding(
        DirectThreadBindingsCompanion.insert(
          localChatId: 'shared',
          profileId: 'other-profile',
          headMessageId: 'shared-other-head',
          transportSessionId: 'session-shared-other',
          modelId: 'other-model',
          accountFingerprint: 'account-b',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      await db.directThreadBindingsDao.putBinding(
        DirectThreadBindingsCompanion.insert(
          localChatId: 'unrelated',
          profileId: 'other-profile',
          headMessageId: 'other-head',
          transportSessionId: 'session-other',
          modelId: 'other-model',
          accountFingerprint: 'account-b',
          createdAt: 1,
          updatedAt: 1,
        ),
      );

      check(
        await db.directThreadBindingsDao.deleteAccountChats('account-a'),
      ).equals(1);
      check(await db.chatsDao.getChat('owned')).isNull();
      check(
        await db.directThreadBindingsDao.getBinding(
          localChatId: 'owned',
          profileId: 'chatgpt-account',
          headMessageId: 'owned-head',
        ),
      ).isNull();
      check(await db.messagesDao.getForChat('owned')).isEmpty();
      check(await db.chatsDao.getChat('unrelated')).isNotNull();
      check(await db.messagesDao.getForChat('unrelated')).length.equals(1);
      check(await db.chatsDao.getChat('shared')).isNotNull();
      check(await db.messagesDao.getForChat('shared')).length.equals(1);
      check(
        await db.directThreadBindingsDao.getBinding(
          localChatId: 'unrelated',
          profileId: 'other-profile',
          headMessageId: 'other-head',
        ),
      ).isNotNull();
      check(
        await db.directThreadBindingsDao.getBinding(
          localChatId: 'shared',
          profileId: 'chatgpt-account',
          headMessageId: 'shared-chatgpt-head',
        ),
      ).isNull();
      check(
        await db.directThreadBindingsDao.getBinding(
          localChatId: 'shared',
          profileId: 'other-profile',
          headMessageId: 'shared-other-head',
        ),
      ).isNotNull();
    },
  );

  test('fallback cleanup deletes every bound chat', () async {
    await _insertChat(db, 'owned-a');
    await _insertChat(db, 'owned-b');
    await _insertChat(db, 'unrelated');
    for (final entry in <(String, String)>[
      ('owned-a', 'account-a'),
      ('owned-b', 'account-b'),
    ]) {
      await db.directThreadBindingsDao.putBinding(
        DirectThreadBindingsCompanion.insert(
          localChatId: entry.$1,
          profileId: 'chatgpt-account',
          headMessageId: 'head-${entry.$1}',
          transportSessionId: 'session-${entry.$1}',
          modelId: 'gpt-test',
          accountFingerprint: entry.$2,
          createdAt: 1,
          updatedAt: 1,
        ),
      );
    }

    check(await db.directThreadBindingsDao.deleteAllBoundChats()).equals(2);
    check(await db.chatsDao.getChat('owned-a')).isNull();
    check(await db.chatsDao.getChat('owned-b')).isNull();
    check(await db.chatsDao.getChat('unrelated')).isNotNull();
  });
}

Future<void> _insertChat(AppDatabase db, String id) => db
    .into(db.chats)
    .insert(
      ChatsCompanion.insert(id: id, title: id, createdAt: 1, updatedAt: 1),
    );

Future<void> _insertMessage(
  AppDatabase db, {
  required String chatId,
  required String id,
}) => db
    .into(db.messages)
    .insert(
      MessagesCompanion.insert(
        id: id,
        chatId: chatId,
        role: 'user',
        content: id,
        createdAt: 1,
        orderIndex: 0,
        payload: '{}',
      ),
    );
