import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image_ce/cached_network_image.dart'
    show BaseCacheManager;
// ignore: implementation_imports
import 'package:cached_network_image_ce/src/cache/default_cache_manager.dart'
    as cached_network_image_ce;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/io_client.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../models/server_config.dart';
import '../services/server_tls_http_client_factory.dart';

typedef SelfSignedImageCacheBaseDirectoryProvider = Future<Directory> Function();

@visibleForTesting
String? buildSelfSignedImageCacheNamespace(ServerConfig server) {
  if (!ServerTlsHttpClientFactory.requiresCustomHttpClient(server)) {
    return null;
  }

  final uri = ServerTlsHttpClientFactory.parseBaseUri(server.url);
  if (uri == null) {
    return null;
  }

  final tlsMode = server.hasMutualTlsCredentials ? 'mtls' : 'selfsigned';
  final host = uri.host.toLowerCase();
  final port = uri.hasPort ? uri.port : 0;
  return 'conduit-$tlsMode-$host:$port';
}

@visibleForTesting
String buildSelfSignedImageCacheDirectoryName(String namespace) {
  final digest = sha256.convert(utf8.encode(namespace)).toString();
  return 'conduit-image-cache-$digest';
}

BaseCacheManager? buildSelfSignedImageCacheManager(
  ServerConfig server, {
  SelfSignedImageCacheBaseDirectoryProvider? cacheDirectoryProvider,
}) {
  final namespace = buildSelfSignedImageCacheNamespace(server);
  if (namespace == null) {
    return null;
  }

  final baseDirectoryProvider = cacheDirectoryProvider ?? getTemporaryDirectory;
  final cacheDirectoryName = buildSelfSignedImageCacheDirectoryName(namespace);

  return cached_network_image_ce.DefaultCacheManager(
    httpClientFactory: () =>
        IOClient(ServerTlsHttpClientFactory.createHttpClient(server)),
    cacheDirectoryProvider: () async {
      final baseDirectory = await baseDirectoryProvider();
      return Directory(path.join(baseDirectory.path, cacheDirectoryName));
    },
  );
}
