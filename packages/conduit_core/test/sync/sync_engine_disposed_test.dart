import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/sync_meta_dao.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/sync/sync_api_client.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/testing.dart';
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// Holds the first read of the pull watermark after a pull has written it:
/// the read a finished cycle makes for its status.
final class _HeldSyncMetaDao extends SyncMetaDao {
  _HeldSyncMetaDao(super.db);

  bool _written = false;
  final Completer<void> asked = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<void> setPullWatermark(int epochSeconds) {
    _written = true;
    return super.setPullWatermark(epochSeconds);
  }

  @override
  Future<int> getPullWatermark() async {
    if (_written && !asked.isCompleted) {
      asked.complete();
      await release.future;
    }
    return super.getPullWatermark();
  }
}

final class _HeldWatermarkDatabase extends AppDatabase {
  _HeldWatermarkDatabase() : super(NativeDatabase.memory());

  late final _HeldSyncMetaDao _syncMetaDao = _HeldSyncMetaDao(this);

  @override
  _HeldSyncMetaDao get syncMetaDao => _syncMetaDao;
}

void main() {
  test('a cycle whose engine is disposed while it reads its status '
      'watermark writes no status and lets no error escape', () {
    final errors = <Object>[];
    final db = _HeldWatermarkDatabase();
    fakeAsync((async) {
      runZonedGuarded(() {
        final server = FakeOpenWebUiServer()
          ..seedChat(
            id: 'chat-1',
            blob: const <String, dynamic>{'title': 'Kettle'},
            createdAt: 100,
            updatedAt: 150,
          );
        final container = ProviderContainer(
          overrides: [
            ...openWebUiStorageOpenOverrides(database: db),
            isAuthenticatedProvider2.overrideWithValue(true),
            reviewerModeProvider.overrideWithValue(false),
            currentUserProvider2.overrideWithValue(
              const User(
                id: FakeOpenWebUiServer.userId,
                username: 'ada',
                email: 'ada@example.com',
                role: 'user',
              ),
            ),
            socketServiceProvider.overrideWithValue(null),
            syncApiClientProvider.overrideWith(
              (ref) => FakeSyncApiClient(server),
            ),
            legacyConversationCachePurgerProvider.overrideWith(
              (ref) => () async {},
            ),
          ],
        );
        container.listen(syncEngineProvider, (_, _) {});
        var answered = false;
        unawaited(
          container
              .read(syncEngineProvider.notifier)
              .requestPull(reason: 'test')
              .then((_) => answered = true),
        );
        async.elapse(kSyncPullDebounce);
        check(db.syncMetaDao.asked.isCompleted).isTrue();

        container.dispose();
        db.syncMetaDao.release.complete();
        async.flushMicrotasks();

        check(answered).isTrue();
      }, (error, _) => errors.add(error));
      async.flushMicrotasks();
    });
    addTearDown(db.close);

    check(errors).isEmpty();
  });
}
