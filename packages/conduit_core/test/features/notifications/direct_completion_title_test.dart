import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/chats_dao.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show directCompletionChatTitle;
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

typedef _Lookup = Future<ChatRow?> Function(String chatId);

/// A database whose chat lookup answers with [_lookup].
final class _Database extends AppDatabase {
  _Database(this._lookup) : super(NativeDatabase.memory());

  final _Lookup _lookup;
  late final ChatsDao _chats = _ChatsDao(this, _lookup);

  @override
  ChatsDao get chatsDao => _chats;
}

final class _ChatsDao extends ChatsDao {
  _ChatsDao(super.db, this._lookup);

  final _Lookup _lookup;

  @override
  Future<ChatRow?> getChat(String chatId) => _lookup(chatId);
}

ChatRow _row(String id, String title) => ChatRow(
  id: id,
  title: title,
  pinned: false,
  archived: false,
  createdAt: 0,
  updatedAt: 0,
  dirty: false,
  deleted: false,
  rawExtra: '{}',
  meta: '{}',
  blobMeta: '{}',
  bodySynced: true,
);

void main() {
  Future<String?> titleWith(_Lookup lookup) async {
    final database = _Database(lookup);
    addTearDown(database.close);
    return directCompletionChatTitle(database, 'direct-local:1');
  }

  test('names the chat by its stored title', () async {
    check(
      await titleWith((id) async => _row(id, 'Trip ideas')),
    ).equals('Trip ideas');
  });

  test('a failed lookup leaves the title out', () async {
    check(
      await titleWith((_) async => throw StateError('database closed')),
    ).isNull();
  });

  test('a lookup slower than two seconds leaves the title out', () {
    fakeAsync((async) {
      final database = _Database((_) => Completer<ChatRow?>().future);
      String? title = 'unset';
      var done = false;
      directCompletionChatTitle(database, 'direct-local:1').then((value) {
        title = value;
        done = true;
      });

      async.elapse(const Duration(seconds: 1));
      check(done).isFalse();
      async.elapse(const Duration(seconds: 1));
      check(done).isTrue();
      check(title).isNull();
      database.close();
    });
  });
}
