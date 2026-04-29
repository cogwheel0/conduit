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
      check(
        loaded!.messages.map((m) => m.content).toList(),
      ).deepEquals(['one (edited)', 'two']);
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

    test('insertMessageAsSending preserves the row across server sync', () async {
      // Outbox rows are user sends the server hasn't seen yet. A passive
      // sync that lands before the worker delivers MUST NOT wipe them —
      // otherwise the user's just-typed bubble vanishes.
      final scaffold = _conversation(id: 'c-pending');
      await store.upsertConversation(scaffold);

      await store.insertMessageAsSending(
        conversationId: 'c-pending',
        message: _message(id: 'm-pending', content: 'just typed'),
      );
      check(
        await store.getSendStatus('m-pending'),
      ).equals(MessageSendStatus.sending);

      // Server refresh lands without the pending message — typical race.
      final serverPayload = scaffold.copyWith(
        messages: [_message(id: 'm-server', content: 'already on server')],
      );
      await store.upsertConversation(serverPayload);

      final loaded = await store.getConversation('c-pending');
      final ids = loaded!.messages.map((m) => m.id).toList()..sort();
      check(ids).deepEquals(['m-pending', 'm-server']);
      check(
        await store.getSendStatus('m-pending'),
      ).equals(MessageSendStatus.sending);
    });

    test(
      'sync does not overwrite a sending row even when server returns the '
      'same id',
      () async {
        final scaffold = _conversation(id: 'c-collide');
        await store.upsertConversation(scaffold);
        await store.insertMessageAsSending(
          conversationId: 'c-collide',
          message: _message(id: 'shared-id', content: 'local pending'),
        );

        // Server happens to return the same id with different content.
        // Leave the in-flight row alone — once markSent fires the next
        // sync wins.
        final serverPayload = scaffold.copyWith(
          messages: [_message(id: 'shared-id', content: 'server content')],
        );
        await store.upsertConversation(serverPayload);

        final loaded = await store.getConversation('c-collide');
        check(loaded!.messages.single.content).equals('local pending');
      },
    );

    test('markSent releases the row so next sync can overwrite', () async {
      final scaffold = _conversation(id: 'c-flow');
      await store.upsertConversation(scaffold);
      await store.insertMessageAsSending(
        conversationId: 'c-flow',
        message: _message(id: 'm', content: 'local'),
      );
      await store.markSent('m');
      check(await store.getSendStatus('m')).equals(MessageSendStatus.sent);

      // Now a sync without `m` should prune it (no longer protected).
      await store.upsertConversation(
        scaffold.copyWith(messages: const []),
      );
      check(await store.getMessageIds('c-flow')).isEmpty();
    });

    test('pendingMessages returns sending and failed rows ordered by ts',
        () async {
      final scaffold = _conversation(id: 'c-pending-list');
      await store.upsertConversation(scaffold);
      await store.insertMessageAsSending(
        conversationId: 'c-pending-list',
        message: _message(
          id: 'older',
          content: 'older',
          timestamp: DateTime(2026, 1, 1),
        ),
      );
      await store.insertMessageAsSending(
        conversationId: 'c-pending-list',
        message: _message(
          id: 'newer',
          content: 'newer',
          timestamp: DateTime(2026, 4, 1),
        ),
      );
      await store.scheduleRetry(
        messageId: 'newer',
        attempt: 2,
        nextAt: DateTime(2026, 5, 1),
        error: 'flaky network',
      );

      final pending = await store.pendingMessages();
      check(pending.map((p) => p.messageId).toList()).deepEquals([
        'older',
        'newer',
      ]);
      check(pending[1].attempt).equals(2);
      check(pending[1].error).equals('flaky network');
      check(
        pending[1].nextAt,
      ).equals(DateTime(2026, 5, 1));
    });

    test('replaceAllConversations prunes conversations missing from the '
        'server snapshot', () async {
      await store.upsertConversations([
        _conversation(id: 'keep', title: 'Keep'),
        _conversation(id: 'delete-on-web', title: 'Will be deleted'),
      ]);

      // Simulate refresh after the user deleted "delete-on-web" on the
      // web app — the server snapshot only includes the surviving one.
      await store.replaceAllConversations([
        _conversation(id: 'keep', title: 'Keep'),
      ]);

      final ids = (await store.getAllSummaries()).map((c) => c.id).toList();
      check(ids).deepEquals(['keep']);
    });

    test('deleteConversation cascades to its messages', () async {
      final conv = _conversation(
        id: 'c4',
        messages: [
          _message(id: 'm1'),
          _message(id: 'm2'),
        ],
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
      await store.upsertConversation(
        _conversation(id: 'old', updatedAt: DateTime(2026, 1, 1)),
      );
      await store.upsertConversation(
        _conversation(id: 'newer', updatedAt: DateTime(2026, 4, 1)),
      );
      await store.upsertConversation(
        _conversation(
          id: 'pinned',
          updatedAt: DateTime(2025, 1, 1),
          pinned: true,
        ),
      );

      final summaries = await store.getAllSummaries();
      check(
        summaries.map((c) => c.id).toList(),
      ).deepEquals(['pinned', 'newer', 'old']);
    });

    test('summaries omit message bodies', () async {
      await store.upsertConversation(
        _conversation(
          id: 'c5',
          messages: List.generate(
            5,
            (i) => _message(id: 'm$i', content: 'body-$i'),
          ),
        ),
      );

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
          _message(id: 'child', metadata: {'parentId': 'parent-msg-id'}),
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
      await store.upsertConversation(
        _conversation(
          id: 'c8',
          messages: [
            _message(id: 'm1', content: 'first'),
            _message(id: 'm2', content: 'this is the last reply'),
          ],
        ),
      );

      final rows = await database.raw.query(
        'conversations',
        columns: ['last_message_preview', 'message_count'],
        where: 'id = ?',
        whereArgs: ['c8'],
      );
      check(
        rows.single['last_message_preview'],
      ).equals('this is the last reply');
      check(rows.single['message_count']).equals(2);
    });

    test('deleteAll wipes both tables', () async {
      await store.upsertConversation(
        _conversation(
          id: 'c9',
          messages: [_message(id: 'm1')],
        ),
      );

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
      await store.upsertConversation(
        _conversation(
          id: 'c10',
          messages: [_message(id: 'm1', content: 'one')],
        ),
      );

      await store.appendMessage(
        'c10',
        _message(id: 'm2', content: 'two', timestamp: DateTime(2027)),
      );

      final loaded = await store.getConversation('c10');
      check(
        loaded!.messages.map((m) => m.id).toList(),
      ).deepEquals(['m1', 'm2']);
    });

    test('updateMessage replaces existing payload', () async {
      await store.upsertConversation(
        _conversation(
          id: 'c11',
          messages: [_message(id: 'm1', content: 'before')],
        ),
      );

      await store.updateMessage(_message(id: 'm1', content: 'after'));

      final loaded = await store.getConversation('c11');
      check(loaded!.messages.single.content).equals('after');
    });

    test('deleteMessage removes a single row only', () async {
      await store.upsertConversation(
        _conversation(
          id: 'c12',
          messages: [
            _message(id: 'm1'),
            _message(id: 'm2'),
          ],
        ),
      );

      await store.deleteMessage('c12', 'm1');

      final ids = await store.getMessageIds('c12');
      check(ids).deepEquals(['m2']);
    });

    test('upsertMessageEnsuringConversation creates the conversation row '
        'when missing', () async {
      final scaffold = _conversation(id: 'new-conv', title: 'Streaming…');
      final msg = _message(id: 'm1', content: 'first chunk');

      await store.upsertMessageEnsuringConversation(
        scaffold: scaffold,
        message: msg,
      );

      final loaded = await store.getConversation('new-conv');
      check(loaded).isNotNull();
      check(loaded!.title).equals('Streaming…');
      check(loaded.messages.single.content).equals('first chunk');

      final rows = await database.raw.query(
        'conversations',
        columns: ['message_count', 'last_message_preview'],
        where: 'id = ?',
        whereArgs: ['new-conv'],
      );
      check(rows.single['message_count']).equals(1);
      check(rows.single['last_message_preview']).equals('first chunk');
    });

    test('upsertMessageEnsuringConversation leaves existing conversation '
        'header intact', () async {
      await store.upsertConversation(
        _conversation(
          id: 'c',
          title: 'Original Title',
          messages: [_message(id: 'm1', content: 'one')],
        ),
      );

      await store.upsertMessageEnsuringConversation(
        scaffold: _conversation(id: 'c', title: 'WRONG'),
        message: _message(id: 'm2', content: 'two', timestamp: DateTime(2027)),
      );

      final loaded = await store.getConversation('c');
      check(loaded!.title).equals('Original Title');
      check(loaded.messages.map((m) => m.id).toList()).deepEquals(['m1', 'm2']);
    });

    test('upsertMessageEnsuringConversation replaces the same message id '
        'across streaming updates', () async {
      final scaffold = _conversation(id: 'stream', title: 'Live');
      await store.upsertMessageEnsuringConversation(
        scaffold: scaffold,
        message: _message(id: 'a1', role: 'assistant', content: 'partial'),
      );
      await store.upsertMessageEnsuringConversation(
        scaffold: scaffold,
        message: _message(
          id: 'a1',
          role: 'assistant',
          content: 'partial then final',
        ),
      );

      final loaded = await store.getConversation('stream');
      check(loaded!.messages.length).equals(1);
      check(loaded.messages.single.content).equals('partial then final');
    });

    group('searchConversations (FTS5)', () {
      test('returns empty list for empty / whitespace query', () async {
        await store.upsertConversation(
          _conversation(
            id: 'a',
            title: 'Greetings',
            messages: [_message(id: 'm1', content: 'hello world')],
          ),
        );

        check(await store.searchConversations('')).isEmpty();
        check(await store.searchConversations('   ')).isEmpty();
      });

      test('matches by message content (FTS5)', () async {
        await store.upsertConversation(
          _conversation(
            id: 'a',
            title: 'Untitled',
            messages: [_message(id: 'm1', content: 'pelican brief')],
          ),
        );
        await store.upsertConversation(
          _conversation(
            id: 'b',
            title: 'Other',
            messages: [_message(id: 'm2', content: 'something else entirely')],
          ),
        );

        final results = await store.searchConversations('pelican');
        check(results.map((c) => c.id).toList()).deepEquals(['a']);
      });

      test('matches by title (LIKE)', () async {
        await store.upsertConversation(
          _conversation(
            id: 'a',
            title: 'Quarterly planning notes',
            messages: [_message(id: 'm1', content: 'foo')],
          ),
        );
        await store.upsertConversation(
          _conversation(
            id: 'b',
            title: 'Vacation ideas',
            messages: [_message(id: 'm2', content: 'foo')],
          ),
        );

        final results = await store.searchConversations('quarterly');
        check(results.map((c) => c.id).toList()).deepEquals(['a']);
      });

      test('dedupes when title and message both match', () async {
        await store.upsertConversation(
          _conversation(
            id: 'a',
            title: 'Pelican',
            messages: [_message(id: 'm1', content: 'I saw a pelican')],
          ),
        );

        final results = await store.searchConversations('pelican');
        check(results.length).equals(1);
        check(results.single.id).equals('a');
      });

      test('is case-insensitive and supports prefix matches', () async {
        await store.upsertConversation(
          _conversation(
            id: 'a',
            title: 'Hello World',
            messages: [_message(id: 'm1', content: 'Testing the indexer')],
          ),
        );

        final byTitle = await store.searchConversations('HELLO');
        check(byTitle.map((c) => c.id).toList()).deepEquals(['a']);

        final byPrefix = await store.searchConversations('test');
        check(byPrefix.map((c) => c.id).toList()).deepEquals(['a']);
      });

      test('sorts pinned first, then by updated_at desc', () async {
        await store.upsertConversation(
          _conversation(
            id: 'old',
            title: 'pelican A',
            updatedAt: DateTime(2026, 1, 1),
            messages: [_message(id: 'm1', content: 'x')],
          ),
        );
        await store.upsertConversation(
          _conversation(
            id: 'new',
            title: 'pelican B',
            updatedAt: DateTime(2026, 4, 1),
            messages: [_message(id: 'm2', content: 'x')],
          ),
        );
        await store.upsertConversation(
          _conversation(
            id: 'pinned',
            title: 'pelican C',
            updatedAt: DateTime(2025, 1, 1),
            pinned: true,
            messages: [_message(id: 'm3', content: 'x')],
          ),
        );

        final results = await store.searchConversations('pelican');
        check(
          results.map((c) => c.id).toList(),
        ).deepEquals(['pinned', 'new', 'old']);
      });

      test('excludes archived conversations by default', () async {
        await store.upsertConversation(
          _conversation(
            id: 'live',
            title: 'pelican live',
            messages: [_message(id: 'm1', content: 'x')],
          ),
        );
        await store.upsertConversation(
          _conversation(
            id: 'arch',
            title: 'pelican arch',
            archived: true,
            messages: [_message(id: 'm2', content: 'x')],
          ),
        );

        final visible = await store.searchConversations('pelican');
        check(visible.map((c) => c.id).toList()).deepEquals(['live']);

        final all = await store.searchConversations(
          'pelican',
          includeArchived: true,
        );
        check(all.map((c) => c.id).toSet()).deepEquals({'live', 'arch'});
      });

      test('FTS index reflects message updates', () async {
        await store.upsertConversation(
          _conversation(
            id: 'a',
            title: 'untitled',
            messages: [_message(id: 'm1', content: 'before')],
          ),
        );

        await store.updateMessage(_message(id: 'm1', content: 'pelican now'));

        check(
          (await store.searchConversations('before')).map((c) => c.id),
        ).isEmpty();
        check(
          (await store.searchConversations(
            'pelican',
          )).map((c) => c.id).toList(),
        ).deepEquals(['a']);
      });

      test('FTS index reflects message deletions', () async {
        await store.upsertConversation(
          _conversation(
            id: 'a',
            title: 'untitled',
            messages: [_message(id: 'm1', content: 'pelican')],
          ),
        );

        check(
          (await store.searchConversations(
            'pelican',
          )).map((c) => c.id).toList(),
        ).deepEquals(['a']);

        await store.deleteMessage('a', 'm1');

        check(
          (await store.searchConversations('pelican')).map((c) => c.id),
        ).isEmpty();
      });

      test('sanitizes FTS-special characters in user input', () async {
        await store.upsertConversation(
          _conversation(
            id: 'a',
            title: 'untitled',
            messages: [_message(id: 'm1', content: 'hello world')],
          ),
        );

        // Quotes / parens / asterisks would be FTS5 syntax — must be
        // stripped, not passed through.
        final results = await store.searchConversations('"hello"*(world');
        check(results.map((c) => c.id).toList()).deepEquals(['a']);
      });

      test(
        'returns empty when query strips to nothing rather than throwing',
        () async {
          await store.upsertConversation(
            _conversation(
              id: 'a',
              messages: [_message(id: 'm1', content: 'hello')],
            ),
          );

          final results = await store.searchConversations('***');
          check(results).isEmpty();
        },
      );
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
