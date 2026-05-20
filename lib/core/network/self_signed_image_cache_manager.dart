import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import 'self_signed_image_cache_manager_factory.dart'
    if (dart.library.io) 'self_signed_image_cache_manager_factory_io.dart'
    as self_signed_image_cache_manager_factory;

/// Returns a CacheManager with server-scoped TLS overrides for the current
/// active server. Returns null when not needed.
///
/// Notes
/// - Scoped to the configured host and (optionally) port only.
/// - Not available on web (browsers enforce TLS validation).
final selfSignedImageCacheManagerProvider = Provider<BaseCacheManager?>((ref) {
  final active = ref.watch(activeServerProvider);

  return active.maybeWhen(
    data: (server) {
      if (server == null) return null;
      final cacheManager =
          self_signed_image_cache_manager_factory
              .buildSelfSignedImageCacheManager(server);
      if (cacheManager != null) {
        ref.onDispose(cacheManager.dispose);
      }
      return cacheManager;
    },
    orElse: () => null,
  );
});
