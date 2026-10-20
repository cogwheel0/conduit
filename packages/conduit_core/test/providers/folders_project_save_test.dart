import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart'
    show ApiAuthSnapshot;
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

class _Epoch extends Notifier<Object> {
  @override
  Object build() => Object();

  void rotate() => state = Object();
}

final _epochProvider = NotifierProvider<_Epoch, Object>(_Epoch.new);

class _CountingEngine extends SyncEngine {
  final drained = <AppDatabase>[];

  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<void> drainNowForDatabase(AppDatabase expectedDatabase) async {
    drained.add(expectedDatabase);
  }
}

/// A real [ApiService] whose folder-by-id and file-info reads are answered
/// locally, with the server's own status for a file: 200, 404 or a failure.
class _DetailApi extends ApiService {
  _DetailApi()
    : super(
        serverConfig: _server,
        workerManager: WorkerManager(),
        authToken: 'session-a',
      );

  Map<String, dynamic>? detail;
  bool offline = false;
  Completer<void>? detailGate;
  final detailRequests = <ApiAuthSnapshot?>[];
  final fileStatus = <String, int>{};
  Completer<void>? fileGate;

  @override
  Future<Map<String, dynamic>?> getFolderById(
    String id, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    detailRequests.add(authSnapshot);
    final answer = detail;
    await detailGate?.future;
    if (offline) {
      throw DioException(
        requestOptions: RequestOptions(path: '/api/v1/folders/$id'),
        type: DioExceptionType.connectionError,
      );
    }
    return answer;
  }

  @override
  Future<Map<String, dynamic>> getFileInfo(
    String fileId, {
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async {
    await fileGate?.future;
    final status = fileStatus[fileId] ?? 200;
    if (status == 200) return <String, dynamic>{'id': fileId};
    final request = RequestOptions(path: '/api/v1/files/$fileId');
    throw DioException(
      requestOptions: request,
      response: Response<Object?>(requestOptions: request, statusCode: status),
    );
  }
}

/// Marks a folder answer that has no `data` key at all.
const _absent = Object();

const _server = ServerConfig(
  id: 'server-a',
  name: 'Server A',
  url: 'https://server-a.example.test',
);

void main() {
  late AppDatabase db;
  late _DetailApi api;
  late _CountingEngine engine;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    api = _DetailApi();
    engine = _CountingEngine();
    PreferencesStore.debugReset();
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    await db.foldersDao.replaceServerFolders([
      {
        'id': 'p',
        'name': 'Project',
        'created_at': 1,
        'updated_at': 2,
        'data': {'system_prompt': 'Be brief'},
      },
      {
        'id': 'shared',
        'name': 'Shared',
        'created_at': 1,
        'updated_at': 2,
        'shared': true,
        'permission': 'write',
        'data': {'system_prompt': 'Be brief'},
      },
    ]);
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        apiServiceProvider.overrideWithValue(api),
        isAuthenticatedProvider2.overrideWithValue(true),
        authTokenProvider3.overrideWithValue('session-a'),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'me',
            username: 'me',
            email: 'me@example.test',
            role: 'user',
          ),
        ),
        activeServerProvider.overrideWith((ref) async => _server),
        openWebUiAuthSessionEpochProvider.overrideWith(
          (ref) => ref.watch(_epochProvider),
        ),
        syncEngineProvider.overrideWith(() => engine),
      ],
    );
    container.listen(activeServerProvider, (_, _) {});
    await container.read(activeServerProvider.future);
  });

  tearDown(() async {
    container.dispose();
    api.dispose();
    await db.close();
    PreferencesStore.debugReset();
  });

  Future<Map<String, dynamic>> storedData() async =>
      (jsonDecode((await db.foldersDao.getFolder('p'))!.rawExtra)
              as Map<String, dynamic>)['data']
          as Map<String, dynamic>;

  Matcher ownerChanged = isA<FolderProjectWriteException>().having(
    (error) => error.reason,
    'reason',
    FolderProjectWriteFailure.ownerChanged,
  );

  test('saves under the folder lock and asks for a drain', () async {
    final folders = container.read(foldersProvider.notifier);
    final owner = folders.captureProjectOwner()!;

    await folders.saveProjectDefaults(owner, 'p', modelIds: ['m-a']);

    check(await storedData()).deepEquals({
      'system_prompt': 'Be brief',
      'model_ids': ['m-a'],
    });
    check(engine.drained).length.equals(1);
  });

  test('clearing every default model saves null, not an empty list', () async {
    final folders = container.read(foldersProvider.notifier);
    final owner = folders.captureProjectOwner()!;
    await folders.saveProjectDefaults(owner, 'p', modelIds: ['m-a']);

    await folders.saveProjectDefaults(owner, 'p', modelIds: const <Object?>[]);

    // The web client treats a stored empty list as "select no model", but a
    // null as "no default", so null is what an emptied list is saved as.
    final data = await storedData();
    check(data.containsKey('model_ids')).isTrue();
    check(data['model_ids']).isNull();
    final queued = (await db.outboxDao.pendingForChat('p')).single;
    check((jsonDecode(queued.payload) as Map<String, dynamic>)['data'])
        .isA<Map<String, dynamic>>()
        .deepEquals({'model_ids': null});
  });

  test('an account that changed before Save writes nothing', () async {
    final folders = container.read(foldersProvider.notifier);
    final owner = folders.captureProjectOwner()!;

    container.read(_epochProvider.notifier).rotate();

    await expectLater(
      folders.saveProjectDefaults(owner, 'p', modelIds: ['m-a']),
      throwsA(ownerChanged),
    );
    check(await db.outboxDao.pendingForChat('p')).isEmpty();
    check(engine.drained).isEmpty();
  });

  test(
    'an account that changed while Save waited for the lock writes nothing',
    () async {
      final folders = container.read(foldersProvider.notifier);
      final owner = folders.captureProjectOwner()!;

      // Another operation holds the folder; Save queues behind it, and the
      // account changes in that window, after Save's first check has passed.
      final release = Completer<void>();
      final holder = container
          .read(folderLocksProvider)
          .runExclusive('p', () => release.future);
      final save = folders.saveProjectDefaults(owner, 'p', modelIds: ['m-a']);
      final outcome = expectLater(save, throwsA(ownerChanged));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      container.read(_epochProvider.notifier).rotate();
      release.complete();
      await holder;
      await outcome;

      check(await storedData()).deepEquals({'system_prompt': 'Be brief'});
      check(await db.outboxDao.pendingForChat('p')).isEmpty();
      check(engine.drained).isEmpty();
    },
  );

  test(
    'the server copy is not offered over edits this device has not sent',
    () async {
      final folders = container.read(foldersProvider.notifier);
      final owner = folders.captureProjectOwner()!;
      await folders.saveProjectDefaults(owner, 'p', modelIds: ['m-offline']);

      // The row is dirty now, so no request is made and nothing replaces it.
      check(await folders.loadProjectDetail(owner, 'p')).isNull();
    },
  );

  // The real GET /folders/{id}: write_access and access_grants, and none of the
  // shared listing's own `shared` / `permission`.
  Map<String, dynamic> detail({required bool writeAccess}) => {
    'id': 'shared',
    'name': 'Shared',
    'user_id': 'someone-else',
    'created_at': 1,
    'updated_at': 3,
    'data': {'system_prompt': 'Changed on the server'},
    'access_grants': [
      {
        'principal_type': 'user',
        'principal_id': 'me',
        'permission': writeAccess ? 'write' : 'read',
      },
    ],
    'write_access': writeAccess,
  };

  Future<Map<String, dynamic>> sharedData() async =>
      (jsonDecode((await db.foldersDao.getFolder('shared'))!.rawExtra)
              as Map<String, dynamic>)['data']
          as Map<String, dynamic>;

  test('a server verdict of no write access refuses a save a cached write '
      'grant would have allowed', () async {
    final folders = container.read(foldersProvider.notifier);
    final owner = folders.captureProjectOwner()!;
    api.detail = detail(writeAccess: false);

    final loaded = await folders.loadProjectDetail(owner, 'shared');
    check(loaded).isNotNull();

    await expectLater(
      folders.saveProjectDefaults(owner, 'shared', modelIds: ['m-a']),
      throwsA(
        isA<FolderProjectWriteException>().having(
          (error) => error.reason,
          'reason',
          FolderProjectWriteFailure.readOnly,
        ),
      ),
    );
    check(await db.outboxDao.pendingForChat('shared')).isEmpty();
    check(engine.drained).isEmpty();
  });

  test(
    'the verdict is kept when this device has unsent edits, and they stay',
    () async {
      final folders = container.read(foldersProvider.notifier);
      final owner = folders.captureProjectOwner()!;
      await folders.saveProjectDefaults(owner, 'shared', modelIds: ['m-mine']);
      api.detail = detail(writeAccess: false);

      // The unsent edit still wins over the server copy in the form...
      check(await folders.loadProjectDetail(owner, 'shared')).isNull();

      // ...is not overwritten by it, and no further edit is admitted.
      check(await sharedData()).deepEquals({
        'system_prompt': 'Be brief',
        'model_ids': ['m-mine'],
      });
      await expectLater(
        folders.saveProjectDefaults(owner, 'shared', modelIds: ['m-other']),
        throwsA(isA<FolderProjectWriteException>()),
      );
      check(await db.outboxDao.pendingForChat('shared')).length.equals(1);
    },
  );

  test(
    'a detail that allows writing leaves the cached grant as it was',
    () async {
      final folders = container.read(foldersProvider.notifier);
      final owner = folders.captureProjectOwner()!;
      api.detail = detail(writeAccess: true);

      await folders.loadProjectDetail(owner, 'shared');
      await folders.saveProjectDefaults(owner, 'shared', modelIds: ['m-a']);

      check((await sharedData())['model_ids'])
          .isA<List<dynamic>>()
          .deepEquals(['m-a']);
    },
  );

  // What a new draft starts from. The list the server sends has no `data`, so
  // this is read from the folder itself, as the account that asked.
  group('the project data of a folder for a new draft', () {
    Map<String, dynamic> answer(String id, {Object? data = _absent}) => {
      'id': id,
      'name': id,
      'created_at': 1,
      'updated_at': 3,
      if (data != _absent) 'data': data,
    };

    test('a folder only just listed takes the saved models and the account '
        'that asked made the request', () async {
      await db.foldersDao.upsertServerFolder({
        'id': 'lean',
        'name': 'lean',
        'created_at': 1,
        'updated_at': 2,
        'meta': null,
      });
      final folders = container.read(foldersProvider.notifier);
      final owner = folders.captureProjectOwner()!;
      api.detail = answer(
        'lean',
        data: {
          'system_prompt': 'Be brief',
          'model_ids': ['m-a', 'm-b'],
        },
      );

      final folder = await folders.refreshProjectData(owner, 'lean');

      check(folder!.projectModelIds).deepEquals(['m-a', 'm-b']);
      check(api.detailRequests.single).isNotNull();
      final stored = jsonDecode(
        (await db.foldersDao.getFolder('lean'))!.rawExtra,
      ) as Map<String, dynamic>;
      check(stored['data']).isA<Map<String, dynamic>>().deepEquals({
        'system_prompt': 'Be brief',
        'model_ids': ['m-a', 'm-b'],
      });
      check((await db.foldersDao.getFolder('lean'))!.dirty).isFalse();
    });

    test('defaults changed or cleared in another client replace the cached '
        'ones, and a shared folder keeps its grant', () async {
      final folders = container.read(foldersProvider.notifier);
      final owner = folders.captureProjectOwner()!;

      api.detail = answer(
        'shared',
        data: {
          'system_prompt': 'Changed on the server',
          'model_ids': ['m-b'],
        },
      );
      final changed = await folders.refreshProjectData(owner, 'shared');
      check(changed!.projectModelIds).deepEquals(['m-b']);
      check(changed.shared).isTrue();
      check(changed.permission).equals('write');

      api.detail = answer(
        'shared',
        data: {'system_prompt': 'Changed on the server', 'model_ids': null},
      );
      check(
        (await folders.refreshProjectData(owner, 'shared'))!.projectModelIds,
      ).isEmpty();

      // data: null is the server clearing everything; an answer with no data
      // key at all is not.
      api.detail = answer('shared', data: null);
      final cleared = await folders.refreshProjectData(owner, 'shared');
      check(cleared!.data).isNull();
      check(cleared.canWrite).isTrue();

      await db.foldersDao.upsertServerFolder({
        'id': 'shared',
        'name': 'Shared',
        'created_at': 1,
        'updated_at': 3,
        'shared': true,
        'permission': 'write',
        'data': {
          'model_ids': ['m-kept'],
        },
      });
      api.detail = answer('shared');
      final unchanged = await folders.refreshProjectData(owner, 'shared');
      check(unchanged!.projectModelIds).deepEquals(['m-kept']);
    });

    test('a failed read leaves the cached defaults as the answer', () async {
      await db.foldersDao.upsertServerFolder({
        'id': 'p',
        'name': 'Project',
        'created_at': 1,
        'updated_at': 2,
        'data': {
          'model_ids': ['m-cached'],
        },
      });
      final folders = container.read(foldersProvider.notifier);
      final owner = folders.captureProjectOwner()!;
      api
        ..detail = answer('p', data: null)
        ..offline = true;

      final folder = await folders.refreshProjectData(owner, 'p');

      check(folder!.projectModelIds).deepEquals(['m-cached']);
      check((await storedData())['model_ids'])
          .isA<List<dynamic>>()
          .deepEquals(['m-cached']);
    });

    test(
      'an edit saved while the read was out is not overwritten by it',
      () async {
        final folders = container.read(foldersProvider.notifier);
        final owner = folders.captureProjectOwner()!;
        api
          ..detail = answer(
            'p',
            data: {
              'model_ids': ['m-server'],
            },
          )
          ..detailGate = Completer<void>();

        final read = folders.refreshProjectData(owner, 'p');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await folders.saveProjectDefaults(owner, 'p', modelIds: ['m-mine']);
        api.detailGate!.complete();
        final folder = await read;

        check(folder!.projectModelIds).deepEquals(['m-mine']);
        check((await storedData())['model_ids'])
            .isA<List<dynamic>>()
            .deepEquals(['m-mine']);
        check(await db.outboxDao.pendingForChat('p')).length.equals(1);
      },
    );

    test(
      'a read of an account that has since changed stores nothing',
      () async {
        final folders = container.read(foldersProvider.notifier);
        final owner = folders.captureProjectOwner()!;
        api
          ..detail = answer(
            'p',
            data: {
              'model_ids': ['m-server'],
            },
          )
          ..detailGate = Completer<void>();

        final read = folders.refreshProjectData(owner, 'p');
        final outcome = expectLater(read, throwsA(ownerChanged));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        container.read(_epochProvider.notifier).rotate();
        api.detailGate!.complete();
        await outcome;

        check((await storedData()).containsKey('model_ids')).isFalse();
      },
    );
  });

  group('a saved file', () {
    test('is gone only when the server says it is not found', () async {
      final folders = container.read(foldersProvider.notifier);
      final owner = folders.captureProjectOwner()!;
      api.fileStatus
        ..['gone'] = 404
        ..['broken'] = 500
        ..['denied'] = 401;

      check(await folders.projectFileExists(owner, 'here')).equals(true);
      check(await folders.projectFileExists(owner, 'gone')).equals(false);
      // A failure says nothing about whether the file exists.
      check(await folders.projectFileExists(owner, 'broken')).isNull();
      check(await folders.projectFileExists(owner, 'denied')).isNull();
    });

    test('is not judged by an answer that outlives the account', () async {
      final folders = container.read(foldersProvider.notifier);
      final owner = folders.captureProjectOwner()!;
      api.fileStatus['gone'] = 404;
      api.fileGate = Completer<void>();

      final answer = folders.projectFileExists(owner, 'gone');
      container.read(_epochProvider.notifier).rotate();
      api.fileGate!.complete();

      check(await answer).isNull();
      // And a sheet that starts under the old account asks nothing at all.
      check(await folders.projectFileExists(owner, 'gone')).isNull();
    });
  });
}
