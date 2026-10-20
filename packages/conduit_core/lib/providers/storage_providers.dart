import 'dart:async';

import 'package:riverpod/riverpod.dart';
import 'package:conduit_core/conduit_core.dart';

import 'package:conduit_core/database/database_manager.dart';

import 'package:conduit_core/database/database_provider.dart';

import 'package:conduit_core/persistence/persistence_providers.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';

import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Credential-grade storage for this host.
///
/// `main.dart` binds `FlutterSecureKeyValueStore` behind a readiness gate,
/// and the `conduitd` sidecar binds its own AES-GCM file store.
///
/// The default is in-memory rather than a throw. That is genuinely what a
/// host without a keychain has, and it is also what tests already got:
/// `flutter_secure_storage`'s own platform-channel mock made the previous
/// default an empty in-memory store. Throwing would break several hundred
/// tests to guard against a binding that production always supplies — so
/// instead the omission is logged, loudly, once.
final secureStorageProvider = Provider<SecureKeyValueStore>((ref) {
  DebugLogger.warning(
    'secure-storage-unbound',
    scope: 'storage/secure',
    data: const <String, Object?>{
      'detail':
          'No host SecureKeyValueStore was bound; credentials will not '
          'survive a restart. main.dart binds FlutterSecureKeyValueStore.',
    },
  );
  return InMemorySecureKeyValueStore();
});

/// Optimized storage service backed by Hive plus secure storage.
final optimizedStorageServiceProvider = Provider<OptimizedStorageService>((
  ref,
) {
  final databaseManager = ref.watch(databaseManagerProvider);
  FutureOr<OptimizedStorageDatabaseHandle?> resolveDatabaseAccessForServer(
    String serverId,
  ) {
    if (!ref.mounted) return null;
    // Keep these reads inside the resolver deliberately. Every Drift cache
    // operation invokes this callback, so it observes the latest isolation
    // gates without rebuilding this stateful service (and replacing its auth
    // lock and in-memory caches) during an account transition.
    final access = ref.read(openWebUiDatabaseAccessProvider);
    if (!access.allowsStorageDatabase) return null;
    final currentServerId = PreferencesStore.getString(
      PreferenceKeys.activeServerId,
    );
    if (currentServerId != serverId) {
      return null;
    }
    if (access == OpenWebUiDatabaseAccessPhase.open &&
        ref.read(openWebUiCertifiedDatabaseServerProvider) != serverId) {
      return null;
    }
    return switch (databaseManager.openForServerIdIfReady(serverId)) {
      DatabaseOpenReady(:final database) => () {
        final lease = databaseManager.tryAcquireLease(database);
        if (lease == null) return null;
        return OptimizedStorageDatabaseHandle(
          database: database,
          onRelease: lease.release,
        );
      }(),
      DatabaseOpenDeferred(:final retryAfter) =>
        retryAfter.then<OptimizedStorageDatabaseHandle?>(
          (_) => resolveDatabaseAccessForServer(serverId),
          onError: (Object _, StackTrace _) =>
              resolveDatabaseAccessForServer(serverId),
        ),
    };
  }

  FutureOr<OptimizedStorageDatabaseHandle?> resolveDatabaseAccess() {
    final serverId = PreferencesStore.getString(PreferenceKeys.activeServerId);
    if (serverId == null || serverId.isEmpty) return null;
    // Capture ownership before any deferred wait. Retrying through the
    // top-level resolver would adopt a newly-selected server and could apply
    // an A mutation to B after A's close settles.
    return resolveDatabaseAccessForServer(serverId);
  }

  return OptimizedStorageService(
    secureStorage: ref.watch(secureStorageProvider),
    boxes: ref.watch(hiveBoxesProvider),
    workerManager: ref.watch(workerManagerProvider),
    // Resolve from the raw active-server preference instead of appDatabaseProvider.
    // appDatabaseProvider depends on activeServerProvider, which itself reads this
    // storage service; using it here re-enters Riverpod during active-server
    // construction and trips CircularDependencyError on cold start.
    // A deferred close is temporary, not an absent cache. Await it and resolve
    // the same captured owner again so writes cannot be silently discarded or
    // retargeted after a switch. The returned lifetime lease also spans the
    // Drift operation itself, closing the resolution-to-query race.
    databaseAccess: resolveDatabaseAccess,
  );
});
