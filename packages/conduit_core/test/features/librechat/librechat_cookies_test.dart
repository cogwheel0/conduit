import 'package:checks/checks.dart';
import 'package:conduit_core/features/librechat/models/librechat_cookies.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 18, 12);

  group('Set-Cookie', () {
    test('reads what express sends for the refresh token', () {
      final cookie = LibreChatCookies.parseSetCookie(
        'refreshToken=eyJ.abc.def; Path=/; Expires=Sun, 25 Oct 2026 12:00:00 '
        'GMT; HttpOnly; Secure; SameSite=Strict',
        now: now,
      )!;
      check(cookie.name).equals('refreshToken');
      check(cookie.value).equals('eyJ.abc.def');
      check(cookie.expires).equals(DateTime.utc(2026, 10, 25, 12));
      check(cookie.path).equals('/');
    });

    test('Max-Age wins over Expires', () {
      final cookie = LibreChatCookies.parseSetCookie(
        'a=1; Expires=Sun, 25 Oct 2026 12:00:00 GMT; Max-Age=60',
        now: now,
      )!;
      check(cookie.expires).equals(now.add(const Duration(minutes: 1)));
    });

    test('unquotes a quoted value and keeps a path', () {
      final cookie = LibreChatCookies.parseSetCookie(
        'b="x y"; path=/api',
        now: now,
      )!;
      check(cookie.value).equals('x y');
      check(cookie.path).equals('/api');
      check(LibreChatCookies.parseSetCookie('=nameless', now: now)).isNull();
    });
  });

  group('the jar', () {
    test('keeps the instance when nothing changed', () {
      final jar = const LibreChatCookies().apply(['a=1; Path=/'], now: now);
      check(identical(jar.apply(['a=1; Path=/'], now: now), jar)).isTrue();
      check(identical(jar.apply(const [], now: now), jar)).isTrue();
    });

    test('a past expiry or an empty value deletes the cookie', () {
      var jar = const LibreChatCookies().apply([
        'refreshToken=r1',
        'token_provider=librechat',
      ], now: now);
      check(jar.hasRefreshToken).isTrue();
      jar = jar.apply([
        'refreshToken=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
      ], now: now);
      check(jar.value('refreshToken')).isNull();
      check(jar.hasRefreshToken).isFalse();
      jar = jar.apply(['token_provider=; Max-Age=0'], now: now);
      check(jar.isEmpty).isTrue();
    });

    test('an OpenID session can renew without a refresh cookie', () {
      final jar = const LibreChatCookies().apply([
        'token_provider=openid',
        'connect.sid=s%3Aabc',
      ], now: now);
      check(jar.hasRefreshToken).isTrue();
    });

    test('sends live cookies for matching paths, Secure or not', () {
      final jar = const LibreChatCookies().apply([
        'refreshToken=r1; Secure; HttpOnly',
        'scoped=s; Path=/api/files',
        'gone=g; Max-Age=10',
      ], now: now);
      check(
        jar.headerFor('/api/files/images', now: now),
      ).equals('refreshToken=r1; scoped=s; gone=g');
      check(
        jar.headerFor('/api/convos', now: now.add(const Duration(minutes: 1))),
      ).equals('refreshToken=r1');
    });

    test('round-trips through JSON', () {
      final jar = const LibreChatCookies().apply([
        'refreshToken=r1; Expires=Sun, 25 Oct 2026 12:00:00 GMT',
        'scoped=s; Path=/api',
      ], now: now);
      check(LibreChatCookies.fromJson(jar.toJson())).equals(jar);
    });
  });

  group('server address', () {
    test('normalizes what users paste', () {
      check(
        LibreChatServer.normalizeBaseUrl('chat.example.com'),
      ).equals('https://chat.example.com');
      check(
        LibreChatServer.normalizeBaseUrl('http://localhost:3080/'),
      ).equals('http://localhost:3080');
      check(
        LibreChatServer.normalizeBaseUrl(
          'https://example.com/librechat/c/6f1d2c3a?x=1#y',
        ),
      ).equals('https://example.com/librechat');
      check(
        LibreChatServer.normalizeBaseUrl('https://example.com/login'),
      ).equals('https://example.com');
      check(LibreChatServer.normalizeBaseUrl('ftp://example.com')).isNull();
      check(LibreChatServer.normalizeBaseUrl('https://u:p@x.com')).isNull();
      check(LibreChatServer.normalizeBaseUrl('  ')).isNull();
    });

    test('owns only its origin and base path', () {
      const server = LibreChatServer(baseUrl: 'https://example.com/lc');
      check(server.owns(Uri.parse('https://example.com/lc/api/x'))).isTrue();
      check(server.owns(Uri.parse('https://EXAMPLE.com:443/lc'))).isTrue();
      check(server.owns(Uri.parse('https://example.com/lcx/api'))).isFalse();
      check(server.owns(Uri.parse('http://example.com/lc/api'))).isFalse();
      check(server.owns(Uri.parse('https://evil.com/lc/api'))).isFalse();
      check(
        server.resolve('/api/convos').toString(),
      ).equals('https://example.com/lc/api/convos');
    });

    test('round-trips through JSON', () {
      const server = LibreChatServer(
        baseUrl: 'https://example.com',
        customHeaders: {'CF-Access-Client-Id': 'id'},
        allowSelfSignedCertificates: true,
      );
      check(LibreChatServer.fromJson(server.toJson())).equals(server);
      check(LibreChatServer.fromJson({'baseUrl': 'https://x.com/'})).isNull();
    });

    test('reads a stored server whose certificate fields are not text', () {
      final server = LibreChatServer.fromJson({
        'baseUrl': 'https://example.com',
        'mtlsCertificateChainPem': 42,
        'mtlsPrivateKeyPem': ['x'],
      });
      check(server).isNotNull();
      check(server!.mtlsCertificateChainPem).isNull();
      check(server.mtlsPrivateKeyPem).isNull();
    });
  });

  group('user', () {
    test('a user built in code keeps its fields through JSON', () {
      const user = LibreChatUser(
        id: 'u1',
        email: 'dev@example.com',
        name: 'Dev',
        username: 'dev',
        role: 'ADMIN',
        provider: 'local',
      );
      final restored = LibreChatUser.fromJson(user.toJson())!;
      check(restored.id).equals('u1');
      check(restored.email).equals('dev@example.com');
      check(restored.name).equals('Dev');
      check(restored.username).equals('dev');
      check(restored.role).equals('ADMIN');
      check(restored.provider).equals('local');
    });
  });
}
