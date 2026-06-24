/// Folders provider tests on the Drift read substrate (CDT-RFC-001 Phase 1).
///
/// The provider renders `FoldersDao.watchFolders()`; server-confirmed
/// mutations land in memory and in the database in the same call. Refresh
/// and warm paths converge on the sync engine.
library;

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/models/folder.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/sync/pull_sync.dart';
import 'package:conduit/core/sync/sync_api_client.dart';
import 'package:conduit/core/sync/sync_engine.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_open_webui_server.dart';
import '../../support/fake_sync_api_client.dart';

class _RecordingSyncEngine extends SyncEngine {
  _RecordingSyncEngine(this.pulls);

  final List<String> pulls;

  @override
  Future<PullResult?> requestPull({required String reason}) {
    pulls.add(reason);
    return Future.value(null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  ProviderContainer makeContainer({
    bool authenticated = true,
    List<Override> extraOverrides = const <Override>[],
  }) {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        isAuthenticatedProvider2.overrideWithValue(authenticated),
        reviewerModeProvider.overrideWithValue(false),
        legacyConversationCachePurgerProvider.overrideWith(
          (ref) => () async {},
        ),
        ...extraOverrides,
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> waitFor(
    Future<bool> Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!await condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('waitFor timed out');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> seedFolderRow(String id, String name) {
    return db.foldersDao.upsertServerFolder(<String, dynamic>{
      'id': id,
      'name': name,
      'parent_id': null,
      'created_at': 100,
      'updated_at': 100,
    });
  }

  Future<List<FolderRow>> folderRows() => db.foldersDao.watchFolders().first;

  List<String> namesOf(List<Folder> folders) =>
      folders.map((folder) => folder.name).toList();

  group('Folders', () {
    test('unauthenticated build returns empty', () async {
      await seedFolderRow('f1', 'Work');
      final container = makeContainer(authenticated: false);

      check(await container.read(foldersProvider.future)).isEmpty();
    });

    test('renders folder rows sorted case-insensitively by name', () async {
      await seedFolderRow('f1', 'zeta');
      await seedFolderRow('f2', 'Alpha');
      await seedFolderRow('f3', 'beta');
      final container = makeContainer();

      final folders = await container.read(foldersProvider.future);

      check(namesOf(folders)).deepEquals(['Alpha', 'beta', 'zeta']);
    });

    test('later database writes stream into provider state', () async {
      await seedFolderRow('f1', 'Work');
      final container = makeContainer();
      await container.read(foldersProvider.future);

      await seedFolderRow('f2', 'Archive');

      await waitFor(() async {
        final state = container.read(foldersProvider);
        return (state.asData?.value ?? const <Folder>[]).length == 2;
      });
      check(
        namesOf(container.read(foldersProvider).requireValue),
      ).deepEquals(['Archive', 'Work']);
    });

    test(
      'upsertFolderFromRemote lands in memory and in the database',
      () async {
        final container = makeContainer();
        await container.read(foldersProvider.future);

        container
            .read(foldersProvider.notifier)
            .upsertFolderFromRemote(
              Folder(
                id: 'f-new',
                name: 'Fresh',
                createdAt: DateTime.fromMillisecondsSinceEpoch(100 * 1000),
                updatedAt: DateTime.fromMillisecondsSinceEpoch(100 * 1000),
              ),
            );

        // Synchronous in-memory upsert.
        check(
          namesOf(container.read(foldersProvider).requireValue),
        ).deepEquals(['Fresh']);

        // Row write lands and the next emission agrees (no flicker revert).
        await waitFor(() async {
          final rows = await folderRows();
          return rows.any((row) => row.name == 'Fresh');
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
        check(
          namesOf(container.read(foldersProvider).requireValue),
        ).deepEquals(['Fresh']);
      },
    );

    test(
      'updateFolderFromRemote renames in memory and in the database',
      () async {
        await seedFolderRow('f1', 'Work');
        final container = makeContainer();
        await container.read(foldersProvider.future);

        container
            .read(foldersProvider.notifier)
            .updateFolderFromRemote(
              'f1',
              (folder) => Folder(
                id: folder.id,
                name: 'Renamed',
                createdAt: folder.createdAt,
                updatedAt: folder.updatedAt,
              ),
            );

        check(
          namesOf(container.read(foldersProvider).requireValue),
        ).deepEquals(['Renamed']);

        await waitFor(() async {
          final rows = await folderRows();
          return rows.any((row) => row.name == 'Renamed');
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
        check(
          namesOf(container.read(foldersProvider).requireValue),
        ).deepEquals(['Renamed']);
      },
    );

    test(
      'updateFolderFromRemote persists while provider state is cold',
      () async {
        await seedFolderRow('f1', 'Work');
        final container = makeContainer();

        container
            .read(foldersProvider.notifier)
            .updateFolderFromRemote(
              'f1',
              (folder) => folder.copyWith(name: 'Renamed'),
            );

        await waitFor(() async {
          final rows = await folderRows();
          return rows.any((row) => row.name == 'Renamed');
        });
      },
    );

    test(
      'missing remote folder update submits reconcile pull immediately',
      () async {
        final pulls = <String>[];
        final container = makeContainer(
          extraOverrides: [
            syncEngineProvider.overrideWith(() => _RecordingSyncEngine(pulls)),
          ],
        );
        await container.read(foldersProvider.future);

        container
            .read(foldersProvider.notifier)
            .updateFolderFromRemote(
              'missing-folder',
              (_) => throw StateError('unexpected transform'),
            );

        check(pulls).deepEquals(['folders-reconcile']);
      },
    );

    test('removeFolderFromRemote hard-deletes the row', () async {
      await seedFolderRow('f1', 'Work');
      await seedFolderRow('f2', 'Play');
      final container = makeContainer();
      await container.read(foldersProvider.future);

      container.read(foldersProvider.notifier).removeFolderFromRemote('f1');

      check(
        namesOf(container.read(foldersProvider).requireValue),
      ).deepEquals(['Play']);

      await waitFor(() async {
        final rows = await folderRows();
        return rows.every((row) => row.id != 'f1');
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      check(
        namesOf(container.read(foldersProvider).requireValue),
      ).deepEquals(['Play']);
    });

    test('warmIfNeeded and refresh converge on the sync engine pull', () async {
      final server = FakeOpenWebUiServer();
      final client = FakeSyncApiClient(server);
      server.seedFolder('f-remote');
      final container = makeContainer(
        extraOverrides: [syncApiClientProvider.overrideWith((ref) => client)],
      );
      await container.read(foldersProvider.future);

      await container.read(foldersProvider.notifier).warmIfNeeded();

      check(client.foldersRequests).isGreaterOrEqual(1);
      await waitFor(() async {
        final state = container.read(foldersProvider);
        return (state.asData?.value ?? const <Folder>[]).any(
          (folder) => folder.id == 'f-remote',
        );
      });

      final requestsBefore = client.foldersRequests;
      await container.read(foldersProvider.notifier).refresh(forceFresh: true);
      check(client.foldersRequests).isGreaterOrEqual(requestsBefore + 1);
    });

    test(
      'a pull reporting folders 403 disables foldersFeatureEnabledProvider',
      () async {
        final server = FakeOpenWebUiServer();
        final client = FakeSyncApiClient(server)..foldersFeatureEnabled = false;
        final container = makeContainer(
          extraOverrides: [syncApiClientProvider.overrideWith((ref) => client)],
        );
        check(container.read(foldersFeatureEnabledProvider)).isTrue();

        await container
            .read(syncEngineProvider.notifier)
            .requestPull(reason: 'test');

        check(container.read(foldersFeatureEnabledProvider)).isFalse();
      },
    );
  });
}
