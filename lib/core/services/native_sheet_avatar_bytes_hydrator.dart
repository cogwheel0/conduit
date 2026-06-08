import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/server_config.dart';
import '../utils/debug_logger.dart';
import 'api_service.dart';
import 'native_sheet_bridge.dart';
import 'server_tls_http_client_factory.dart';

/// Hydrates native sheet avatar payloads with bytes when native networking
/// cannot reuse Dart's server-scoped TLS client.
class NativeSheetAvatarBytesHydrator {
  final Map<String, Future<Uint8List?>> _avatarBytesByUrl = {};

  static const int _batchSize = 6;
  static const Duration _defaultHydrationBudget = Duration(milliseconds: 750);

  Future<List<NativeSheetModelOption>> hydrateModelOptions({
    required ApiService? api,
    required List<NativeSheetModelOption> options,
    Duration maxWait = _defaultHydrationBudget,
  }) async {
    if (api == null ||
        !api.serverConfig.needsCustomTlsClient ||
        options.isEmpty) {
      return options;
    }

    final hydrated = List<NativeSheetModelOption>.of(options);
    final stopwatch = Stopwatch()..start();

    for (var start = 0; start < options.length; start += _batchSize) {
      final remaining = maxWait - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        break;
      }

      final end = math.min(start + _batchSize, options.length);
      final batch = options.sublist(start, end);
      final batchResults = await Future.wait(
        batch.map(
          (option) => _hydrateModelOption(
            api,
            option,
          ).timeout(remaining, onTimeout: () => option),
        ),
      );

      for (var index = 0; index < batchResults.length; index += 1) {
        hydrated[start + index] = batchResults[index];
      }
    }
    return hydrated;
  }

  Future<NativeSheetModelOption> _hydrateModelOption(
    ApiService api,
    NativeSheetModelOption option,
  ) async {
    final avatarUrl = option.avatarUrl;
    if (option.avatarBytes != null ||
        !_shouldHydrateNativeAvatarUrl(api, avatarUrl)) {
      return option;
    }

    final bytes = await _loadAvatarBytes(api, avatarUrl!);
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
    final cacheKey = '${api.serverConfig.id}|$avatarUrl';
    final cached = _avatarBytesByUrl[cacheKey];
    if (cached != null) {
      return cached;
    }

    final future = _fetchAvatarBytes(api, avatarUrl, cacheKey);
    _avatarBytesByUrl[cacheKey] = future;
    return future;
  }

  Future<Uint8List?> _fetchAvatarBytes(
    ApiService api,
    String avatarUrl,
    String cacheKey,
  ) async {
    try {
      final bytes = await api.fetchImageBytes(avatarUrl);
      if (bytes.isEmpty) {
        _avatarBytesByUrl.remove(cacheKey);
        return null;
      }
      return bytes;
    } catch (error, stackTrace) {
      _avatarBytesByUrl.remove(cacheKey);
      DebugLogger.error(
        'native-avatar-prefetch-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
        data: {'url': avatarUrl},
      );
      return null;
    }
  }
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
