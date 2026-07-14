import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/core/network/conduit_user_agent.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';

/// Builds HTTP headers for protected image requests.
///
/// Includes Authorization (Bearer token or API key), the Conduit User-Agent,
/// and any server-configured custom headers. Returns `null` without an API.
Map<String, String>? buildImageHeadersForUrlFromWidgetRef(
  WidgetRef ref,
  String url,
) {
  final api = ref.watch(apiServiceProvider);
  if (!imageUrlIsServerOrigin(api?.serverConfig.url, url)) {
    return null;
  }
  final token = ref.watch(authTokenProvider3);
  return _build(api, token);
}

Map<String, String>? readImageHeadersForUrlFromWidgetRef(
  WidgetRef ref,
  String url,
) {
  final api = ref.read(apiServiceProvider);
  if (!imageUrlIsServerOrigin(api?.serverConfig.url, url)) {
    return null;
  }
  final token = ref.read(authTokenProvider3);
  return _build(api, token);
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
  final api = container.read(apiServiceProvider);
  if (!imageUrlIsServerOrigin(api?.serverConfig.url, url)) {
    return null;
  }
  final token = container.read(authTokenProvider3);
  return _build(api, token);
}

Map<String, String>? _build(ApiService? api, String? token) {
  final headers = <String, String>{};

  if (token != null && token.isNotEmpty) {
    headers['Authorization'] = 'Bearer $token';
  } else if (api?.serverConfig.apiKey != null &&
      api!.serverConfig.apiKey!.isNotEmpty) {
    headers['Authorization'] = 'Bearer ${api.serverConfig.apiKey}';
  }

  final customHeaders = api?.serverConfig.customHeaders ?? {};
  if (customHeaders.isNotEmpty) {
    headers.addAll(customHeaders);
  }

  if (api == null) {
    return headers.isEmpty ? null : headers;
  }
  return ConduitUserAgent.mergeHeaders(headers);
}
