@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
