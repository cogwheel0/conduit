import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/note_mapper.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/sharing/models/resource_access.dart';
import 'package:conduit_core/features/sharing/providers/resource_access_controller.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _server = ServerConfig(
  id: 'test-server',
  name: 'Test Server',
  url: 'https://server.example',
  isActive: true,
);

const _user = User(
  id: 'alice',
  username: 'alice',
  email: 'alice@example.com',
  role: 'user',
);

WorkspaceAccessGrantInput _grant(
  WorkspacePrincipalType type,
  String id,
  WorkspaceGrantPermission permission,
) => WorkspaceAccessGrantInput(
  principalType: type,
  principalId: id,
  permission: permission,
);

const _anyone = {
  'principal_type': 'anyone',
  'principal_id': '*',
  'permission': 'read',
};

void main() {
  late _Adapter adapter;
  late ApiService api;
  late AppDatabase db;
  late ProviderContainer container;
  var epoch = Object();

  void switchAccount() {
    epoch = Object();
    container.invalidate(openWebUiAuthSessionEpochProvider);
  }

  setUp(() async {
    adapter = _Adapter();
    api = ApiService(
      serverConfig: _server,
      workerManager: WorkerManager(),
      authToken: 'session-a',
    );
    api.dio.httpClientAdapter = adapter;
    db = AppDatabase(NativeDatabase.memory());
    epoch = Object();
    container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        appDatabaseProvider.overrideWith((ref) => db),
        isAuthenticatedProvider2.overrideWithValue(true),
        currentUserProvider2.overrideWithValue(_user),
        activeServerProvider.overrideWith((ref) async => _server),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
      ],
    );
    await container.read(activeServerProvider.future);
  });

  tearDown(() async {
    container.dispose();
    api.dispose();
    await db.close();
  });

  ResourceAccessController openFor(ResourceKind kind, String id) =>
      ResourceAccessController.open(container, kind: kind, resourceId: id)!;

  Map<String, dynamic> noteDetail({
    required bool writeAccess,
    List<Map<String, dynamic>> grants = const [],
  }) => {
    'id': 'n1',
    'user_id': 'creator',
    'title': 'Shared',
    'write_access': writeAccess,
    'access_grants': grants,
  };

  test('a write recipient saves, keeps rows it cannot model, and hydrates the '
      "server's filtered answer", () async {
    adapter.respondWith = [
      noteDetail(
        writeAccess: true,
        grants: [
          {
            'principal_type': 'user',
            'principal_id': 'alice',
            'permission': 'read',
          },
          {
            'principal_type': 'user',
            'principal_id': 'alice',
            'permission': 'write',
          },
          _anyone,
        ],
      ),
      // The update response: no write_access.
      {'id': 'n1', 'access_grants': <Map<String, dynamic>>[]},
      // The server dropped the user row it was not allowed to keep.
      noteDetail(
        writeAccess: true,
        grants: [
          {
            'principal_type': 'group',
            'principal_id': 'g1',
            'permission': 'read',
          },
          _anyone,
        ],
      ),
    ];
    final controller = openFor(ResourceKind.note, 'n1');
    final loaded = await controller.load();
    check(loaded.canEdit).isTrue();

    final saved = await controller.save(loaded, [
      _grant(WorkspacePrincipalType.group, 'g1', WorkspaceGrantPermission.read),
      _grant(WorkspacePrincipalType.user, 'bob', WorkspaceGrantPermission.read),
    ]);

    check(adapter.requests.map((r) => '${r.method} ${r.path}')).deepEquals([
      'GET /api/v1/notes/n1',
      'POST /api/v1/notes/n1/access/update',
      'GET /api/v1/notes/n1',
    ]);
    check(adapter.requests[1].data).isA<Map>().deepEquals({
      'access_grants': [
        {'principal_type': 'group', 'principal_id': 'g1', 'permission': 'read'},
        {'principal_type': 'user', 'principal_id': 'bob', 'permission': 'read'},
        _anyone,
      ],
    });
    // The form is replaced by the server's answer, write access included.
    check(saved.writeAccess).equals(true);
    check(saved.rawGrants).length.equals(2);
    check(saved.editableGrants.single.principalId).equals('g1');
  });

  test('an account switch while the hydration waits for the note lock refuses '
      'the saved answer', () async {
    adapter.respondWith = [
      noteDetail(writeAccess: true),
      {'id': 'n1'},
      noteDetail(writeAccess: true, grants: [_anyone]),
    ];
    await db
        .into(db.notes)
        .insertOnConflictUpdate(
          serverToNoteRow({
            ...noteDetail(writeAccess: true),
            'data': {
              'content': {'md': 'body'},
            },
            'created_at': 1,
            'updated_at': 1,
          }),
        );
    final controller = openFor(ResourceKind.note, 'n1');
    final loaded = await controller.load();

    // A pull holds the note while the save's POST and read-back complete.
    final held = Completer<void>();
    final holding = Completer<void>();
    final pull = container.read(noteLocksProvider).runExclusive('n1', () async {
      holding.complete();
      await held.future;
    });
    await holding.future;
    final saving = controller.save(loaded, const []);
    final outcome = saving.then<Object?>((v) => v, onError: (Object e) => e);
    while (adapter.requests.length < 3) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    switchAccount();
    held.complete();
    await pull;

    check(await outcome)
        .isA<ResourceAccessException>()
        .has((e) => e.failure, 'failure')
        .equals(ResourceAccessFailure.sessionChanged);
    final stored = decodeJsonMap((await db.notesDao.getNote('n1'))!.rawExtra);
    check(stored['access_grants']).isA<List>().isEmpty();
  });

  test('a read-only recipient cannot save and nothing is sent', () async {
    adapter.respondWith = [noteDetail(writeAccess: false)];
    final controller = openFor(ResourceKind.note, 'n1');
    final loaded = await controller.load();

    await check(controller.save(loaded, const []))
        .throws<ResourceAccessException>(
          (e) => e
              .has((x) => x.failure, 'failure')
              .equals(ResourceAccessFailure.notEditable),
        );
    check(adapter.requests).length.equals(1);
  });

  test(
    'an account switched on the same API after open sends nothing at all',
    () async {
      adapter.respondWith = [noteDetail(writeAccess: true)];
      final controller = openFor(ResourceKind.note, 'n1');
      final loaded = await controller.load();
      adapter.requests.clear();

      switchAccount();

      await check(controller.save(loaded, const []))
          .throws<ResourceAccessException>(
            (e) => e
                .has((x) => x.failure, 'failure')
                .equals(ResourceAccessFailure.sessionChanged),
          );
      await check(controller.load()).throws<ResourceAccessException>();
      check(adapter.requests).isEmpty();
    },
  );

  test(
    'an account switched while the update is in flight is not hydrated',
    () async {
      adapter.respondWith = [
        noteDetail(writeAccess: true),
        {'id': 'n1'},
        noteDetail(writeAccess: true, grants: [_anyone]),
      ];
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow(
              noteDetail(writeAccess: true)
                ..['data'] = {
                  'content': {'md': 'body'},
                }
                ..['created_at'] = 1
                ..['updated_at'] = 1,
            ),
          );
      final controller = openFor(ResourceKind.note, 'n1');
      final loaded = await controller.load();
      adapter.requests.clear();
      final gate = adapter.hold = Completer<void>();

      final saving = controller.save(loaded, const []);
      await pumpEventQueue();
      check(adapter.requests).length.equals(1);
      switchAccount();
      gate.complete();

      await check(saving).throws<ResourceAccessException>();
      // No read of the new account's state, and nothing stored for it.
      check(adapter.requests).length.equals(1);
      final row = (await db.notesDao.getNote('n1'))!;
      check(decodeJsonMap(row.rawExtra)['access_grants']).isA<List>().isEmpty();
    },
  );

  test('a revoked read is denied, not missing', () async {
    adapter.statusFor = (path) => path.endsWith('/notes/n1') ? 403 : 404;
    final controller = openFor(ResourceKind.note, 'n1');

    await check(controller.load()).throws<ResourceAccessException>(
      (e) => e
          .has((x) => x.failure, 'failure')
          .equals(ResourceAccessFailure.denied),
    );

    final missing = openFor(ResourceKind.folder, 'gone');
    await check(missing.load()).throws<ResourceAccessException>(
      (e) => e
          .has((x) => x.failure, 'failure')
          .equals(ResourceAccessFailure.missing),
    );
  });

  test(
    'saving a note stores its grants beside the content, never as an edit',
    () async {
      adapter.respondWith = [
        noteDetail(writeAccess: true),
        {'id': 'n1'},
        noteDetail(writeAccess: true, grants: [_anyone]),
      ];
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow(
              noteDetail(writeAccess: true)
                ..['data'] = {
                  'content': {'md': 'body'},
                }
                ..['created_at'] = 1
                ..['updated_at'] = 1,
            ),
          );
      final controller = openFor(ResourceKind.note, 'n1');

      await controller.save(await controller.load(), const []);

      final row = (await db.notesDao.getNote('n1'))!;
      check(decodeJsonMap(row.rawExtra)['access_grants'])
          .isA<List>()
          .length
          .equals(1);
      check(row.dirtyData).isFalse();
      check(row.dirtyTitle).isFalse();
      check(await db.outboxDao.pendingForChat('n1')).isEmpty();
    },
  );

  test(
    'a chat is opened by its own id and its link id is never the key',
    () async {
      adapter.respondWith = [
        [_anyone],
      ];
      final controller = openFor(ResourceKind.chat, 'chat-original');

      final loaded = await controller.load();

      check(adapter.requests.single.path)
          .equals('/api/v1/chats/shared/chat-original/access');
      check(loaded.canEdit).isTrue();
      check(loaded.editableGrants).isEmpty();
      check(loaded.preservedGrants).deepEquals([_anyone]);
    },
  );
}

final class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  /// Bodies handed out in order; the last one repeats.
  List<Object> respondWith = const [<String, dynamic>{}];

  /// When set, the next response waits for it.
  Completer<void>? hold;

  int Function(String path)? statusFor;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final gate = hold;
    if (gate != null && requests.length == 1) {
      hold = null;
      await gate.future;
    }
    final status = statusFor?.call(options.path) ?? 200;
    final index = (requests.length - 1).clamp(0, respondWith.length - 1);
    return ResponseBody.fromString(
      jsonEncode(status == 200 ? respondWith[index] : {'detail': 'no'}),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
