import 'package:conduit_core/models/user.dart' as models;
import 'package:conduit_core/services/api_service.dart';

String? deriveUserProfileImage(dynamic user) {
  if (user == null) return null;

  String? pick(dynamic source) {
    if (source is Map) {
      for (final key in const [
        'profile_image_url',
        'profileImage',
        'avatar_url',
        'avatar',
        'picture',
        'image',
      ]) {
        final value = source[key];
        if (value is String && value.trim().isNotEmpty) {
          return value.trim();
        }
      }
    }
    return null;
  }

  if (user is models.User) {
    final value = user.profileImage;
    if (value != null && value.trim().isNotEmpty) {
      return value.trim();
    }
    return null;
  }

  final topLevel = pick(user);
  if (topLevel != null) return topLevel;

  if (user is Map && user['user'] != null) {
    final nested = pick(user['user']);
    if (nested != null) return nested;
  }

  return null;
}

String? resolveUserProfileImageUrl(ApiService? api, String? rawUrl) {
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

String? resolveUserAvatarUrlForUser(ApiService? api, dynamic user) {
  final raw = deriveUserProfileImage(user);
  return resolveUserProfileImageUrl(api, raw);
}
