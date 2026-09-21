import 'package:conduit_core/models/user.dart' as models;

String deriveUserDisplayName(dynamic user, {String fallback = 'User'}) {
  if (user == null) {
    return fallback;
  }

  String normalize(String? value) {
    if (value == null) return '';
    final trimmed = value.trim();
    return trimmed;
  }

  String emailFallback(String? email) {
    final trimmed = normalize(email);
    if (trimmed.isEmpty) return '';
    final at = trimmed.indexOf('@');
    if (at > 0) {
      return trimmed.substring(0, at);
    }
    return trimmed;
  }

  if (user is models.User) {
    final name = normalize(user.name);
    if (name.isNotEmpty) return name;

    final username = normalize(user.username);
    if (username.isNotEmpty) return username;

    final email = emailFallback(user.email);
    if (email.isNotEmpty) return email;

    return fallback;
  }

  if (user is Map) {
    String? pick(Map<dynamic, dynamic> source) {
      for (final key in const [
        'name',
        'display_name',
        'preferred_username',
        'username',
      ]) {
        final value = source[key];
        final normalized = normalize(value is String ? value : null);
        if (normalized.isNotEmpty) {
          return normalized;
        }
      }
      return null;
    }

    final topLevel = pick(user);
    if (topLevel != null && topLevel.isNotEmpty) {
      return topLevel;
    }

    final nestedUser = user['user'];
    if (nestedUser is Map) {
      final nested = pick(nestedUser);
      if (nested != null && nested.isNotEmpty) {
        return nested;
      }
      final email = emailFallback(nestedUser['email'] as String?);
      if (email.isNotEmpty) {
        return email;
      }
    }

    final email = emailFallback(user['email'] as String?);
    if (email.isNotEmpty) {
      return email;
    }

    return fallback;
  }

  final asString = normalize(user.toString());
  if (asString.isNotEmpty) {
    return asString;
  }

  return fallback;
}
