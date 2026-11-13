@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

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
        case '/api/auth/me'
            when cookie?.contains('hermes_session_at=good') ?? false:
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
    final list = await admin.connections();
    final id = list.connections.single.id;
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
    final list = await admin.connections();
    final id = list.connections.single.id;
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
    // Back where it was, for the tests after.
    await admin.saveConnection(
      HermesConnectionEdit(id: id, baseUrl: api.baseUrl, apiKey: api.key),
    );
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
    final now = (await admin.connections()).connection;
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
}
