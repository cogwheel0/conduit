import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:conduit_core/providers/storage_providers.dart';
import 'package:conduit_core/services/secure_credential_storage.dart';
import 'package:crypto/crypto.dart';
import 'package:riverpod/riverpod.dart';
import 'package:synchronized/synchronized.dart';

enum DeepSeekHarnessFailure {
  invalidUrl,
  unauthorized,
  untrustedHost,
  unavailable,
  invalidResponse,
}

class DeepSeekHarnessException implements Exception {
  const DeepSeekHarnessException(this.reason);

  final DeepSeekHarnessFailure reason;

  // A network/parse exception may include the complete launch URL.
  @override
  String toString() => 'DeepSeek Harness: ${reason.name}';
}

const _invalidResponse = DeepSeekHarnessException(
  DeepSeekHarnessFailure.invalidResponse,
);
const _invalidUrl = DeepSeekHarnessException(DeepSeekHarnessFailure.invalidUrl);

bool _safePath(Uri uri) => uri.pathSegments.every(
  (segment) =>
      segment != '.' &&
      segment != '..' &&
      !segment.contains(RegExp(r'[/\\%\x00-\x1f\x7f]')),
);

bool _webAddress(Uri uri) =>
    (uri.scheme == 'https' || uri.scheme == 'http') &&
    uri.hasAuthority &&
    uri.host.isNotEmpty &&
    !uri.authority.contains('@') &&
    uri.port > 0 &&
    uri.port <= 65535 &&
    _safePath(uri);

Uri _parseLaunch(String input) {
  try {
    final value = input.trim();
    if (value.contains(RegExp(r'[\\\s\x00-\x1f\x7f]'))) throw _invalidUrl;
    final uri = Uri.parse(value);
    final query = uri.queryParametersAll;
    final tokens = query['token'];
    if (!_webAddress(uri) ||
        uri.hasFragment ||
        query.length != 1 ||
        tokens == null ||
        tokens.length != 1 ||
        tokens.single.isEmpty) {
      throw _invalidUrl;
    }
    return uri;
  } on FormatException {
    throw _invalidUrl;
  }
}

String _encode(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

String _cookieName(String audience) =>
    'dsh-auth-${_encode(sha256.convert(utf8.encode(audience)).bytes)}';

List<int> _decode(String value) {
  final bytes = base64Url.decode(base64Url.normalize(value));
  if (_encode(bytes) != value) throw _invalidResponse;
  return bytes;
}

/// A host- and directory-scoped browser grant minted by `dsh web`.
class DeepSeekHarnessConnection {
  const DeepSeekHarnessConnection._(
    this.root,
    this.cookieName,
    this.cookieValue,
    this.expiresAt,
  );

  final Uri root;
  final String cookieName;
  final String cookieValue;
  final DateTime expiresAt;

  String get cookiePath => root.path;
  bool get isExpired => !clock.now().isBefore(expiresAt);

  bool allowsNavigation(Uri target) {
    try {
      return _webAddress(target) &&
          target.origin == root.origin &&
          target.path.startsWith(root.path) &&
          !target.queryParametersAll.containsKey('token');
    } on FormatException {
      return false;
    } on ArgumentError {
      return false;
    }
  }

  Map<String, dynamic> _toJson() => {
    'root': root.toString(),
    'name': cookieName,
    'value': cookieValue,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
  };

  // Check the payload's binding locally. Only the host can authenticate
  // the HMAC, which the exchange confirms by requesting the clean index.
  static DeepSeekHarnessConnection _fromGrant({
    required Uri root,
    required String name,
    required String value,
    required int expiresAt,
  }) {
    try {
      if (!_webAddress(root) ||
          root.hasQuery ||
          root.hasFragment ||
          !root.path.endsWith('/')) {
        throw _invalidResponse;
      }
      final parts = value.split('.');
      if (parts.length != 3 ||
          parts.first != 'v1' ||
          _decode(parts[2]).length != 32) {
        throw _invalidResponse;
      }
      final payload = jsonDecode(utf8.decode(_decode(parts[1])));
      if (payload is! Map<String, dynamic> || payload['version'] != 1) {
        throw _invalidResponse;
      }
      final authority = payload['authority'];
      final issued = payload['issuedAt'];
      final expiry = payload['expiresAt'];
      // A TLS-terminating proxy can forward to an HTTP Harness listener.
      if (authority is! String ||
          !(authority == root.authority ||
              (root.scheme == 'https' && authority == root.origin)) ||
          name != _cookieName(authority) ||
          issued is! int ||
          expiry is! int ||
          expiry <= issued) {
        throw _invalidResponse;
      }
      final effective = expiresAt < expiry ? expiresAt : expiry;
      return DeepSeekHarnessConnection._(
        root,
        name,
        value,
        DateTime.fromMillisecondsSinceEpoch(effective, isUtc: true),
      );
    } on FormatException {
      throw _invalidResponse;
    } on ArgumentError {
      throw _invalidResponse;
    }
  }

  static DeepSeekHarnessConnection? _restore(String? stored) {
    if (stored == null) return null;
    try {
      final json = jsonDecode(stored);
      if (json case {
        'root': String root,
        'name': String name,
        'value': String value,
        'expiresAt': int expiresAt,
      }) {
        return _fromGrant(
          root: Uri.parse(root),
          name: name,
          value: value,
          expiresAt: expiresAt,
        );
      }
    } on FormatException {
      return null;
    } on DeepSeekHarnessException {
      return null;
    }
    return null;
  }
}

void _expectStatus(HttpClientResponse response, int expected) {
  if (response.statusCode == expected) return;
  throw DeepSeekHarnessException(switch (response.statusCode) {
    HttpStatus.unauthorized => DeepSeekHarnessFailure.unauthorized,
    HttpStatus.forbidden => DeepSeekHarnessFailure.untrustedHost,
    >= 500 => DeepSeekHarnessFailure.unavailable,
    _ => DeepSeekHarnessFailure.invalidResponse,
  });
}

Future<DeepSeekHarnessConnection> _exchange(
  HttpClient client,
  Uri root,
  String token,
) async {
  final launch = root.replace(queryParameters: {'token': token});
  final request = await client.getUrl(launch);
  request.followRedirects = false;
  final response = await request.close();
  _expectStatus(response, HttpStatus.seeOther);
  final locations = response.headers[HttpHeaders.locationHeader];
  if (locations == null ||
      locations.length != 1 ||
      root.resolve(locations.single) != root) {
    throw _invalidResponse;
  }

  DeepSeekHarnessConnection? grant;
  for (final header
      in response.headers[HttpHeaders.setCookieHeader] ?? <String>[]) {
    if (!header.startsWith('dsh-auth-')) continue;
    late final Cookie cookie;
    try {
      cookie = Cookie.fromSetCookieValue(header);
    } on HttpException {
      throw _invalidResponse;
    }
    final audience = cookie.secure ? root.origin : root.authority;
    if (cookie.name != _cookieName(audience)) continue;
    if (grant != null ||
        !cookie.httpOnly ||
        cookie.domain != null ||
        cookie.sameSite != SameSite.strict ||
        !(cookie.path == '/' || cookie.path == root.path) ||
        (cookie.secure && root.scheme != 'https') ||
        cookie.expires == null ||
        cookie.maxAge == null ||
        cookie.maxAge! <= 0) {
      throw _invalidResponse;
    }
    final maxAgeExpiry =
        clock.now().millisecondsSinceEpoch + cookie.maxAge! * 1000;
    final cookieExpiry = cookie.expires!.millisecondsSinceEpoch;
    grant = DeepSeekHarnessConnection._fromGrant(
      root: root,
      name: cookie.name,
      value: cookie.value,
      expiresAt: cookieExpiry < maxAgeExpiry ? cookieExpiry : maxAgeExpiry,
    );
    if (grant.isExpired) throw _invalidResponse;
  }
  if (grant == null) throw _invalidResponse;
  await response.drain<void>();
  final verify = await client.headUrl(root);
  verify.followRedirects = false;
  verify.cookies.add(Cookie(grant.cookieName, grant.cookieValue));
  final index = await verify.close();
  _expectStatus(index, HttpStatus.ok);
  if (index.headers.contentType?.mimeType != 'text/html') {
    throw _invalidResponse;
  }
  return grant;
}

final deepSeekHarnessConnectionProvider =
    AsyncNotifierProvider<
      DeepSeekHarnessConnections,
      DeepSeekHarnessConnection?
    >(DeepSeekHarnessConnections.new);

class DeepSeekHarnessConnections
    extends AsyncNotifier<DeepSeekHarnessConnection?> {
  final _lock = Lock();
  late SecureCredentialStorage _storage;
  Timer? _expiryTimer;

  void _watchExpiry(DeepSeekHarnessConnection? grant) {
    _expiryTimer?.cancel();
    if (grant != null && !grant.isExpired && ref.mounted) {
      // On a suspended phone this fires when Dart resumes.
      _expiryTimer = Timer(
        grant.expiresAt.difference(clock.now()),
        ref.invalidateSelf,
      );
    }
  }

  @override
  Future<DeepSeekHarnessConnection?> build() {
    _storage = SecureCredentialStorage(
      instance: ref.watch(secureStorageProvider),
    );
    ref.onDispose(() => _expiryTimer?.cancel());
    return _lock.synchronized(() async {
      final grant = DeepSeekHarnessConnection._restore(
        await _storage.readDeepSeekHarnessConnection(),
      );
      _watchExpiry(grant);
      return grant;
    });
  }

  /// Run [beforeSave] after authentication, e.g. to clear an old browser
  /// workspace before publishing a replacement. A failed exchange leaves
  /// both the current grant and that workspace intact.
  Future<DeepSeekHarnessConnection> connect(
    String launchUrl, {
    Future<void> Function()? beforeSave,
  }) => _lock.synchronized(() async {
    final launch = _parseLaunch(launchUrl);
    final directory = launch.path.endsWith('/')
        ? launch.path
        : '${launch.path}/';
    final root = Uri.parse('${launch.origin}$directory');
    const timeout = Duration(seconds: 15);
    final client = HttpClient()..connectionTimeout = timeout;
    late final DeepSeekHarnessConnection grant;
    try {
      grant = await _exchange(
        client,
        root,
        launch.queryParameters['token']!,
      ).timeout(timeout);
    } on IOException {
      throw const DeepSeekHarnessException(DeepSeekHarnessFailure.unavailable);
    } on TimeoutException {
      throw const DeepSeekHarnessException(DeepSeekHarnessFailure.unavailable);
    } on FormatException {
      throw _invalidResponse;
    } finally {
      client.close(force: true);
    }
    if (beforeSave != null) await beforeSave();
    await _storage.saveDeepSeekHarnessConnection(jsonEncode(grant._toJson()));
    _watchExpiry(grant);
    if (ref.mounted) state = AsyncData(grant);
    return grant;
  });

  Future<void> disconnect() => _lock.synchronized(() async {
    await _storage.deleteDeepSeekHarnessConnection();
    _watchExpiry(null);
    if (ref.mounted) state = const AsyncData(null);
  });
}
