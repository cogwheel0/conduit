import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:conduit_core/features/chat/services/chat_branch_service.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

Map<String, dynamic> _message(
  String id, {
  String? parent,
  List<String> children = const <String>[],
  String role = 'user',
  int timestamp = 1,
}) => <String, dynamic>{
  'id': id,
  'parentId': parent,
  'childrenIds': children,
  'role': role,
  'content': 'text of $id',
  'timestamp': timestamp,
  'futureMessageKey': 'keep-$id',
};

Map<String, dynamic> _blob(
  Map<String, Map<String, dynamic>> messages, {
  String? currentId,
  String title = 'Branches',
}) => <String, dynamic>{
  'title': title,
  'params': <String, dynamic>{'temperature': 0.3},
  'futureEnvelopeKey': <String, dynamic>{'kept': true},
  'history': <String, dynamic>{'currentId': ?currentId, 'messages': messages},
};

/// u1 has two answers. The last answer (a2) continues; a1 is the other answer.
/// A second, edited first message (e1) is a root sibling of u1 with its own
/// descendants. The active branch is u1 > a2 > u2 > a3.
Map<String, dynamic> _branchedBlob({String title = 'Branches'}) => _blob(
  {
    'u1': _message('u1', children: ['a1', 'a2']),
    'a1': _message('a1', parent: 'u1', role: 'assistant', timestamp: 90),
    'a2': _message(
      'a2',
      parent: 'u1',
      role: 'assistant',
      children: ['u2'],
      timestamp: 10,
    ),
    'u2': _message('u2', parent: 'a2', children: ['a3']),
    'a3': _message('a3', parent: 'u2', role: 'assistant'),
    'e1': _message('e1', children: ['b1']),
    'b1': _message('b1', parent: 'e1', role: 'assistant', children: ['e2']),
    'e2': _message('e2', parent: 'b1', children: ['b2']),
    'b2': _message('b2', parent: 'e2', role: 'assistant'),
  },
  currentId: 'a3',
  title: title,
);

ChatRows _rows(
  Map<String, dynamic> blob, {
  String id = 'c1',
  int updatedAt = 1,
  String title = 'Branches',
}) => ChatBlobMapper.blobToRows(
  chatId: id,
  title: title,
  createdAt: 1,
  updatedAt: updatedAt,
  blob: blob,
);

Map<String, dynamic> _envelope(
  Map<String, dynamic> blob, {
  required String id,
  String title = 'Branches (fork)',
  String? folderId,
  int updatedAt = 50,
}) => <String, dynamic>{
  'id': id,
  'user_id': 'user-1',
  'title': title,
  'chat': blob,
  'updated_at': updatedAt,
  'created_at': 50,
  'share_id': null,
  'archived': false,
  'pinned': false,
  'folder_id': folderId,
  'meta': <String, dynamic>{'forked_from': 'c1', 'tags': <String>[]},
};

/// 130 messages on one path (well past a 50-row presentation window), plus an
/// alternative first message whose whole branch lies outside that window.
Map<String, dynamic> _longBlob() {
  final messages = <String, Map<String, dynamic>>{};
  String? parent;
  for (var i = 0; i < 130; i++) {
    final id = 'm$i';
    messages[id] = _message(
      id,
      parent: parent,
      role: i.isEven ? 'user' : 'assistant',
      children: i == 129 ? const <String>[] : ['m${i + 1}'],
      timestamp: i + 1,
    );
    parent = id;
  }
  messages['alt0'] = _message('alt0', children: ['alt1']);
  messages['alt1'] = _message('alt1', parent: 'alt0', role: 'assistant');
  return _blob(messages, currentId: 'm129');
}

DioException _http(int status, [Object? body]) => DioException(
  requestOptions: RequestOptions(path: '/api/v1/chats/c1/fork'),
  response: Response<Object?>(
    requestOptions: RequestOptions(path: '/api/v1/chats/c1/fork'),
    statusCode: status,
    data: body == null ? null : utf8.encode(jsonEncode(body)),
  ),
);

void main() {
  late AppDatabase db;
  late ChatLocks locks;
  var ownerCurrent = true;
  var now = 100;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    locks = ChatLocks();
    ownerCurrent = true;
    now = 100;
  });
  tearDown(() => db.close());

  ChatBranchService service({
    ChatBranchGraphOffload? graphOffload,
    ChatEnvelopeLoader? loader,
    bool Function(String chatId)? running,
  }) => ChatBranchService(
    database: db,
    locks: locks,
    ownerIsCurrent: () => ownerCurrent,
    nowEpochSeconds: () => now++,
    graphOffload: graphOffload,
    authoritativeLoader: loader,
    responseIsRunning: running,
  );

  Future<void> seed(Map<String, dynamic> blob, {String id = 'c1'}) =>
      db.chatsDao.upsertServerChat(rows: _rows(blob, id: id));

  Future<Map<String, String>> storedPayloads(String chatId) async => {
    for (final row in await db.messagesDao.getForChat(chatId))
      row.id: row.payload,
  };

  group('ChatBranchGraph', () {
    test('follows the last child in list order, never the newest', () {
      final graph = ChatBranchGraph.fromEnvelope(<String, dynamic>{
        'chat': _branchedBlob(),
      });

      // a1 has the newer timestamp (90 against 10), but a2 is listed last, so
      // a2 and its descendants are what selecting u1 leads to.
      check(graph.leafBelow('u1')).equals('a3');
      check(graph.leafBelow('a1')).equals('a1');
      check(graph.leafBelow('e1')).equals('b2');
    });

    test('lists same-role alternatives in display order, roots included', () {
      final graph = ChatBranchGraph.fromEnvelope(<String, dynamic>{
        'chat': _branchedBlob(),
      });

      check(graph.siblingsOf('a2')!.ids).deepEquals(['a1', 'a2']);
      check(graph.siblingsOf('a2')!.index).equals(1);
      check(graph.siblingsOf('e1')!.ids).deepEquals(['u1', 'e1']);
      check(graph.siblingsOf('missing')).isNull();
      check(graph.isAlternativeOf('a1', 'a2')).isTrue();
      check(graph.isAlternativeOf('a2', 'a2')).isFalse();
      check(graph.isAlternativeOf('u2', 'a2')).isFalse();
      check(graph.isAlternativeOf('b1', 'a2')).isFalse();
    });

    test('carries a one-line preview of each alternative', () {
      final long = List<String>.filled(60, 'word').join('  ');
      final blob = _blob({
        'r': _message('r', children: ['x', 'y', 'z']),
        'x': _message('x', parent: 'r', role: 'assistant'),
        'y': {
          ..._message('y', parent: 'r', role: 'assistant'),
          'content': 'first line\n\n  second line',
        },
        'z': {
          ..._message('z', parent: 'r', role: 'assistant'),
          'content': long,
        },
      }, currentId: 'x');
      final graph = ChatBranchGraph.fromEnvelope(<String, dynamic>{
        'chat': blob,
      });

      final previews = graph.siblingsOf('x')!.previews;
      check(previews['x']).equals('text of x');
      check(previews['y']).equals('first line second line');
      check(previews['z']!.length).isLessOrEqual(161);
      check(previews['z']!).endsWith('…');
      check(previews['z']!).not((it) => it.contains('  '));
    });

    test('a version without text has no preview', () {
      final blob = _blob({
        'r': _message('r', children: ['x', 'y']),
        'x': {
          ..._message('x', parent: 'r', role: 'assistant'),
          'content': '   ',
        },
        'y': {
          ..._message('y', parent: 'r', role: 'assistant'),
          'content': [
            {'type': 'image_url', 'image_url': 'data:'},
            {'type': 'text', 'text': 'look at this'},
          ],
        },
      }, currentId: 'x');
      final graph = ChatBranchGraph.fromEnvelope(<String, dynamic>{
        'chat': blob,
      });

      final previews = graph.siblingsOf('x')!.previews;
      check(previews.containsKey('x')).isFalse();
      check(previews['y']).equals('look at this');
    });

    test('a child the parent forgot to list is still its child', () {
      final blob = _blob({
        'r': _message('r', children: ['x']),
        'x': _message('x', parent: 'r', role: 'assistant'),
        'y': _message('y', parent: 'r', role: 'assistant'),
      }, currentId: 'x');
      final graph = ChatBranchGraph.fromEnvelope(<String, dynamic>{
        'chat': blob,
      });

      check(graph.siblingsOf('x')!.ids).deepEquals(['x', 'y']);
      check(graph.leafBelow('r')).equals('y');
    });

    test('a cycle, a missing child and an orphan end the walk', () {
      final blob = _blob({
        'a': _message('a', parent: 'c', children: ['b']),
        'b': _message('b', parent: 'a', role: 'assistant', children: ['c']),
        'c': _message('c', parent: 'b', children: ['a', 'ghost']),
        'orphan': _message('orphan', parent: 'nowhere', role: 'assistant'),
      }, currentId: 'c');
      final before = jsonEncode(blob);
      final graph = ChatBranchGraph.fromEnvelope(<String, dynamic>{
        'chat': blob,
      });

      check(graph.leafBelow('a')).equals('c');
      check(graph.leafBelow('ghost')).isNull();
      check(graph.leafBelow('orphan')).equals('orphan');
      check(graph.siblingsOf('a')!.ids).deepEquals(['a']);
      check(jsonEncode(blob)).equals(before);
    });

    test('a chat without history has an empty graph', () {
      final graph = ChatBranchGraph.fromEnvelope(<String, dynamic>{
        'chat': <String, dynamic>{'title': 'x'},
      });

      check(graph.contains('x')).isFalse();
      check(graph.leafBelow('x')).isNull();
      check(graph.siblingsOf('x')).isNull();
    });
  });

  group('readGraph', () {
    test('reads every branch, not only the visible window', () async {
      await seed(_longBlob());

      var offloaded = 0;
      final graph = await service(
        graphOffload: (envelope) async {
          offloaded++;
          return ChatBranchGraph.fromEnvelope(envelope);
        },
      ).readGraph('c1');

      check(graph).isNotNull();
      check(offloaded).equals(1);
      // Every message is in the graph, the far end of the path included.
      for (final id in [for (var i = 0; i < 130; i++) 'm$i', 'alt0', 'alt1']) {
        check(graph!.contains(id)).isTrue();
      }
      check(graph!.contains('ghost')).isFalse();
      check(graph.leafBelow('alt0')).equals('alt1');
      check(graph.siblingsOf('m0')!.ids).deepEquals(['m0', 'alt0']);
    });

    test('a small graph is parsed inline', () async {
      await seed(_branchedBlob());
      var offloaded = 0;

      final graph = await service(
        graphOffload: (envelope) async {
          offloaded++;
          return ChatBranchGraph.fromEnvelope(envelope);
        },
      ).readGraph('c1');

      for (final id in ['u1', 'a1', 'a2', 'u2', 'a3', 'e1', 'b1', 'e2', 'b2']) {
        check(graph!.contains(id)).isTrue();
      }
      check(offloaded).equals(0);
    });

    test('an absent chat has no graph', () async {
      check(await service().readGraph('nope')).isNull();
    });

    test(
      'a body that is not stored is loaded for the captured account',
      () async {
        await db.chatsDao.upsertEnvelopeStub(
          id: 'c1',
          title: 'Stub',
          createdAt: 1,
          updatedAt: 5,
        );
        final asked = <String>[];

        final graph = await service(
          loader: (chatId) async {
            asked.add(chatId);
            return _envelope(_branchedBlob(), id: 'c1', updatedAt: 5);
          },
        ).readGraph('c1');

        check(asked).deepEquals(['c1']);
        check(graph!.leafBelow('e1')).equals('b2');
        check((await db.chatsDao.getChat('c1'))!.bodySynced).isTrue();
      },
    );

    test('a body that cannot be loaded is not a graph to branch', () async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'c1',
        title: 'Stub',
        createdAt: 1,
        updatedAt: 5,
      );

      await expectLater(
        service().readGraph('c1'),
        throwsA(
          isA<ChatBranchException>().having(
            (e) => e.reason,
            'reason',
            ChatBranchFailure.unavailable,
          ),
        ),
      );
      await expectLater(
        service(loader: (_) async => _envelope(_branchedBlob(), id: 'other'))
            .readGraph('c1'),
        throwsA(isA<ChatBranchException>()),
      );
    });

    test('a changed owner reads nothing', () async {
      await seed(_branchedBlob());
      ownerCurrent = false;

      await expectLater(
        service().readGraph('c1'),
        throwsA(
          isA<ChatBranchException>().having(
            (e) => e.reason,
            'reason',
            ChatBranchFailure.ownerChanged,
          ),
        ),
      );
    });
  });

  group('selectBranch', () {
    test(
      'points currentId at the leaf and queues one flagged update',
      () async {
        await seed(_branchedBlob());
        final before = await storedPayloads('c1');

        final selection = await service().selectBranch(
          chatId: 'c1',
          messageId: 'a1',
          alternativeTo: 'a2',
        );

        check(selection.leafId).equals('a1');
        check(selection.changed).isTrue();
        final chat = (await db.chatsDao.getChat('c1'))!;
        check(chat.currentMessageId).equals('a1');
        check(chat.dirty).isTrue();
        final ops = await db.outboxDao.pendingForChat('c1');
        check(ops).length.equals(1);
        check(ops.single.kind).equals('updateChat');
        check(jsonDecode(ops.single.payload) as Map)
            .deepEquals({'branchEdit': true});
        check(await db.outboxDao.hasPendingBranchEdit('c1')).isTrue();
        check(await db.outboxDao.hasPendingParamsEdit('c1')).isFalse();
        // Every message, its children order and its unknown keys are untouched,
        // and no message was marked dirty.
        check(await storedPayloads('c1')).deepEquals(before);
        check((await db.messagesDao.getForChat('c1')).where((m) => m.dirty))
            .isEmpty();
      },
    );

    test('selecting an edited user message resolves its descendants', () async {
      await seed(_branchedBlob());

      final selection = await service().selectBranch(
        chatId: 'c1',
        messageId: 'e1',
        alternativeTo: 'u1',
      );

      check(selection.leafId).equals('b2');
      check((await db.chatsDao.getChat('c1'))!.currentMessageId).equals('b2');
    });

    test('the choice is what the next reload and push see', () async {
      await seed(_branchedBlob());
      await service().selectBranch(chatId: 'c1', messageId: 'a1');

      final chat = (await db.chatsDao.getChat('c1'))!;
      final rows = await db.messagesDao.getForChat('c1');
      final blob = ChatBlobMapper.rowsToBlob(chatRowsFromDb(chat, rows));
      check((blob['history'] as Map)['currentId']).equals('a1');
      // The other branch is still all there.
      final graph = await service().readGraph('c1');
      check(graph!.leafBelow('e1')).equals('b2');
      check(graph.siblingsOf('a1')!.ids).deepEquals(['a1', 'a2']);
    });

    test('a blob that never had a currentId still emits the choice', () async {
      final blob = _branchedBlob();
      (blob['history'] as Map<String, dynamic>).remove('currentId');
      await seed(blob);

      await service().selectBranch(chatId: 'c1', messageId: 'a1');

      final chat = (await db.chatsDao.getChat('c1'))!;
      final pushed = ChatBlobMapper.rowsToBlob(
        chatRowsFromDb(chat, await db.messagesDao.getForChat('c1')),
      );
      check((pushed['history'] as Map)['currentId']).equals('a1');
    });

    test(
      'choosing where the chat already is writes and queues nothing',
      () async {
        await seed(_branchedBlob());

        final selection = await service().selectBranch(
          chatId: 'c1',
          messageId: 'a2',
        );

        check(selection.leafId).equals('a3');
        check(selection.changed).isFalse();
        check(await db.outboxDao.pendingForChat('c1')).isEmpty();
        check((await db.chatsDao.getChat('c1'))!.dirty).isFalse();
      },
    );

    test('is refused while a response is running, and stops nothing', () async {
      await seed(_branchedBlob());

      await expectLater(
        service(running: (chatId) => chatId == 'c1')
            .selectBranch(chatId: 'c1', messageId: 'a1'),
        throwsA(
          isA<ChatBranchException>().having(
            (e) => e.reason,
            'reason',
            ChatBranchFailure.responseRunning,
          ),
        ),
      );
      // Another chat's activity is not this chat's.
      await service(running: (chatId) => chatId == 'other')
          .selectBranch(chatId: 'c1', messageId: 'a1');
    });

    test('is refused while a completion is queued for the chat', () async {
      await seed(_branchedBlob());
      await db.outboxDao.enqueue(
        kind: OutboxKind.requestCompletion,
        chatId: 'c1',
        payload: <String, dynamic>{
          'assistantMessageId': 'a3',
          'model': 'm',
          'toolIds': <String>[],
        },
      );

      await expectLater(
        service().selectBranch(chatId: 'c1', messageId: 'a1'),
        throwsA(
          isA<ChatBranchException>().having(
            (e) => e.reason,
            'reason',
            ChatBranchFailure.responseRunning,
          ),
        ),
      );
      check((await db.chatsDao.getChat('c1'))!.currentMessageId).equals('a3');
    });

    test('rejects an unknown message and a non-alternative', () async {
      await seed(_branchedBlob());

      await expectLater(
        service().selectBranch(chatId: 'c1', messageId: 'ghost'),
        throwsA(
          isA<ChatBranchException>().having(
            (e) => e.reason,
            'reason',
            ChatBranchFailure.messageNotFound,
          ),
        ),
      );
      for (final candidate in ['u2', 'b1', 'a2']) {
        await expectLater(
          service().selectBranch(
            chatId: 'c1',
            messageId: candidate,
            alternativeTo: 'a2',
          ),
          throwsA(
            isA<ChatBranchException>().having(
              (e) => e.reason,
              'reason',
              ChatBranchFailure.notAnAlternative,
            ),
          ),
          reason: candidate,
        );
      }
      check((await db.chatsDao.getChat('c1'))!.currentMessageId).equals('a3');
      check(await db.outboxDao.pendingForChat('c1')).isEmpty();
    });

    test('an owner change inside the locked unit writes nothing', () async {
      await seed(_branchedBlob());

      await expectLater(
        service(
          // Asked inside the lock, before the graph is read.
          running: (_) {
            ownerCurrent = false;
            return false;
          },
        ).selectBranch(chatId: 'c1', messageId: 'a1'),
        throwsA(
          isA<ChatBranchException>().having(
            (e) => e.reason,
            'reason',
            ChatBranchFailure.ownerChanged,
          ),
        ),
      );
      check((await db.chatsDao.getChat('c1'))!.currentMessageId).equals('a3');
      check(await db.outboxDao.pendingForChat('c1')).isEmpty();
    });

    test(
      'an account switch while a large graph parses writes nothing',
      () async {
        await seed(_longBlob());

        await expectLater(
          service(
            graphOffload: (envelope) async {
              ownerCurrent = false;
              return ChatBranchGraph.fromEnvelope(envelope);
            },
          ).selectBranch(chatId: 'c1', messageId: 'alt0'),
          throwsA(
            isA<ChatBranchException>().having(
              (e) => e.reason,
              'reason',
              ChatBranchFailure.ownerChanged,
            ),
          ),
        );
        final chat = (await db.chatsDao.getChat('c1'))!;
        check(chat.currentMessageId).equals('m129');
        check(chat.dirty).isFalse();
        check(await db.outboxDao.pendingForChat('c1')).isEmpty();
      },
    );

    test('a branch outside the visible window can be continued', () async {
      await seed(_longBlob());

      final selection = await service().selectBranch(
        chatId: 'c1',
        messageId: 'alt0',
        alternativeTo: 'm0',
      );

      check(selection.leafId).equals('alt1');
      check((await db.chatsDao.getChat('c1'))!.currentMessageId).equals('alt1');
      check((await db.messagesDao.getForChat('c1'))).length.equals(132);
    });

    test('a chat with no stored copy cannot be branched', () async {
      await expectLater(
        service().selectBranch(chatId: 'nope', messageId: 'a1'),
        throwsA(
          isA<ChatBranchException>().having(
            (e) => e.reason,
            'reason',
            ChatBranchFailure.unavailable,
          ),
        ),
      );
    });
  });

  group('forkAt', () {
    test('sends the real id once and stores the whole answer', () async {
      await seed(_branchedBlob());
      final sent = <(String, String)>[];
      final forkBlob = _blob(
        {
          'u1': _message('u1', children: ['a2']),
          'a2': _message('a2', parent: 'u1', role: 'assistant'),
        },
        currentId: 'a2',
        title: 'Branches (fork)',
      );
      forkBlob['originalChatId'] = 'c1';

      final outcome = await service().forkAt(
        chatId: 'c1',
        messageId: 'a2',
        request: (chatId, messageId) async {
          sent.add((chatId, messageId));
          return _envelope(forkBlob, id: 'fork-1', folderId: 'folder-9');
        },
      );

      check(outcome.chatId).equals('fork-1');
      check(sent).deepEquals([('c1', 'a2')]);
      final stored = (await db.chatsDao.getChat('fork-1'))!;
      check(stored.title).equals('Branches (fork)');
      check(stored.folderId).equals('folder-9');
      check(stored.currentMessageId).equals('a2');
      check(stored.bodySynced).isTrue();
      check(stored.dirty).isFalse();
      check(jsonDecode(stored.rawExtra) as Map).containsKey('originalChatId');
      check(await db.chatsDao.getChatParams('fork-1'))
          .isNotNull()
          .deepEquals({'temperature': 0.3});
      check((await db.messagesDao.getForChat('fork-1')).map((m) => m.id))
          .unorderedEquals(['u1', 'a2']);
      // The source chat is exactly as it was.
      check((await db.messagesDao.getForChat('c1'))).length.equals(9);
      check((await db.chatsDao.getChat('c1'))!.currentMessageId).equals('a3');
      check(await db.outboxDao.pendingForChat('fork-1')).isEmpty();
    });

    test('an unknown message is not sent at all', () async {
      await seed(_branchedBlob());
      var calls = 0;

      await expectLater(
        service().forkAt(
          chatId: 'c1',
          messageId: 'ghost',
          request: (_, _) async {
            calls++;
            return _envelope(_branchedBlob(), id: 'x');
          },
        ),
        throwsA(
          isA<ChatBranchException>().having(
            (e) => e.reason,
            'reason',
            ChatBranchFailure.messageNotFound,
          ),
        ),
      );
      check(calls).equals(0);
    });

    test(
      'each server refusal is its own failure, sent once, no clone',
      () async {
        await seed(_branchedBlob());
        final cases = <ChatBranchFailure, DioException>{
          ChatBranchFailure.forkForbidden: _http(403),
          ChatBranchFailure.forkSourceMissing: _http(401),
          ChatBranchFailure.forkConflict: _http(409, {
            'detail': 'Wait for the current response to finish before forking.',
          }),
          ChatBranchFailure.messageNotFound: _http(404, {
            'detail': 'message not found',
          }),
          ChatBranchFailure.forkUnsupported: _http(404, {
            'detail': 'Not Found',
          }),
          ChatBranchFailure.forkFailed: _http(500),
        };

        for (final entry in cases.entries) {
          var calls = 0;
          await expectLater(
            service().forkAt(
              chatId: 'c1',
              messageId: 'a2',
              request: (_, _) async {
                calls++;
                throw entry.value;
              },
            ),
            throwsA(
              isA<ChatBranchException>().having(
                (e) => e.reason,
                'reason',
                entry.key,
              ),
            ),
            reason: entry.key.name,
          );
          check(calls).equals(1);
        }
        check((await db.chatsDao.getChat('c1'))!.currentMessageId).equals('a3');
        check(await db.chatsDao.allServerChatReconcileEntries()).length
            .equals(1);
      },
    );

    test('a delayed answer after an owner change stores nothing', () async {
      await seed(_branchedBlob());

      await expectLater(
        service().forkAt(
          chatId: 'c1',
          messageId: 'a2',
          request: (_, _) async {
            ownerCurrent = false;
            return _envelope(_branchedBlob(), id: 'fork-late');
          },
        ),
        throwsA(
          isA<ChatBranchException>().having(
            (e) => e.reason,
            'reason',
            ChatBranchFailure.ownerChanged,
          ),
        ),
      );
      check(await db.chatsDao.getChat('fork-late')).isNull();
    });

    test(
      'a late answer for another owner reports that, even if malformed',
      () async {
        await seed(_branchedBlob());

        await expectLater(
          service().forkAt(
            chatId: 'c1',
            messageId: 'a2',
            request: (_, _) async {
              ownerCurrent = false;
              return <String, dynamic>{'id': ''};
            },
          ),
          throwsA(
            isA<ChatBranchException>().having(
              (e) => e.reason,
              'reason',
              ChatBranchFailure.ownerChanged,
            ),
          ),
        );
      },
    );

    test('an answer that is not a new chat is not stored', () async {
      await seed(_branchedBlob());

      for (final id in <Object?>['', 'c1', null, 7]) {
        await expectLater(
          service().forkAt(
            chatId: 'c1',
            messageId: 'a2',
            request: (_, _) async => <String, dynamic>{
              ..._envelope(_branchedBlob(), id: 'x'),
              'id': id,
            },
          ),
          throwsA(
            isA<ChatBranchException>().having(
              (e) => e.reason,
              'reason',
              ChatBranchFailure.forkFailed,
            ),
          ),
          reason: '$id',
        );
      }
      check(await db.chatsDao.allServerChatReconcileEntries()).length.equals(1);
    });
  });

  group('an account-wide delete that ends while a read is in flight', () {
    test('a body loaded before it is not stored after it', () async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'c1',
        title: 'Stub',
        createdAt: 1,
        updatedAt: 1,
      );
      final gate = Completer<void>();
      final loaded = Completer<void>();

      final reading = service(
        loader: (chatId) async {
          final envelope = _envelope(_branchedBlob(), id: chatId);
          loaded.complete();
          await gate.future;
          return envelope;
        },
      ).readGraph('c1');
      await loaded.future;
      await locks.runBarrier(() => db.chatsDao.purgeServerWideChats('user-1'));
      gate.complete();

      await expectLater(
        reading,
        throwsA(
          isA<ChatBranchException>().having(
            (e) => e.reason,
            'reason',
            ChatBranchFailure.unavailable,
          ),
        ),
      );
      check(await db.chatsDao.getChat('c1')).isNull();
    });

    test('a fork answered before it is not stored after it', () async {
      await seed(_branchedBlob());
      final gate = Completer<void>();
      final asked = Completer<void>();

      final forking = service().forkAt(
        chatId: 'c1',
        messageId: 'a2',
        request: (_, _) async {
          asked.complete();
          await gate.future;
          return _envelope(_branchedBlob(), id: 'fork-1');
        },
      );
      await asked.future;
      await locks.runBarrier(() => db.chatsDao.purgeServerWideChats('user-1'));
      gate.complete();

      await expectLater(
        forking,
        throwsA(
          isA<ChatBranchException>().having(
            (e) => e.reason,
            'reason',
            ChatBranchFailure.forkFailed,
          ),
        ),
      );
      check(await db.chatsDao.getChat('fork-1')).isNull();
    });
  });
}
