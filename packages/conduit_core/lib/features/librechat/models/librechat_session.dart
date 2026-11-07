import 'dart:convert';

import 'package:meta/meta.dart';

import 'package:conduit_core/features/librechat/models/librechat_cookies.dart';

/// The signed-in LibreChat user, as `/api/auth/login`, `/api/auth/refresh`
/// and `/api/user` describe it.
@immutable
final class LibreChatUser {
  const LibreChatUser({
    required this.id,
    this.email,
    this.name,
    this.username,
    this.avatar,
    this.role,
    this.provider,
    this.raw = const <String, dynamic>{},
  });

  final String id;
  final String? email;
  final String? name;
  final String? username;
  final String? avatar;

  /// The LibreChat role, `USER` or `ADMIN` unless the admin added others. It
  /// names the permission set `/api/roles/:role` returns.
  final String? role;

  /// How the user signs in: `local`, `ldap`, `openid`, `google`, ...
  final String? provider;

  /// Everything else the server sent.
  final Map<String, dynamic> raw;

  /// What to call the user: the name, else the username, else the email.
  String get displayName =>
      [name, username, email].firstWhere(
        (value) => value != null && value.trim().isNotEmpty,
        orElse: () => null,
      ) ??
      id;

  static LibreChatUser? fromJson(Object? json) {
    if (json is! Map) return null;
    final map = Map<String, dynamic>.from(json);
    final id = map['id'] ?? map['_id'];
    if (id is! String || id.isEmpty) return null;
    String? text(String key) {
      final value = map[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    return LibreChatUser(
      id: id,
      email: text('email'),
      name: text('name'),
      username: text('username'),
      avatar: text('avatar'),
      role: text('role'),
      provider: text('provider'),
      raw: Map<String, dynamic>.unmodifiable(map),
    );
  }

  /// The server's record, with the fields this user was built with on top.
  Map<String, dynamic> toJson() => <String, dynamic>{
    ...raw,
    'id': id,
    'email': ?email,
    'name': ?name,
    'username': ?username,
    'avatar': ?avatar,
    'role': ?role,
    'provider': ?provider,
  };

  @override
  bool operator ==(Object other) =>
      other is LibreChatUser &&
      other.id == id &&
      other.email == email &&
      other.name == name &&
      other.username == username &&
      other.avatar == avatar &&
      other.role == role &&
      other.provider == provider;

  @override
  int get hashCode =>
      Object.hash(id, email, name, username, avatar, role, provider);
}

/// A signed-in LibreChat session: the short-lived access token, the cookies
/// that renew it, and whom it belongs to.
///
/// LibreChat's access token is a JWT that lasts 15 minutes by default. It is
/// renewed by `POST /api/auth/refresh`, which reads only the refresh cookie,
/// rotates it, and ends for good when the session it belongs to does (seven
/// days after sign-in by default, however often it is renewed).
@immutable
final class LibreChatSession {
  const LibreChatSession({
    required this.accessToken,
    required this.user,
    this.cookies = const LibreChatCookies(),
  });

  final String accessToken;
  final LibreChatUser user;
  final LibreChatCookies cookies;

  LibreChatSession copyWith({
    String? accessToken,
    LibreChatUser? user,
    LibreChatCookies? cookies,
  }) => LibreChatSession(
    accessToken: accessToken ?? this.accessToken,
    user: user ?? this.user,
    cookies: cookies ?? this.cookies,
  );

  /// When [accessToken] lapses, read from its `exp` claim; null when it is
  /// not a JWT with one.
  DateTime? get accessTokenExpiry => jwtExpiry(accessToken);

  /// Whether [accessToken] lapses within [margin] of [now], so a request
  /// should renew it first rather than be refused.
  bool accessTokenExpiresSoon(DateTime now, {Duration margin = _margin}) {
    final expiry = accessTokenExpiry;
    return expiry != null && !expiry.isAfter(now.add(margin));
  }

  static const Duration _margin = Duration(seconds: 30);

  /// The `exp` claim of [token], or null when it is not a readable JWT.
  static DateTime? jwtExpiry(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      final exp = payload is Map ? payload['exp'] : null;
      return exp is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (exp * 1000).round(),
              isUtc: true,
            )
          : null;
    } on FormatException {
      return null;
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': 1,
    'accessToken': accessToken,
    'user': user.toJson(),
    'cookies': cookies.toJson(),
  };

  static LibreChatSession? fromJson(Object? json) {
    if (json is! Map || json['version'] != 1) return null;
    final token = json['accessToken'];
    final user = LibreChatUser.fromJson(json['user']);
    if (token is! String || token.isEmpty || user == null) return null;
    return LibreChatSession(
      accessToken: token,
      user: user,
      cookies: LibreChatCookies.fromJson(json['cookies']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LibreChatSession &&
      other.accessToken == accessToken &&
      other.user == user &&
      other.cookies == cookies;

  @override
  int get hashCode => Object.hash(accessToken, user, cookies);
}
