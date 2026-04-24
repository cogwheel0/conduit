import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/persistence/conversation_store.dart';
import 'package:conduit/core/persistence/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('ConversationStore', () {
    late AppDatabase database;
    late ConversationStore store;

    setUp(() async {
      database = await AppDatabase.openInMemory();
      store = ConversationStore(database);
    });

    tearDown(() async {
      await database.close();
    });

    test('round-trips a conversation with messages', () async {
      final conv = _conversation(
        id: 'c1',
        title: 'First',
        messages: [
          _message(id: 'm1', role: 'user', content: 'hi'),
          _message(id: 'm2', role: 'assistant', content: 'hello'),
        ],
      );
      await store.upsertConversation(conv);

      final loaded = await store.getConversation('c1');
      check(loaded).isNotNull();
      check(loaded!.id).equals('c1');
      check(loaded.title).equals('First');
      check(loaded.messages.length).equals(2);
      check(loaded.messages[0].id).equals('m1');
      check(loaded.messages[0].content).equals('hi');
      check(loaded.messages[1].role).equals('assistant');
    });

    test('returns null for unknown conversation', () async {
      final loaded = await store.getConversation('nope');
      check(loaded).isNull();
    });

    test('upsert is idempotent and preserves message edits', () async {
      final initial = _conversation(
        id: 'c2',
        messages: [_message(id: 'm1', content: 'one')],
      );
      await store.upsertConversation(initial);

      final edited = initial.copyWith(
        messages: [
          _message(id: 'm1', content: 'one (edited)'),
          _message(id: 'm2', content: 'two'),
        ],
      );
      await store.upsertConversation(edited);

      final loaded = await store.getConversation('c2');
      check(loaded!.messages.map((m) => m.content).toList()).deepEquals([
        'one (edited)',
        'two',
      ]);
    });

    test('upsert removes messages no longer present', () async {
      final initial = _conversation(
        id: 'c3',
        messages: [
          _message(id: 'm1', content: 'a'),
          _message(id: 'm2', content: 'b'),
          _message(id: 'm3', content: 'c'),
        ],
      );
      await store.upsertConversation(initial);

      final pruned = initial.copyWith(
        messages: [
          _message(id: 'm1', content: 'a'),
          _message(id: 'm3', content: 'c'),
        ],
      );
      await store.upsertConversation(pruned);

      final ids = await store.getMessageIds('c3');
      check(ids).deepEquals(['m1', 'm3']);
    });

    test('deleteConversation cascades to its messages', () async {
      final conv = _conversation(
        id: 'c4',
        messages: [_message(id: 'm1'), _message(id: 'm2')],
      );
      await store.upsertConversation(conv);

      await store.deleteConversation('c4');

      check(await store.getConversation('c4')).isNull();
      final orphans = await database.raw.query(
        'messages',
        where: 'conversation_id = ?',
        whereArgs: ['c4'],
      );
      check(orphans).isEmpty();
    });

    test('getAllSummaries orders by pinned then updated_at desc', () async {
      await store.upsertConversation(_conversation(
        id: 'old',
        updatedAt: DateTime(2026, 1, 1),
      ));
      await store.upsertConversation(_conversation(
        id: 'newer',
        updatedAt: DateTime(2026, 4, 1),
      ));
      await store.upsertConversation(_conversation(
        id: 'pinned',
        updatedAt: DateTime(2025, 1, 1),
        pinned: true,
      ));

      final summaries = await store.getAllSummaries();
      check(summaries.map((c) => c.id).toList()).deepEquals([
        'pinned',
        'newer',
        'old',
      ]);
    });

    test('summaries omit message bodies', () async {
      await store.upsertConversation(_conversation(
        id: 'c5',
        messages: List.generate(
          5,
          (i) => _message(id: 'm$i', content: 'body-$i'),
        ),
      ));

      final summaries = await store.getAllSummaries();
      final summary = summaries.firstWhere((c) => c.id == 'c5');
      check(summary.messages).isEmpty();
    });

    test('round-trips nested ChatMessage payload via JSON column', () async {
      final conv = _conversation(
        id: 'c6',
        messages: [
          _message(
            id: 'm1',
            content: 'rich',
            metadata: {'parentId': null, 'extra': 'value'},
            attachmentIds: ['file-1', 'file-2'],
          ),
        ],
      );
      await store.upsertConversation(conv);

      final loaded = await store.getConversation('c6');
      final m = loaded!.messages.single;
      check(m.attachmentIds).isNotNull();
      check(m.attachmentIds!).deepEquals(['file-1', 'file-2']);
      check(m.metadata?['extra']).equals('value');
    });

    test('extracts parent_id column from metadata for indexing', () async {
      final conv = _conversation(
        id: 'c7',
        messages: [
          _message(
            id: 'child',
            metadata: {'parentId': 'parent-msg-id'},
          ),
        ],
      );
      await store.upsertConversation(conv);

      final rows = await database.raw.query(
        'messages',
        columns: ['id', 'parent_id'],
        where: 'id = ?',
        whereArgs: ['child'],
      );
      check(rows.single['parent_id']).equals('parent-msg-id');
    });

    test('stores last_message_preview from final message', () async {
      await store.upsertConversation(_conversation(
        id: 'c8',
        messages: [
          _message(id: 'm1', content: 'first'),
          _message(id: 'm2', content: 'this is the last reply'),
        ],
      ));

      final rows = await database.raw.query(
        'conversations',
        columns: ['last_message_preview', 'message_count'],
        where: 'id = ?',
        whereArgs: ['c8'],
      );
      check(rows.single['last_message_preview']).equals('this is the last reply');
      check(rows.single['message_count']).equals(2);
    });

    test('deleteAll wipes both tables', () async {
      await store.upsertConversation(_conversation(
        id: 'c9',
        messages: [_message(id: 'm1')],
      ));

      await store.deleteAll();

      check(await store.getAllSummaries()).isEmpty();
      check(await database.raw.query('messages')).isEmpty();
    });

    test('upsertConversations applies multiple atomically', () async {
      await store.upsertConversations([
        _conversation(id: 'a', title: 'A'),
        _conversation(id: 'b', title: 'B'),
      ]);
      final ids = (await store.getAllSummaries()).map((c) => c.id).toList()
        ..sort();
      check(ids).deepEquals(['a', 'b']);
    });

    test('appendMessage adds without losing siblings', () async {
      await store.upsertConversation(_conversation(
        id: 'c10',
        messages: [_message(id: 'm1', content: 'one')],
      ));

      await store.appendMessage(
        'c10',
        _message(id: 'm2', content: 'two', timestamp: DateTime(2027)),
      );

      final loaded = await store.getConversation('c10');
      check(loaded!.messages.map((m) => m.id).toList()).deepEquals([
        'm1',
        'm2',
      ]);
    });

    test('updateMessage replaces existing payload', () async {
      await store.upsertConversation(_conversation(
        id: 'c11',
        messages: [_message(id: 'm1', content: 'before')],
      ));

      await store.updateMessage(_message(id: 'm1', content: 'after'));

      final loaded = await store.getConversation('c11');
      check(loaded!.messages.single.content).equals('after');
    });

    test('deleteMessage removes a single row only', () async {
      await store.upsertConversation(_conversation(
        id: 'c12',
        messages: [
          _message(id: 'm1'),
          _message(id: 'm2'),
        ],
      ));

      await store.deleteMessage('c12', 'm1');

      final ids = await store.getMessageIds('c12');
      check(ids).deepEquals(['m2']);
    });

    test('payload_json strips messages list to avoid duplication', () async {
      final conv = _conversation(
        id: 'c13',
        messages: [_message(id: 'm1', content: 'in-row')],
      );
      await store.upsertConversation(conv);

      final rows = await database.raw.query(
        'conversations',
        columns: ['payload_json'],
        where: 'id = ?',
        whereArgs: ['c13'],
      );
      final payload = jsonDecode(rows.single['payload_json'] as String) as Map;
      check(payload['messages']).isA<List>();
      check((payload['messages'] as List).isEmpty).isTrue();
    });
  });
}

Conversation _conversation({
  required String id,
  String title = 'untitled',
  DateTime? createdAt,
  DateTime? updatedAt,
  List<ChatMessage> messages = const [],
  bool pinned = false,
  bool archived = false,
}) {
  return Conversation(
    id: id,
    title: title,
    createdAt: createdAt ?? DateTime(2026, 4, 1),
    updatedAt: updatedAt ?? DateTime(2026, 4, 1),
    messages: messages,
    pinned: pinned,
    archived: archived,
  );
}

ChatMessage _message({
  required String id,
  String role = 'user',
  String content = '',
  DateTime? timestamp,
  List<String>? attachmentIds,
  Map<String, dynamic>? metadata,
}) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    timestamp: timestamp ?? DateTime(2026, 4, 1),
    attachmentIds: attachmentIds,
    metadata: metadata,
  );
}
