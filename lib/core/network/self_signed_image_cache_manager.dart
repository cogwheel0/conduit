import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/io_client.dart';

import '../models/server_config.dart';
import '../providers/app_providers.dart';

/// Returns a CacheManager that accepts a self-signed certificate for the
/// currently active server's host/port. Returns null when not needed.
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
  if (!server.allowSelfSignedCertificates) return null;

  final uri = _parseUri(server.url);
  if (uri == null) return null;

  // Configure a HttpClient that accepts only this host (+ optional port).
  final client = HttpClient();
  final host = uri.host.toLowerCase();
  final port = uri.hasPort ? uri.port : null;

  client.badCertificateCallback =
      (X509Certificate cert, String requestHost, int requestPort) {
        if (requestHost.toLowerCase() != host) return false;
        if (port == null) return true; // Any port on this host
        return requestPort == port; // Exact host+port only
      };

  final ioClient = IOClient(client);
  final fileService = HttpFileService(httpClient: ioClient);

  // Use a stable key per host/port to share cache across widgets.
  final key = 'qonduit-selfsigned-$host:${port ?? 0}';
  return CacheManager(Config(key, fileService: fileService));
}

Uri? _parseUri(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return null;
  Uri? parsed = Uri.tryParse(trimmed);
  if (parsed == null) return null;
  if (!parsed.hasScheme) {
    parsed =
        Uri.tryParse('https://$trimmed') ?? Uri.tryParse('http://$trimmed');
  }
  return parsed;
}
