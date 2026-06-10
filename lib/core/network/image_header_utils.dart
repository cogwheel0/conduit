import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';

/// Builds HTTP headers for protected image requests.
///
/// Includes Authorization (Bearer token or API key) and any server-configured
/// custom headers. Returns `null` if no headers are needed.
Map<String, String>? buildImageHeadersFromRef(Ref ref) {
  final api = ref.watch(apiServiceProvider);
  final token = ref.watch(authTokenProvider3);
  return _build(api, token);
}

Map<String, String>? buildImageHeadersFromWidgetRef(WidgetRef ref) {
  final api = ref.watch(apiServiceProvider);
  final token = ref.watch(authTokenProvider3);
  return _build(api, token);
}

/// Same as [buildImageHeadersFromRef] but using a [ProviderContainer], useful
/// when you don't have a `Ref` (e.g., in non-Consumer widgets/utilities).
Map<String, String>? buildImageHeadersFromContainer(
  ProviderContainer container,
) {
  final api = container.read(apiServiceProvider);
  final token = container.read(authTokenProvider3);
  return _build(api, token);
}

bool imageUrlIsServerOrigin(String? serverBaseUrl, String imageUrl) {
  if (serverBaseUrl == null || serverBaseUrl.isEmpty) return false;
  final serverHost = Uri.tryParse(serverBaseUrl)?.host.toLowerCase();
  if (serverHost == null || serverHost.isEmpty) return false;
  final imageUri = Uri.tryParse(imageUrl);
  if (imageUri == null) return false;
  if (!imageUri.hasScheme && imageUri.host.isEmpty) return true;
  return imageUri.host.toLowerCase() == serverHost;
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

  return headers.isEmpty ? null : headers;
}
