import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/backoff.dart';
import 'package:conduit_core/sync/chat_adapter.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/clock.dart';
import 'package:conduit_core/sync/id_remapper.dart';
import 'package:conduit_core/sync/outbox_drainer.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/push_sync.dart';
import 'package:conduit_core/sync/sync_api_client.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor;
import 'package:drift/native.dart';
import 'package:test/test.dart';

/// Regression guard: the folder-update seam must NOT collapse a healthy 2xx
/// response with an unexpected (non-map / empty) body into the same `null`
/// signal it uses for a genuine 404. The push path treats a null return as
/// "folder gone on server" and PURGES the local row, so a 2xx-null would be
/// silent data loss (CDT-RFC-001 §7.4; the route returns `null` with HTTP 200
/// when the server-side update helper bails, e.g. duplicate-name collision).
void main() {
  group('ApiSyncApiClient.updateFolder', () {
    test('2xx response with a non-map body returns a map, never null', () async {
      // Server replied 200 with a JSON `null` body (the vendored
      // `update_folder_by_id_and_user_id` returns None on its bail paths while
      // the folder still exists). This MUST read as success, not a 404.
      final client = _buildClient(_FixedAdapter(statusCode: 200, body: null));

      final result = await client.updateFolder('folder-1', name: 'Renamed');

      check(result).isNotNull();
    });

    test('genuine 404 returns null (caller purges the local row)', () async {
      final client = _buildClient(
        _FixedAdapter(statusCode: 404, body: {'detail': 'Not found'}),
      );

      final result = await client.updateFolder('folder-1', name: 'Renamed');

      check(result).isNull();
    });

    test('2xx map body is returned verbatim', () async {
      final folder = {'id': 'folder-1', 'name': 'Renamed', 'updated_at': 42};
      final client = _buildClient(_FixedAdapter(statusCode: 200, body: folder));

      final result = await client.updateFolder('folder-1', name: 'Renamed');

      check(result).isNotNull().deepEquals(folder);
    });
  });

  group('a project edit made offline', () {
    late AppDatabase db;
    late IdRemapper remapper;
    late _RecordingAdapter adapter;
    late PushSync push;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      remapper = IdRemapper(db);
      adapter = _RecordingAdapter();
      push = PushSync(
        client: _buildClient(adapter),
        db: db,
        chatLocks: ConversationLocks(),
        folderLocks: FolderLocks(),
        clock: _FixedClock(),
        remapper: remapper,
      );
      await db.foldersDao.replaceServerFolders([
        {
          'id': 'p',
          'name': 'Project',
          'created_at': 1,
          'updated_at': 2,
          'meta': {'icon': 'briefcase'},
          'data': {
            'system_prompt': 'Be brief',
            'files': [
              {'type': 'collection', 'id': 'kb-1', 'name': 'Docs'},
            ],
          },
        },
      ]);
    });

    tearDown(() async {
      await remapper.dispose();
      await db.close();
    });

    test('drains as a request that carries only the edited key', () async {
      await db.foldersDao.patchFolderDataWithOutbox(
        id: 'p',
        dataPatch: {
          'model_ids': ['m-a', 'm-b'],
        },
      );

      final op = (await db.outboxDao.pendingForChat('p')).single;
      await push.pushFolderUpsert(
        jsonDecode(op.payload) as Map<String, dynamic>,
      );

      final request = adapter.requests.single;
      check(request.method).equals('POST');
      check(request.path).equals('/api/v1/folders/p/update');
      check(request.data).isA<Map<String, dynamic>>().deepEquals({
        'data': {
          'model_ids': ['m-a', 'm-b'],
        },
      });
      check((await db.foldersDao.getFolder('p'))!.dirty).isFalse();
    });
  });

  group('a folder the user closes', () {
    late AppDatabase db;
    late IdRemapper remapper;
    late _RecordingAdapter adapter;
    late PushSync push;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      remapper = IdRemapper(db);
      adapter = _RecordingAdapter();
      push = PushSync(
        client: _buildClient(adapter),
        db: db,
        chatLocks: ConversationLocks(),
        folderLocks: FolderLocks(),
        clock: _FixedClock(),
        remapper: remapper,
      );
      await db.foldersDao.replaceServerFolders([
        {
          'id': 'p',
          'name': 'Project',
          'created_at': 1,
          'updated_at': 2,
          'is_expanded': true,
        },
      ]);
    });

    tearDown(() async {
      await remapper.dispose();
      await db.close();
    });

    test('drains as the request the web client sends for it', () async {
      await db.foldersDao.setFolderExpandedWithOutbox(
        id: 'p',
        isExpanded: false,
      );

      final op = (await db.outboxDao.pendingForChat('p')).single;
      await push.pushFolderUpsert(
        jsonDecode(op.payload) as Map<String, dynamic>,
      );

      final request = adapter.requests.single;
      check(request.method).equals('POST');
      check(request.path).equals('/api/v1/folders/p/update/expanded');
      check(
        request.data,
      ).isA<Map<String, dynamic>>().deepEquals({'is_expanded': false});
      check((await db.foldersDao.getFolder('p'))!.dirty).isFalse();
    });
  });

  group('ApiSyncApiClient.updateFolderExpanded', () {
    test('a folder gone from the server answers false', () async {
      final client = _buildClient(
        _FixedAdapter(statusCode: 404, body: {'detail': 'Not found'}),
      );

      check(await client.updateFolderExpanded('p', false)).isFalse();
    });

    test('a refusal is terminal, as for other folder edits', () async {
      final client = _buildClient(
        _FixedAdapter(statusCode: 403, body: {'detail': 'Forbidden'}),
      );

      await check(
        client.updateFolderExpanded('p', false),
      ).throws<SyncTerminalException>();
    });
  });

  group('ApiSyncApiClient.deleteChatMessages', () {
    test('a message already gone from the server is deleted', () async {
      final client = _buildClient(
        _FixedAdapter(statusCode: 404, body: {'detail': 'Not found'}),
      );

      await client.deleteChatMessages('c1', ['a1']);
    });

    test('a refusal is terminal', () async {
      final client = _buildClient(
        _FixedAdapter(statusCode: 403, body: {'detail': 'Forbidden'}),
      );

      await check(client.deleteChatMessages('c1', ['a1']))
          .throws<SyncTerminalException>();
    });

    // Open WebUI 0.13.4 answers 401 for a delete whose write failed, as for
    // one the session may not make (routers/chats.py:1683-1687).
    for (final (label, sessionStatus, owner, terminal) in const [
      ('tried again while the session owns the chat', 200, 'user-1', false),
      ('terminal once the chat is another account\'s', 200, 'user-2', true),
      ('terminal once the session is refused', 401, 'user-1', true),
      ('parked while the session can\'t be read', 503, 'user-1', true),
    ]) {
      test('a 401 is $label', () async {
        final client = _buildClient(
          _heldChatServer(sessionStatus: sessionStatus, owner: owner),
        );

        final deleting = client.deleteChatMessages('c1', ['a1']);

        if (terminal) {
          await check(deleting).throws<SyncTerminalException>();
        } else {
          await check(deleting).throws<DioException>();
        }
      });
    }
  });

  group('a held answer\'s delete drained later', () {
    test('goes as the account it started as, for every message', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final remapper = IdRemapper(db);
      addTearDown(remapper.dispose);
      final adapter = _RecordingAdapter();
      final api = ApiService(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://server.example',
        ),
        workerManager: WorkerManager(),
        authToken: 'session-a',
      );
      addTearDown(api.dispose);
      api.dio.httpClientAdapter = adapter;
      final push = PushSync(
        client: ApiSyncApiClient(api, ownsDatabase: (_) => true),
        db: db,
        chatLocks: ConversationLocks(),
        folderLocks: FolderLocks(),
        clock: _FixedClock(),
        remapper: remapper,
      );
      // Another account signs in once the first delete has gone out.
      adapter.onFetch = () => api.updateAuthToken('session-b');

      await check(push.pushDeleteMessages('c1', ['a1', 'a2']))
          .throws<DioException>();

      check(adapter.requests.map((request) => request.headers['Authorization']))
          .deepEquals(['Bearer session-a']);
    });

    for (final (owner, sentAgain) in const [
      ('user-1', true),
      ('user-2', false),
    ]) {
      test('parked on a refusal, goes again with the connection only while the '
          'session owns its chat ($owner)', () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remapper = IdRemapper(db);
        addTearDown(remapper.dispose);
        final server = _heldChatServer(
          sessionStatus: 200,
          owner: owner,
          deleteStatus: 200,
        );
        final drainer = _chatDrainer(db, _buildClient(server), remapper);
        final seq = await _parkedDelete(db);

        await drainer.onConnectivityRegained();

        check(server.requests).contains('GET /api/v1/chats/c1');
        check(server.requests.contains('DELETE /api/v1/chats/c1/messages/a1'))
            .equals(sentAgain);
        check((await db.outboxDao.opBySeq(seq))?.status)
            .equals(sentAgain ? null : OutboxStatus.failed);
      });
    }

    test('parked, goes again on a later drain once a check that timed out '
        'can tell', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final remapper = IdRemapper(db);
      addTearDown(remapper.dispose);
      final owned = _heldChatServer(
        sessionStatus: 200,
        owner: 'user-1',
        deleteStatus: 200,
      );
      var chatReads = 0;
      final server = _RoutedAdapter(
        (method, path) => path == '/api/v1/chats/c1' && chatReads++ == 0
            ? throw _timeout(path)
            : owned.answer(method, path),
      );
      final clock = _MovableClock();
      final drainer = _chatDrainer(
        db,
        _buildClient(server),
        remapper,
        clock: clock,
      );
      final seq = await _parkedDelete(db);

      await drainer.drain();
      check(server.requests).not((it) => it.contains(_deleteA1));
      clock.now += _pastAnyBackoff;
      await drainer.drain();

      check(server.requests).contains(_deleteA1);
      check((await db.outboxDao.opBySeq(seq))?.status).isNull();
    });

    test('a check that keeps timing out is asked again a few times, and once '
        'more with the connection', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final remapper = IdRemapper(db);
      addTearDown(remapper.dispose);
      final owned = _heldChatServer(
        sessionStatus: 200,
        owner: 'user-1',
        deleteStatus: 200,
      );
      final server = _RoutedAdapter(
        (method, path) => path == '/api/v1/chats/c1'
            ? throw _timeout(path)
            : owned.answer(method, path),
      );
      final clock = _MovableClock();
      final drainer = _chatDrainer(
        db,
        _buildClient(server),
        remapper,
        clock: clock,
      );
      final seq = await _parkedDelete(db);
      int checks() =>
          server.requests.where((r) => r == 'GET /api/v1/chats/c1').length;

      for (var i = 0; i < OutboxDrainer.kParkedRecheckLimit + 3; i++) {
        await drainer.drain();
        clock.now += _pastAnyBackoff;
      }
      check(checks()).equals(1 + OutboxDrainer.kParkedRecheckLimit);
      await drainer.onConnectivityRegained();

      check(checks()).equals(2 + OutboxDrainer.kParkedRecheckLimit);
      check((await db.outboxDao.opBySeq(seq))?.status)
          .equals(OutboxStatus.failed);
    });

    test('parked mid-drain, goes again once a check can tell', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final remapper = IdRemapper(db);
      addTearDown(remapper.dispose);
      final refusing = _heldChatServer(sessionStatus: 200, owner: 'user-1');
      final owned = _heldChatServer(
        sessionStatus: 200,
        owner: 'user-1',
        deleteStatus: 200,
      );
      var healthy = false;
      final server = _RoutedAdapter(
        (method, path) => healthy
            ? owned.answer(method, path)
            : path == '/api/v1/chats/c1'
            ? throw _timeout(path)
            : refusing.answer(method, path),
      );
      final clock = _MovableClock();
      final drainer = _chatDrainer(
        db,
        _buildClient(server),
        remapper,
        clock: clock,
      );
      final seq = await _pendingDelete(db);

      await drainer.drain();
      check((await db.outboxDao.opBySeq(seq))?.status)
          .equals(OutboxStatus.failed);
      healthy = true;
      clock.now += _pastAnyBackoff;
      await drainer.drain();

      check(server.requests.where((r) => r == _deleteA1)).length.equals(2);
      check((await db.outboxDao.opBySeq(seq))?.status).isNull();
    });

    test("parked mid-drain as another account's isn't asked again", () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final remapper = IdRemapper(db);
      addTearDown(remapper.dispose);
      final server = _heldChatServer(sessionStatus: 200, owner: 'user-2');
      final clock = _MovableClock();
      final drainer = _chatDrainer(
        db,
        _buildClient(server),
        remapper,
        clock: clock,
      );
      final seq = await _pendingDelete(db);

      await drainer.drain();
      clock.now += _pastAnyBackoff;
      await drainer.drain();

      check(server.requests.where((r) => r == 'GET /api/v1/chats/c1')).length
          .equals(1);
      check((await db.outboxDao.opBySeq(seq))?.status)
          .equals(OutboxStatus.failed);
    });

    test("a slow recheck holds up no other chat's work", () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final remapper = IdRemapper(db);
      addTearDown(remapper.dispose);
      final owned = _heldChatServer(
        sessionStatus: 200,
        owner: 'user-1',
        deleteStatus: 200,
      );
      final otherSent = Completer<void>();
      var chatReads = 0;
      final server = _RoutedAdapter(
        (method, path) => path == '/api/v1/chats/c1' && chatReads == 1
            ? throw _timeout(path)
            : owned.answer(method, path),
        // The recheck's read of c1 is answered once c2's delete has gone.
        before: (request) async {
          if (request == _deleteB1) otherSent.complete();
          if (request == 'GET /api/v1/chats/c1' && ++chatReads == 2) {
            await otherSent.future;
          }
        },
      );
      final clock = _MovableClock();
      final drainer = _chatDrainer(
        db,
        _buildClient(server),
        remapper,
        clock: clock,
      );
      final seq = await _parkedDelete(db);

      await drainer.drain();
      clock.now += _pastAnyBackoff;
      final other = await db.outboxDao.enqueue(
        kind: OutboxKind.deleteMessages,
        chatId: 'c2',
        payload: {
          kDeleteMessagesIdsKey: ['b1'],
        },
      );
      await drainer.drain();

      check(await db.outboxDao.opBySeq(other)).isNull();
      // What the recheck re-armed goes in the same drain.
      check(server.requests.where((r) => r == _deleteA1)).length.equals(1);
      check((await db.outboxDao.opBySeq(seq))?.status).isNull();
    });

    test('a delete parked while a recheck runs is still asked again', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final remapper = IdRemapper(db);
      addTearDown(remapper.dispose);
      final owned = _heldChatServer(
        sessionStatus: 200,
        owner: 'user-1',
        deleteStatus: 200,
      );
      var c1Reads = 0;
      var c2Reads = 0;
      var c2Deletes = 0;
      final server = _RoutedAdapter(
        (method, path) => switch (path) {
          '/api/v1/chats/c1' when c1Reads == 1 => throw _timeout(path),
          '/api/v1/chats/c2' when c2Reads == 1 => throw _timeout(path),
          '/api/v1/chats/c2/messages/b1' when c2Deletes == 1 => (
            401,
            {'detail': 'access prohibited'},
          ),
          '/api/v1/chats/c2' => (
            200,
            {'id': 'c2', 'user_id': 'user-1', 'chat': <String, dynamic>{}},
          ),
          _ => owned.answer(method, path),
        },
        // The recheck's read of c1 is answered once c2's delete has parked.
        before: (request) async {
          if (request == 'GET /api/v1/chats/c2') c2Reads++;
          if (request == _deleteB1) c2Deletes++;
          if (request == 'GET /api/v1/chats/c1' && ++c1Reads == 2) {
            await db.outboxDao
                .watchParkedForChat('c2')
                .firstWhere((ops) => ops.isNotEmpty);
          }
        },
      );
      final clock = _MovableClock();
      final drainer = _chatDrainer(
        db,
        _buildClient(server),
        remapper,
        clock: clock,
      );
      await _parkedDelete(db);

      await drainer.drain();
      clock.now += _pastAnyBackoff;
      final other = await db.outboxDao.enqueue(
        kind: OutboxKind.deleteMessages,
        chatId: 'c2',
        payload: {
          kDeleteMessagesIdsKey: ['b1'],
        },
      );
      await drainer.drain();
      check((await db.outboxDao.opBySeq(other))?.status)
          .equals(OutboxStatus.failed);
      clock.now += _pastAnyBackoff;
      await drainer.drain();

      check(server.requests.where((r) => r == _deleteB1)).length.equals(2);
      check(await db.outboxDao.opBySeq(other)).isNull();
    });

    test('a re-arm the connection asks for while a recheck runs goes after '
        'it', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final remapper = IdRemapper(db);
      addTearDown(remapper.dispose);
      final owned = _heldChatServer(
        sessionStatus: 200,
        owner: 'user-1',
        deleteStatus: 200,
      );
      final held = Completer<void>();
      final release = Completer<void>();
      final whileHeld = <String>[];
      var chatReads = 0;
      final server = _RoutedAdapter(
        (method, path) => path == '/api/v1/chats/c1' && chatReads < 3
            ? throw _timeout(path)
            : owned.answer(method, path),
        // The recheck's read of c1 is held until the test releases it.
        before: (request) async {
          if (held.isCompleted && !release.isCompleted) whileHeld.add(request);
          if (request == 'GET /api/v1/chats/c1' && ++chatReads == 2) {
            held.complete();
            await release.future;
          }
        },
      );
      final clock = _MovableClock();
      final drainer = _chatDrainer(
        db,
        _buildClient(server),
        remapper,
        clock: clock,
      );
      final seq = await _parkedDelete(db);

      await drainer.drain();
      clock.now += _pastAnyBackoff;
      final drained = drainer.drain();
      await held.future;
      await drainer.onConnectivityRegained();
      release.complete();
      await drained;

      check(whileHeld).isEmpty();
      check(chatReads).equals(3);
      check(server.requests.where((r) => r == _deleteA1)).length.equals(1);
      check((await db.outboxDao.opBySeq(seq))?.status).isNull();
    });
  });

  group('a chat push drained later', () {
    // The outbox drains an account's chats as the session that owns the
    // account's database when the push starts. Another account signing in
    // on the same server while the push reads its rows must not get them.
    late AppDatabase db;
    late _ReadTap reads;
    late IdRemapper remapper;
    late _RecordingAdapter server;
    late ApiService api;

    setUp(() async {
      reads = _ReadTap();
      db = AppDatabase(NativeDatabase.memory().interceptWith(reads));
      remapper = IdRemapper(db);
      server = _RecordingAdapter();
      api = ApiService(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://server.example',
        ),
        workerManager: WorkerManager(),
        authToken: 'session-a',
      );
      api.dio.httpClientAdapter = server;
    });

    tearDown(() async {
      api.dispose();
      await remapper.dispose();
      await db.close();
    });

    PushSync push() => PushSync(
      client: ApiSyncApiClient(api, ownsDatabase: (_) => true),
      db: db,
      chatLocks: ConversationLocks(),
      folderLocks: FolderLocks(),
      clock: _FixedClock(),
      remapper: remapper,
    );

    List<Object?> bearers() => [
      for (final request in server.requests) request.headers['Authorization'],
    ];

    Future<void> seedChat(String id) => db.chatsDao.upsertServerChat(
      rows: ChatBlobMapper.blobToRows(
        chatId: id,
        title: 'Bird notes',
        createdAt: 1,
        updatedAt: 1,
        blob: <String, dynamic>{
          'title': 'Bird notes',
          'history': <String, dynamic>{
            'currentId': 'm1',
            'messages': <String, dynamic>{
              'm1': <String, dynamic>{
                'id': 'm1',
                'parentId': null,
                'childrenIds': <String>[],
                'role': 'user',
                'content': 'Which herons winter here?',
                'timestamp': 1,
              },
            },
          },
        },
      ),
    );

    test('an update goes only as the session it started as', () async {
      await seedChat('c1');
      reads.onMessagesRead = () => api.updateAuthToken('session-b');

      final refusal = await push()
          .pushUpdateChat('c1')
          .then<Object?>((_) => null, onError: (Object error) => error);

      check(bearers()).isEmpty();
      check(refusal).isA<DioException>();
    });

    test('a new chat is created only as the session it started as', () async {
      await seedChat('local:new');
      reads.onMessagesRead = () => api.updateAuthToken('session-b');

      final refusal = await push()
          .pushCreateChat('local:new')
          .then<Object?>((_) => null, onError: (Object error) => error);

      check(bearers()).isEmpty();
      check(refusal).isA<DioException>();
    });

    // Open WebUI refuses a session that has been replaced (its token signed
    // out) as it refuses one that may not write the chat. Only the second
    // says anything about the session the op will go as next.
    for (final (label, replaced) in const [
      ('one replaced since stays queued', true),
      ('the current one parks', false),
    ]) {
      test('a refusal of the session it went as: $label', () async {
        await seedChat('c1');
        final seq = await db.outboxDao.enqueue(
          kind: OutboxKind.updateChat,
          chatId: 'c1',
        );
        api.dio.httpClientAdapter = _RoutedAdapter((method, path) {
          if (replaced) api.updateAuthToken('session-b');
          return (401, {'detail': 'access prohibited'});
        });

        await _chatDrainer(
          db,
          ApiSyncApiClient(api, ownsDatabase: (_) => true),
          remapper,
        ).drain();

        check((await db.outboxDao.opBySeq(seq))?.status)
            .equals(replaced ? OutboxStatus.pending : OutboxStatus.failed);
      });
    }

    test('stays queued, unsent, while no session owns the account', () async {
      await seedChat('c1');
      final seq = await db.outboxDao.enqueue(
        kind: OutboxKind.updateChat,
        chatId: 'c1',
      );
      final drainer = _chatDrainer(
        db,
        ApiSyncApiClient(api, ownsDatabase: (_) => false),
        remapper,
      );

      await drainer.drain();

      check(server.requests).isEmpty();
      final op = (await db.outboxDao.opBySeq(seq))!;
      check(op.status).equals(OutboxStatus.pending);
      check(op.attempts).equals(0);
    });
  });

  group('getFolderById', () {
    test('reads as the account that captured the snapshot', () async {
      final adapter = _RecordingAdapter();
      final api = ApiService(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://server.example',
        ),
        workerManager: WorkerManager(),
        authToken: 'session-a',
      );
      addTearDown(api.dispose);
      api.dio.httpClientAdapter = adapter;

      final accountA = api.captureAuthSnapshot();
      await api.getFolderById('p', authSnapshot: accountA);
      check(adapter.requests.single.headers['Authorization'])
          .equals('Bearer session-a');

      // Another account signs in; the editor's snapshot must not follow it.
      api.updateAuthToken('session-b');
      await check(
        api.getFolderById('p', authSnapshot: accountA),
      ).throws<DioException>(
        (error) =>
            error.has((e) => e.type, 'type').equals(DioExceptionType.cancel),
      );
      check(adapter.requests).length.equals(1);
    });
  });
}

/// Runs [onMessagesRead] once, as a read of a chat's messages returns.
class _ReadTap extends QueryInterceptor {
  void Function()? onMessagesRead;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final rows = await executor.runSelect(statement, args);
    final read = onMessagesRead;
    if (read != null && statement.contains('FROM "messages"')) {
      onMessagesRead = null;
      read();
    }
    return rows;
  }
}

class _FixedClock implements SyncClock {
  @override
  int nowEpochSeconds() => 1000;
}

class _MovableClock implements SyncClock {
  int now = 1000;

  @override
  int nowEpochSeconds() => now;
}

/// Seconds past the longest backoff a drainer waits ([Backoff.capMs]).
const _pastAnyBackoff = 301;

class _RecordingAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  /// Runs as each request arrives.
  void Function()? onFetch;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    onFetch?.call();
    return ResponseBody.fromString(
      jsonEncode({'id': 'p', 'name': 'Project', 'updated_at': 3}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A server holding chat `c1`, owned by [owner], for a session that
/// [sessionStatus] lets in as `user-1`. A message delete answers
/// [deleteStatus].
_RoutedAdapter _heldChatServer({
  required int sessionStatus,
  required String owner,
  int deleteStatus = 401,
}) => _RoutedAdapter(
  (method, path) => switch ((method, path)) {
    ('DELETE', _) => (
      deleteStatus,
      deleteStatus == 200
          ? {'id': 'c1', 'user_id': owner, 'chat': <String, dynamic>{}}
          : {'detail': 'access prohibited'},
    ),
    ('GET', '/api/v1/auths/') => (
      sessionStatus,
      sessionStatus == 200
          ? {'id': 'user-1', 'email': 'ada@example.test', 'role': 'user'}
          : {'detail': 'Not authenticated'},
    ),
    ('GET', '/api/v1/chats/c1') => (
      200,
      {'id': 'c1', 'user_id': owner, 'chat': <String, dynamic>{}},
    ),
    _ => (404, {'detail': 'Not found'}),
  },
);

/// Answers each request with [answer], recording it as `METHOD path`, once
/// [before] it is done.
class _RoutedAdapter implements HttpClientAdapter {
  _RoutedAdapter(this.answer, {this.before});

  final (int, Object?) Function(String method, String path) answer;
  final Future<void> Function(String request)? before;
  final requests = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final request = '${options.method} ${options.path}';
    requests.add(request);
    await before?.call(request);
    final (status, body) = answer(options.method, options.path);
    return ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(body)))),
      status,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _NoCompletions implements RequestCompletionRunner {
  @override
  Future<void> run({
    required String chatId,
    required Map<String, dynamic> payload,
  }) => throw StateError('no completion runs here');
}

class _FixedAdapter implements HttpClientAdapter {
  _FixedAdapter({required this.statusCode, required this.body});

  final int statusCode;
  final Object? body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(body)))),
      statusCode,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

SyncApiClient _buildClient(HttpClientAdapter adapter) {
  final service = ApiService(
    serverConfig: const ServerConfig(
      id: 'test',
      name: 'Test',
      url: 'http://localhost:0',
    ),
    workerManager: WorkerManager(),
  );
  service.dio.httpClientAdapter = adapter;
  service.dio.interceptors.clear();
  return ApiSyncApiClient(service, ownsDatabase: (_) => true);
}

const _deleteA1 = 'DELETE /api/v1/chats/c1/messages/a1';
const _deleteB1 = 'DELETE /api/v1/chats/c2/messages/b1';

DioException _timeout(String path) => DioException.receiveTimeout(
  timeout: const Duration(seconds: 30),
  requestOptions: RequestOptions(path: path),
);

/// A drainer of [db] whose only adapter is the chat one, sending as [client].
OutboxDrainer _chatDrainer(
  AppDatabase db,
  SyncApiClient client,
  IdRemapper remapper, {
  SyncClock? clock,
}) {
  final locks = ConversationLocks();
  return OutboxDrainer(
    db: db,
    clock: clock ?? _FixedClock(),
    backoff: Backoff(jitter: () => 0.0),
    isOnline: () => true,
    completion: _NoCompletions(),
    adapters: [
      ChatAdapter(
        pull: PullSync(client: client, db: db, locks: locks),
        push: PushSync(
          client: client,
          db: db,
          chatLocks: locks,
          folderLocks: FolderLocks(),
          clock: _FixedClock(),
          remapper: remapper,
        ),
      ),
    ],
  );
}

/// The delete of message `a1` of chat `c1`, waiting to go.
Future<int> _pendingDelete(AppDatabase db) => db.outboxDao.enqueue(
  kind: OutboxKind.deleteMessages,
  chatId: 'c1',
  payload: {
    kDeleteMessagesIdsKey: ['a1'],
  },
);

/// The delete of message `a1` of chat `c1`, parked on a refusal.
Future<int> _parkedDelete(AppDatabase db) async {
  final seq = await _pendingDelete(db);
  await db.outboxDao.markParked(seq, error: 'forbidden');
  return seq;
}
