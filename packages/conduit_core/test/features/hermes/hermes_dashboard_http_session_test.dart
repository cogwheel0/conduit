import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_http_session.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/fake.dart';
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
      // An expiry past what a DateTime holds, or not a whole number, is not
      // a cookie; none at all is a session cookie.
      for (final expires in <Object>[9000000000000000, '1000', 1.5]) {
        check(
          because: '$expires',
          HermesDashboardCookie.fromJson({
            'name': 'pref',
            'value': '1',
            'domain': 'gateway.example',
            'expires': expires,
          }),
        ).isNull();
      }
      check(
        HermesDashboardCookie.fromJson({
          'name': 'pref',
          'value': '1',
          'domain': 'gateway.example',
        })?.expires,
      ).isNull();
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

  group('one request at a time', () {
    final root = Uri.parse('https://hermes.example.test');
    late _Net net;
    late HermesDashboardCookieJar jar;

    setUp(() {
      net = _Net();
      jar = HermesDashboardCookieJar([
        const HermesDashboardCookie(
          name: 'hermes_session_at',
          value: 'kept',
          domain: 'hermes.example.test',
        ),
      ]);
    });

    HermesDashboardHttpSession session({
      Future<void> Function()? onCookiesChanged,
    }) => HermesDashboardHttpSession(
      root: root,
      accessHeaders: const {},
      jar: jar,
      onCookiesChanged: onCookiesChanged,
      httpClient: net.client,
      requestTimeout: const Duration(seconds: 30),
    );

    Uri at(String path) => root.replace(path: path);

    test('a request past its deadline is ended before the next one, and its '
        'late answer keeps no cookie', () {
      fakeAsync((async) {
        final slow = net.answers['/api/slow'] = Completer<_Answer>();
        final dashboard = session();
        Object? timedOut;
        dashboard
            .request('POST', at('/api/slow'))
            .then(
              (_) {},
              onError: (Object e) {
                timedOut = e;
              },
            );
        final next = dashboard.request('GET', at('/api/next'));
        async.flushMicrotasks();
        check(net.log).deepEquals(['open /api/slow', 'send /api/slow']);

        async.elapse(const Duration(seconds: 30));
        check(timedOut).isA<TimeoutException>();
        // Cut off first; only then does the next one go out.
        check(net.log).deepEquals([
          'open /api/slow',
          'send /api/slow',
          'abort /api/slow',
          'client closed',
          'open /api/next',
          'send /api/next',
          'client closed',
        ]);
        slow.complete(const _Answer(cookie: 'hermes_session_at=late; Path=/'));
        async.flushMicrotasks();
        check(next).completes();
        check(jar.cookieHeader(at('/api/x'))).equals('hermes_session_at=kept');
        dashboard.close();
        async.flushMicrotasks();
      });
    });

    for (final stall in [
      'its connection never opens',
      'saving its cookies '
          'never ends',
    ]) {
      test('a request whose $stall still times out at its deadline, and the '
          'next one goes out a short while after', () {
        fakeAsync((async) {
          if (stall == 'its connection never opens') {
            net.openGates['/api/stuck'] = Completer<void>();
          } else {
            net.answers['/api/stuck'] = Completer<_Answer>()
              ..complete(const _Answer(cookie: 'hermes_session_at=x; Path=/'));
          }
          final dashboard = session(
            onCookiesChanged: () => Completer<void>().future,
          );
          Object? timedOut;
          dashboard
              .request('POST', at('/api/stuck'))
              .then(
                (_) {},
                onError: (Object e) {
                  timedOut = e;
                },
              );
          var nextDone = false;
          dashboard
              .request('GET', at('/api/next'))
              .then((_) => nextDone = true);
          async.flushMicrotasks();

          async.elapse(const Duration(seconds: 30));
          check(timedOut).isA<TimeoutException>();
          check(net.log).not((it) => it.contains('open /api/next'));

          async.elapse(const Duration(seconds: 5));
          check(net.log).contains('open /api/next');
          check(nextDone).isTrue();
          var closed = false;
          dashboard.close().then((_) => closed = true);
          async.flushMicrotasks();
          check(closed).isTrue();
        });
      });
    }

    test('a request is withdrawn up to the moment it is sent', () {
      fakeAsync((async) {
        final opening = net.openGates['/api/run'] = Completer<void>();
        final dashboard = session();
        var withdrawn = false;
        Object? outcome;
        dashboard
            .request('POST', at('/api/run'), beforeSend: () => !withdrawn)
            .then(
              (_) {},
              onError: (Object e) {
                outcome = e;
              },
            );
        async.flushMicrotasks();
        // A Stop overtakes it while its connection opens.
        withdrawn = true;
        dashboard.request('POST', at('/api/stop'), urgent: true);
        async.flushMicrotasks();
        opening.complete();
        async.flushMicrotasks();

        check(outcome).isA<HermesDashboardRequestWithdrawn>();
        check(net.log).not((it) => it.contains('send /api/run'));
        check(net.log).contains('abort /api/run');
        dashboard.close();
        async.flushMicrotasks();
      });
    });

    test('closing waits for an urgent request, and takes no new ones', () {
      fakeAsync((async) {
        final stop = net.answers['/api/stop'] = Completer<_Answer>();
        final dashboard = session();
        final stopped = dashboard.request(
          'POST',
          at('/api/stop'),
          urgent: true,
        );
        async.flushMicrotasks();
        var closed = false;
        dashboard.close().then((_) => closed = true);
        async.flushMicrotasks();
        check(closed).isFalse();
        check(dashboard.request('GET', at('/api/after'))).throws<StateError>();

        stop.complete(const _Answer(cookie: 'hermes_session_at=fresh; Path=/'));
        async.flushMicrotasks();
        check(stopped).completes();
        check(closed).isTrue();
        check(jar.cookieHeader(at('/api/x'))).equals('hermes_session_at=fresh');
        check(net.log).not((it) => it.contains('open /api/after'));
        async.flushMicrotasks();
      });
    });

    test('an answer that is refused or not kept lets go of its connection', () {
      fakeAsync((async) {
        net.answers['/api/huge'] = Completer<_Answer>()
          ..complete(const _Answer(contentLength: 100 << 20));
        net.answers['/api/cookie'] = Completer<_Answer>()
          ..complete(const _Answer(cookie: 'hermes_session_at=new; Path=/'));
        final dashboard = session(
          onCookiesChanged: () async => throw StateError('disk full'),
        );
        check(dashboard.request('GET', at('/api/huge'))).throws<StateError>();
        check(dashboard.request('GET', at('/api/cookie'))).throws<StateError>();
        async.flushMicrotasks();

        // Neither body is read to its end; each connection is closed.
        check(net.drained).isEmpty();
        check(net.log.where((line) => line == 'client closed').length)
            .equals(2);
        dashboard.close();
        async.flushMicrotasks();
      });
    });
  });
}

/// What the fake dashboard answers.
final class _Answer {
  const _Answer({this.cookie, this.contentLength = -1});

  int get status => 200;
  final String? cookie;
  final int contentLength;
}

/// The network a fake [HttpClient] reaches: what each request went through,
/// in order, with the opening of a connection and an answer held back by
/// path when the test says.
final class _Net {
  final log = <String>[];
  final openGates = <String, Completer<void>>{};
  final answers = <String, Completer<_Answer>>{};
  final drained = <String>[];

  HttpClient client() => _Client(this);
}

final class _Client extends Fake implements HttpClient {
  _Client(this.net);

  final _Net net;
  bool _closed = false;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    net.log.add('open ${url.path}');
    await net.openGates[url.path]?.future;
    if (_closed) throw const SocketException('closed');
    return _Request(net, url.path);
  }

  @override
  void close({bool force = false}) {
    if (_closed) return;
    _closed = true;
    net.log.add('client closed');
  }
}

final class _Request extends Fake implements HttpClientRequest {
  _Request(this.net, this.path);

  final _Net net;
  final String path;
  final _answer = Completer<HttpClientResponse>();

  @override
  bool followRedirects = true;

  @override
  final HttpHeaders headers = _Headers();

  @override
  void add(List<int> data) {}

  @override
  Future<HttpClientResponse> close() {
    net.log.add('send $path');
    final pending = net.answers[path]?.future ?? Future.value(const _Answer());
    pending.then((answer) {
      if (!_answer.isCompleted) _answer.complete(_Response(net, path, answer));
    });
    return _answer.future;
  }

  @override
  Future<HttpClientResponse> get done => _answer.future;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    net.log.add('abort $path');
    if (!_answer.isCompleted) {
      _answer.completeError(const HttpException('aborted'));
    }
  }
}

final class _Headers extends Fake implements HttpHeaders {
  _Headers([this.cookies]);

  final List<String>? cookies;

  @override
  ContentType? contentType;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  List<String>? operator [](String name) =>
      name == HttpHeaders.setCookieHeader ? cookies : null;
}

final class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.net, this.path, this.answer)
    : headers = _Headers([?answer.cookie]);

  final _Net net;
  final String path;
  final _Answer answer;

  @override
  final HttpHeaders headers;

  @override
  int get statusCode => answer.status;

  @override
  bool get isRedirect => answer.status >= 300 && answer.status < 400;

  @override
  int get contentLength => answer.contentLength;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    net.drained.add(path);
    return Stream<List<int>>.value(utf8.encode('{}')).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
