import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/features/chat/services/chat_backup.dart';
import 'package:conduit_core/features/chat/services/chat_data_controls.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:test/test.dart';

const _me = 'user-me';

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

/// u1 has two answers; the second is continued. An edited first message (e1)
/// has its own branch. The active branch is u1 > a2 > u2 > a3.
Map<String, dynamic> _branchedBlob({
  String title = 'Branches',
}) => <String, dynamic>{
  'title': title,
  'params': <String, dynamic>{'temperature': 0.3},
  'futureBlobKey': <String, dynamic>{'kept': true},
  'history': <String, dynamic>{
    'currentId': 'a3',
    'messages': <String, Map<String, dynamic>>{
      'u1': _message('u1', children: ['a1', 'a2']),
      'a1': _message('a1', parent: 'u1', role: 'assistant'),
      'a2': _message('a2', parent: 'u1', role: 'assistant', children: ['u2']),
      'u2': _message('u2', parent: 'a2', children: ['a3']),
      'a3': _message('a3', parent: 'u2', role: 'assistant'),
      'e1': _message('e1', children: ['b1']),
      'b1': _message('b1', parent: 'e1', role: 'assistant'),
    },
  },
};

/// 130 messages on one path, well past a 50-row presentation window, plus an
/// alternative first message whose whole branch lies outside that window.
Map<String, dynamic> _longBlob() {
  final messages = <String, Map<String, dynamic>>{};
  String? parent;
  for (var i = 0; i < 130; i++) {
    messages['m$i'] = _message(
      'm$i',
      parent: parent,
      role: i.isEven ? 'user' : 'assistant',
      children: i == 129 ? const <String>[] : ['m${i + 1}'],
      timestamp: i + 1,
    );
    parent = 'm$i';
  }
  messages['alt0'] = _message('alt0', children: ['alt1']);
  messages['alt1'] = _message('alt1', parent: 'alt0', role: 'assistant');
  return <String, dynamic>{
    'title': 'Long',
    'history': <String, dynamic>{'currentId': 'm129', 'messages': messages},
  };
}

ChatRows _rows(Map<String, dynamic> blob, String id) =>
    ChatBlobMapper.blobToRows(
      chatId: id,
      title: blob['title'] as String? ?? id,
      createdAt: 1,
      updatedAt: 10,
      blob: blob,
    );

Map<String, dynamic> _serverEnvelope(String id, Map<String, dynamic> blob) =>
    <String, dynamic>{
      'id': id,
      'user_id': _me,
      'title': blob['title'] ?? id,
      'chat': blob,
      'updated_at': 10,
      'created_at': 1,
      'share_id': null,
      'archived': false,
      'pinned': false,
      'folder_id': null,
      'meta': <String, dynamic>{},
      'future_envelope_field': <String, dynamic>{'from': 'server'},
    };

DioException _http(int status) => DioException(
  requestOptions: RequestOptions(path: '/x'),
  response: Response<Object?>(
    requestOptions: RequestOptions(path: '/x'),
    statusCode: status,
  ),
);

DioException _noAnswer() => DioException(
  requestOptions: RequestOptions(path: '/x'),
  type: DioExceptionType.receiveTimeout,
);

Future<void> expectFailure(Future<Object?> future, ChatDataControlsFailure f) =>
    check(future).throws<ChatDataControlsException>((it) {
      it.has((e) => e.failure, 'failure').equals(f);
    });

Future<void> expectBackupFailure(Future<Object?> future, ChatBackupFailure f) =>
    check(future).throws<ChatBackupException>((it) {
      it.has((e) => e.failure, 'failure').equals(f);
    });

final class _Api implements ChatDataControlsApi {
  final calls = <String>[];
  Stream<List<int>> Function()? libraryStream;
  final raw = <String, Map<String, dynamic>>{};
  Object? rawFailure;
  Future<List<Map<String, dynamic>>> Function(Uint8List body)? onImport;
  final answers = <String, Future<bool> Function()>{};

  Future<bool> _bulk(String name) {
    calls.add(name);
    final answer = answers[name];
    return answer == null ? Future.value(true) : answer();
  }

  @override
  Future<Stream<List<int>>> openLibraryExport({
    CancelToken? cancelToken,
  }) async {
    calls.add('export');
    return libraryStream!();
  }

  @override
  Future<Map<String, dynamic>?> getChatRaw(String chatId) async {
    calls.add('raw:$chatId');
    final failure = rawFailure;
    if (failure != null) throw failure;
    return raw[chatId];
  }

  @override
  Future<List<Map<String, dynamic>>> importChats(Uint8List body) {
    calls.add('import');
    return onImport!(body);
  }

  @override
  Future<bool> archiveAllChats() => _bulk('archive');

  @override
  Future<bool> unarchiveAllChats() => _bulk('unarchive');

  @override
  Future<bool> unshareAllChats() => _bulk('unshare');

  @override
  Future<bool> deleteAllChats() => _bulk('delete');
}

final class _Sink implements ChatBackupSink {
  final text = StringBuffer();
  var committed = false;
  var aborted = false;

  @override
  Future<void> write(String chunk) async => text.write(chunk);

  @override
  Future<void> commit() async => committed = true;

  @override
  Future<void> abort() async => aborted = true;
}

void main() {
  late AppDatabase db;
  late ConversationLocks locks;
  late _Api api;
  var ownerCurrent = true;
  String? account = _me;
  var activeChats = <String>{};

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    locks = ConversationLocks();
    api = _Api();
    ownerCurrent = true;
    account = _me;
    activeChats = <String>{};
  });
  tearDown(() => db.close());

  ChatDataControlsService service() => ChatDataControlsService(
    database: db,
    locks: locks,
    api: api,
    accountId: account,
    ownerIsCurrent: () => ownerCurrent,
    activeChatIds: () => activeChats,
    nowEpochSeconds: () => 100,
  );

  Future<void> seed(
    String id,
    Map<String, dynamic> blob, {
    String? userId = _me,
    String? shareId,
    bool archived = false,
  }) async {
    await db.chatsDao.upsertServerChat(
      rows: _rows(blob, id),
      userId: userId,
      shareId: shareId,
    );
    if (archived) {
      await db.chatsDao.updateEnvelope(id, archived: const Value(true));
    }
  }

  Future<void> makeDirty(String id) => db.chatsDao.updateEnvelopeWithOutbox(
    id,
    title: const Value('edited'),
    enqueue: true,
  );

  Future<void> queueResponse(String id, {bool inFlight = false}) async {
    await db.transaction(
      () => db.outboxDao.enqueue(
        kind: OutboxKind.requestCompletion,
        chatId: id,
        payload: const RequestCompletionPayload(
          assistantMessageId: 'a-new',
          model: 'm',
        ).toJson(),
      ),
    );
    if (inFlight) {
      await db.customStatement(
        "UPDATE outbox_ops SET status = 'inFlight' WHERE chat_id = '$id'",
      );
    }
  }

  Future<void> seedLocalOnly(String id) {
    final rows = _rows(_branchedBlob(), id);
    return db.chatsDao.insertLocalChatWithCreateOp(
      chat: rows.chat,
      messages: rows.messages,
      blobRows: rows,
      contentHash: 'hash-$id',
    );
  }

  Future<Set<String>> chatIds() async => {
    for (final row in await db.select(db.chats).get()) row.id,
  };

  Future<int> opCount(String id) async => (await (db.select(
    db.outboxOps,
  )..where((t) => t.chatId.equals(id))).get()).length;

  group('exportChat', () {
    test('exports every branch outside the visible window and the edits the '
        'server lacks, from the device', () async {
      await seed('long', _longBlob());
      await db.chatsDao.patchChatParamsWithOutbox(
        'long',
        set: {'temperature': 0.9},
        updatedAt: 20,
      );

      final export = await service().exportChat('long');

      check(export.hasUnsyncedChanges).isTrue();
      check(export.fromServer).isFalse();
      check(api.calls).isEmpty();
      final chat = export.envelope['chat'] as Map<String, dynamic>;
      final messages =
          (chat['history'] as Map<String, dynamic>)['messages']
              as Map<String, dynamic>;
      check(messages.length).equals(132);
      check(messages.containsKey('alt1')).isTrue();
      check((messages['m5'] as Map<String, dynamic>)['futureMessageKey'])
          .equals('keep-m5');
      check((chat['params'] as Map<String, dynamic>)['temperature'])
          .equals(0.9);
      // The file is the upstream shape: a one-element array of the envelope.
      final file = jsonDecode(export.toJson()) as List<dynamic>;
      check(file).length.equals(1);
      check((file.single as Map)['id']).equals('long');
      check((file.single as Map).containsKey('tasks')).isFalse();
    });

    test('a clean chat the server holds is read from the server, so fields '
        'the app does not model come with it', () async {
      await seed('c1', _branchedBlob());
      api.raw['c1'] = _serverEnvelope('c1', _branchedBlob(title: 'Server'));

      final export = await service().exportChat('c1');

      check(export.fromServer).isTrue();
      check(export.hasUnsyncedChanges).isFalse();
      check(export.envelope['future_envelope_field']).isNotNull();
      check(export.title).equals('Server');
      check(api.calls).deepEquals(['raw:c1']);
    });

    test(
      'falls back to the complete stored copy when the server read fails',
      () async {
        await seed('c1', _branchedBlob());
        api.rawFailure = _noAnswer();

        final export = await service().exportChat('c1');

        check(export.fromServer).isFalse();
        check(export.hasUnsyncedChanges).isFalse();
        final history =
            (export.envelope['chat'] as Map<String, dynamic>)['history']
                as Map<String, dynamic>;
        check((history['messages'] as Map).keys)
            .unorderedEquals(['u1', 'a1', 'a2', 'u2', 'a3', 'e1', 'b1']);
      },
    );

    test('a chat that was never sent exports from the device', () async {
      await seedLocalOnly('local:abc');

      final export = await service().exportChat('local:abc');

      check(export.hasUnsyncedChanges).isTrue();
      check(api.calls).isEmpty();
      check(export.envelope['id']).equals('local:abc');
    });

    test(
      'a chat with no stored body is loaded first, then exported whole',
      () async {
        await db.chatsDao.upsertEnvelopeStub(
          id: 'stub',
          title: 'Stub',
          createdAt: 1,
          updatedAt: 10,
        );
        api.raw['stub'] = _serverEnvelope('stub', _branchedBlob(title: 'Stub'));
        api.rawFailure = null;

        final export = await service().exportChat('stub');

        check(api.calls).deepEquals(['raw:stub']);
        final history =
            (export.envelope['chat'] as Map<String, dynamic>)['history']
                as Map<String, dynamic>;
        check((history['messages'] as Map).length).equals(7);
      },
    );

    test(
      'refuses an unknown or deleted chat and an account that changed',
      () async {
        await expectFailure(
          service().exportChat('missing'),
          ChatDataControlsFailure.unavailable,
        );

        await seed('c1', _branchedBlob());
        ownerCurrent = false;
        await expectFailure(
          service().exportChat('c1'),
          ChatDataControlsFailure.ownerChanged,
        );
      },
    );

    test(
      'the transcript follows the active branch only and says what it is',
      () async {
        await seed('c1', _branchedBlob(title: 'My chat'));
        api.rawFailure = _noAnswer();

        final markdown = await service().exportChatTranscript('c1');

        check(markdown).startsWith('# My chat\n');
        for (final id in ['u1', 'a2', 'u2', 'a3']) {
          check(markdown).contains('text of $id');
        }
        for (final id in ['a1', 'e1', 'b1']) {
          check(markdown).not((it) => it.contains('text of $id'));
        }
      },
    );
  });

  group('importChats', () {
    ChatImportPreview preview() => prepareChatImport(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode([
            {'chat': _branchedBlob()},
          ]),
        ),
      ),
    );

    test('sends the prepared body once and stores what the server created, '
        'old timestamps included', () async {
      final sent = <Uint8List>[];
      api.onImport = (body) async {
        sent.add(body);
        return [
          {..._serverEnvelope('new-1', _branchedBlob()), 'updated_at': 5},
        ];
      };
      final prepared = preview();

      final result = await service().importChats(prepared);

      check(result.imported).equals(1);
      check(result.stored).equals(1);
      check(sent).length.equals(1);
      check(sent.single).deepEquals(prepared.body);
      check(await chatIds()).deepEquals({'new-1'});
      check((await db.chatsDao.getChat('new-1'))!.bodySynced).isTrue();
    });

    test(
      'an answerless failure is reported unknown and never sent again',
      () async {
        api.onImport = (_) async => throw _noAnswer();

        await expectFailure(
          service().importChats(preview()),
          ChatDataControlsFailure.outcomeUnknown,
        );

        check(api.calls).deepEquals(['import']);
        check(await chatIds()).isEmpty();
      },
    );

    test('a refusal is its own failure', () async {
      api.onImport = (_) async => throw _http(403);

      await expectFailure(
        service().importChats(preview()),
        ChatDataControlsFailure.forbidden,
      );
    });

    test("another account's answer is not stored", () async {
      api.onImport = (_) async {
        ownerCurrent = false;
        return [_serverEnvelope('new-1', _branchedBlob())];
      };

      await expectFailure(
        service().importChats(preview()),
        ChatDataControlsFailure.ownerChanged,
      );

      check(await chatIds()).isEmpty();
    });

    test('an answer that lands after an account-wide delete does not bring '
        'chats back', () async {
      api.onImport = (_) async {
        await locks.runBarrier(() async {});
        return [_serverEnvelope('new-1', _branchedBlob())];
      };

      final result = await service().importChats(preview());

      check(result.imported).equals(1);
      check(result.stored).equals(0);
      check(await chatIds()).isEmpty();
    });
  });

  group('exportLibrary', () {
    String line(String id) =>
        jsonEncode(_serverEnvelope(id, _branchedBlob(title: id)));

    test(
      'writes the whole library and delivers it only when complete',
      () async {
        api.libraryStream = () =>
            Stream.value(utf8.encode('${line('a')}\n${line('b')}'));
        final sink = _Sink();

        final result = await service().exportLibrary(sink);

        check(result.chats).equals(2);
        check(sink.committed).isTrue();
        check(
          (jsonDecode(sink.text.toString()) as List).map(
            (e) => (e as Map)['id'],
          ),
        ).deepEquals(['a', 'b']);
      },
    );

    test('an account change part-way discards the file', () async {
      api.libraryStream = () async* {
        yield utf8.encode('${line('a')}\n');
        ownerCurrent = false;
        yield utf8.encode('${line('b')}\n');
      };
      final sink = _Sink();

      await expectBackupFailure(
        service().exportLibrary(sink),
        ChatBackupFailure.ownerChanged,
      );

      check(sink.committed).isFalse();
      check(sink.aborted).isTrue();
    });

    test('a stop discards the file', () async {
      final token = CancelToken();
      api.libraryStream = () async* {
        yield utf8.encode('${line('a')}\n');
        token.cancel();
        yield utf8.encode('${line('b')}\n');
      };
      final sink = _Sink();

      await expectBackupFailure(
        service().exportLibrary(sink, cancelToken: token),
        ChatBackupFailure.cancelled,
      );

      check(sink.committed).isFalse();
    });
  });

  group('account-wide changes', () {
    // A library with: two clean chats, one with an unsent edit, one with a
    // response queued, a chat another user shares into a folder, a chat that
    // exists only on this device, and a chat already deleted by the user.
    Future<void> seedLibrary() async {
      await seed('s1', _branchedBlob(), shareId: 'share-1');
      await seed('s2', _branchedBlob(), shareId: 'share-2', archived: true);
      await seed('s3', _branchedBlob(), shareId: 'share-3');
      await makeDirty('s3');
      await seed('s4', _branchedBlob());
      await queueResponse('s4');
      await seed(
        'foreign',
        _branchedBlob(),
        userId: 'someone-else',
        shareId: 'x',
      );
      await seedLocalOnly('local:l1');
      await db.syncMetaDao.setChatRemapTarget('local:old', 's1');
    }

    Future<Map<String, bool>> archivedFlags() async => {
      for (final row in await db.select(db.chats).get()) row.id: row.archived,
    };

    test('archive all and unarchive all follow the server for the '
        "account's own chats, queued edits included", () async {
      await seedLibrary();

      final archived = await service().archiveAll();

      check(api.calls).deepEquals(['archive']);
      // s2 was already archived, so only the other three change.
      check(archived.changed).equals(3);
      var flags = await archivedFlags();
      for (final id in ['s1', 's2', 's3', 's4']) {
        check(flags[id]).equals(true);
      }
      // Never a chat another user owns, and never one that is not on the server.
      check(flags['foreign']).equals(false);
      check(flags['local:l1']).equals(false);
      // The queued edit is untouched, so it still goes out afterwards.
      check(await opCount('s3')).equals(1);

      await service().unarchiveAll();

      flags = await archivedFlags();
      for (final id in ['s1', 's2', 's3', 's4']) {
        check(flags[id]).equals(false);
      }
      check(api.calls).deepEquals(['archive', 'unarchive']);
    });

    test('unshare all clears the links of the same chats only', () async {
      await seedLibrary();

      final outcome = await service().unshareAll();

      check(outcome.changed).equals(3);
      final shares = {
        for (final row in await db.select(db.chats).get()) row.id: row.shareId,
      };
      check(shares['s1']).isNull();
      check(shares['s2']).isNull();
      check(shares['s3']).isNull();
      check(shares['foreign']).equals('x');
    });

    test(
      'a refusal, a failure or no answer leaves the stored chats as they were',
      () async {
        await seedLibrary();
        final before = await archivedFlags();
        final cases = <(Future<bool> Function(), ChatDataControlsFailure)>[
          (() async => false, ChatDataControlsFailure.serverRefused),
          (() async => throw _http(500), ChatDataControlsFailure.serverRefused),
          (() async => throw _http(403), ChatDataControlsFailure.forbidden),
          (() async => throw _http(401), ChatDataControlsFailure.forbidden),
          (
            () async => throw _noAnswer(),
            ChatDataControlsFailure.outcomeUnknown,
          ),
        ];
        for (final (answer, failure) in cases) {
          api.answers['archive'] = answer;
          api.answers['delete'] = answer;
          await expectFailure(service().archiveAll(), failure);
          await expectFailure(
            service().deleteAll(discardUnsyncedWork: true),
            failure,
          );
        }

        check(await archivedFlags()).deepEquals(before);
        check(await chatIds()).contains('s1');
        check(await opCount('s4')).equals(1);
      },
    );

    test('delete all refuses to discard unsent work unless asked, and sends '
        'nothing', () async {
      await seedLibrary();

      await check(service().deleteAll(discardUnsyncedWork: false))
          .throws<ChatDataControlsException>((it) {
            it
                .has((e) => e.failure, 'failure')
                .equals(ChatDataControlsFailure.pendingWork);
            it.has((e) => e.scope!.unsyncedEdits, 'edits').equals(1);
            it.has((e) => e.scope!.queuedResponses, 'responses').equals(1);
            it.has((e) => e.scope!.localOnlyChatIds, 'local-only').deepEquals([
              'local:l1',
            ]);
          });

      check(api.calls).isEmpty();
      check(await chatIds()).contains('s3');
    });

    test(
      'delete all removes the account\'s server chats and their queued work, '
      'and keeps the rest',
      () async {
        await seedLibrary();

        final outcome = await service().deleteAll(
          discardUnsyncedWork: true,
          knownLocalOnlyChatIds: {'local:l1'},
        );

        check(api.calls).deepEquals(['delete']);
        check(outcome.removedChatIds).unorderedEquals(['s1', 's2', 's3', 's4']);
        check(await chatIds()).unorderedEquals(['foreign', 'local:l1']);
        check(await opCount('s3')).equals(0);
        check(await opCount('s4')).equals(0);
        // The device-only chat keeps the send that has not happened yet.
        check(await opCount('local:l1')).equals(1);
        check(await db.syncMetaDao.getChatRemapTarget('local:old')).isNull();
        check((await db.select(db.messages).get()).map((m) => m.chatId).toSet())
            .unorderedEquals(['foreign', 'local:l1']);
      },
    );

    test('delete all never discards a response that is running', () async {
      await seedLibrary();
      await queueResponse('s1', inFlight: true);

      await expectFailure(
        service().deleteAll(discardUnsyncedWork: true),
        ChatDataControlsFailure.responseRunning,
      );

      check(api.calls).isEmpty();
      check(await chatIds()).contains('s1');
    });

    test(
      'delete all refuses while the registry knows a response is running, '
      'though no request op is in flight, and sends once the last ends',
      () async {
        await seedLibrary();
        // Task transport records the response, then its request op completes.
        activeChats = {'s1', 's2'};

        await expectFailure(
          service().deleteAll(discardUnsyncedWork: true),
          ChatDataControlsFailure.responseRunning,
        );
        // One of two chats finishing leaves the other's response running.
        activeChats.remove('s1');
        await expectFailure(
          service().deleteAll(discardUnsyncedWork: true),
          ChatDataControlsFailure.responseRunning,
        );
        check(api.calls).isEmpty();
        check(await chatIds()).contains('s1');

        activeChats.remove('s2');
        final outcome = await service().deleteAll(discardUnsyncedWork: true);

        check(api.calls).deepEquals(['delete']);
        check(outcome.removedChatIds).unorderedEquals(['s1', 's2', 's3', 's4']);
      },
    );

    test('a response that starts while delete all waits for an admitted write '
        'is refused', () async {
      await seedLibrary();
      final writeDone = Completer<void>();
      final admitted = locks.runExclusive('s1', () => writeDone.future);

      final deleting = expectFailure(
        service().deleteAll(discardUnsyncedWork: true),
        ChatDataControlsFailure.responseRunning,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      check(api.calls).isEmpty();

      activeChats.add('s2');
      writeDone.complete();
      await Future.wait([admitted, deleting]);

      check(api.calls).isEmpty();
      check(await chatIds()).contains('s2');
    });

    test('a running response does not hold up the other account-wide changes, '
        'and an account that is no longer signed in is told so', () async {
      await seedLibrary();
      activeChats = {'s1'};

      await service().archiveAll();
      check(api.calls).deepEquals(['archive']);

      ownerCurrent = false;
      await expectFailure(
        service().deleteAll(discardUnsyncedWork: true),
        ChatDataControlsFailure.ownerChanged,
      );
      check(api.calls).deepEquals(['archive']);
    });

    test('delete all refuses when a chat the user saw as device-only reached '
        'the server while it waited', () async {
      await seedLibrary();

      await expectFailure(
        service().deleteAll(
          discardUnsyncedWork: true,
          knownLocalOnlyChatIds: {'local:l1', 'local:was-sent'},
        ),
        ChatDataControlsFailure.localWorkChanged,
      );

      check(api.calls).isEmpty();
    });

    test(
      'nothing is sent when the account has no id to match chats against',
      () async {
        await seedLibrary();
        account = null;

        await expectFailure(
          service().deleteAll(discardUnsyncedWork: true),
          ChatDataControlsFailure.accountUnknown,
        );

        check(api.calls).isEmpty();
      },
    );

    test(
      'an account change while the server works leaves the device as it was',
      () async {
        await seedLibrary();
        api.answers['delete'] = () async {
          ownerCurrent = false;
          return true;
        };

        await expectFailure(
          service().deleteAll(discardUnsyncedWork: true),
          ChatDataControlsFailure.ownerChanged,
        );

        check(await chatIds()).contains('s1');
      },
    );

    test('a write that arrives while delete all runs waits, then finds the chat gone', () async {
      await seedLibrary();
      final reply = Completer<bool>();
      final requestSent = Completer<void>();
      api.answers['delete'] = () {
        requestSent.complete();
        return reply.future;
      };

      final deleting = service().deleteAll(discardUnsyncedWork: true);
      await requestSent.future;
      var lateWriteSaw = '';
      final lateWrite = locks.runExclusive('s2', () async {
        lateWriteSaw = (await db.chatsDao.getChat('s2')) == null
            ? 'gone'
            : 'present';
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      check(lateWriteSaw).equals('');

      reply.complete(true);
      await Future.wait([deleting, lateWrite]);

      check(lateWriteSaw).equals('gone');
    });
  });

  group('scope', () {
    test('counts what a backup leaves out, for the account only', () async {
      await seed('s1', _branchedBlob());
      await seed('s2', _branchedBlob());
      await makeDirty('s2');
      await seed('foreign', _branchedBlob(), userId: 'someone-else');
      await seedLocalOnly('local:l1');
      await seedLocalOnly('local:l2');

      final scope = await service().scope();

      check(scope.serverChats).equals(2);
      check(scope.unsyncedEdits).equals(1);
      check(scope.queuedResponses).equals(0);
      check(scope.localOnlyChatIds).deepEquals(['local:l1', 'local:l2']);
    });

    test('counts a chat with an unsent edit and a queued response '
        'once', () async {
      await seed('s1', _branchedBlob());
      await makeDirty('s1');
      await queueResponse('s1');
      await seed('s2', _branchedBlob());
      await queueResponse('s2');

      final scope = await service().scope();

      check(scope.unsyncedEdits).equals(1);
      check(scope.queuedResponses).equals(2);
      check(scope.chatsWithUnsentWork).equals(2);
    });
  });
}
