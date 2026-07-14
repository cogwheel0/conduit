import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../database/database_manager.dart';
import '../database/database_provider.dart';
import '../persistence/persistence_providers.dart';
import '../persistence/persistence_keys.dart';
import '../persistence/preferences_store.dart';
import '../services/optimized_storage_service.dart';
import '../services/worker_manager.dart';

/// Provides a shared [FlutterSecureStorage] instance with platform-specific
/// configuration.
final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage(
    aOptions: AndroidOptions(
      // Keep legacy Android storage readable until a storageNamespace migration
      // can move both encrypted data and wrapped keys.
      // ignore: deprecated_member_use
      sharedPreferencesName: 'conduit_secure_prefs',
      preferencesKeyPrefix: 'conduit_',
      // Avoid auto-wipe on transient errors; handled at call sites instead.
      resetOnError: false,
    ),
    iOptions: IOSOptions(
      accountName: 'conduit_secure_storage',
      synchronizable: false,
    ),
  );
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
