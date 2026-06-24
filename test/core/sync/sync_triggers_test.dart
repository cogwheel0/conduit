/// CDT-RFC-001 §7.6 trigger-wiring tests: the once-only app-start gate, the
/// auth and connectivity edge triggers, the foreground/background lifecycle
/// observer with its periodic timer, and the offline skip inside the
/// periodic tick. The debounce/coalescing funnel itself is covered by
/// sync_engine_test.dart; here the engine is replaced with a recorder so
/// each trigger firing is observable directly.
library;

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/connectivity_service.dart';
import 'package:conduit/core/sync/pull_sync.dart';
import 'package:conduit/core/sync/sync_api_client.dart';
import 'package:conduit/core/sync/sync_engine.dart';
import 'package:conduit/core/sync/sync_triggers.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_open_webui_server.dart';
import '../../support/fake_sync_api_client.dart';

/// Externally mutable provider value, so `ref.listen`ers inside
/// [SyncTriggers] observe edges without recreating the notifier.
class _MutableValue<T> extends Notifier<T> {
  _MutableValue(this.initial);

  final T initial;

  @override
  T build() => initial;

  void set(T value) => state = value;
}

final _authProvider = NotifierProvider<_MutableValue<bool>, bool>(
  () => _MutableValue<bool>(false),
);
final _onlineProvider = NotifierProvider<_MutableValue<bool>, bool>(
  () => _MutableValue<bool>(true),
);
final _dbProvider = NotifierProvider<_MutableValue<AppDatabase?>, AppDatabase?>(
  () => _MutableValue<AppDatabase?>(null),
);
final _clientProvider =
    NotifierProvider<_MutableValue<SyncApiClient?>, SyncApiClient?>(
      () => _MutableValue<SyncApiClient?>(null),
    );

/// Replaces the real engine: records every trigger reason, runs no cycle.
/// Recreated (with the same shared list) whenever its watched dependencies
/// flap, exactly like the production engine.
class _RecordingSyncEngine extends SyncEngine {
  _RecordingSyncEngine(this.pulls, this.drains);

  final List<String> pulls;
  final List<String> drains;

  @override
  Future<PullResult?> requestPull({required String reason}) {
    pulls.add(reason);
    return Future.value(null);
  }

  @override
  Future<void> drainNow() async {
    drains.add('now');
  }

  @override
  Future<void> drainOutbox() async {
    drains.add('outbox');
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late FakeSyncApiClient client;
  late List<String> pulls;
  late List<String> drains;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    client = FakeSyncApiClient(FakeOpenWebUiServer());
    pulls = <String>[];
    drains = <String>[];
  });

  tearDown(() async {
    await db.close();
  });

  /// Keeps the redirected readiness providers materialized for the container's
  /// lifetime. Without an active subscriber, a provider overridden as
  /// `(ref) => ref.watch(_mutable)` is recomputed lazily and `ref.listen`ers
  /// inside [SyncTriggers] never observe the edge — whereas in production the
  /// UI watches auth/online and the conversation list watches the database, so
  /// those providers stay live. This mirrors that.
  void materializeReadiness(ProviderContainer container) {
    container.listen(isAuthenticatedProvider2, (_, _) {});
    container.listen(isOnlineProvider, (_, _) {});
    container.listen(appDatabaseProvider, (_, _) {});
    container.listen(syncApiClientProvider, (_, _) {});
  }

  ProviderContainer makeContainer({bool autoDispose = true}) {
    final container = ProviderContainer(
      overrides: [
        isAuthenticatedProvider2.overrideWith(
          (ref) => ref.watch(_authProvider),
        ),
        isOnlineProvider.overrideWith((ref) => ref.watch(_onlineProvider)),
        appDatabaseProvider.overrideWith((ref) => ref.watch(_dbProvider)),
        syncApiClientProvider.overrideWith((ref) => ref.watch(_clientProvider)),
        syncEngineProvider.overrideWith(
          () => _RecordingSyncEngine(pulls, drains),
        ),
      ],
    );
    if (autoDispose) {
      addTearDown(container.dispose);
    }
    materializeReadiness(container);
    return container;
  }

  Future<void> flushMicrotasks([int count = 3]) async {
    for (var i = 0; i < count; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  int countOf(String reason) => pulls.where((r) => r == reason).length;

  group('app-start gate', () {
    test('start fires exactly once when (auth, db, client) become ready and '
        'never again while dependencies flap', () async {
      final container = makeContainer();
      container.read(syncTriggersProvider);
      await flushMicrotasks();
      check(pulls).isEmpty();

      // Partial readiness never fires.
      container.read(_dbProvider.notifier).set(db);
      await flushMicrotasks();
      container.read(_clientProvider.notifier).set(client);
      await flushMicrotasks();
      check(countOf('start')).equals(0);

      // Final dependency arrives: one start (plus the auth edge trigger).
      container.read(_authProvider.notifier).set(true);
      await flushMicrotasks();
      check(countOf('start')).equals(1);
      check(countOf('auth')).equals(1);

      // Flap every dependency; the once-only gate must hold.
      container.read(_dbProvider.notifier).set(null);
      await flushMicrotasks();
      container.read(_dbProvider.notifier).set(db);
      await flushMicrotasks();
      container.read(_clientProvider.notifier).set(null);
      await flushMicrotasks();
      container.read(_clientProvider.notifier).set(client);
      await flushMicrotasks();
      container.read(_authProvider.notifier).set(false);
      await flushMicrotasks();
      container.read(_authProvider.notifier).set(true);
      await flushMicrotasks();

      check(countOf('start')).equals(1);
      // The auth false->true edge legitimately fired a second time.
      check(countOf('auth')).equals(2);
    });

    test(
      'start fires immediately when everything is ready at install',
      () async {
        final container = makeContainer();
        container.read(_authProvider.notifier).set(true);
        container.read(_dbProvider.notifier).set(db);
        container.read(_clientProvider.notifier).set(client);

        container.read(syncTriggersProvider);
        check(countOf('start')).equals(1);
        await flushMicrotasks();

        check(countOf('start')).equals(1);
      },
    );

    test('start pull is submitted before immediate disposal can skip it', () {
      final container = makeContainer(autoDispose: false);
      container.read(_authProvider.notifier).set(true);
      container.read(_dbProvider.notifier).set(db);
      container.read(_clientProvider.notifier).set(client);

      container.read(syncTriggersProvider);
      container.dispose();

      check(countOf('start')).equals(1);
    });

    test(
      'start fires again when the ready database/client pair changes',
      () async {
        final container = makeContainer();
        container.read(_authProvider.notifier).set(true);
        container.read(_dbProvider.notifier).set(db);
        container.read(_clientProvider.notifier).set(client);
        container.read(syncTriggersProvider);
        await flushMicrotasks();
        check(countOf('start')).equals(1);

        final db2 = AppDatabase(NativeDatabase.memory());
        addTearDown(db2.close);
        final client2 = FakeSyncApiClient(FakeOpenWebUiServer());

        container.read(_dbProvider.notifier).set(db2);
        container.read(_clientProvider.notifier).set(client2);
        await flushMicrotasks();

        check(countOf('start')).equals(2);

        // Re-emitting the same ready pair does not refire.
        container.read(_dbProvider.notifier).set(db2);
        container.read(_clientProvider.notifier).set(client2);
        await flushMicrotasks();
        check(countOf('start')).equals(2);
      },
    );
  });

  group('connectivity edge', () {
    test(
      'offline->online fires exactly one pull; going offline fires none',
      () async {
        final container = makeContainer();
        container.read(_authProvider.notifier).set(true);
        container.read(_dbProvider.notifier).set(db);
        container.read(_clientProvider.notifier).set(client);
        container.read(syncTriggersProvider);
        await flushMicrotasks();
        pulls.clear();

        container.read(_onlineProvider.notifier).set(false);
        await flushMicrotasks();
        check(countOf('online')).equals(0);

        container.read(_onlineProvider.notifier).set(true);
        await flushMicrotasks();
        check(countOf('online')).equals(1);
        check(pulls).deepEquals(['online']);
      },
    );
  });

  group('active conversation edge', () {
    test(
      'chat-open drain is submitted before immediate disposal can skip it',
      () {
        final container = makeContainer(autoDispose: false);
        container.read(_authProvider.notifier).set(true);
        container.read(_dbProvider.notifier).set(db);
        container.read(_clientProvider.notifier).set(client);
        container.read(syncTriggersProvider);
        pulls.clear();
        drains.clear();

        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-open'));
        container.dispose();

        check(drains).deepEquals(['outbox']);
      },
    );
  });

  group('lifecycle observer + periodic timer', () {
    test('resume fires a foreground pull and restarts the timer; pause '
        'cancels it; dispose removes the observer', () {
      fakeAsync((async) {
        final container = ProviderContainer(
          overrides: [
            isAuthenticatedProvider2.overrideWith(
              (ref) => ref.watch(_authProvider),
            ),
            isOnlineProvider.overrideWith((ref) => ref.watch(_onlineProvider)),
            appDatabaseProvider.overrideWith((ref) => ref.watch(_dbProvider)),
            syncApiClientProvider.overrideWith(
              (ref) => ref.watch(_clientProvider),
            ),
            syncEngineProvider.overrideWith(
              () => _RecordingSyncEngine(pulls, drains),
            ),
          ],
        );
        materializeReadiness(container);
        container.read(_authProvider.notifier).set(true);
        container.read(_dbProvider.notifier).set(db);
        container.read(_clientProvider.notifier).set(client);
        container.read(syncTriggersProvider);
        async.flushMicrotasks();
        pulls.clear();

        // The timer starts only after a foreground resume.
        async.elapse(kPeriodicPullInterval);
        check(countOf('periodic')).equals(0);

        // Resume: one foreground pull, timer restarted from zero.
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        async.flushMicrotasks();
        check(countOf('foreground')).equals(1);
        async.elapse(kPeriodicPullInterval);
        check(countOf('periodic')).equals(1);

        // Pause: the periodic timer must not survive backgrounding.
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        async.flushMicrotasks();
        async.elapse(kPeriodicPullInterval * 3);
        check(countOf('periodic')).equals(1);

        // Inactive and hidden are background-equivalent for periodic pulls.
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        async.flushMicrotasks();
        check(countOf('foreground')).equals(2);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        async.flushMicrotasks();
        async.elapse(kPeriodicPullInterval * 3);
        check(countOf('periodic')).equals(1);

        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        async.flushMicrotasks();
        check(countOf('foreground')).equals(3);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        async.flushMicrotasks();
        async.elapse(kPeriodicPullInterval * 3);
        check(countOf('periodic')).equals(1);

        // Resume restarts it.
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        async.flushMicrotasks();
        check(countOf('foreground')).equals(4);
        async.elapse(kPeriodicPullInterval);
        check(countOf('periodic')).equals(2);

        // Dispose: observer removed, timer cancelled — nothing fires again.
        container.dispose();
        async.flushMicrotasks();
        pulls.clear();
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        async.flushMicrotasks();
        async.elapse(kPeriodicPullInterval * 3);
        check(pulls).isEmpty();
      });
    });

    test('periodic tick is skipped while offline', () {
      fakeAsync((async) {
        final container = ProviderContainer(
          overrides: [
            isAuthenticatedProvider2.overrideWith(
              (ref) => ref.watch(_authProvider),
            ),
            isOnlineProvider.overrideWith((ref) => ref.watch(_onlineProvider)),
            appDatabaseProvider.overrideWith((ref) => ref.watch(_dbProvider)),
            syncApiClientProvider.overrideWith(
              (ref) => ref.watch(_clientProvider),
            ),
            syncEngineProvider.overrideWith(
              () => _RecordingSyncEngine(pulls, drains),
            ),
          ],
        );
        materializeReadiness(container);
        container.read(_authProvider.notifier).set(true);
        container.read(_dbProvider.notifier).set(db);
        container.read(_clientProvider.notifier).set(client);
        container.read(syncTriggersProvider);
        async.flushMicrotasks();
        container.read(_onlineProvider.notifier).set(false);
        // Riverpod delivers ref.listen edges via an event-loop task, not a
        // microtask; under fakeAsync that needs a timer flush, so elapse(zero)
        // rather than flushMicrotasks.
        async.elapse(Duration.zero);
        pulls.clear();
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        async.flushMicrotasks();
        pulls.clear();

        // Offline ticks are skipped entirely.
        async.elapse(kPeriodicPullInterval * 3);
        check(countOf('periodic')).equals(0);

        // Back online: the connectivity edge fires, and subsequent ticks run.
        container.read(_onlineProvider.notifier).set(true);
        async.elapse(Duration.zero);
        check(countOf('online')).equals(1);
        async.elapse(kPeriodicPullInterval);
        check(countOf('periodic')).equals(1);

        container.dispose();
      });
    });
  });
}

Conversation _conversation(String id) {
  final now = DateTime.fromMillisecondsSinceEpoch(1000);
  return Conversation(
    id: id,
    title: 'Title $id',
    createdAt: now,
    updatedAt: now,
  );
}
