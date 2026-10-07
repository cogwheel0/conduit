import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/server_memory.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/fake.dart';
import 'package:test/test.dart';

const _server = ServerConfig(
  id: 'test-server',
  name: 'Test Server',
  url: 'https://example.com',
  isActive: true,
);

void main() {
  group('account fence', () {
    test(
      'a same-server account switch discards the previous account\'s load',
      () async {
        final api = _FakeMemoriesApi()..holdLoads = true;
        final session = await _Session.start(api);
        addTearDown(session.dispose);

        unawaited(
          session.container.read(userMemoriesProvider.future).then((_) {}),
        );
        await pumpEventQueue();
        check(api.loads).length.equals(1);

        session.switchAccount();
        unawaited(
          session.container.read(userMemoriesProvider.future).then((_) {}),
        );
        await pumpEventQueue();
        check(api.loads).length.equals(2);

        api.loads[1].complete([_memory('b1')]);
        await pumpEventQueue();
        api.loads[0].complete([_memory('a1')]);
        await pumpEventQueue();

        check(
          session.container
              .read(userMemoriesProvider)
              .requireValue
              .map((memory) => memory.id),
        ).deepEquals(['b1']);
      },
    );

    test('a mutation finishing after an account switch cannot update the '
        'new account\'s memories', () async {
      final api = _FakeMemoriesApi()..memories = [_memory('a1')];
      final session = await _Session.start(api);
      addTearDown(session.dispose);
      await session.container.read(userMemoriesProvider.future);

      final gate = api.holdCreate = Completer<void>();
      final added = session.container
          .read(userMemoriesProvider.notifier)
          .add('from account A');
      await pumpEventQueue();
      check(api.created).length.equals(1);

      api.memories = [_memory('b1')];
      session.switchAccount();
      await session.container.read(userMemoriesProvider.future);
      gate.complete();

      check((await added).content).equals('from account A');
      check(
        session.container
            .read(userMemoriesProvider)
            .requireValue
            .map((memory) => memory.id),
      ).deepEquals(['b1']);
    });

    test('a delete finishing after an account switch leaves the new account '
        'untouched', () async {
      final api = _FakeMemoriesApi()..memories = [_memory('shared-id')];
      final session = await _Session.start(api);
      addTearDown(session.dispose);
      await session.container.read(userMemoriesProvider.future);

      final gate = api.holdDelete = Completer<void>();
      final deleted = session.container
          .read(userMemoriesProvider.notifier)
          .deleteItem('shared-id');
      await pumpEventQueue();

      api.memories = [_memory('shared-id', content: 'account B')];
      session.switchAccount();
      await session.container.read(userMemoriesProvider.future);
      gate.complete();
      await deleted;

      check(
        session.container
            .read(userMemoriesProvider)
            .requireValue
            .map((memory) => memory.content),
      ).deepEquals(['account B']);
    });

    test('a refresh finishing after an account switch is discarded', () async {
      final api = _FakeMemoriesApi()..memories = [_memory('a1')];
      final session = await _Session.start(api);
      addTearDown(session.dispose);
      await session.container.read(userMemoriesProvider.future);

      api.holdLoads = true;
      final refreshed = session.container
          .read(userMemoriesProvider.notifier)
          .refresh();
      await pumpEventQueue();
      check(api.loads).length.equals(1);

      api.holdLoads = false;
      api.memories = [_memory('b1')];
      session.switchAccount();
      await session.container.read(userMemoriesProvider.future);
      api.loads.single.complete([_memory('a-stale')]);
      await refreshed;

      check(
        session.container
            .read(userMemoriesProvider)
            .requireValue
            .map((memory) => memory.id),
      ).deepEquals(['b1']);
    });

    test('a mutation never reaches the server when the account changes while '
        'its permission is being checked', () async {
      final api = _FakeMemoriesApi();
      final session = await _Session.start(api);
      addTearDown(session.dispose);
      await session.container.read(userMemoriesProvider.future);

      final permissions = api.holdPermissions =
          Completer<Map<String, dynamic>>();
      final added = session.container
          .read(userMemoriesProvider.notifier)
          .add('late');
      await pumpEventQueue();
      check(api.permissionCalls).equals(2);
      session.switchAccount();
      permissions.complete(const {});

      await expectLater(added, throwsStateError);
      check(api.created).isEmpty();
    });
  });

  group('owner captured when a form opens', () {
    test('saves for the account that opened it', () async {
      final api = _FakeMemoriesApi()..memories = [_memory('m1')];
      final session = await _Session.start(api);
      addTearDown(session.dispose);
      await session.container.read(userMemoriesProvider.future);
      final notifier = session.container.read(userMemoriesProvider.notifier);

      final owner = notifier.captureOwner();
      await notifier.add('kept', owner: owner);
      await notifier.updateItem('m1', 'edited', owner: owner);

      check(api.created.map((write) => write.content)).deepEquals(['kept']);
      check(api.updated.map((write) => write.content)).deepEquals(['edited']);
    });

    test('no mutation reaches the server once another account signs in on the '
        'same server', () async {
      final api = _FakeMemoriesApi()..memories = [_memory('a1')];
      final session = await _Session.start(api);
      addTearDown(session.dispose);
      await session.container.read(userMemoriesProvider.future);
      final notifier = session.container.read(userMemoriesProvider.notifier);
      final owner = notifier.captureOwner();

      api.memories = [_memory('b1')];
      session.switchAccount();
      await session.container.read(userMemoriesProvider.future);

      final attempts = <String, Future<Object?> Function()>{
        'add': () => notifier.add('from A', owner: owner),
        'update': () => notifier.updateItem('b1', 'from A', owner: owner),
        'delete': () => notifier.deleteItem('b1', owner: owner),
        'clear': () => notifier.clearAll(owner: owner),
      };
      for (final MapEntry(:key, :value) in attempts.entries) {
        await expectLater(
          value(),
          throwsA(isA<MemoryOwnerChangedException>()),
          reason: key,
        );
      }

      check(api.created).isEmpty();
      check(api.updated).isEmpty();
      check(api.deleted).isEmpty();
      check(api.cleared).equals(0);
      check(
        session.container
            .read(userMemoriesProvider)
            .requireValue
            .map((memory) => memory.id),
      ).deepEquals(['b1']);
    });
  });

  group('requests', () {
    test('a new memory is classified as user by default', () async {
      final api = _FakeMemoriesApi();
      final session = await _Session.start(api);
      addTearDown(session.dispose);
      await session.container.read(userMemoriesProvider.future);

      final created = await session.container
          .read(userMemoriesProvider.notifier)
          .add('Prefers metric units');

      check(api.created.single.type).equals('user');
      check(api.created.single.path).isNull();
      check(api.created.single.snapshotted).isTrue();
      check(created.type).equals('user');
    });

    test('a content-only edit keeps an existing context classification and '
        'path', () async {
      final api = _FakeMemoriesApi()
        ..memories = [
          _memory('m1', type: 'context', path: 'projects/conduit'),
          _memory('m2', type: 'episodic'),
          _memory('m3'),
        ];
      final session = await _Session.start(api);
      addTearDown(session.dispose);
      await session.container.read(userMemoriesProvider.future);
      final notifier = session.container.read(userMemoriesProvider.notifier);

      await notifier.updateItem('m1', 'edited 1');
      await notifier.updateItem('m2', 'edited 2');
      await notifier.updateItem('m3', 'edited 3');

      for (final update in api.updated) {
        check(update.type).isNull();
        check(update.path).isNull();
        check(update.snapshotted).isTrue();
      }
      final byId = {
        for (final memory
            in session.container.read(userMemoriesProvider).requireValue)
          memory.id: memory,
      };
      check(byId['m1']!.type).equals('context');
      check(byId['m1']!.path).equals('projects/conduit');
      check(byId['m2']!.type).equals('episodic');
      check(byId['m3']!.type).isNull();
    });

    test('an explicit type and path change is forwarded', () async {
      final api = _FakeMemoriesApi()
        ..memories = [_memory('m1', type: 'context')];
      final session = await _Session.start(api);
      addTearDown(session.dispose);
      await session.container.read(userMemoriesProvider.future);

      await session.container
          .read(userMemoriesProvider.notifier)
          .updateItem('m1', 'edited', type: 'user', path: 'prefs');

      check(api.updated.single.type).equals('user');
      check(api.updated.single.path).equals('prefs');
    });
  });

  group('memory permission', () {
    test(
      'a user without the memories permission neither reads nor writes',
      () async {
        final api = _FakeMemoriesApi()
          ..permissions = {
            'features': {'memories': false},
          };
        final session = await _Session.start(api, role: 'user');
        addTearDown(session.dispose);

        final loaded = await session.container.read(
          userMemoriesProvider.future,
        );

        check(loaded).isEmpty();
        check(api.getCalls).equals(0);
        await expectLater(
          session.container.read(userMemoriesProvider.notifier).add('x'),
          throwsA(isA<MemoriesNotPermittedException>()),
        );
        check(api.created).isEmpty();
        check(await session.container.read(memoriesPermittedProvider.future))
            .isFalse();
      },
    );

    test('a missing memories permission is allowed', () async {
      final api = _FakeMemoriesApi()
        ..permissions = {
          'features': {'web_search': false},
        }
        ..memories = [_memory('m1')];
      final session = await _Session.start(api, role: 'user');
      addTearDown(session.dispose);

      final loaded = await session.container.read(userMemoriesProvider.future);

      check(loaded.map((memory) => memory.id)).deepEquals(['m1']);
    });

    test('an admin is allowed regardless of the permission document', () async {
      final api = _FakeMemoriesApi()
        ..permissions = {
          'features': {'memories': false},
        };
      final session = await _Session.start(api, role: 'admin');
      addTearDown(session.dispose);
      await session.container.read(userMemoriesProvider.future);

      await session.container.read(userMemoriesProvider.notifier).add('x');

      check(api.created).length.equals(1);
      check(api.permissionCalls).equals(0);
    });

    test('an unreadable permission document leaves the decision to the '
        'server', () async {
      final api = _FakeMemoriesApi()
        ..permissionsError = StateError('permissions unavailable')
        ..memories = [_memory('m1')];
      final session = await _Session.start(api, role: 'user');
      addTearDown(session.dispose);

      final loaded = await session.container.read(userMemoriesProvider.future);

      check(loaded).length.equals(1);
    });
  });
}

/// One signed-in client whose account can be switched without replacing the
/// [ApiService], as happens when another user signs in on the same server.
final class _Session {
  _Session(this.api, {String role = 'user'}) {
    container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        currentUserProvider2.overrideWithValue(
          User(
            id: 'user-1',
            username: 'user',
            email: 'user@example.com',
            role: role,
          ),
        ),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => _epoch),
      ],
    );
  }

  /// Starts a session whose active server has resolved, so the first read of a
  /// memory provider is not superseded by that resolution.
  static Future<_Session> start(
    _FakeMemoriesApi api, {
    String role = 'user',
  }) async {
    final session = _Session(api, role: role);
    await session.container.read(activeServerProvider.future);
    return session;
  }

  final _FakeMemoriesApi api;
  late final ProviderContainer container;
  Object _epoch = Object();

  void switchAccount() {
    _epoch = Object();
    container.invalidate(openWebUiAuthSessionEpochProvider);
  }

  void dispose() => container.dispose();
}

final class _Storage extends Fake implements OptimizedStorageService {
  @override
  bool isUncommittedServerConfigCandidate(ServerConfig config) => false;

  @override
  Future<List<ServerConfig>> getServerConfigs() async => const [_server];

  @override
  Future<List<ServerConfig>> getServerConfigsStrict() async => const [_server];

  @override
  Future<String?> getActiveServerId() async => _server.id;
}

typedef _Write = ({
  String content,
  String? type,
  String? path,
  bool snapshotted,
});

final class _FakeMemoriesApi extends ApiService {
  _FakeMemoriesApi()
    : super(serverConfig: _server, workerManager: WorkerManager());

  List<ServerMemory> memories = const [];
  Map<String, dynamic> permissions = const {};
  Object? permissionsError;
  bool holdLoads = false;
  Completer<Map<String, dynamic>>? holdPermissions;
  Completer<void>? holdCreate;
  Completer<void>? holdDelete;

  final loads = <Completer<List<ServerMemory>>>[];
  final created = <_Write>[];
  final updated = <_Write>[];
  final deleted = <String>[];
  int cleared = 0;
  int getCalls = 0;
  int permissionCalls = 0;

  @override
  Future<Map<String, dynamic>> getUserPermissions({
    ApiAuthSnapshot? authSnapshot,
  }) async {
    permissionCalls += 1;
    final error = permissionsError;
    if (error != null) throw error;
    return holdPermissions?.future ?? permissions;
  }

  @override
  Future<List<ServerMemory>> getMemories({
    ApiAuthSnapshot? authSnapshot,
  }) async {
    getCalls += 1;
    if (holdLoads) {
      final load = Completer<List<ServerMemory>>();
      loads.add(load);
      return load.future;
    }
    return memories;
  }

  @override
  Future<ServerMemory> createMemory({
    required String content,
    String type = ServerMemory.userType,
    String? path,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    created.add((
      content: content,
      type: type,
      path: path,
      snapshotted: authSnapshot != null,
    ));
    await holdCreate?.future;
    return _memory('created-${created.length}', content: content, type: type);
  }

  @override
  Future<ServerMemory> updateMemory({
    required String memoryId,
    required String content,
    String? type,
    String? path,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    updated.add((
      content: content,
      type: type,
      path: path,
      snapshotted: authSnapshot != null,
    ));
    // The server keeps what it stores for every field the request omits.
    final stored = memories.firstWhere((memory) => memory.id == memoryId);
    return _memory(
      memoryId,
      content: content,
      type: type ?? stored.type,
      path: path ?? stored.path,
      updatedAtEpoch: 99,
    );
  }

  @override
  Future<void> deleteMemory(
    String memoryId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    deleted.add(memoryId);
    await holdDelete?.future;
  }

  @override
  Future<void> clearAllMemories({ApiAuthSnapshot? authSnapshot}) async {
    cleared += 1;
  }
}

ServerMemory _memory(
  String id, {
  String? content,
  String? type,
  String? path,
  int updatedAtEpoch = 10,
}) {
  return ServerMemory(
    id: id,
    userId: 'user-1',
    content: content ?? id,
    updatedAtEpoch: updatedAtEpoch,
    createdAtEpoch: 1,
    type: type,
    path: path,
  );
}
