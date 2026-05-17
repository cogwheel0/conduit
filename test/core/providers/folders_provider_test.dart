import 'dart:async';

import 'package:conduit/core/models/folder.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _flushMicrotasks([int count = 1]) async {
  for (var i = 0; i < count; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('Folders', () {
    test('warmIfNeeded reuses an in-flight provider load', () async {
      final api = _SequencedFoldersApiService();
      final storage = _FakeOptimizedStorageService();
      final container = _container(api: api, storage: storage);
      addTearDown(container.dispose);

      final initialLoad = container.read(foldersProvider.future);
      await _flushMicrotasks(2);

      final warmFuture = container
          .read(foldersProvider.notifier)
          .warmIfNeeded();
      await _flushMicrotasks();

      expect(api.getFoldersCalls, 1);

      api.completeFolders([
        {'id': 'folder-a', 'name': 'Folder A'},
      ]);

      final initialFolders = await initialLoad;
      await warmFuture;
      final current = container.read(foldersProvider).requireValue;

      expect(initialFolders.map((folder) => folder.id), ['folder-a']);
      expect(current.map((folder) => folder.id), ['folder-a']);
    });

    test('cache-backed folders stay untrusted until refresh settles', () async {
      final api = _SequencedFoldersApiService();
      final storage = _FakeOptimizedStorageService(
        localFolders: const [
          Folder(id: 'cached-folder', name: 'Cached Folder'),
        ],
      );
      final container = _container(
        api: api,
        storage: storage,
        authTokenOverride: authTokenProvider3.overrideWithValue('test-token'),
      );
      addTearDown(container.dispose);

      final initialFolders = await container.read(foldersProvider.future);
      expect(initialFolders.map((folder) => folder.id), ['cached-folder']);

      await _flushMicrotasks(2);
      expect(api.getFoldersCalls, 1);

      final notifier = container.read(foldersProvider.notifier);
      notifier.updateFolder(
        'cached-folder',
        (folder) => folder.copyWith(name: 'Renamed Folder'),
      );
      notifier.upsertFolder(const Folder(id: 'new-folder', name: 'New Folder'));
      notifier.removeFolder('cached-folder');

      expect(api.getFoldersCalls, 1);
      expect(
        container.read(foldersProvider).requireValue.map((folder) => folder.id),
        ['cached-folder'],
      );
      expect(storage.savedFolderSnapshots, isEmpty);

      api.completeFolders([
        {'id': 'fresh-folder', 'name': 'Fresh Folder'},
      ]);
      await _flushMicrotasks(2);

      final current = container.read(foldersProvider).requireValue;
      expect(current.map((folder) => folder.id), ['fresh-folder']);
      expect(storage.savedFolderSnapshots, isNotEmpty);
      expect(storage.savedFolderSnapshots.last, ['fresh-folder']);
    });

    test(
      'server-confirmed folder upserts force a fresh reconcile and ignore an older refresh',
      () async {
        final api = _SequencedFoldersApiService();
        final storage = _FakeOptimizedStorageService(
          localFolders: const [
            Folder(id: 'cached-folder', name: 'Cached Folder'),
          ],
        );
        final container = _container(
          api: api,
          storage: storage,
          authTokenOverride: authTokenProvider3.overrideWithValue('test-token'),
        );
        addTearDown(container.dispose);

        final initialFolders = await container.read(foldersProvider.future);
        expect(initialFolders.map((folder) => folder.id), ['cached-folder']);

        await _flushMicrotasks(2);
        expect(api.getFoldersCalls, 1);

        final notifier = container.read(foldersProvider.notifier);
        notifier.upsertFolderFromRemote(
          const Folder(id: 'new-folder', name: 'New Folder'),
        );
        await _flushMicrotasks();

        expect(
          container
              .read(foldersProvider)
              .requireValue
              .map((folder) => folder.id),
          ['cached-folder', 'new-folder'],
        );
        expect(api.getFoldersCalls, 2);
        expect(storage.savedFolderSnapshots, isEmpty);

        api.completeFolders([
          {'id': 'cached-folder', 'name': 'Cached Folder'},
        ]);
        await _flushMicrotasks(2);

        expect(
          container
              .read(foldersProvider)
              .requireValue
              .map((folder) => folder.id),
          ['cached-folder', 'new-folder'],
        );

        api.completeFolders([
          {'id': 'cached-folder', 'name': 'Cached Folder'},
          {'id': 'new-folder', 'name': 'New Folder'},
        ], index: 1);
        await _flushMicrotasks(2);

        final current = container.read(foldersProvider).requireValue;
        expect(current.map((folder) => folder.id), [
          'cached-folder',
          'new-folder',
        ]);
        expect(storage.savedFolderSnapshots, isNotEmpty);
        expect(storage.savedFolderSnapshots.last, [
          'cached-folder',
          'new-folder',
        ]);
      },
    );

    test('warmIfNeeded starts a new load after auth token changes', () async {
      final api = _SequencedFoldersApiService();
      final storage = _FakeOptimizedStorageService();
      var authToken = 'old-token';
      final container = _container(
        api: api,
        storage: storage,
        authTokenOverride: authTokenProvider3.overrideWith((ref) => authToken),
      );
      addTearDown(container.dispose);

      final initialLoad = container.read(foldersProvider.future);
      await _flushMicrotasks(2);

      authToken = 'new-token';
      container.invalidate(authTokenProvider3);
      final warmFuture = container
          .read(foldersProvider.notifier)
          .warmIfNeeded();
      await _flushMicrotasks();

      expect(api.getFoldersCalls, 2);
      expect(api.requestAuthTokens, ['old-token', 'new-token']);

      api.completeFolders([
        {'id': 'old-folder', 'name': 'Old Folder'},
      ]);
      await _flushMicrotasks();

      api.completeFolders([
        {'id': 'new-folder', 'name': 'New Folder'},
      ], index: 1);

      await initialLoad;
      await warmFuture;
      final current = container.read(foldersProvider).requireValue;

      expect(current.map((folder) => folder.id), ['new-folder']);
    });

    test(
      'warmIfNeeded ignores a stale initial load that completes after the fresh load',
      () async {
        final api = _SequencedFoldersApiService();
        final storage = _FakeOptimizedStorageService();
        var authToken = 'old-token';
        final container = _container(
          api: api,
          storage: storage,
          authTokenOverride: authTokenProvider3.overrideWith(
            (ref) => authToken,
          ),
        );
        addTearDown(container.dispose);

        final initialLoad = container.read(foldersProvider.future);
        await _flushMicrotasks(2);

        authToken = 'new-token';
        container.invalidate(authTokenProvider3);
        final warmFuture = container
            .read(foldersProvider.notifier)
            .warmIfNeeded();
        await _flushMicrotasks();

        expect(api.getFoldersCalls, 2);

        api.completeFolders([
          {'id': 'new-folder', 'name': 'New Folder'},
        ], index: 1);
        await warmFuture;

        api.completeFolders([
          {'id': 'old-folder', 'name': 'Old Folder'},
        ]);

        final initialFolders = await initialLoad;
        await _flushMicrotasks();
        final current = container.read(foldersProvider).requireValue;

        expect(initialFolders.map((folder) => folder.id), ['new-folder']);
        expect(current.map((folder) => folder.id), ['new-folder']);
        expect(storage.savedFolderSnapshots, isNotEmpty);
        expect(storage.savedFolderSnapshots.last, ['new-folder']);
      },
    );

    test(
      'an in-flight load is revalidated against the current api service before it lands',
      () async {
        final oldApi = _SequencedFoldersApiService(serverId: 'old-server');
        final newApi = _SequencedFoldersApiService(serverId: 'new-server');
        final storage = _FakeOptimizedStorageService();
        ApiService currentApi = oldApi;
        final container = _container(
          storage: storage,
          apiOverride: apiServiceProvider.overrideWith((ref) => currentApi),
          authTokenOverride: authTokenProvider3.overrideWithValue('test-token'),
        );
        addTearDown(container.dispose);
        final subscription = container.listen<AsyncValue<List<Folder>>>(
          foldersProvider,
          (previous, next) {},
        );
        addTearDown(subscription.close);

        container.read(foldersProvider.future);
        await _flushMicrotasks(2);

        currentApi = newApi;
        container.invalidate(apiServiceProvider);

        oldApi.completeFolders([
          {'id': 'old-folder', 'name': 'Old Folder'},
        ]);
        await _flushMicrotasks(2);

        expect(newApi.getFoldersCalls, 1);

        newApi.completeFolders([
          {'id': 'new-folder', 'name': 'New Folder'},
        ]);

        final current = await container.read(foldersProvider.future);

        expect(current.map((folder) => folder.id), ['new-folder']);
        expect(storage.savedFolderSnapshots, isNotEmpty);
        expect(storage.savedFolderSnapshots.last, ['new-folder']);
      },
    );

    test(
      'warmIfNeeded refreshes settled folders after auth token changes',
      () async {
        final api = _SequencedFoldersApiService();
        final storage = _FakeOptimizedStorageService();
        var authToken = 'old-token';
        final container = _container(
          api: api,
          storage: storage,
          authTokenOverride: authTokenProvider3.overrideWith(
            (ref) => authToken,
          ),
        );
        addTearDown(container.dispose);

        final initialLoad = container.read(foldersProvider.future);
        await _flushMicrotasks(2);

        api.completeFolders([
          {'id': 'old-folder', 'name': 'Old Folder'},
        ]);

        final initialFolders = await initialLoad;
        expect(initialFolders.map((folder) => folder.id), ['old-folder']);

        authToken = 'new-token';
        container.invalidate(authTokenProvider3);
        final warmFuture = container
            .read(foldersProvider.notifier)
            .warmIfNeeded();
        await _flushMicrotasks();

        expect(api.getFoldersCalls, 2);

        api.completeFolders([
          {'id': 'new-folder', 'name': 'New Folder'},
        ], index: 1);

        await warmFuture;
        final current = container.read(foldersProvider).requireValue;

        expect(current.map((folder) => folder.id), ['new-folder']);
      },
    );

    test(
      'folder mutations refresh instead of merging stale state after auth token changes',
      () async {
        final api = _SequencedFoldersApiService();
        final storage = _FakeOptimizedStorageService();
        var authToken = 'old-token';
        final container = _container(
          api: api,
          storage: storage,
          authTokenOverride: authTokenProvider3.overrideWith(
            (ref) => authToken,
          ),
        );
        addTearDown(container.dispose);

        final initialLoad = container.read(foldersProvider.future);
        await _flushMicrotasks(2);

        api.completeFolders([
          {'id': 'old-folder', 'name': 'Old Folder'},
        ]);

        final initialFolders = await initialLoad;
        expect(initialFolders.map((folder) => folder.id), ['old-folder']);

        authToken = 'new-token';
        container.invalidate(authTokenProvider3);
        container
            .read(foldersProvider.notifier)
            .upsertFolder(
              const Folder(id: 'optimistic-folder', name: 'Optimistic Folder'),
            );
        await _flushMicrotasks();

        expect(api.getFoldersCalls, 2);
        expect(
          container
              .read(foldersProvider)
              .requireValue
              .map((folder) => folder.id),
          ['old-folder'],
        );

        api.completeFolders([
          {'id': 'new-folder', 'name': 'New Folder'},
        ], index: 1);
        await _flushMicrotasks(2);

        final current = container.read(foldersProvider).requireValue;
        expect(current.map((folder) => folder.id), ['new-folder']);
      },
    );

    test(
      'stale folder refresh clears untrusted state when the new-scope load fails',
      () async {
        final api = _SequencedFoldersApiService();
        final storage = _FakeOptimizedStorageService(
          localFolders: const [
            Folder(id: 'cached-folder', name: 'Cached Folder'),
          ],
        );
        var authToken = 'old-token';
        final container = _container(
          api: api,
          storage: storage,
          authTokenOverride: authTokenProvider3.overrideWith(
            (ref) => authToken,
          ),
        );
        addTearDown(container.dispose);

        final initialFolders = await container.read(foldersProvider.future);
        expect(initialFolders.map((folder) => folder.id), ['cached-folder']);

        await _flushMicrotasks(2);
        expect(api.getFoldersCalls, 1);

        authToken = 'new-token';
        container.invalidate(authTokenProvider3);
        final warmFuture = container
            .read(foldersProvider.notifier)
            .warmIfNeeded();
        await _flushMicrotasks();

        expect(api.getFoldersCalls, 2);

        api.failFolders(Exception('folder warmup failed'), index: 1);
        await expectLater(warmFuture, throwsA(isA<Exception>()));

        api.completeFolders([
          {'id': 'stale-folder', 'name': 'Stale Folder'},
        ]);
        await _flushMicrotasks();
        expect(api.getFoldersCalls, 3);

        api.failFolders(Exception('retry failed'), index: 2);
        await _flushMicrotasks(2);

        final current = container.read(foldersProvider).requireValue;
        expect(current, isEmpty);
      },
    );

    test(
      'refresh clears trusted folders when a new-scope load fails',
      () async {
        final api = _SequencedFoldersApiService();
        final storage = _FakeOptimizedStorageService();
        var authToken = 'old-token';
        final container = _container(
          api: api,
          storage: storage,
          authTokenOverride: authTokenProvider3.overrideWith(
            (ref) => authToken,
          ),
        );
        addTearDown(container.dispose);

        final initialLoad = container.read(foldersProvider.future);
        await _flushMicrotasks(2);

        api.completeFolders([
          {'id': 'old-folder', 'name': 'Old Folder'},
        ]);

        final initialFolders = await initialLoad;
        expect(initialFolders.map((folder) => folder.id), ['old-folder']);

        authToken = 'new-token';
        container.invalidate(authTokenProvider3);
        final refreshFuture = container
            .read(foldersProvider.notifier)
            .refresh();
        await _flushMicrotasks();

        expect(api.getFoldersCalls, 2);
        expect(api.requestAuthTokens, ['old-token', 'new-token']);

        api.failFolders(Exception('new-scope refresh failed'), index: 1);

        await refreshFuture;
        await _flushMicrotasks();

        final current = container.read(foldersProvider).requireValue;
        expect(current, isEmpty);
      },
    );

    test(
      'a stale refresh failure does not clear newer folders from a new auth scope',
      () async {
        final api = _SequencedFoldersApiService();
        final storage = _FakeOptimizedStorageService();
        var authToken = 'old-token';
        final container = _container(
          api: api,
          storage: storage,
          authTokenOverride: authTokenProvider3.overrideWith(
            (ref) => authToken,
          ),
        );
        addTearDown(container.dispose);

        final initialLoad = container.read(foldersProvider.future);
        await _flushMicrotasks(2);

        api.completeFolders([
          {'id': 'old-folder', 'name': 'Old Folder'},
        ]);

        final initialFolders = await initialLoad;
        expect(initialFolders.map((folder) => folder.id), ['old-folder']);

        final notifier = container.read(foldersProvider.notifier);
        final staleRefresh = notifier.refresh();
        await _flushMicrotasks();

        authToken = 'new-token';
        container.invalidate(authTokenProvider3);
        final freshRefresh = notifier.refresh();
        await _flushMicrotasks();

        expect(api.getFoldersCalls, 3);
        expect(api.requestAuthTokens, ['old-token', 'old-token', 'new-token']);

        api.completeFolders([
          {'id': 'new-folder', 'name': 'New Folder'},
        ], index: 2);

        await freshRefresh;
        await _flushMicrotasks();
        expect(
          container
              .read(foldersProvider)
              .requireValue
              .map((folder) => folder.id),
          ['new-folder'],
        );

        api.failFolders(Exception('stale refresh failed'), index: 1);

        await staleRefresh;
        await _flushMicrotasks();
        final current = container.read(foldersProvider).requireValue;
        expect(current.map((folder) => folder.id), ['new-folder']);
      },
    );

    test(
      'refresh reusing an in-flight same-scope load preserves current state on failure',
      () async {
        final api = _SequencedFoldersApiService();
        final storage = _FakeOptimizedStorageService();
        final container = _container(
          api: api,
          storage: storage,
          authTokenOverride: authTokenProvider3.overrideWithValue('test-token'),
        );
        addTearDown(container.dispose);

        final initialLoad = container.read(foldersProvider.future);
        await _flushMicrotasks(2);
        expect(api.getFoldersCalls, 1);

        api.completeFolders([
          {'id': 'existing-folder', 'name': 'Existing Folder'},
        ]);
        final initialFolders = await initialLoad;
        expect(initialFolders.map((folder) => folder.id), ['existing-folder']);

        final notifier = container.read(foldersProvider.notifier);
        final primaryRefresh = notifier.refresh();
        await _flushMicrotasks();

        final reusedRefresh = notifier.refresh();
        await _flushMicrotasks();

        expect(api.getFoldersCalls, 2);

        api.failFolders(Exception('shared refresh failed'), index: 1);

        await primaryRefresh;
        await reusedRefresh;
        await _flushMicrotasks();

        final current = container.read(foldersProvider).requireValue;
        expect(current.map((folder) => folder.id), ['existing-folder']);
      },
    );

    test('warmIfNeeded surfaces fetch failures for startup retries', () async {
      final api = _ThrowingFoldersApiService();
      final storage = _FakeOptimizedStorageService();
      final container = _container(api: api, storage: storage);
      addTearDown(container.dispose);

      final notifier = container.read(foldersProvider.notifier);

      await expectLater(notifier.warmIfNeeded(), throwsA(isA<Exception>()));
      expect(api.getFoldersCalls, greaterThanOrEqualTo(1));
    });
  });
}

ProviderContainer _container({
  required OptimizedStorageService storage,
  ApiService? api,
  Override? apiOverride,
  Override? authTokenOverride,
}) {
  assert(api != null || apiOverride != null);
  return ProviderContainer(
    overrides: [
      isAuthenticatedProvider2.overrideWithValue(true),
      ?authTokenOverride,
      apiOverride ?? apiServiceProvider.overrideWithValue(api!),
      optimizedStorageServiceProvider.overrideWithValue(storage),
    ],
  );
}

class _SequencedFoldersApiService extends ApiService {
  _SequencedFoldersApiService({String serverId = 'test-server'})
    : super(
        serverConfig: ServerConfig(
          id: serverId,
          name: 'Test Server',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  int getFoldersCalls = 0;
  final requestAuthTokens = <String?>[];
  final _completers = <Completer<(List<Map<String, dynamic>>, bool)>>[];

  @override
  Future<(List<Map<String, dynamic>>, bool)> getFolders() {
    getFoldersCalls += 1;
    requestAuthTokens.add(authToken);
    final completer = Completer<(List<Map<String, dynamic>>, bool)>();
    _completers.add(completer);
    return completer.future;
  }

  void completeFolders(List<Map<String, dynamic>> folders, {int index = 0}) {
    _completers[index].complete((folders, true));
  }

  void failFolders(Object error, {int index = 0}) {
    _completers[index].completeError(error);
  }
}

class _FakeOptimizedStorageService extends Fake
    implements OptimizedStorageService {
  _FakeOptimizedStorageService({List<Folder> localFolders = const <Folder>[]})
    : _localFolders = List<Folder>.unmodifiable(localFolders);

  final List<Folder> _localFolders;
  final savedFolderSnapshots = <List<String>>[];

  @override
  Future<List<Folder>> getLocalFolders() async {
    await Future<void>.delayed(Duration.zero);
    return _localFolders;
  }

  @override
  Future<void> saveLocalFolders(List<Folder> folders) async {
    savedFolderSnapshots.add(folders.map((folder) => folder.id).toList());
  }
}

class _ThrowingFoldersApiService extends ApiService {
  _ThrowingFoldersApiService()
    : super(
        serverConfig: const ServerConfig(
          id: 'test-server',
          name: 'Test Server',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  int getFoldersCalls = 0;

  @override
  Future<(List<Map<String, dynamic>>, bool)> getFolders() async {
    getFoldersCalls += 1;
    throw Exception('folder warmup failed');
  }
}
