@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/hermes/services/hermes_dashboard_cookie_registry.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_http_session.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/fake_hermes_server.dart';
import 'support/null_sink.dart';

/// A Desktop Gateway's dashboard, as far as its sign-in goes: `/api/auth/me`
/// answers only with the session cookie, and rotates it.
final class _FakeDashboard {
  _FakeDashboard._(this._server);

  final HttpServer _server;
  final List<String?> cookies = [];

  /// When set, a signed-in `/api/auth/me` check waits for it, after
  /// completing [arrived]: a test acts while the check is out.
  Completer<void>? hold;
  Completer<void>? arrived;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_FakeDashboard> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeDashboard._(server);
    server.listen((request) async {
      final response = request.response;
      final cookie = request.headers.value(HttpHeaders.cookieHeader);
      fake.cookies.add(cookie);
      response.headers.contentType = ContentType.json;
      switch (request.uri.path) {
        case '/api/status':
          response.write(
            jsonEncode({
              'auth_required': true,
              'auth_flows': ['cookie'],
            }),
          );
        // A dashboard request whose answer rotates the session (held like
        // the sign-in check when [hold] is set).
        case '/api/rotate':
          final wait = fake.hold;
          if (wait != null) {
            fake.arrived?.complete();
            await wait.future;
          }
          response.headers.add(
            HttpHeaders.setCookieHeader,
            'hermes_session_at=rotated-late; HttpOnly; Path=/',
          );
          response.write('{}');
        // A dashboard answer that sets cookies the sign-in did not have.
        case '/api/adds':
          response.headers
            ..add(
              HttpHeaders.setCookieHeader,
              'hermes_session_rt=fresh; HttpOnly; Path=/',
            )
            ..add(HttpHeaders.setCookieHeader, 'dashboard_pref=1; Path=/');
          response.write('{}');
        // An answer that deletes the session cookie.
        case '/api/expire':
          response.headers.add(
            HttpHeaders.setCookieHeader,
            'hermes_session_at=; Max-Age=0; Path=/',
          );
          response.write('{}');
        // An answer that sets more cookies than a sign-in's record holds.
        case '/api/many':
          for (var i = 0; i < 70; i++) {
            response.headers.add(
              HttpHeaders.setCookieHeader,
              'pref_$i=1; Path=/',
            );
          }
          response.write('{}');
        // A gateway's Webapp listener: its session cookies carry the
        // gateway's suffix (`g`), as each gateway home names its own.
        case '/api/gateway':
          final gateway = request.uri.queryParameters['g'] ?? '';
          response.headers
            ..add(
              HttpHeaders.setCookieHeader,
              'hermes_session_at_$gateway=at-${server.port}; HttpOnly; Path=/',
            )
            ..add(
              HttpHeaders.setCookieHeader,
              'hermes_webapp_signin_$gateway=1; Path=/',
            );
          response.write('{}');
        case '/api/auth/me'
            when cookie?.contains('hermes_session_at=good') ?? false:
          final wait = fake.hold;
          if (wait != null) {
            fake.arrived?.complete();
            await wait.future;
          }
          response.headers.add(
            HttpHeaders.setCookieHeader,
            'hermes_session_at=rotated; HttpOnly; Path=/',
          );
          response.write('{"user_id":"demo-user"}');
        default:
          response.statusCode = 401;
          response.write('{"error":"unauthenticated"}');
      }
      await response.close();
    });
    return fake;
  }

  Future<void> close() => _server.close(force: true);
}

/// A Hermes connection's extras: access headers, the memory key, the
/// profile list's fallbacks and the dashboard sign-in the window hands over.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late FakeHermesServer api;
  late _FakeDashboard dashboard;
  late HermesAdminService admin;
  late HermesService hermes;

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('hermes-extras-test');
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    api = await FakeHermesServer.start();
    dashboard = await _FakeDashboard.start();
    final events = EventBus();
    hermes = HermesService(runtime.container, events: events);
    admin = HermesAdminService(
      runtime.container,
      events: events,
      hermes: hermes,
      dashboardCookies: runtime.dashboardCookies,
    );
  });

  tearDownAll(() async {
    admin.dispose();
    await api.close();
    await dashboard.close();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  HermesConnectionDto row(HermesConnections list, String id) =>
      list.connections.firstWhere((c) => c.id == id);

  /// An API server connection of the test's own: no test needs another's.
  Future<String> apiConnection(String name) async =>
      (await admin.saveConnection(
        HermesConnectionEdit(name: name, baseUrl: api.baseUrl, apiKey: api.key),
      )).savedId!;

  test('access headers and the memory key are kept, never shown', () async {
    var list = await admin.saveConnection(
      HermesConnectionEdit(
        baseUrl: api.baseUrl,
        apiKey: api.key,
        accessHeaders: const [
          HermesAccessHeaderEdit(
            name: 'CF-Access-Client-Id',
            value: 'demo.access',
          ),
          HermesAccessHeaderEdit(name: 'X-Gate', value: 'first-secret'),
        ],
        memoryKey: 'demo-memory',
      ),
    );
    final id = list.savedId!;
    var saved = row(list, id);
    expect(saved.accessHeaderNames, ['CF-Access-Client-Id', 'X-Gate']);
    expect(saved.hasMemoryKey, isTrue);
    expect(jsonEncode(list.toJson()), isNot(contains('first-secret')));

    // A test sends them: the headers, and the memory key on a turn's
    // session header.
    api.requestHeaders.clear();
    expect(
      (await admin.testConnection(
        HermesConnectionEdit(id: id, baseUrl: api.baseUrl),
      )).ok,
      isTrue,
    );
    expect(api.requestHeaders, isNotEmpty);
    expect(api.requestHeaders.last['cf-access-client-id'], 'demo.access');
    expect(api.requestHeaders.last['x-gate'], 'first-secret');

    // Renamed without its value: the saved value goes with the new name;
    // one removed is gone.
    list = await admin.saveConnection(
      HermesConnectionEdit(
        id: id,
        baseUrl: api.baseUrl,
        accessHeaders: const [
          HermesAccessHeaderEdit(name: 'X-Gateway', savedName: 'X-Gate'),
        ],
      ),
    );
    saved = row(list, id);
    expect(saved.accessHeaderNames, ['X-Gateway']);
    api.requestHeaders.clear();
    await admin.testConnection(
      HermesConnectionEdit(id: id, baseUrl: api.baseUrl),
    );
    expect(api.requestHeaders.last['x-gateway'], 'first-secret');
    expect(api.requestHeaders.last.containsKey('cf-access-client-id'), isFalse);

    // Left out, they stay; the memory key cleared.
    list = await admin.saveConnection(
      HermesConnectionEdit(id: id, baseUrl: api.baseUrl, memoryKey: ''),
    );
    expect(row(list, id).accessHeaderNames, ['X-Gateway']);
    expect(row(list, id).hasMemoryKey, isFalse);
  });

  test('a header the core refuses names the issue and the header', () async {
    final id = await apiConnection('Refused headers');
    for (final (headers, issue) in [
      (const [HermesAccessHeaderEdit(name: 'Cookie', value: 'x')], 'reserved'),
      (const [HermesAccessHeaderEdit(name: 'X A', value: 'x')], 'invalidName'),
      (
        const [
          HermesAccessHeaderEdit(name: 'X-A', value: '1'),
          HermesAccessHeaderEdit(name: 'x-a', value: '2'),
        ],
        'duplicate',
      ),
      (const [HermesAccessHeaderEdit(name: 'X-New')], 'invalidValue'),
    ]) {
      await expectLater(
        admin.saveConnection(
          HermesConnectionEdit(
            id: id,
            baseUrl: api.baseUrl,
            accessHeaders: headers,
          ),
        ),
        throwsA(
          isA<RpcError>()
              .having((e) => e.args['reason'], 'reason', 'accessHeader')
              .having((e) => e.args['issue'], 'issue', issue),
        ),
      );
    }
    // A test is refused the same way, not reported unreachable.
    await expectLater(
      admin.testConnection(
        HermesConnectionEdit(
          id: id,
          baseUrl: api.baseUrl,
          accessHeaders: const [
            HermesAccessHeaderEdit(name: 'Host', value: 'x'),
          ],
        ),
      ),
      throwsA(
        isA<RpcError>().having((e) => e.args['header'], 'header', 'Host'),
      ),
    );
  });

  test('saved header values never follow a connection elsewhere', () async {
    final id = await apiConnection('Moved headers');
    await admin.saveConnection(
      HermesConnectionEdit(
        id: id,
        baseUrl: api.baseUrl,
        accessHeaders: const [
          HermesAccessHeaderEdit(name: 'X-Gateway', value: 'gateway-value'),
        ],
      ),
    );
    final other = await FakeHermesServer.start();
    addTearDown(other.close);
    final moved = await admin.saveConnection(
      HermesConnectionEdit(
        id: id,
        baseUrl: other.baseUrl,
        apiKey: other.key,
        accessHeaders: const [
          HermesAccessHeaderEdit(name: 'X-Gateway'),
          HermesAccessHeaderEdit(name: 'X-Typed', value: 'typed-here'),
        ],
      ),
    );
    expect(row(moved, id).accessHeaderNames, ['X-Typed']);
  });

  test('a profile list that cannot load says why', () async {
    expect(
      (await admin.profiles(
        const HermesConnectionEdit(baseUrl: '', mode: 'desktop'),
      )).issue,
      'noUrl',
    );
    expect(
      (await admin.profiles(
        const HermesConnectionEdit(
          baseUrl: 'http://gateway.example:8642',
          mode: 'desktop',
          legacyToken: 'demo-token',
        ),
      )).issue,
      'testFirst',
    );
    // Nothing listens there.
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    final unreachable = await admin.profiles(
      HermesConnectionEdit(
        baseUrl: 'http://127.0.0.1:$port',
        mode: 'desktop',
        legacyToken: 'demo-token',
      ),
    );
    expect(unreachable.issue, 'signInFirst');
    expect(unreachable.profiles, isEmpty);
  });

  test('toolsets and skills need a Desktop Gateway', () async {
    final id = await apiConnection('Toolsets');
    final now = (await admin.activate(id)).connection;
    expect(now, isNotNull);
    // A change names the connection it is for: none, or another, is
    // refused before anything is asked of the gateway.
    await expectLater(
      admin.setToolset(const HermesToolsetToggle(name: 'web', enabled: false)),
      throwsA(
        isA<RpcError>().having(
          (e) => e.args['reason'],
          'reason',
          'connectionRequired',
        ),
      ),
    );
    await expectLater(
      admin.reloadSkills(HermesConnectionRef(connection: '$now-before')),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
    );
    await expectLater(
      admin.setToolset(
        HermesToolsetToggle(name: 'web', enabled: false, connection: now),
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.unsupported,
        ),
      ),
    );
    await expectLater(
      admin.reloadSkills(HermesConnectionRef(connection: now)),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.unsupported,
        ),
      ),
    );
  });

  test('a dashboard sign-in is kept once the dashboard accepts it', () async {
    final saved = await admin.saveConnection(
      HermesConnectionEdit(
        name: 'Dashboard gateway',
        baseUrl: dashboard.baseUrl,
        mode: 'desktop',
        desktopAuthKind: 'dashboardCookie',
      ),
    );
    final id = saved.savedId!;
    final now = (await admin.activate(id)).connection;

    // Named for no connection, or another than the one in use: refused.
    await expectLater(
      admin.dashboardStart(HermesDashboardStart(id: id)),
      throwsA(
        isA<RpcError>().having(
          (e) => e.args['reason'],
          'reason',
          'connectionRequired',
        ),
      ),
    );
    await expectLater(
      admin.dashboardComplete(
        HermesDashboardCookies(id: id, connection: '$now-before'),
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
    );

    final plan = await admin.dashboardStart(
      HermesDashboardStart(id: id, connection: now),
    );
    expect(plan.loginUrl, '${dashboard.baseUrl}/login');
    expect(plan.origin, dashboard.baseUrl);
    expect(plan.supported, isTrue);

    // The sign-in page itself, then a page with a stale session: nothing
    // is kept.
    expect(
      (await admin.dashboardComplete(
        HermesDashboardCookies(id: id, connection: now),
      )).signedIn,
      isFalse,
    );
    final stale = await admin.dashboardComplete(
      HermesDashboardCookies(
        id: id,
        connection: now,
        cookies: const [
          HermesCookieDto(
            name: 'hermes_session_at',
            value: 'stale',
            domain: '127.0.0.1',
          ),
        ],
      ),
    );
    expect(stale.signedIn, isFalse);
    expect(runtime.dashboardCookies.cookies, isEmpty);

    // Signed in: kept (with the session the check rotated), and only the
    // dashboard host's cookies.
    final done = await admin.dashboardComplete(
      HermesDashboardCookies(
        id: id,
        connection: now,
        cookies: const [
          HermesCookieDto(
            name: 'hermes_session_at',
            value: 'good',
            domain: '127.0.0.1',
            httpOnly: true,
          ),
          HermesCookieDto(
            name: 'hermes_session_rt',
            value: 'refresh',
            domain: '127.0.0.1',
            httpOnly: true,
          ),
          HermesCookieDto(
            name: 'idp_session',
            value: 'elsewhere',
            domain: '.idp.example',
          ),
        ],
      ),
    );
    expect(done.signedIn, isTrue);
    expect(row(done.connections!, id).dashboardSignedIn, isTrue);
    final kept = {
      for (final c in runtime.dashboardCookies.cookies) c.name: c.value,
    };
    expect(kept, {
      'hermes_session_at': 'rotated',
      'hermes_session_rt': 'refresh',
    });

    // The connection's own dashboard requests carry them.
    dashboard.cookies.clear();
    await admin.profiles(
      HermesConnectionEdit(
        id: id,
        baseUrl: dashboard.baseUrl,
        mode: 'desktop',
        desktopAuthKind: 'dashboardCookie',
      ),
    );
    expect(
      dashboard.cookies.whereType<String>().any(
        (c) => c.contains('hermes_session_rt=refresh'),
      ),
      isTrue,
    );

    // With access headers this Mac's browser window cannot sign in.
    await admin.saveConnection(
      HermesConnectionEdit(
        id: id,
        baseUrl: dashboard.baseUrl,
        mode: 'desktop',
        desktopAuthKind: 'dashboardCookie',
        accessHeaders: const [
          HermesAccessHeaderEdit(name: 'CF-Access-Client-Id', value: 'x'),
        ],
      ),
    );
    // Saved again, the connection in use is named anew.
    final edited = (await admin.connections()).connection;
    expect(
      (await admin.dashboardStart(
        HermesDashboardStart(id: id, connection: edited),
      )).supported,
      isFalse,
    );
    await admin.saveConnection(
      HermesConnectionEdit(
        id: id,
        baseUrl: dashboard.baseUrl,
        mode: 'desktop',
        desktopAuthKind: 'dashboardCookie',
        accessHeaders: const [],
      ),
    );

    // Sign Out drops what the sign-in recorded.
    await hermes.signOut();
    expect(runtime.dashboardCookies.cookies, isEmpty);
    expect(row(await admin.connections(), id).dashboardSignedIn, isFalse);
  });

  const goodSession = [
    HermesCookieDto(
      name: 'hermes_session_at',
      value: 'good',
      domain: '127.0.0.1',
      httpOnly: true,
    ),
  ];

  Matcher refusedAs(String code) =>
      throwsA(isA<RpcError>().having((e) => e.code, 'code', code));

  /// A dashboard connection saved and put in use; its daemon name.
  Future<({String id, String? connection})> dashboardInUse(String name) async {
    final saved = await admin.saveConnection(
      HermesConnectionEdit(
        name: name,
        baseUrl: dashboard.baseUrl,
        mode: 'desktop',
        desktopAuthKind: 'dashboardCookie',
      ),
    );
    final id = saved.savedId!;
    return (id: id, connection: (await admin.activate(id)).connection);
  }

  /// Holds the dashboard's next signed-in check; completes once it is out.
  Future<void> holdCheck() {
    dashboard.hold = Completer<void>();
    dashboard.arrived = Completer<void>();
    return dashboard.arrived!.future;
  }

  void releaseCheck() {
    dashboard.hold?.complete();
    dashboard.hold = null;
    dashboard.arrived = null;
  }

  test('a dashboard sign-in is only for the connection in use', () async {
    final inUse = await dashboardInUse('Gateway in use');
    final other = await admin.saveConnection(
      HermesConnectionEdit(
        name: 'Gateway not in use',
        baseUrl: dashboard.baseUrl,
        mode: 'desktop',
        desktopAuthKind: 'dashboardCookie',
      ),
    );
    final otherId = other.savedId!;
    expect(row(other, otherId).active, isFalse);

    await expectLater(
      admin.dashboardStart(
        HermesDashboardStart(id: otherId, connection: inUse.connection),
      ),
      refusedAs(ConduitErrorCodes.sessionExpired),
    );
    await expectLater(
      admin.dashboardComplete(
        HermesDashboardCookies(
          id: otherId,
          connection: inUse.connection,
          cookies: goodSession,
        ),
      ),
      refusedAs(ConduitErrorCodes.sessionExpired),
    );
    expect(runtime.dashboardCookies.cookies, isEmpty);
  });

  test('a clear while the dashboard checks a sign-in keeps nothing', () async {
    final inUse = await dashboardInUse('Gateway cleared');
    final out = holdCheck();
    final completing = admin.dashboardComplete(
      HermesDashboardCookies(
        id: inUse.id,
        connection: inUse.connection,
        cookies: goodSession,
      ),
    );
    await out;
    // What a Sign Out or a disconnect asks of the cookie store.
    await runtime.dashboardCookies.clearForOrigin(dashboard.baseUrl);
    releaseCheck();
    expect((await completing).signedIn, isFalse);
    expect(runtime.dashboardCookies.cookies, isEmpty);
    expect(row(await admin.connections(), inUse.id).dashboardSignedIn, isFalse);
  });

  test('a switch while the dashboard checks a sign-in keeps nothing', () async {
    final inUse = await dashboardInUse('Gateway left');
    final next = await admin.saveConnection(
      HermesConnectionEdit(name: 'Next', baseUrl: api.baseUrl, apiKey: api.key),
    );
    final out = holdCheck();
    final completing = admin.dashboardComplete(
      HermesDashboardCookies(
        id: inUse.id,
        connection: inUse.connection,
        cookies: goodSession,
      ),
    );
    await out;
    await admin.activate(next.savedId!);
    releaseCheck();
    await expectLater(completing, refusedAs(ConduitErrorCodes.sessionExpired));
    expect(runtime.dashboardCookies.cookies, isEmpty);
  });

  test('a sign-in window closed during the check keeps nothing', () async {
    final inUse = await dashboardInUse('Gateway window closed');
    HermesDashboardCookies page() => HermesDashboardCookies(
      id: inUse.id,
      connection: inUse.connection,
      cookies: goodSession,
      attempt: 'dashboard-closed-1',
    );
    final out = holdCheck();
    final completing = admin.dashboardComplete(page());
    await out;
    // The window closes while the dashboard is asked.
    expect(
      (await admin.dashboardCancel(
        const HermesDashboardCancel(attempt: 'dashboard-closed-1'),
      )).cancelled,
      isTrue,
    );
    releaseCheck();
    expect((await completing).signedIn, isFalse);
    expect(runtime.dashboardCookies.cookies, isEmpty);
    // A page it loaded later keeps nothing either.
    expect((await admin.dashboardComplete(page())).signedIn, isFalse);
    expect(runtime.dashboardCookies.cookies, isEmpty);
  });

  test('a sign-in that cannot be saved says so and keeps nothing', () async {
    final inUse = await dashboardInUse('Gateway unsaved');
    final store = await DaemonHermesDashboardCookies.open(_FailingStore());
    final root = Uri.parse(dashboard.baseUrl);
    await expectLater(
      store.adopt(root, const [
        HermesDashboardCookie(
          name: 'hermes_session_at',
          value: 'good',
          domain: '127.0.0.1',
        ),
      ], accessHeaders: const {}),
      throwsA(isA<FileSystemException>()),
    );
    expect(store.cookies, isEmpty);
    expect(store.hasSession(dashboard.baseUrl), isFalse);
    await admin.deleteConnection(inUse.id);
  });

  const signedInCookie = HermesDashboardCookie(
    name: 'hermes_session_at',
    value: 'good',
    domain: '127.0.0.1',
  );

  /// A cookie store of its own on [secure], signed in to the dashboard.
  Future<DaemonHermesDashboardCookies> signedInStore(
    SecureKeyValueStore secure,
  ) async {
    final store = await DaemonHermesDashboardCookies.open(secure);
    expect(
      await store.adopt(Uri.parse(dashboard.baseUrl), const [
        signedInCookie,
      ], accessHeaders: const {}),
      isTrue,
    );
    return store;
  }

  test('a purge whose write fails says so, and is written later', () async {
    final secure = _FailingStore()..failing = false;
    final store = await signedInStore(secure);
    secure.failing = true;
    expect(await store.clearForOrigin(dashboard.baseUrl), isFalse);
    // Out of the jar now, but the secure store still holds it.
    expect(store.cookies, isEmpty);
    expect(
      (await DaemonHermesDashboardCookies.open(secure)).cookies,
      isNotEmpty,
    );

    // Asked again, the purge writes again.
    secure.failing = false;
    expect(await store.clearForOrigin(dashboard.baseUrl), isTrue);
    expect((await DaemonHermesDashboardCookies.open(secure)).cookies, isEmpty);

    // A full purge that fails is finished by the next auth surface.
    final again = await signedInStore(secure);
    secure.failing = true;
    expect(await again.clearAll(), isFalse);
    secure.failing = false;
    expect(await again.completePendingClear(), isTrue);
    expect((await DaemonHermesDashboardCookies.open(secure)).cookies, isEmpty);
  });

  test(
    'a full purge empties the jar and stops a sign-in being checked',
    () async {
      final secure = InMemorySecureKeyValueStore();
      final store = await signedInStore(secure);
      expect(await store.clearAll(), isTrue);
      expect(store.cookies, isEmpty);
      expect(
        (await DaemonHermesDashboardCookies.open(secure)).cookies,
        isEmpty,
      );

      final out = holdCheck();
      final adopting = store.adopt(Uri.parse(dashboard.baseUrl), const [
        signedInCookie,
      ], accessHeaders: const {});
      await out;
      expect(await store.clearAll(), isTrue);
      releaseCheck();
      expect(await adopting, isFalse);
      expect(store.cookies, isEmpty);
    },
  );

  /// A dashboard request of [store]'s bridge whose answer rotates the
  /// session, held at the dashboard until [releaseCheck].
  Future<Future<Object?>> rotatingRequest(
    DaemonHermesDashboardCookies store,
  ) async {
    final root = Uri.parse(dashboard.baseUrl);
    final bridge = store.bridge(root: root, accessHeaders: const {});
    final out = holdCheck();
    final answer = bridge
        .request('GET', root.resolve('/api/rotate'))
        .then<Object?>((a) => a, onError: (Object e) => e);
    await out;
    return answer;
  }

  test('a purge over cookies that could not be read clears the store '
      'before it says so, and only its own dashboard\'s', () async {
    final other = await _FakeDashboard.start();
    addTearDown(other.close);
    final secure = _UnreadableStore();
    final signedIn = await signedInStore(secure);
    final otherRoot = Uri.parse(other.baseUrl);
    await signedIn
        .bridge(root: otherRoot, accessHeaders: const {})
        .request('GET', otherRoot.resolve('/api/gateway?g=fedcba9876543210'));
    // Opened while the secure store refuses reads: the jar is empty, but
    // the store still holds both sessions.
    secure.unreadable = true;
    final store = await DaemonHermesDashboardCookies.open(secure);
    expect(store.cookies, isEmpty);

    // Still unreadable: not cleared, and the store is left as it was.
    final before = await secure.peek();
    expect(await store.clearForOrigin(dashboard.baseUrl), isFalse);
    expect(await secure.peek(), before);

    // Readable again: this dashboard's cookies go, the other's stay.
    secure.unreadable = false;
    expect(await store.clearForOrigin(dashboard.baseUrl), isTrue);
    final reopened = await DaemonHermesDashboardCookies.open(secure);
    expect(
      reopened.cookies.map((c) => c.name),
      unorderedEquals(<String>[
        'hermes_session_at_fedcba9876543210',
        'hermes_webapp_signin_fedcba9876543210',
      ]),
    );
    expect(reopened.hasSession(other.baseUrl), isTrue);
    expect(reopened.hasSession(dashboard.baseUrl), isFalse);
  });

  test('a stored cookie that cannot be read is dropped, and the rest '
      'load', () async {
    final origin = hermesDashboardCookieOriginKey(dashboard.baseUrl)!;
    final secure = _UnreadableStore()
      ..seed({
        origin: [
          signedInCookie.toJson(),
          {
            ...signedInCookie.toJson(),
            'name': 'pref',
            // Past the last instant a DateTime holds.
            'expires': 9000000000000000,
          },
          'nonsense',
        ],
        'http://127.0.0.1:1': 'not a jar',
      });
    final store = await DaemonHermesDashboardCookies.open(secure);
    expect(store.cookies.map((c) => c.name), ['hermes_session_at']);
    expect(store.hasSession(dashboard.baseUrl), isTrue);
    // Written again without what could not be read.
    expect(jsonDecode((await secure.peek())!), {
      origin: [signedInCookie.toJson()],
    });
  });

  test('a sign-in whose window closed while the store was being read '
      'keeps nothing', () async {
    final secure = _UnreadableStore()..unreadable = true;
    final store = await DaemonHermesDashboardCookies.open(secure);
    final release = Completer<void>();
    secure
      ..unreadable = false
      ..holdRead = release
      ..readArrived = Completer<void>();
    var wanted = true;
    final adopting = store.adopt(
      Uri.parse(dashboard.baseUrl),
      const [signedInCookie],
      accessHeaders: const {},
      wanted: () => wanted,
    );
    // Fails at once, not at the runner's timeout, if the sign-in ended
    // before its commit read the store.
    await Future.any([
      secure.readArrived!.future,
      adopting.then((_) => fail('the sign-in ended before the store read')),
    ]);
    // The window closes while the commit waits for the store.
    wanted = false;
    release.complete();
    expect(await adopting, isFalse);
    expect(store.cookies, isEmpty);
    expect(await secure.peek(), isNull);
  });

  test('while the store cannot be read, a dashboard request is refused and '
      'takes nothing in; once it reads, its cookies are served', () async {
    final secure = _UnreadableStore();
    await signedInStore(secure);
    final stored = await secure.peek();
    final root = Uri.parse(dashboard.baseUrl);

    secure.unreadable = true;
    final store = await DaemonHermesDashboardCookies.open(secure);
    final bridge = store.bridge(root: root, accessHeaders: const {});
    final sent = dashboard.cookies.length;
    await expectLater(
      bridge.request('GET', root.resolve('/api/rotate')),
      throwsA(isA<StateError>()),
    );
    expect(dashboard.cookies, hasLength(sent));
    expect(store.cookies, isEmpty);
    expect(store.hasSession(dashboard.baseUrl), isFalse);

    // Readable again: the request that finds it unread has it read, and the
    // store's cookies are served from then on, as stored.
    secure.unreadable = false;
    await expectLater(
      bridge.request('GET', root.resolve('/api/status')),
      throwsA(isA<StateError>()),
    );
    await bridge.request('GET', root.resolve('/api/status'));
    expect(dashboard.cookies.last, contains('hermes_session_at=rotated'));
    expect(await secure.peek(), stored);
  });

  test('a clear removes every cookie its dashboard\'s answers set, past '
      'any count', () async {
    final secure = InMemorySecureKeyValueStore();
    final store = await signedInStore(secure);
    final root = Uri.parse(dashboard.baseUrl);
    await store
        .bridge(root: root, accessHeaders: const {})
        .request('GET', root.resolve('/api/many'));
    expect(store.cookies.length, greaterThan(70));
    expect(await store.clearForOrigin(dashboard.baseUrl), isTrue);
    expect(store.cookies, isEmpty);
    expect((await DaemonHermesDashboardCookies.open(secure)).cookies, isEmpty);
  });

  test('two dashboards on one host keep their cookies apart', () async {
    final other = await _FakeDashboard.start();
    addTearDown(other.close);
    final secure = InMemorySecureKeyValueStore();
    final store = await DaemonHermesDashboardCookies.open(secure);
    final a = Uri.parse(dashboard.baseUrl);
    final b = Uri.parse(other.baseUrl);
    final bridgeA = store.bridge(root: a, accessHeaders: const {});
    final bridgeB = store.bridge(root: b, accessHeaders: const {});
    await bridgeA.request('GET', a.resolve('/api/gateway?g=0123456789abcdef'));
    await bridgeB.request('GET', b.resolve('/api/gateway?g=fedcba9876543210'));

    // Each dashboard is sent its own cookies only.
    await bridgeA.request('GET', a.resolve('/api/status'));
    await bridgeB.request('GET', b.resolve('/api/status'));
    expect(dashboard.cookies.last, contains('0123456789abcdef'));
    expect(dashboard.cookies.last, isNot(contains('fedcba9876543210')));
    expect(other.cookies.last, contains('fedcba9876543210'));
    expect(other.cookies.last, isNot(contains('0123456789abcdef')));

    // Clearing one leaves the other's, in the jar and in the store.
    expect(await store.clearForOrigin(dashboard.baseUrl), isTrue);
    for (final held in [
      store,
      await DaemonHermesDashboardCookies.open(secure),
    ]) {
      expect(
        held.cookies.map((c) => c.name),
        unorderedEquals(<String>[
          'hermes_session_at_fedcba9876543210',
          'hermes_webapp_signin_fedcba9876543210',
        ]),
      );
    }
    await bridgeB.request('GET', b.resolve('/api/status'));
    expect(other.cookies.last, contains('fedcba9876543210'));
  });

  test('cookies saved in the old single-jar form are dropped once, and the '
      'store is written in the new form', () async {
    final secure = InMemorySecureKeyValueStore({
      kHermesDashboardCookiesKey: jsonEncode([signedInCookie.toJson()]),
    });
    final store = await DaemonHermesDashboardCookies.open(secure);
    expect(store.cookies, isEmpty);
    expect(store.hasSession(dashboard.baseUrl), isFalse);
    expect(await secure.read(key: kHermesDashboardCookiesKey), isNull);
    // A sign-in afterwards is kept in the new form.
    expect(
      await store.adopt(Uri.parse(dashboard.baseUrl), const [
        signedInCookie,
      ], accessHeaders: const {}),
      isTrue,
    );
    final stored = jsonDecode(
      (await secure.read(key: kHermesDashboardCookiesKey))!,
    );
    expect(stored, isA<Map<String, dynamic>>());
    expect(
      (await DaemonHermesDashboardCookies.open(secure))
          .hasSession(dashboard.baseUrl),
      isTrue,
    );
  });

  test(
    'cookies a dashboard answer adds are cleared with the sign-in',
    () async {
      final secure = InMemorySecureKeyValueStore();
      final store = await signedInStore(secure);
      final root = Uri.parse(dashboard.baseUrl);
      await store
          .bridge(root: root, accessHeaders: const {})
          .request('GET', root.resolve('/api/adds'));
      expect(
        store.cookies.map((c) => c.name),
        containsAll(<String>['hermes_session_rt', 'dashboard_pref']),
      );
      expect(await store.clearForOrigin(dashboard.baseUrl), isTrue);
      expect(store.cookies, isEmpty);
      expect(
        (await DaemonHermesDashboardCookies.open(secure)).cookies,
        isEmpty,
      );
    },
  );

  test('a dashboard answer from before a purge keeps nothing', () async {
    final secure = InMemorySecureKeyValueStore();
    final store = await signedInStore(secure);
    final answer = await rotatingRequest(store);
    expect(await store.clearForOrigin(dashboard.baseUrl), isTrue);
    releaseCheck();
    await answer;
    expect(store.cookies, isEmpty);
    expect((await DaemonHermesDashboardCookies.open(secure)).cookies, isEmpty);
  });

  test('a dashboard answer from before a failed purge keeps nothing', () async {
    final secure = _FailingStore()..failing = false;
    final store = await signedInStore(secure);
    final answer = await rotatingRequest(store);
    secure.failing = true;
    expect(await store.clearForOrigin(dashboard.baseUrl), isFalse);
    releaseCheck();
    await answer;
    expect(store.cookies, isEmpty);
    // The purge written again leaves nothing the answer brought.
    secure.failing = false;
    expect(await store.completePendingClear(), isTrue);
    expect((await DaemonHermesDashboardCookies.open(secure)).cookies, isEmpty);
  });

  /// A dashboard request of [store]'s bridge whose answer rotates the
  /// session; settles to its answer or its error.
  Future<Object?> rotateNow(DaemonHermesDashboardCookies store) {
    final root = Uri.parse(dashboard.baseUrl);
    return store
        .bridge(root: root, accessHeaders: const {})
        .request('GET', root.resolve('/api/rotate'))
        .then<Object?>((a) => a, onError: (Object e) => e);
  }

  for (final full in [true, false]) {
    test(
      'a request made while a purge waits reads nothing (full: $full)',
      () async {
        final secure = _HeldStore();
        final store = await signedInStore(secure);
        // An earlier write holds the store's turn: a rotation being saved.
        final writing = secure.holdNext();
        final first = rotateNow(store);
        await writing;
        final purge = full
            ? store.clearAll()
            : store.clearForOrigin(dashboard.baseUrl);
        // Asked while the purge waits behind that write.
        final out = holdCheck();
        final late = rotateNow(store);
        await Future.any<Object?>([out, late]);
        secure.release();
        expect(await purge, isTrue);
        releaseCheck();
        await late;
        await first;
        expect(store.cookies, isEmpty);
        expect(
          (await DaemonHermesDashboardCookies.open(secure)).cookies,
          isEmpty,
        );
      },
    );
  }
}

/// A secure store whose writes fail while [failing] (a Keychain that
/// refuses).
final class _FailingStore extends InMemorySecureKeyValueStore {
  bool failing = true;

  @override
  Future<void> write({required String key, required String? value}) => failing
      ? Future<void>.error(const FileSystemException('refused'))
      : super.write(key: key, value: value);
}

/// A secure store whose reads fail while [unreadable] (a locked Keychain).
final class _UnreadableStore extends InMemorySecureKeyValueStore {
  bool unreadable = false;

  /// When set, the next read waits for it, after completing [readArrived].
  Completer<void>? holdRead;
  Completer<void>? readArrived;

  /// What the store holds, read past [unreadable].
  Future<String?> peek() => super.read(key: kHermesDashboardCookiesKey);

  /// Stores [jars] as written, without a daemon.
  void seed(Object jars) => unawaited(
    super.write(key: kHermesDashboardCookiesKey, value: jsonEncode(jars)),
  );

  @override
  Future<String?> read({required String key}) async {
    final wait = holdRead;
    if (wait != null) {
      holdRead = null;
      readArrived?.complete();
      await wait.future;
    }
    if (unreadable) throw const FileSystemException('locked');
    return super.read(key: key);
  }
}

/// A secure store whose next write waits for [release] once [holdNext]
/// asked for it.
final class _HeldStore extends InMemorySecureKeyValueStore {
  Completer<void>? _held;
  Completer<void>? _started;

  /// Holds the next write; completes once it started.
  Future<void> holdNext() {
    _held = Completer<void>();
    _started = Completer<void>();
    return _started!.future;
  }

  void release() => _waiting?.complete();

  /// The write being held, until [release].
  Completer<void>? _waiting;

  @override
  Future<void> write({required String key, required String? value}) async {
    final held = _held;
    if (held != null) {
      _held = null;
      _waiting = held;
      _started?.complete();
      await held.future;
    }
    await super.write(key: key, value: value);
  }
}
