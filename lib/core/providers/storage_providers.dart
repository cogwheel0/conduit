import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../persistence/persistence_providers.dart';
import '../services/optimized_storage_service.dart';
import '../services/worker_manager.dart';

/// Provides a shared [FlutterSecureStorage] instance with platform-specific
/// configuration.
final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage(
    aOptions: AndroidOptions(
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
  return OptimizedStorageService(
    secureStorage: ref.watch(secureStorageProvider),
    boxes: ref.watch(hiveBoxesProvider),
    workerManager: ref.watch(workerManagerProvider),
    conversationStore: ref.watch(conversationStoreProvider),
  );
});
