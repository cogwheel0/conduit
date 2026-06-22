import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
  return OptimizedStorageService(
    secureStorage: ref.watch(secureStorageProvider),
    boxes: ref.watch(hiveBoxesProvider),
    workerManager: ref.watch(workerManagerProvider),
    // Resolve from the raw active-server preference instead of appDatabaseProvider.
    // appDatabaseProvider depends on activeServerProvider, which itself reads this
    // storage service; using it here re-enters Riverpod during active-server
    // construction and trips CircularDependencyError on cold start.
    database: () {
      final serverId = PreferencesStore.getString(
        PreferenceKeys.activeServerId,
      );
      if (serverId == null || serverId.isEmpty) {
        return null;
      }
      return databaseManager.openForServerId(serverId);
    },
  );
});
