import '../models/model.dart';
import '../services/api_service.dart';
import '../../features/hermes/models/hermes_model.dart';

/// Extracts the profile image URL from a model's metadata.
///
/// Note: After OpenWebUI updates, the profile_image_url field is stripped from
/// the /api/models response. This function still checks for legacy data but
/// clients should use [buildModelAvatarUrl] to construct the proper endpoint URL.
String? deriveModelIcon(Model? model) {
  if (model == null) return null;

  String? pick(Map<String, dynamic>? source) {
    if (source == null) return null;
    for (final key in const [
      'profile_image_url',
      'profileImageUrl',
      'profileImage',
      'icon_url',
      'icon',
      'image',
      'avatar',
    ]) {
      final value = source[key];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return null;
  }

  final metadata = model.metadata ?? const <String, dynamic>{};
  final capabilities = model.capabilities ?? const <String, dynamic>{};
  final info = metadata['info'] as Map<String, dynamic>?;
  final infoMeta = info?['meta'] as Map<String, dynamic>?;
  final nestedMeta = metadata['meta'] as Map<String, dynamic>?;

  final candidates = <String?>[
    pick(metadata),
    pick(nestedMeta),
    pick(info),
    pick(infoMeta),
    pick(capabilities),
    pick(capabilities['meta'] as Map<String, dynamic>?),
  ];

  for (final candidate in candidates) {
    if (candidate != null && candidate.isNotEmpty) {
      return candidate;
    }
  }

  return null;
}

/// Builds the model avatar URL using the new OpenWebUI endpoint.
///
/// OpenWebUI now serves model avatars through a dedicated endpoint:
/// `/api/v1/models/model/profile/image?id={modelId}`
///
/// This endpoint:
/// - Requires authentication
/// - Handles external URLs (returns 302 redirect)
/// - Decodes base64 data URIs
/// - Provides a fallback favicon.png
String? buildModelAvatarUrl(ApiService? api, String? modelId) {
  if (api == null || modelId == null || modelId.isEmpty) {
    return null;
  }

  final baseUrl = api.baseUrl.trim();
  if (baseUrl.isEmpty) {
    return null;
  }

  try {
    final baseUri = Uri.parse(baseUrl);
    final path = '/api/v1/models/model/profile/image';
    final queryParams = {'id': modelId};

    final avatarUri = baseUri.replace(path: path, queryParameters: queryParams);

    return avatarUri.toString();
  } catch (_) {
    // Fallback to manual URL construction
    final normalizedBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return '$normalizedBase/api/v1/models/model/profile/image?id=${Uri.encodeComponent(modelId)}';
  }
}

String? resolveModelIconUrl(ApiService? api, String? rawUrl) {
  final value = rawUrl?.trim();
  if (value == null || value.isEmpty) {
    return null;
  }

  if (value.startsWith('data:image')) {
    return value;
  }

  if (value.startsWith('http://') || value.startsWith('https://')) {
    return value;
  }

  if (value.startsWith('//')) {
    final base = api?.baseUrl;
    if (base != null && base.isNotEmpty) {
      try {
        final baseUri = Uri.parse(base);
        final scheme = baseUri.scheme.isNotEmpty ? baseUri.scheme : 'https';
        return '$scheme:$value';
      } catch (_) {
        return 'https:$value';
      }
    }
    return 'https:$value';
  }

  if (api == null || api.baseUrl.isEmpty) {
    return value.startsWith('/') ? value : '/$value';
  }

  try {
    final baseUri = Uri.parse(api.baseUrl);
    final resolved = baseUri.resolve(value);
    return resolved.toString();
  } catch (_) {
    final normalizedBase = api.baseUrl.endsWith('/')
        ? api.baseUrl.substring(0, api.baseUrl.length - 1)
        : api.baseUrl;
    if (value.startsWith('/')) {
      return '$normalizedBase$value';
    }
    return '$normalizedBase/$value';
  }
}

/// Resolves the final model icon URL for a given model.
///
/// This function first checks for a legacy profile_image_url in the model's
/// metadata (for backwards compatibility with older OpenWebUI versions).
/// If found and it's an external URL or data URI, it uses that directly.
///
/// Otherwise, it constructs the URL using the new OpenWebUI endpoint:
/// `/api/v1/models/model/profile/image?id={modelId}`
String? resolveModelIconUrlForModel(ApiService? api, Model? model) {
  if (model == null) return null;
  if (isHermesModel(model)) return 'asset:$kHermesModelAvatarAsset';

  // Check for legacy profile_image_url in metadata
  final legacyUrl = deriveModelIcon(model);

  // If we have a legacy URL that's external or a data URI, use it directly
  if (legacyUrl != null && legacyUrl.isNotEmpty) {
    final trimmed = legacyUrl.trim();
    if (trimmed.startsWith('data:image') ||
        trimmed.startsWith('http://') ||
        trimmed.startsWith('https://')) {
      return trimmed;
    }
  }

  // Use the new dedicated endpoint for model avatars
  return buildModelAvatarUrl(api, model.id);
}
