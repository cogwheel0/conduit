import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_open_webui_server.dart';

/// uuid4 format: version nibble must be 4, variant nibble 8/9/a/b.
final RegExp uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

String paddedId(int i) => 'chat-${i.toString().padLeft(3, '0')}';

void main() {
  group('getChatList pagination', () {
    late FakeOpenWebUiServer server;

    setUp(() {
      server = FakeOpenWebUiServer();
      // 130 chats with strictly increasing updated_at so chat-130 is newest.
      for (var i = 1; i <= 130; i++) {
        server.seedChat(
          id: paddedId(i),
          blob: {'title': 'Chat $i'},
          createdAt: 1000 + i,
          updatedAt: 2000 + i,
        );
      }
    });

    test('returns all chats when page is null', () {
      check(server.getChatList()).length.equals(130);
    });

    test('pages are exactly 60 items', () {
      check(server.getChatList(page: 1)).length.equals(60);
      check(server.getChatList(page: 2)).length.equals(60);
      check(server.getChatList(page: 3)).length.equals(10);
      check(server.getChatList(page: 4)).isEmpty();
    });

    test('orders by updated_at descending across pages', () {
      final ids = [
        ...server.getChatList(page: 1),
        ...server.getChatList(page: 2),
        ...server.getChatList(page: 3),
      ].map((item) => item['id']).toList();

      final expected = [for (var i = 130; i >= 1; i--) paddedId(i)];
      check(ids).deepEquals(expected);
    });

    test('page 1 starts at the most recently updated chat', () {
      final first = server.getChatList(page: 1).first;
      check(first['id']).equals(paddedId(130));
      check(first['updated_at']).equals(2130);
    });

    test('page boundary is contiguous and non-overlapping', () {
      final page1 = server.getChatList(page: 1);
      final page2 = server.getChatList(page: 2);
      check(page1.last['id']).equals(paddedId(71));
      check(page2.first['id']).equals(paddedId(70));
    });
  });

  group('getChatList ordering tiebreak', () {
    test('equal updated_at falls back to id ascending', () {
      final server = FakeOpenWebUiServer();
      for (final id in ['bbb', 'aaa', 'ccc']) {
        server.seedChat(
          id: id,
          blob: {'title': id},
          createdAt: 1,
          updatedAt: 500,
        );
      }
      server.seedChat(
        id: 'zzz-newest',
        blob: {'title': 'newest'},
        createdAt: 1,
        updatedAt: 900,
      );

      final ids = server.getChatList().map((item) => item['id']).toList();
      check(ids).deepEquals(['zzz-newest', 'aaa', 'bbb', 'ccc']);
    });
  });

  group('getChatList filters', () {
    late FakeOpenWebUiServer server;

    setUp(() {
      server = FakeOpenWebUiServer();
      server.seedChat(
        id: 'plain',
        blob: {'title': 'plain'},
        createdAt: 1,
        updatedAt: 10,
      );
      server.seedChat(
        id: 'pinned',
        blob: {'title': 'pinned'},
        createdAt: 1,
        updatedAt: 20,
        pinned: true,
      );
      server.seedChat(
        id: 'foldered',
        blob: {'title': 'foldered'},
        createdAt: 1,
        updatedAt: 30,
        folderId: 'folder-1',
      );
      server.seedChat(
        id: 'archived',
        blob: {'title': 'archived'},
        createdAt: 1,
        updatedAt: 40,
        archived: true,
      );
    });

    List<Object?> ids({bool includePinned = false, bool includeFolders = false}) =>
        server
            .getChatList(
              includePinned: includePinned,
              includeFolders: includeFolders,
            )
            .map((item) => item['id'])
            .toList();

    test('excludes pinned, foldered, and archived by default', () {
      check(ids()).deepEquals(['plain']);
    });

    test('includePinned adds pinned chats', () {
      check(ids(includePinned: true)).deepEquals(['pinned', 'plain']);
    });

    test('includeFolders adds chats with a folder_id', () {
      check(ids(includeFolders: true)).deepEquals(['foldered', 'plain']);
    });

    test('archived chats are excluded even with both flags', () {
      check(
        ids(includePinned: true, includeFolders: true),
      ).deepEquals(['foldered', 'pinned', 'plain']);
    });

    test('items have the ChatTitleIdResponse shape', () {
      final item = server.getChatList().single;
      check(item.keys.toSet()).deepEquals(
        {'id', 'title', 'updated_at', 'created_at', 'last_read_at'},
      );
      check(item['title']).equals('plain');
      check(item['created_at']).equals(1);
      check(item['updated_at']).equals(10);
    });
  });

  group('createChat', () {
    test('generates a uuid4 id on the server', () {
      final server = FakeOpenWebUiServer();
      final created = server.createChat({'title': 'Hello'});
      check(created['id']).isA<String>().matchesPattern(uuidV4);
    });

    test('generates unique ids across creations', () {
      final server = FakeOpenWebUiServer();
      final ids = <String>{
        for (var i = 0; i < 50; i++)
          server.createChat({'title': 'Chat $i'})['id'] as String,
      };
      check(ids).length.equals(50);
    });

    test('ignores a client-supplied id but stores the blob verbatim', () {
      final server = FakeOpenWebUiServer();
      final created = server.createChat({
        'id': 'client-chosen-id',
        'title': 'Hello',
      });
      check(created['id']).isA<String>().matchesPattern(uuidV4);
      check(created['id']).not((it) => it.equals('client-chosen-id'));
      // The id key inside the chat blob is untouched server-side.
      check(created['chat']).isA<Map<String, dynamic>>()['id']
          .equals('client-chosen-id');
      check(server.getChatById('client-chosen-id')).isNull();
    });

    test('takes the title from the blob, defaulting to New Chat', () {
      final server = FakeOpenWebUiServer();
      check(server.createChat({'title': 'Custom'})['title']).equals('Custom');
      check(server.createChat(<String, dynamic>{})['title']).equals('New Chat');
    });

    test('stamps created_at and updated_at from the internal clock', () {
      final server = FakeOpenWebUiServer();
      server.tick(100);
      final created = server.createChat({'title': 'Hello'});
      check(created['created_at']).equals(100);
      check(created['updated_at']).equals(100);
    });

    test('uses an injected clock when provided', () {
      var now = 42;
      final server = FakeOpenWebUiServer(nowEpochSeconds: () => now);
      final created = server.createChat({'title': 'Hello'});
      check(created['created_at']).equals(42);

      now = 99;
      final updated = server.updateChat(created['id'] as String, {
        'title': 'Hello',
      });
      check(updated).isNotNull();
      check(updated!['updated_at']).equals(99);
    });

    test('returns a ChatResponse-shaped map', () {
      final server = FakeOpenWebUiServer();
      server.seedFolder('f1');
      final created = server.createChat({'title': 'Hello'}, folderId: 'f1');
      check(created.keys.toSet()).deepEquals({
        'id',
        'user_id',
        'title',
        'chat',
        'updated_at',
        'created_at',
        'share_id',
        'archived',
        'pinned',
        'meta',
        'folder_id',
        'tasks',
        'summary',
      });
      check(created['archived']).equals(false);
      check(created['pinned']).equals(false);
      check(created['folder_id']).equals('f1');
    });

    test('deep-copies the blob so later caller mutations are not visible', () {
      final server = FakeOpenWebUiServer();
      final blob = <String, dynamic>{
        'title': 'Hello',
        'history': <String, dynamic>{
          'messages': <String, dynamic>{},
          'currentId': null,
        },
      };
      final id = server.createChat(blob)['id'] as String;

      (blob['history'] as Map<String, dynamic>)['currentId'] = 'sneaky';
      final stored = server.getChatById(id)!['chat'] as Map<String, dynamic>;
      check((stored['history'] as Map<String, dynamic>)['currentId']).isNull();
    });
  });

  group('getChatById', () {
    test('returns null for a missing id', () {
      check(FakeOpenWebUiServer().getChatById('nope')).isNull();
    });

    test('returns the stored blob and envelope fields', () {
      final server = FakeOpenWebUiServer();
      server.seedChat(
        id: 'c1',
        blob: {
          'title': 'Seeded',
          'models': ['llama3'],
        },
        createdAt: 11,
        updatedAt: 22,
      );
      final chat = server.getChatById('c1')!;
      check(chat['id']).equals('c1');
      check(chat['title']).equals('Seeded');
      check(chat['created_at']).equals(11);
      check(chat['updated_at']).equals(22);
      check(chat['chat']).isA<Map<String, dynamic>>()['models']
          .isA<List<Object?>>()
          .deepEquals(['llama3']);
    });

    test('returns a copy: mutating the result does not change the store', () {
      final server = FakeOpenWebUiServer();
      server.seedChat(
        id: 'c1',
        blob: {'title': 'Seeded'},
        createdAt: 1,
        updatedAt: 2,
      );
      final first = server.getChatById('c1')!;
      (first['chat'] as Map<String, dynamic>)['title'] = 'mutated';
      check(
        server.getChatById('c1')!['chat'] as Map<String, dynamic>,
      )['title'].equals('Seeded');
    });
  });

  group('updateChat', () {
    test('returns null for a missing id', () {
      check(
        FakeOpenWebUiServer().updateChat('nope', {'title': 'x'}),
      ).isNull();
    });

    test('restamps updated_at from the clock, keeping created_at', () {
      final server = FakeOpenWebUiServer();
      server.tick(10);
      final id = server.createChat({'title': 'Hello'})['id'] as String;
      server.tick(5);

      final updated = server.updateChat(id, {'title': 'Hello'})!;
      check(updated['created_at']).equals(10);
      check(updated['updated_at']).equals(15);
    });

    test(
      'shallow-merges the incoming blob over the existing one '
      '(vendored route does {**existing, **incoming})',
      () {
        final server = FakeOpenWebUiServer();
        final id = server.createChat({
          'title': 'Hello',
          'models': ['llama3'],
          'params': {'temperature': 0.5},
        })['id'] as String;

        final updated = server.updateChat(id, {
          'title': 'Renamed',
          'params': {'top_p': 0.9},
        })!;
        final blob = updated['chat'] as Map<String, dynamic>;
        // Untouched top-level keys survive.
        check(blob['models']).isA<List<Object?>>().deepEquals(['llama3']);
        // Provided top-level keys are replaced wholesale (not deep-merged).
        check(blob['params']).isA<Map<String, dynamic>>().deepEquals({
          'top_p': 0.9,
        });
        check(updated['title']).equals('Renamed');
      },
    );

    test('re-derives title from the merged blob', () {
      final server = FakeOpenWebUiServer();
      // No title anywhere: stays New Chat.
      final id = server.createChat(<String, dynamic>{})['id'] as String;
      final updated = server.updateChat(id, {'models': <Object?>[]})!;
      check(updated['title']).equals('New Chat');

      // Existing title survives an update that omits it (merge keeps the key).
      final id2 = server.createChat({'title': 'Keep me'})['id'] as String;
      final updated2 = server.updateChat(id2, {'models': <Object?>[]})!;
      check(updated2['title']).equals('Keep me');
    });

    test('never rejects stale writes (no concurrency control)', () {
      var now = 100;
      final server = FakeOpenWebUiServer(nowEpochSeconds: () => now);
      final id = server.createChat({'title': 'v1'})['id'] as String;

      now = 200;
      check(server.updateChat(id, {'title': 'v2'})).isNotNull();

      // A write stamped from an earlier clock still wins unconditionally.
      now = 50;
      final stale = server.updateChat(id, {'title': 'v3-stale'});
      check(stale).isNotNull();
      check(stale!['updated_at']).equals(50);
      check(server.getChatById(id)!['title']).equals('v3-stale');
    });
  });

  group('updateChat output-to-content re-derivation', () {
    Map<String, dynamic> outputItem(String text) => <String, dynamic>{
          'type': 'message',
          'id': 'msg_1',
          'status': 'completed',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': text, 'annotations': <Object?>[]},
          ],
        };

    Map<String, dynamic> blobWith({
      required String content,
      List<Object?>? output,
      String role = 'assistant',
    }) =>
        <String, dynamic>{
          'title': 'Rederive',
          'history': {
            'currentId': 'a1',
            'messages': {
              'a1': {
                'id': 'a1',
                'parentId': null,
                'childrenIds': <String>[],
                'role': role,
                'content': content,
                'timestamp': 1,
                'output': ?output,
              },
            },
          },
        };

    Map<String, dynamic> storedMessage(
      FakeOpenWebUiServer server,
      String id,
    ) {
      final chat = server.getChatById(id)!['chat'] as Map<String, dynamic>;
      final history = chat['history'] as Map<String, dynamic>;
      final messages = history['messages'] as Map<String, dynamic>;
      return messages['a1'] as Map<String, dynamic>;
    }

    test('rewrites assistant content when output changed', () {
      final server = FakeOpenWebUiServer();
      final id = server.createChat(
        blobWith(content: 'old content', output: [outputItem('old text')]),
      )['id'] as String;

      server.updateChat(
        id,
        blobWith(content: 'old content', output: [outputItem('new text')]),
      );

      check(
        because: 'the vendored route rewrites content = '
            'serialize_output(output) when output deep-differs '
            '(routers/chats.py update_chat_by_id)',
        storedMessage(server, id)['content'],
      ).equals('new text');
    });

    test('keeps content set independently when output is unchanged', () {
      final server = FakeOpenWebUiServer();
      final output = [outputItem('same text')];
      final id = server.createChat(
        blobWith(content: 'same text', output: output),
      )['id'] as String;

      // e.g. a `replace` event or an outlet-filter footer edited content
      // without touching output: the route must NOT revert it.
      server.updateChat(
        id,
        blobWith(content: 'independently edited content', output: output),
      );

      check(storedMessage(server, id)['content'])
          .equals('independently edited content');
    });

    test('rewrites when output appears on a message that had none', () {
      final server = FakeOpenWebUiServer();
      final id = server.createChat(
        blobWith(content: 'streamed content'),
      )['id'] as String;

      server.updateChat(
        id,
        blobWith(content: 'streamed content', output: [outputItem('final')]),
      );

      check(storedMessage(server, id)['content']).equals('final');
    });

    test('ignores user messages and empty output lists', () {
      final server = FakeOpenWebUiServer();
      final userId = server.createChat(
        blobWith(
          content: 'user content',
          output: [outputItem('ignored')],
          role: 'user',
        ),
      )['id'] as String;
      server.updateChat(
        userId,
        blobWith(
          content: 'user content',
          output: [outputItem('changed')],
          role: 'user',
        ),
      );
      check(storedMessage(server, userId)['content']).equals('user content');

      // Python truthiness: an empty output list never triggers a rewrite.
      final emptyId = server.createChat(
        blobWith(content: 'kept', output: const <Object?>[]),
      )['id'] as String;
      server.updateChat(
        emptyId,
        blobWith(content: 'kept', output: const <Object?>[]),
      );
      check(storedMessage(server, emptyId)['content']).equals('kept');
    });

    test('fixture 08 chat: changed output rewrites the stored content', () {
      final raw = jsonDecode(
        File('test/fixtures/chat_blobs/08_unknown_future_keys.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      final blob = raw['chat'] as Map<String, dynamic>;

      final server = FakeOpenWebUiServer();
      final id = server.createChat(blob)['id'] as String;

      // Edit the assistant's output (the reasoning item keeps its duration,
      // the message item's text changes), then push the whole blob back.
      final edited = jsonDecode(jsonEncode(blob)) as Map<String, dynamic>;
      final history = edited['history'] as Map<String, dynamic>;
      final messages = history['messages'] as Map<String, dynamic>;
      final assistant =
          messages['fa11fa11-2222-4333-8444-555566667777']
              as Map<String, dynamic>;
      final output = assistant['output'] as List<dynamic>;
      final messageItem = output[1] as Map<String, dynamic>;
      ((messageItem['content'] as List).first as Map<String, dynamic>)['text'] =
          'Edited: the night sky is dark because the universe is young and expanding.';

      server.updateChat(id, edited);

      final stored = server.getChatById(id)!['chat'] as Map<String, dynamic>;
      final storedAssistant = ((stored['history']
              as Map<String, dynamic>)['messages']
          as Map<String, dynamic>)['fa11fa11-2222-4333-8444-555566667777']
          as Map<String, dynamic>;

      // serialize_output renders the reasoning item as an HTML-escaped
      // blockquote details block, then the message text verbatim.
      check(storedAssistant['content']).equals(
        '<details type="reasoning" done="true" duration="3">\n'
        '<summary>Thought for 3 seconds</summary>\n'
        '&gt; Olbers&#x27; paradox...\n'
        '</details>\n'
        'Edited: the night sky is dark because the universe is young and '
        'expanding.',
      );
    });
  });

  group('serializeOutput', () {
    test('renders message items as trimmed concatenated text parts', () {
      check(
        FakeOpenWebUiServer.serializeOutput([
          {
            'type': 'message',
            'content': [
              {'type': 'output_text', 'text': '  hello  '},
              {'type': 'output_text', 'text': ''},
              {'type': 'output_text', 'text': 'world'},
            ],
          },
        ]),
      ).equals('hello\nworld');
    });

    test('renders reasoning with quoting and Python html.escape semantics',
        () {
      check(
        FakeOpenWebUiServer.serializeOutput([
          {
            'type': 'reasoning',
            'status': 'completed',
            'duration': 3,
            'summary': null,
            'content': [
              {'type': 'output_text', 'text': "a < b & \"c\" 'd'\n> quoted"},
            ],
          },
          {
            'type': 'message',
            'content': [
              {'type': 'output_text', 'text': 'answer'},
            ],
          },
        ]),
      ).equals(
        '<details type="reasoning" done="true" duration="3">\n'
        '<summary>Thought for 3 seconds</summary>\n'
        '&gt; a &lt; b &amp; &quot;c&quot; &#x27;d&#x27;\n&gt; quoted\n'
        '</details>\n'
        'answer',
      );
    });

    test('an in-progress trailing reasoning item renders as not done', () {
      check(
        FakeOpenWebUiServer.serializeOutput([
          {
            'type': 'reasoning',
            'status': 'in_progress',
            'content': [
              {'type': 'output_text', 'text': 'thinking'},
            ],
          },
        ]),
      ).equals(
        '<details type="reasoning" done="false">\n'
        '<summary>Thinking…</summary>\n&gt; thinking\n</details>',
      );
    });

    test('skips unknown item types like the upstream if/elif chain', () {
      check(
        FakeOpenWebUiServer.serializeOutput([
          {'type': 'mystery_future_item', 'payload': 42},
          {
            'type': 'message',
            'content': [
              {'type': 'output_text', 'text': 'kept'},
            ],
          },
        ]),
      ).equals('kept');
    });

    test('throws for item types whose rendering is not ported', () {
      check(
        () => FakeOpenWebUiServer.serializeOutput([
          {'type': 'function_call', 'call_id': 'c1', 'name': 'f'},
        ]),
      ).throws<UnsupportedError>();
    });
  });

  group('folders', () {
    test('createChat throws a 404-equivalent for an unknown folder id', () {
      final server = FakeOpenWebUiServer();
      check(() => server.createChat({'title': 'x'}, folderId: 'missing'))
          .throws<FakeOpenWebUiHttpException>()
          .has((e) => e.statusCode, 'statusCode')
          .equals(404);
      check(
        because: 'the vendored route rejects the chat before inserting it '
            '(routers/chats.py create_new_chat)',
        server.getChatList(includeFolders: true),
      ).isEmpty();
    });

    test('createChat accepts a folder registered via seedFolder', () {
      final server = FakeOpenWebUiServer();
      server.seedFolder('folder-1');
      final created = server.createChat({'title': 'x'}, folderId: 'folder-1');
      check(created['folder_id']).equals('folder-1');
    });

    test('createChat without a folder id needs no registered folders', () {
      final server = FakeOpenWebUiServer();
      check(server.createChat({'title': 'x'})['folder_id']).isNull();
    });

    test('seedChat registers its folder id as existing', () {
      final server = FakeOpenWebUiServer();
      server.seedChat(
        id: 'c1',
        blob: {'title': 'seeded'},
        createdAt: 1,
        updatedAt: 2,
        folderId: 'seeded-folder',
      );
      final created =
          server.createChat({'title': 'x'}, folderId: 'seeded-folder');
      check(created['folder_id']).equals('seeded-folder');
    });
  });

  group('deleteChat', () {
    test('removes an existing chat and returns true', () {
      final server = FakeOpenWebUiServer();
      final id = server.createChat({'title': 'Hello'})['id'] as String;

      check(server.deleteChat(id)).isTrue();
      check(server.getChatById(id)).isNull();
      check(server.getChatList()).isEmpty();
    });

    test('returns false for a missing id', () {
      check(FakeOpenWebUiServer().deleteChat('nope')).isFalse();
    });

    test('returns false when deleting twice', () {
      final server = FakeOpenWebUiServer();
      final id = server.createChat({'title': 'Hello'})['id'] as String;
      check(server.deleteChat(id)).isTrue();
      check(server.deleteChat(id)).isFalse();
    });
  });

  group('seedChat', () {
    test('uses explicit timestamps verbatim', () {
      final server = FakeOpenWebUiServer();
      server.tick(9999); // The clock must not influence seeded rows.
      server.seedChat(
        id: 'seeded',
        blob: {'title': 'Seeded'},
        createdAt: 123,
        updatedAt: 456,
      );
      final chat = server.getChatById('seeded')!;
      check(chat['created_at']).equals(123);
      check(chat['updated_at']).equals(456);
    });

    test('seeded timestamps drive list ordering', () {
      final server = FakeOpenWebUiServer();
      server.seedChat(
        id: 'old',
        blob: {'title': 'old'},
        createdAt: 1,
        updatedAt: 100,
      );
      server.seedChat(
        id: 'new',
        blob: {'title': 'new'},
        createdAt: 1,
        updatedAt: 200,
      );
      check(
        server.getChatList().map((item) => item['id']).toList(),
      ).deepEquals(['new', 'old']);
    });
  });
}
