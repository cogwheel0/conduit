import 'package:http_parser/http_parser.dart';
import 'package:meta/meta.dart';

/// One cookie a LibreChat server set.
@immutable
final class LibreChatCookie {
  const LibreChatCookie({
    required this.name,
    required this.value,
    this.expires,
    this.path = '/',
  });

  final String name;
  final String value;

  /// When the cookie lapses; null for a cookie that lasts the session.
  final DateTime? expires;

  final String path;

  bool isExpiredAt(DateTime now) =>
      expires != null && !expires!.isAfter(now);

  /// Whether a request to [requestPath] carries this cookie.
  bool appliesTo(String requestPath) =>
      path == '/' ||
      requestPath == path ||
      requestPath.startsWith(path.endsWith('/') ? path : '$path/');

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'value': value,
    if (expires != null) 'expires': expires!.toUtc().toIso8601String(),
    if (path != '/') 'path': path,
  };

  static LibreChatCookie? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final value = json['value'];
    if (name is! String || name.isEmpty || value is! String) return null;
    final expires = json['expires'];
    final path = json['path'];
    return LibreChatCookie(
      name: name,
      value: value,
      expires: expires is String ? DateTime.tryParse(expires) : null,
      path: path is String && path.startsWith('/') ? path : '/',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LibreChatCookie &&
      other.name == name &&
      other.value == value &&
      other.expires == expires &&
      other.path == path;

  @override
  int get hashCode => Object.hash(name, value, expires, path);
}

/// The cookies one LibreChat account holds, by name.
///
/// LibreChat keeps its session in cookies rather than in anything a client
/// can ask for: the rotating refresh token, the provider that issued it and,
/// for OpenID sign-ins, the IdP user and an express session. A browser keeps
/// them in its jar; Conduit keeps them with the account and sends them on
/// every request to that server, as the browser would. It differs from a
/// browser jar in three deliberate ways:
///
/// - It belongs to one server, so cookie domains are not tracked. The client
///   never sends them anywhere else (see `LibreChatServer.owns`).
/// - The Secure flag is not enforced. A server reached over plain HTTP marks
///   its cookies Secure unless told otherwise, and a browser would then drop
///   the session; the app talks only to the address the user chose.
/// - httpOnly and SameSite only restrict scripts and other sites, so they
///   have nothing to restrict here.
@immutable
final class LibreChatCookies {
  const LibreChatCookies([this._byName = const <String, LibreChatCookie>{}]);

  LibreChatCookies.of(Iterable<LibreChatCookie> cookies)
    : _byName = <String, LibreChatCookie>{
        for (final cookie in cookies) cookie.name: cookie,
      };

  final Map<String, LibreChatCookie> _byName;

  static const String refreshTokenName = 'refreshToken';
  static const String tokenProviderName = 'token_provider';

  Iterable<LibreChatCookie> get all => _byName.values;

  bool get isEmpty => _byName.isEmpty;

  String? value(String name) => _byName[name]?.value;

  bool get hasRefreshToken =>
      (value(refreshTokenName)?.isNotEmpty ?? false) ||
      value(tokenProviderName) == 'openid';

  /// These cookies after a response's `Set-Cookie` [headers], at [now]. The
  /// same instance when nothing changed, so a caller can skip saving.
  LibreChatCookies apply(Iterable<String> headers, {required DateTime now}) {
    Map<String, LibreChatCookie>? next;
    for (final header in headers) {
      final cookie = parseSetCookie(header, now: now);
      if (cookie == null) continue;
      final current = (next ?? _byName)[cookie.name];
      if (cookie.isExpiredAt(now) || cookie.value.isEmpty) {
        if (current == null) continue;
        (next ??= Map<String, LibreChatCookie>.of(_byName)).remove(cookie.name);
      } else if (current != cookie) {
        (next ??= Map<String, LibreChatCookie>.of(_byName))[cookie.name] =
            cookie;
      }
    }
    return next == null ? this : LibreChatCookies(Map.unmodifiable(next));
  }

  /// These cookies with the changes that turned [base] into [changed]: the
  /// cookies [changed] set or replaced, and the ones it dropped. Cookies this
  /// jar gained after [base] that [changed] did not touch are kept. The same
  /// instance when that changes nothing.
  LibreChatCookies withChanges({
    required LibreChatCookies base,
    required LibreChatCookies changed,
  }) {
    Map<String, LibreChatCookie>? next;
    for (final cookie in changed._byName.values) {
      if (base._byName[cookie.name] == cookie ||
          _byName[cookie.name] == cookie) {
        continue;
      }
      (next ??= Map<String, LibreChatCookie>.of(_byName))[cookie.name] =
          cookie;
    }
    for (final name in base._byName.keys) {
      if (changed._byName.containsKey(name) ||
          !(next ?? _byName).containsKey(name)) {
        continue;
      }
      (next ??= Map<String, LibreChatCookie>.of(_byName)).remove(name);
    }
    return next == null ? this : LibreChatCookies(Map.unmodifiable(next));
  }

  /// The `Cookie` header for a request to [path], or null when no live cookie
  /// applies.
  String? headerFor(String path, {required DateTime now}) {
    final pairs = [
      for (final cookie in _byName.values)
        if (!cookie.isExpiredAt(now) && cookie.appliesTo(path))
          '${cookie.name}=${cookie.value}',
    ];
    return pairs.isEmpty ? null : pairs.join('; ');
  }

  /// Parses one `Set-Cookie` header value; null when it has no name.
  ///
  /// `Max-Age` wins over `Expires`, as RFC 6265 says. A `Max-Age` of zero or
  /// less, or an `Expires` in the past, yields an already-expired cookie,
  /// which [apply] reads as a deletion.
  @visibleForTesting
  static LibreChatCookie? parseSetCookie(
    String header, {
    required DateTime now,
  }) {
    final parts = header.split(';');
    final pair = parts.first;
    final equals = pair.indexOf('=');
    if (equals <= 0) return null;
    final name = pair.substring(0, equals).trim();
    if (name.isEmpty) return null;
    var value = pair.substring(equals + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }

    DateTime? expires;
    DateTime? maxAgeExpiry;
    var path = '/';
    for (final attribute in parts.skip(1)) {
      final separator = attribute.indexOf('=');
      final key =
          (separator < 0 ? attribute : attribute.substring(0, separator))
              .trim()
              .toLowerCase();
      final argument = separator < 0
          ? ''
          : attribute.substring(separator + 1).trim();
      switch (key) {
        case 'expires':
          try {
            expires = parseHttpDate(argument);
          } on FormatException {
            // An unreadable date is ignored, as a browser ignores it.
          }
        case 'max-age':
          final seconds = int.tryParse(argument);
          if (seconds != null) {
            maxAgeExpiry = seconds <= 0
                ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
                : now.toUtc().add(Duration(seconds: seconds));
          }
        case 'path':
          if (argument.startsWith('/')) path = argument;
      }
    }
    return LibreChatCookie(
      name: name,
      value: value,
      expires: maxAgeExpiry ?? expires,
      path: path,
    );
  }

  List<Map<String, dynamic>> toJson() => [
    for (final cookie in _byName.values) cookie.toJson(),
  ];

  static LibreChatCookies fromJson(Object? json) {
    if (json is! List) return const LibreChatCookies();
    return LibreChatCookies.of(json.map(LibreChatCookie.fromJson).nonNulls);
  }

  @override
  bool operator ==(Object other) =>
      other is LibreChatCookies &&
      other._byName.length == _byName.length &&
      _byName.entries.every((entry) => other._byName[entry.key] == entry.value);

  @override
  int get hashCode => Object.hashAllUnordered(_byName.values);
}
