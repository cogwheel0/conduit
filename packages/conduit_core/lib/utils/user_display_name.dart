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

/// Scripts that write the family name first and the given name without a
/// space-separated order a client can rely on (Han, Kana, Hangul).
final RegExp _familyNameFirstScript = RegExp(
  r'[ᄀ-ᇿ぀-ヿ㄰-㆏㐀-䶿一-鿿'
  r'가-힯豈-﫿]',
);

final RegExp _letter = RegExp(r'\p{L}', unicode: true);

/// The name a greeting addresses: the first name of [displayName] ("Robin"
/// for "Robin Vale"), or the whole display name when it has no clear first
/// name.
///
/// The whole name stays when it is one word, looks like an email address,
/// is written in a script that puts the family name first (Chinese,
/// Japanese, Korean), or starts with an initial or a title ("J. Vale",
/// "Dr. Vale"), where the first word alone would read oddly. "Vale, Robin"
/// gives "Robin". Other scripts use their first word, as Latin does.
String deriveGreetingName(String displayName) {
  final name = displayName.trim();
  if (name.isEmpty || name.contains('@')) return name;
  if (_familyNameFirstScript.hasMatch(name)) return name;

  final words = name.split(RegExp(r'\s+'));
  if (words.length < 2) return name;

  bool isGivenName(String word) {
    if (!_letter.hasMatch(word)) return false;
    // An initial ("J", "J.") or a title or abbreviation ("Dr.", "Mr.").
    if (word.endsWith('.')) return false;
    if (word.runes.length < 2) return false;
    return true;
  }

  final first = words.first;
  if (first.endsWith(',')) {
    // "Family, Given".
    final given = words[1];
    return isGivenName(given) ? given : name;
  }
  return isGivenName(first) ? first : name;
}
