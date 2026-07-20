import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/server_config.dart';
import '../utils/debug_logger.dart';
import 'api_service.dart';
import 'native_sheet_bridge.dart';
import 'server_tls_http_client_factory.dart';

final Expando<Object> _avatarSessionTokens = Expando<Object>(
  'native-sheet-avatar-session',
);

Object _avatarSessionToken(ApiService api) =>
    _avatarSessionTokens[api] ??= Object();

final class _AvatarCacheKey {
  const _AvatarCacheKey({
    required this.sessionToken,
    required this.authenticationEpoch,
    required this.serverId,
    required this.avatarUrl,
  });

  final Object sessionToken;
  final int authenticationEpoch;
  final String serverId;
  final String avatarUrl;

  @override
  bool operator ==(Object other) =>
      other is _AvatarCacheKey &&
      identical(sessionToken, other.sessionToken) &&
      authenticationEpoch == other.authenticationEpoch &&
      serverId == other.serverId &&
      avatarUrl == other.avatarUrl;

  @override
  int get hashCode => Object.hash(
    identityHashCode(sessionToken),
    authenticationEpoch,
    serverId,
    avatarUrl,
  );
}

/// Hydrates native sheet avatar payloads with bytes when native networking
/// cannot reuse Dart's server-scoped TLS client.
class NativeSheetAvatarBytesHydrator {
  final LinkedHashMap<_AvatarCacheKey, Future<Uint8List?>> _avatarBytesByUrl =
      LinkedHashMap<_AvatarCacheKey, Future<Uint8List?>>();
  final Map<_AvatarCacheKey, Object> _avatarRequestTokens =
      <_AvatarCacheKey, Object>{};
  final Map<_AvatarCacheKey, CancelToken> _avatarCancelTokens =
      <_AvatarCacheKey, CancelToken>{};
  final Map<_AvatarCacheKey, int> _avatarByteSizes = <_AvatarCacheKey, int>{};
  int _cachedByteCount = 0;

  static const int _maxConcurrentRequests = 4;
  static const int _maxCacheEntries = 32;
  static const int _maxCachedBytes = 8 * 1024 * 1024;
  static const int _maxAvatarBytes = 1024 * 1024;
  static const Duration _defaultHydrationBudget = Duration(milliseconds: 750);

  /// Removes same-server URLs that native URLSession cannot load with Dart's
  /// custom TLS identity/trust configuration. The original options remain the
  /// source for Dart-side hydration; native receives initials until bytes are
  /// available and never retries a URL that is guaranteed to fail.
  List<NativeSheetModelOption> prepareForNativePresentation({
    required ApiService? api,
    required List<NativeSheetModelOption> options,
  }) {
    if (api == null ||
        !api.serverConfig.needsCustomTlsClient ||
        options.isEmpty) {
      return options;
    }
    return List<NativeSheetModelOption>.unmodifiable(
      options.map((option) {
        if (!_shouldHydrateNativeAvatarUrl(api, option.avatarUrl)) {
          return option;
        }
        return NativeSheetModelOption(
          id: option.id,
          name: option.name,
          subtitle: option.subtitle,
          sfSymbol: option.sfSymbol,
          avatarBytes: option.avatarBytes,
          tags: option.tags,
        );
      }),
    );
  }

  Future<List<NativeSheetModelOption>> hydrateModelOptions({
    required ApiService? api,
    required List<NativeSheetModelOption> options,
    Duration maxWait = _defaultHydrationBudget,
    void Function(List<NativeSheetModelOption> options)? onProgress,
    bool Function()? isActive,
  }) async {
    if (api == null ||
        !api.serverConfig.needsCustomTlsClient ||
        options.isEmpty ||
        !_isHydrationActive(isActive)) {
      return options;
    }

    final hydrated = List<NativeSheetModelOption>.of(options);
    final stopwatch = Stopwatch()..start();
    var nextIndex = 0;

    // A fixed worker pool advances as each request settles. A single custom-TLS
    // endpoint that never answers may occupy one slot until the global budget,
    // but it cannot hold the other slots behind a Future.wait batch barrier.
    Future<void> hydrateNext() async {
      while (_isHydrationActive(isActive)) {
        final remaining = maxWait - stopwatch.elapsed;
        if (remaining <= Duration.zero || nextIndex >= options.length) return;
        final index = nextIndex++;
        final original = options[index];
        final result = await _hydrateModelOption(
          api,
          original,
          maxWait: remaining,
        );
        if (!_isHydrationActive(isActive)) return;

        hydrated[index] = result;
        if (original.avatarBytes == null && result.avatarBytes != null) {
          onProgress?.call(List<NativeSheetModelOption>.unmodifiable([result]));
        }
      }
    }

    await Future.wait(
      List<Future<void>>.generate(
        math.min(_maxConcurrentRequests, options.length),
        (_) => hydrateNext(),
      ),
    );
    return hydrated;
  }

  Future<NativeSheetModelOption> _hydrateModelOption(
    ApiService api,
    NativeSheetModelOption option, {
    required Duration maxWait,
  }) async {
    final avatarUrl = option.avatarUrl;
    if (option.avatarBytes != null ||
        !_shouldHydrateNativeAvatarUrl(api, avatarUrl)) {
      return option;
    }

    final load = _loadAvatarBytes(api, avatarUrl!);
    final bytes = await load.timeout(
      maxWait,
      onTimeout: () {
        // This deadline belongs only to the current sheet presentation. The
        // future and CancelToken are shared by every concurrent subscriber,
        // so leave the request running for a longer-lived presentation (and
        // for the bounded cache) instead of cancelling it globally.
        return null;
      },
    );
    if (bytes == null || bytes.isEmpty) {
      return option;
    }

    return NativeSheetModelOption(
      id: option.id,
      name: option.name,
      subtitle: option.subtitle,
      sfSymbol: option.sfSymbol,
      avatarUrl: option.avatarUrl,
      avatarBytes: bytes,
      avatarHeaders: option.avatarHeaders,
      tags: option.tags,
    );
  }

  Future<Uint8List?> _loadAvatarBytes(ApiService api, String avatarUrl) {
    // An ApiService represents a concrete authenticated server session. Do
    // not let a logout/login using the same persisted server ID reuse avatar
    // bytes fetched with the previous account's credentials.
    final cacheKey = _AvatarCacheKey(
      sessionToken: _avatarSessionToken(api),
      authenticationEpoch: api.authenticationEpoch,
      serverId: api.serverConfig.id,
      avatarUrl: avatarUrl,
    );
    final cached = _avatarBytesByUrl[cacheKey];
    if (cached != null) {
      final requestToken = _avatarRequestTokens[cacheKey];
      final cancelToken = _avatarCancelTokens[cacheKey];
      if (requestToken == null || cancelToken == null) {
        _removeCacheEntry(cacheKey);
        return _loadAvatarBytes(api, avatarUrl);
      }
      _avatarBytesByUrl
        ..remove(cacheKey)
        ..[cacheKey] = cached;
      return cached;
    }

    final requestToken = Object();
    final cancelToken = CancelToken();
    final future = _fetchAvatarBytes(
      api,
      avatarUrl,
      cacheKey,
      requestToken,
      cancelToken,
    );
    _avatarBytesByUrl[cacheKey] = future;
    _avatarRequestTokens[cacheKey] = requestToken;
    _avatarCancelTokens[cacheKey] = cancelToken;
    _trimCache();
    return future;
  }

  Future<Uint8List?> _fetchAvatarBytes(
    ApiService api,
    String avatarUrl,
    _AvatarCacheKey cacheKey,
    Object requestToken,
    CancelToken cancelToken,
  ) async {
    try {
      final bytes = await _requestAvatarBytes(api, avatarUrl, cancelToken);
      if (bytes.isEmpty || bytes.length > _maxAvatarBytes) {
        _removeCacheEntry(cacheKey, requestToken: requestToken);
        return null;
      }
      // The in-flight entry may have been evicted while waiting. Return the
      // result to its original caller without resurrecting an orphaned cache
      // cost entry.
      if (!identical(_avatarRequestTokens[cacheKey], requestToken)) {
        return bytes;
      }
      _cachedByteCount -= _avatarByteSizes[cacheKey] ?? 0;
      _avatarByteSizes[cacheKey] = bytes.length;
      _cachedByteCount += bytes.length;
      _trimCache(preserving: cacheKey);
      return bytes;
    } catch (error) {
      _removeCacheEntry(cacheKey, requestToken: requestToken);
      if (error is DioException && CancelToken.isCancel(error)) return null;
      DebugLogger.error(
        'native-avatar-prefetch-failed',
        scope: 'native-sheet/avatar',
        data: {
          'origin': _redactedAvatarUrlForLog(avatarUrl),
          'urlHash': _avatarUrlHashForLog(avatarUrl),
          'errorType': error.runtimeType.toString(),
        },
      );
      return null;
    }
  }

  Future<Uint8List> _requestAvatarBytes(
    ApiService api,
    String avatarUrl,
    CancelToken cancelToken,
  ) async {
    final uri = Uri.parse(avatarUrl);
    final options = Options(
      responseType: ResponseType.bytes,
      receiveTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 10),
    );
    final Response<List<int>> response = uri.hasScheme
        ? await api.dio.getUri<List<int>>(
            uri,
            options: options,
            cancelToken: cancelToken,
            onReceiveProgress: (received, total) {
              if (received > _maxAvatarBytes || total > _maxAvatarBytes) {
                cancelToken.cancel(
                  'Avatar response exceeded $_maxAvatarBytes bytes',
                );
              }
            },
          )
        : await api.dio.get<List<int>>(
            avatarUrl,
            options: options,
            cancelToken: cancelToken,
            onReceiveProgress: (received, total) {
              if (received > _maxAvatarBytes || total > _maxAvatarBytes) {
                cancelToken.cancel(
                  'Avatar response exceeded $_maxAvatarBytes bytes',
                );
              }
            },
          );
    final contentType = response.headers.value(Headers.contentTypeHeader);
    if (contentType != null &&
        !contentType.toLowerCase().startsWith('image/')) {
      throw const FormatException('Avatar response has a non-image MIME type.');
    }
    final data = response.data;
    if (data == null || data.isEmpty) return Uint8List(0);
    if (data.length > _maxAvatarBytes) {
      throw StateError('Avatar response exceeded $_maxAvatarBytes bytes.');
    }
    return data is Uint8List ? data : Uint8List.fromList(data);
  }

  void _trimCache({_AvatarCacheKey? preserving}) {
    while (_avatarBytesByUrl.length > _maxCacheEntries ||
        _cachedByteCount > _maxCachedBytes) {
      _AvatarCacheKey? candidate;
      for (final key in _avatarBytesByUrl.keys) {
        if (key != preserving) {
          candidate = key;
          break;
        }
      }
      if (candidate == null) return;
      _removeCacheEntry(candidate);
    }
  }

  void _removeCacheEntry(_AvatarCacheKey cacheKey, {Object? requestToken}) {
    if (requestToken != null &&
        !identical(_avatarRequestTokens[cacheKey], requestToken)) {
      return;
    }
    _avatarBytesByUrl.remove(cacheKey);
    _avatarRequestTokens.remove(cacheKey);
    _avatarCancelTokens.remove(cacheKey);
    _cachedByteCount -= _avatarByteSizes.remove(cacheKey) ?? 0;
    if (_cachedByteCount < 0) _cachedByteCount = 0;
  }
}

bool _isHydrationActive(bool Function()? isActive) {
  if (isActive == null) return true;
  try {
    return isActive();
  } catch (_) {
    return false;
  }
}

String _redactedAvatarUrlForLog(String avatarUrl) {
  final uri = Uri.tryParse(avatarUrl);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return '<invalid-avatar-origin>';
  }
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  ).toString();
}

String _avatarUrlHashForLog(String avatarUrl) =>
    sha256.convert(utf8.encode(avatarUrl)).toString();

@visibleForTesting
String redactedNativeAvatarUrlForLogForTest(String avatarUrl) {
  return _redactedAvatarUrlForLog(avatarUrl);
}

@visibleForTesting
String nativeAvatarUrlHashForLogForTest(String avatarUrl) {
  return _avatarUrlHashForLog(avatarUrl);
}

@visibleForTesting
bool shouldHydrateNativeAvatarUrlForTest(ApiService api, String? avatarUrl) {
  return _shouldHydrateNativeAvatarUrl(api, avatarUrl);
}

bool _shouldHydrateNativeAvatarUrl(ApiService api, String? avatarUrl) {
  final value = avatarUrl?.trim();
  if (value == null ||
      value.isEmpty ||
      value.startsWith('data:image') ||
      !api.serverConfig.needsCustomTlsClient) {
    return false;
  }

  final uri = Uri.tryParse(value);
  final serverUri = ServerTlsHttpClientFactory.parseBaseUri(api.baseUrl);
  if (uri == null ||
      serverUri == null ||
      !uri.hasScheme ||
      !serverUri.hasScheme) {
    return false;
  }

  return uri.scheme.toLowerCase() == serverUri.scheme.toLowerCase() &&
      uri.host.toLowerCase() == serverUri.host.toLowerCase() &&
      _effectivePort(uri) == _effectivePort(serverUri);
}

int _effectivePort(Uri uri) {
  if (uri.hasPort) {
    return uri.port;
  }
  return switch (uri.scheme.toLowerCase()) {
    'http' => 80,
    'https' => 443,
    _ => 0,
  };
}
