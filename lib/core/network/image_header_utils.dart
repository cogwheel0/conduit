import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/core/network/conduit_user_agent.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';

int _unownedImageCacheKeyNonce = 0;
final String _unownedImageCacheProcessSalt = _newProcessCacheSalt();
final Expando<String> _imageCacheOwnerNonces = Expando<String>(
  'conduit-image-cache-owner',
);

String _newProcessCacheSalt() {
  final random = Random.secure();
  return base64UrlEncode(
    List<int>.generate(16, (_) => random.nextInt(256), growable: false),
  );
}

String _imageCacheOwnerNonce(Object owner) {
  return _imageCacheOwnerNonces[owner] ??= _newProcessCacheSalt();
}

/// Builds HTTP headers for protected image requests.
///
/// Includes Authorization (Bearer token or API key), the Conduit User-Agent,
/// and any server-configured custom headers. Returns `null` without an API.
Map<String, String>? buildImageHeadersForUrlFromWidgetRef(
  WidgetRef ref,
  String url,
) {
  try {
    final api = ref.watch(apiServiceProvider);
    if (api == null || !imageUrlIsServerOrigin(api.serverConfig.url, url)) {
      return null;
    }
    final token = ref.watch(authTokenProvider3);
    return _build(api, token);
  } catch (_) {
    // Image authentication is optional enrichment. If the surrounding app
    // owner is unavailable (for example during teardown/bootstrap), fail
    // closed without making an otherwise public image row unbuildable.
    return null;
  }
}

Map<String, String>? readImageHeadersForUrlFromWidgetRef(
  WidgetRef ref,
  String url,
) {
  try {
    final api = ref.read(apiServiceProvider);
    if (api == null || !imageUrlIsServerOrigin(api.serverConfig.url, url)) {
      return null;
    }
    final token = ref.read(authTokenProvider3);
    return _build(api, token);
  } catch (_) {
    return null;
  }
}

/// Returns an opaque cache key for an authenticated server-origin image.
///
/// The default network-image cache keys only by URL. Open WebUI file URLs can
/// be identical across accounts, so URL-only memory/disk entries can expose a
/// previous account's bytes. API and auth-epoch objects receive opaque random
/// ownership nonces. Unlike `identityHashCode`, these do not collide through
/// hash truncation or deterministically reuse a persistent disk key after an
/// app restart. Hashing also keeps signed URLs out of cache metadata.
/// Cross-origin/public images retain the package's normal URL key.
String? buildSessionScopedImageCacheKey({
  required ApiService? api,
  required Object authSessionEpoch,
  required String url,
  Map<String, String>? effectiveHeaders,
}) {
  if (api == null) {
    return _buildFailClosedImageCacheKey(url);
  }
  if (!imageUrlIsServerOrigin(api.serverConfig.url, url)) {
    return null;
  }
  final digest = sha256.convert(
    utf8.encode(
      'conduit-auth-image-v2\u0000$url\u0000'
      '${_imageCacheOwnerNonce(api)}\u0000'
      '${_imageCacheOwnerNonce(authSessionEpoch)}\u0000'
      '${_stableImageHeaderDigest(effectiveHeaders)}',
    ),
  );
  return 'conduit-auth-image-$digest';
}

String? buildImageCacheKeyForUrlFromWidgetRef(
  WidgetRef ref,
  String url, {
  Map<String, String>? effectiveHeaders,
}) {
  try {
    final api = ref.watch(apiServiceProvider);
    if (api == null) {
      return _buildFailClosedImageCacheKey(url);
    }
    if (!imageUrlIsServerOrigin(api.serverConfig.url, url)) {
      if (effectiveHeaders == null || effectiveHeaders.isEmpty) return null;
      return _buildExplicitHeaderImageCacheKey(
        api: api,
        authSessionEpoch: ref.watch(openWebUiAuthSessionEpochProvider),
        url: url,
        effectiveHeaders: effectiveHeaders,
      );
    }
    return buildSessionScopedImageCacheKey(
      api: api,
      authSessionEpoch: ref.watch(openWebUiAuthSessionEpochProvider),
      url: url,
      effectiveHeaders:
          effectiveHeaders ?? _build(api, ref.watch(authTokenProvider3)),
    );
  } catch (_) {
    return _buildFailClosedImageCacheKey(url);
  }
}

String? buildImageCacheKeyForUrlFromContainer(
  ProviderContainer container,
  String url, {
  Map<String, String>? effectiveHeaders,
}) {
  try {
    final api = container.read(apiServiceProvider);
    if (api == null) {
      return _buildFailClosedImageCacheKey(url);
    }
    if (!imageUrlIsServerOrigin(api.serverConfig.url, url)) {
      if (effectiveHeaders == null || effectiveHeaders.isEmpty) return null;
      return _buildExplicitHeaderImageCacheKey(
        api: api,
        authSessionEpoch: container.read(openWebUiAuthSessionEpochProvider),
        url: url,
        effectiveHeaders: effectiveHeaders,
      );
    }
    return buildSessionScopedImageCacheKey(
      api: api,
      authSessionEpoch: container.read(openWebUiAuthSessionEpochProvider),
      url: url,
      effectiveHeaders:
          effectiveHeaders ?? _build(api, container.read(authTokenProvider3)),
    );
  } catch (_) {
    return _buildFailClosedImageCacheKey(url);
  }
}

String _buildExplicitHeaderImageCacheKey({
  required ApiService api,
  required Object authSessionEpoch,
  required String url,
  required Map<String, String> effectiveHeaders,
}) {
  final digest = sha256.convert(
    utf8.encode(
      'conduit-header-image-v1\u0000$url\u0000'
      '${_imageCacheOwnerNonce(api)}\u0000'
      '${_imageCacheOwnerNonce(authSessionEpoch)}\u0000'
      '${_stableImageHeaderDigest(effectiveHeaders)}',
    ),
  );
  return 'conduit-header-image-$digest';
}

/// Returns a deterministic, privacy-safe identity for the exact headers that
/// affect an image response. Header names are case-insensitive and map order is
/// irrelevant; raw bearer, cookie, and tenant values never enter cache keys.
String _stableImageHeaderDigest(Map<String, String>? headers) {
  if (headers == null || headers.isEmpty) {
    return sha256.convert(const <int>[]).toString();
  }
  final entries =
      headers.entries
          .map((entry) => (name: entry.key.toLowerCase(), value: entry.value))
          .toList(growable: false)
        ..sort((left, right) {
          final byName = left.name.compareTo(right.name);
          return byName != 0 ? byName : left.value.compareTo(right.value);
        });
  final canonical = StringBuffer();
  for (final entry in entries) {
    canonical
      ..write(entry.name.length)
      ..write(':')
      ..write(entry.name)
      ..write(entry.value.length)
      ..write(':')
      ..write(entry.value);
  }
  return sha256.convert(utf8.encode(canonical.toString())).toString();
}

String _buildFailClosedImageCacheKey(String url) {
  // A null cacheKey makes CachedNetworkImage silently fall back to the raw
  // URL. If ownership resolution is unavailable, use a one-shot opaque key so
  // protected bytes can neither read nor populate a URL-shared cache entry.
  // The exceptional path intentionally forgoes cache reuse rather than risking
  // account crossover; a random process salt also prevents persistent disk-key
  // reuse after an app restart. Normal resolution remains stable per auth epoch.
  final nonce = _unownedImageCacheKeyNonce++;
  final digest = sha256.convert(
    utf8.encode(
      'conduit-unowned-image-v1\u0000$url\u0000'
      '$_unownedImageCacheProcessSalt\u0000$nonce',
    ),
  );
  return 'conduit-unowned-image-$digest';
}

bool imageUrlIsServerOrigin(String? serverBaseUrl, String imageUrl) {
  if (serverBaseUrl == null || serverBaseUrl.isEmpty) return false;
  final serverUri = Uri.tryParse(serverBaseUrl.trim());
  if (serverUri == null || !_isHttpScheme(serverUri.scheme)) return false;
  if (serverUri.host.isEmpty) return false;

  final imageUri = Uri.tryParse(imageUrl.trim());
  if (imageUri == null) return false;
  if (!imageUri.hasScheme && imageUri.host.isEmpty) return true;

  final imageScheme = imageUri.scheme.isEmpty
      ? serverUri.scheme.toLowerCase()
      : imageUri.scheme.toLowerCase();
  if (!_isHttpScheme(imageScheme)) return false;

  return imageScheme == serverUri.scheme.toLowerCase() &&
      imageUri.host.toLowerCase() == serverUri.host.toLowerCase() &&
      _effectivePort(imageUri, imageScheme) ==
          _effectivePort(serverUri, serverUri.scheme.toLowerCase());
}

bool _isHttpScheme(String scheme) {
  final lower = scheme.toLowerCase();
  return lower == 'http' || lower == 'https';
}

int? _effectivePort(Uri uri, String scheme) {
  if (uri.hasPort) return uri.port;
  return switch (scheme) {
    'http' => 80,
    'https' => 443,
    _ => null,
  };
}

Map<String, String>? buildImageHeadersForUrlFromContainer(
  ProviderContainer container,
  String url,
) {
  try {
    final api = container.read(apiServiceProvider);
    if (api == null || !imageUrlIsServerOrigin(api.serverConfig.url, url)) {
      return null;
    }
    final token = container.read(authTokenProvider3);
    return _build(api, token);
  } catch (_) {
    return null;
  }
}

Map<String, String> _build(ApiService api, String? token) {
  final headers = <String, String>{};

  if (token != null && token.isNotEmpty) {
    headers['Authorization'] = 'Bearer $token';
  }

  final customHeaders = api.serverConfig.customHeaders;
  if (customHeaders.isNotEmpty) {
    for (final entry in customHeaders.entries) {
      // Persisted legacy configs may predate reserved-header validation.
      // Never let alternate casing replace or supplement the live session's
      // bearer for an authenticated image request.
      final normalizedName = entry.key.toLowerCase();
      if (normalizedName == 'authorization' ||
          (normalizedName == 'cookie' && api.cookieCustomHeaderSuppressed)) {
        continue;
      }
      headers[entry.key] = entry.value;
    }
  }

  return ConduitUserAgent.mergeHeaders(headers);
}
