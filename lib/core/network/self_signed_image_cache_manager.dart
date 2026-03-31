import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/io_client.dart';

import '../models/server_config.dart';
import '../providers/app_providers.dart';
import '../services/server_tls_http_client_factory.dart';

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
      return _buildForServer(server);
    },
    orElse: () => null,
  );
});

BaseCacheManager? _buildForServer(ServerConfig server) {
  if (kIsWeb) return null;
  if (!ServerTlsHttpClientFactory.requiresCustomHttpClient(server)) return null;

  final uri = ServerTlsHttpClientFactory.parseBaseUri(server.url);
  if (uri == null) return null;

  final client = ServerTlsHttpClientFactory.createHttpClient(server);
  final host = uri.host.toLowerCase();
  final port = uri.hasPort ? uri.port : null;

  final ioClient = IOClient(client);
  final fileService = HttpFileService(httpClient: ioClient);

  // Use a stable key per host/port to share cache across widgets.
  final tlsMode = server.hasMutualTlsCredentials ? 'mtls' : 'selfsigned';
  final key = 'conduit-$tlsMode-$host:${port ?? 0}';
  return CacheManager(Config(key, fileService: fileService));
}
