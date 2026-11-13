import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_http_session.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 12, 9);

  group('Set-Cookie', () {
    test('keeps the value verbatim and reads the attributes', () {
      final cookie = parseHermesDashboardSetCookie(
        'hermes_session_at="abc=="; HttpOnly; Max-Age=60; Path=/; '
        'SameSite=lax',
        Uri.parse('http://127.0.0.1:8642/auth/password-login'),
        now: now,
      )!;
      check(cookie.name).equals('hermes_session_at');
      check(cookie.value).equals('"abc=="');
      check(cookie.domain).equals('127.0.0.1');
      check(cookie.path).equals('/');
      check(cookie.httpOnly).isTrue();
      check(cookie.hostOnly).isTrue();
      check(cookie.expires).equals(now.add(const Duration(seconds: 60)));
    });

    test('a past expiry, a foreign domain and a default path', () {
      final url = Uri.parse('https://chat.example.org/hermes/auth/logout');
      check(
        parseHermesDashboardSetCookie(
          'hermes_session_rt=; Max-Age=0; Path=/',
          url,
          now: now,
        )!.isExpired(now),
      ).isTrue();
      check(parseHermesDashboardSetCookie('x=1; Domain=evil.example', url))
          .isNull();
      final parent = parseHermesDashboardSetCookie(
        'x=1; Domain=.example.org',
        url,
      )!;
      check(parent.hostOnly).isFalse();
      check(parent.domain).equals('example.org');
      check(parent.path).equals('/hermes/auth');
      check(parseHermesDashboardSetCookie('=1', url)).isNull();
    });
  });

  group('jar', () {
    test('sends a cookie where a browser would', () {
      final jar = HermesDashboardCookieJar([
        const HermesDashboardCookie(name: 'a', value: '1', domain: 'h.test'),
        const HermesDashboardCookie(
          name: 'b',
          value: '2',
          domain: 'h.test',
          path: '/api',
        ),
        const HermesDashboardCookie(
          name: 's',
          value: '3',
          domain: 'h.test',
          secure: true,
        ),
        const HermesDashboardCookie(
          name: 'p',
          value: '4',
          domain: 'test',
          hostOnly: false,
        ),
      ]);
      check(jar.cookieHeader(Uri.parse('http://h.test:9/api/status'), now: now))
          .equals('b=2; a=1; p=4');
      check(jar.cookieHeader(Uri.parse('https://h.test/apiary'), now: now))
          .equals('a=1; s=3; p=4');
      check(jar.cookieHeader(Uri.parse('http://other.example/'))).isNull();
      check(jar.identitiesFor('h.test', now: now)).length.equals(4);
      check(jar.identitiesFor('x.h.test', now: now)).length.equals(1);
    });

    test('a rotated cookie replaces, an expired one deletes', () {
      final url = Uri.parse('http://127.0.0.1:8642/api/status');
      final jar = HermesDashboardCookieJar();
      check(jar.absorb(url, ['hermes_session_at=old; Path=/'], now: now))
          .isTrue();
      check(jar.absorb(url, ['hermes_session_at=new; Path=/'], now: now))
          .isTrue();
      check(jar.cookieHeader(url, now: now)).equals('hermes_session_at=new');
      check(jar.absorb(url, ['hermes_session_at=new; Path=/'], now: now))
          .isFalse();
      check(
        jar.absorb(url, ['hermes_session_at=; Path=/; Max-Age=0'], now: now),
      ).isTrue();
      check(jar.isEmpty).isTrue();
    });

    test('round-trips through JSON', () {
      final jar = HermesDashboardCookieJar([
        HermesDashboardCookie(
          name: 'hermes_session_rt',
          value: '"r"',
          domain: 'gateway.example',
          secure: true,
          httpOnly: true,
          expires: now,
        ),
      ]);
      final back = HermesDashboardCookieJar.fromJson(
        jsonDecode(jsonEncode(jar.toJson())),
      );
      check(back.cookies.single.identity).equals(jar.cookies.single.identity);
      check(back.cookies.single.expires).equals(now);
      check(back.cookies.single.secure).isTrue();
      check(HermesDashboardCookieJar.fromJson('nonsense').isEmpty).isTrue();
    });
  });

  group('session', () {
    late HttpServer server;
    late Uri root;
    final seen = <Map<String, String?>>[];

    setUp(() async {
      seen.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      root = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((request) async {
        seen.add({
          'path': request.uri.path,
          'cookie': request.headers.value(HttpHeaders.cookieHeader),
          'access': request.headers.value('CF-Access-Client-Id'),
          'body': await utf8.decoder.bind(request).join(),
        });
        final response = request.response;
        switch (request.uri.path) {
          case '/api/rotate':
            response.headers.add(
              HttpHeaders.setCookieHeader,
              'hermes_session_at="fresh"; HttpOnly; Path=/',
            );
            response.write('{"ok":true}');
          case '/api/moved':
            response.statusCode = 302;
            response.headers.set(HttpHeaders.locationHeader, '/login');
          case '/auth/logout':
            response.statusCode = 302;
            response.headers.set(HttpHeaders.locationHeader, '/login');
            response.headers.add(
              HttpHeaders.setCookieHeader,
              'hermes_session_at=; Max-Age=0; Path=/',
            );
            response.headers.add(
              HttpHeaders.setCookieHeader,
              'hermes_session_rt=; Max-Age=0; Path=/',
            );
          default:
            response.write('[]');
        }
        await response.close();
      });
    });

    tearDown(() => server.close(force: true));

    HermesDashboardCookieJar signedIn() => HermesDashboardCookieJar([
      const HermesDashboardCookie(
        name: 'hermes_session_at',
        value: '"stale"',
        domain: '127.0.0.1',
      ),
      const HermesDashboardCookie(
        name: 'hermes_session_rt',
        value: '"refresh"',
        domain: '127.0.0.1',
      ),
    ]);

    test(
      'sends the cookies and headers, and keeps a rotated session',
      () async {
        final jar = signedIn();
        var saved = 0;
        final session = HermesDashboardHttpSession(
          root: root,
          accessHeaders: const {'CF-Access-Client-Id': 'client.access'},
          jar: jar,
          onCookiesChanged: () async => saved++,
        );
        final answer = await session.request(
          'POST',
          root.replace(path: '/api/rotate'),
          body: '{"name":"web"}',
        );
        check(answer.status).equals(200);
        check(seen.single['cookie'])
            .equals('hermes_session_at="stale"; hermes_session_rt="refresh"');
        check(seen.single['access']).equals('client.access');
        check(seen.single['body']).equals('{"name":"web"}');
        check(saved).equals(1);
        await session.request('GET', root.replace(path: '/api/tools/toolsets'));
        check(seen.last['cookie'])
            .equals('hermes_session_at="fresh"; hermes_session_rt="refresh"');
        await session.close();
      },
    );

    test('never leaves the dashboard, follows no redirect', () async {
      final session = HermesDashboardHttpSession(
        root: root,
        accessHeaders: const {},
        jar: signedIn(),
      );
      await check(session.request('GET', Uri.parse('http://127.0.0.2:1/api/x')))
          .throws<StateError>();
      await check(session.request('GET', root.replace(path: '/api/moved')))
          .throws<StateError>();
      await check(
        session.request(
          'GET',
          root.replace(path: '/api/x'),
          beforeSend: () => false,
        ),
      ).throws<HermesDashboardRequestWithdrawn>();
      check(seen).length.equals(1);
      await session.close();
    });

    test('a sign-out takes the deletions Hermes sends', () async {
      final jar = signedIn();
      final signedOut = await hermesDashboardHttpSignOut(
        root: root,
        accessHeaders: const {'CF-Access-Client-Id': 'client.access'},
        jar: jar,
      );
      check(signedOut).isTrue();
      check(jar.isEmpty).isTrue();
      check(seen.single['access']).equals('client.access');
    });
  });
}
