import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/services/hermes_push_backend.dart';
import 'package:conduit_core/features/push/services/push_backend.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

const _subscription = PushServerSubscription(
  sid: 'AAAAAAAAAAAAAAAAAAAAAA',
  did: 'device-1',
  endpoint: 'https://relay.test/v1/push/one',
  p256dh: 'BPUBLIC',
  auth: 'AUTH',
  events: ['reply', 'reply_failed', 'cron'],
  label: 'iOS',
  platform: 'ios',
);

void main() {
  group('helpers', () {
    test('the install command pins the commit and names the profile', () {
      check(hermesPluginInstallCommand()).equals(
        'hermes plugins install cogwheel0/conduit-hermes-push --enable'
        ' && hermes gateway restart',
      );
      check(hermesPluginInstallCommand(profile: 'work', ref: 'a' * 40)).equals(
        'hermes -p work plugins install cogwheel0/conduit-hermes-push'
        ' --ref ${'a' * 40} --enable && hermes -p work gateway restart',
      );
      check(hermesPluginInstallCommand(profile: 'default'))
          .not((it) => it.contains(' -p '));
    });

    test('finds the profile and root of an API server URL', () {
      check(HermesApiPushBackend.rootOf('https://h.test/p/work/v1/'))
          .equals('https://h.test/p/work');
      check(hermesApiProfile('https://h.test/p/work')).equals('work');
      check(hermesApiProfile('https://h.test')).isNull();
    });

    test('adds conduit to a job delivery and removes it', () {
      check(hermesDeliverWithConduit(null, notify: true))
          .equals('local,conduit');
      check(hermesDeliverWithConduit('', notify: true)).equals('local,conduit');
      check(hermesDeliverWithConduit('telegram', notify: true))
          .equals('telegram,conduit');
      check(hermesDeliverWithConduit('telegram, conduit', notify: true))
          .equals('telegram,conduit');
      check(hermesDeliverWithConduit('local,conduit', notify: false))
          .equals('local');
      check(hermesDeliverWithConduit('conduit', notify: false)).equals('local');
      check(hermesDeliverIncludesConduit('telegram, conduit')).isTrue();
      check(hermesDeliverIncludesConduit('local')).isFalse();
    });

    test('names push endpoint statuses like Open WebUI does', () {
      check(pushStatusCategory(201)).isNull();
      check(pushStatusCategory(410)).equals('gone');
      check(pushStatusCategory(413)).equals('too_large');
      check(pushStatusCategory(429)).equals('rate_limited');
      check(pushStatusCategory(502)).equals('server_error');
      check(pushStatusCategory(400)).equals('rejected');
      check(pushStatusCategory(0)).equals('network');
    });
  });

  group('API server', () {
    late _Gateway gateway;
    late HermesApiPushBackend backend;

    setUp(() {
      gateway = _Gateway();
      backend = HermesApiPushBackend(
        root: 'https://h.test/p/work',
        dio: Dio(BaseOptions(headers: {'Authorization': 'Bearer key'}))
          ..httpClientAdapter = gateway,
      );
    });

    test('hello: the plugin is ready', () async {
      final probe = await backend.probe();
      check(probe.isReady).isTrue();
      check(probe.pluginVersion).equals('1.0.0');
      final request = gateway.requests.single;
      check(request.uri.toString())
          .equals('https://h.test/p/work/api/platforms/conduit/events');
      check(request.headers['Authorization']).equals('Bearer key');
      check(jsonDecode(request.data as String) as Map)
          .deepEquals({'op': 'hello'});
    });

    test('hello: 503 means the plugin is missing or not loaded', () async {
      gateway.status = 503;
      gateway.code = 'platform_unavailable';
      final probe = await backend.probe();
      check(probe.outcome).equals(PushProbeOutcome.needsHermesPlugin);
      check(probe.hermesInstallCommand).isNotNull().contains('hermes -p work');
      check(probe.canInstallHermesPlugin).isFalse();
    });

    for (final code in [
      'conduit_auth_failed',
      'conduit_api_key_unusable',
      'conduit_auth_unavailable',
    ]) {
      test('hello: 401 $code is an auth error', () async {
        gateway.status = 401;
        gateway.code = code;
        final probe = await backend.probe();
        check(probe.outcome).equals(PushProbeOutcome.failed);
        check(probe.failure).isNotNull()
          ..has(
            (f) => f.reason,
            'reason',
          ).equals(PushFailureReason.hermesAuthFailed)
          ..has((f) => f.detail, 'detail').equals(code);
      });
    }

    test('hello: a plain 404 means Hermes is too old', () async {
      gateway.status = 404;
      gateway.plainBody = '404: Not Found';
      check((await backend.probe()).outcome)
          .equals(PushProbeOutcome.serverTooOld);
    });

    test('hello: an unreachable server', () async {
      gateway.offline = true;
      final probe = await backend.probe();
      check(probe.outcome).equals(PushProbeOutcome.failed);
      check(probe.failure?.reason).equals(PushFailureReason.serverUnreachable);
    });

    test('subscribe with a test sends both ops and reads the status', () async {
      gateway.pushStatus = 201;
      final dispatch = await backend.subscribe(
        _subscription,
        testNonce: 'nonce-1',
      );
      check(gateway.ops).deepEquals(['subscribe', 'test']);
      check(gateway.bodies.first['sub'] as Map)
          .deepEquals(_subscription.toJson());
      check(gateway.bodies.last).deepEquals({
        'op': 'test',
        'sid': 'AAAAAAAAAAAAAAAAAAAAAA',
        'nonce': 'nonce-1',
      });
      check(dispatch).isNotNull()
        ..has((d) => d.failedAtServer, 'failedAtServer').isFalse()
        ..has((d) => d.diagnostics?.code, 'code').equals(201);
    });

    test('a test the endpoint refused fails at the server', () async {
      gateway.pushStatus = 410;
      final dispatch = await backend.requestTest(_subscription, 'nonce-2');
      check(dispatch.failedAtServer).isTrue();
      check(dispatch.diagnostics?.error).equals('gone');
    });

    test('an op error comes back as a rejection', () async {
      gateway.opError = 'invalid_sid';
      final error = await _backendError(backend.unsubscribe('nope'));
      check(error.failure).equals(
        const PushFailure(
          PushFailureReason.serverRejected,
          detail: 'invalid_sid',
        ),
      );
    });

    test('watch marks a session for six hours', () async {
      await backend.watch('session-9');
      check(gateway.bodies.single)
          .deepEquals({'op': 'watch', 'session_id': 'session-9', 'ttl': 21600});
    });

    test('list answers the subscribed sids', () async {
      gateway.sids = ['A', 'B'];
      check(await backend.listSids()).deepEquals(['A', 'B']);
    });

    test('install is a command, not a request', () async {
      final error = await _backendError(backend.install());
      check(error.failure.reason).equals(PushFailureReason.installFailed);
      check(gateway.requests).isEmpty();
    });
  });

  group('dashboard', () {
    late _Dashboard dashboard;
    late HermesDashboardPushBackend backend;

    setUp(() {
      dashboard = _Dashboard();
      backend = HermesDashboardPushBackend(client: dashboard, profile: 'work');
    });

    test('hello 200 is ready', () async {
      final probe = await backend.probe();
      check(probe.isReady).isTrue();
      check(dashboard.calls.single).equals('GET /api/plugins/conduit/v1/hello');
    });

    test(
      'an unmounted route with the plugin enabled needs a restart',
      () async {
        dashboard.hello = const HermesDashboardResponse(
          404,
          '{"detail":"No such API endpoint: /api/plugins/conduit/v1/hello"}',
        );
        dashboard.hubRow = {'name': 'conduit', 'runtime_status': 'enabled'};
        final probe = await backend.probe();
        check(probe.outcome).equals(PushProbeOutcome.restartHermes);
      },
    );

    test('an unmounted route without the plugin needs it installed', () async {
      dashboard.hello = const HermesDashboardResponse(
        404,
        '{"detail":"No such API endpoint: /api/plugins/conduit/v1/hello"}',
      );
      final probe = await backend.probe();
      check(probe.outcome).equals(PushProbeOutcome.needsHermesPlugin);
      check(probe.canInstallHermesPlugin).isTrue();
      check(probe.hermesInstallCommand).isNotNull().contains('-p work');
    });

    test('"Plugin not found" needs it installed or enabled', () async {
      dashboard.hello = const HermesDashboardResponse(
        404,
        '{"detail":"Plugin not found"}',
      );
      dashboard.hubRow = {'name': 'conduit', 'runtime_status': 'disabled'};
      check((await backend.probe()).outcome)
          .equals(PushProbeOutcome.needsHermesPlugin);
    });

    test('a dashboard without a plugin hub is too old', () async {
      dashboard.hello = const HermesDashboardResponse(404, '{"detail":"x"}');
      dashboard.hubStatus = 404;
      check((await backend.probe()).outcome)
          .equals(PushProbeOutcome.serverTooOld);
    });

    test('an expired dashboard sign-in needs sign-in', () async {
      dashboard.signedOut = true;
      check((await backend.probe()).outcome)
          .equals(PushProbeOutcome.signInNeeded);
    });

    test('ops go to the events route for the profile', () async {
      await backend.unsubscribe('AAAAAAAAAAAAAAAAAAAAAA');
      check(dashboard.calls.single)
          .equals('POST /api/plugins/conduit/v1/events?profile=work');
      check(dashboard.bodies.single as Map)
          .deepEquals({'op': 'unsubscribe', 'sid': 'AAAAAAAAAAAAAAAAAAAAAA'});
    });

    test('install never forces, then restarts a running gateway', () async {
      dashboard.gatewayIsRunning = true;
      await backend.install();
      check(dashboard.calls).deepEquals([
        'GET /api/dashboard/plugins/hub',
        'POST /api/dashboard/agent-plugins/install',
        'POST /api/gateway/restart?profile=work',
      ]);
      check(dashboard.bodies.first as Map).deepEquals({
        'identifier': 'cogwheel0/conduit-hermes-push',
        if (kConduitHermesPluginRef.isNotEmpty) 'ref': kConduitHermesPluginRef,
        'enable': true,
        'force': false,
      });
    });

    test('install enables a plugin that is already there', () async {
      dashboard.hubRow = {'name': 'conduit', 'runtime_status': 'inactive'};
      await backend.install();
      check(dashboard.calls).deepEquals([
        'GET /api/dashboard/plugins/hub',
        'POST /api/dashboard/agent-plugins/conduit/enable',
      ]);
    });

    test("a caution scan is the user's to see", () async {
      dashboard.installResponse = const HermesDashboardResponse(
        400,
        '{"detail":"Plugin scan returned caution: network access"}',
      );
      final error = await _backendError(backend.install());
      check(error.failure).equals(
        const PushFailure(
          PushFailureReason.installFailed,
          detail: 'Plugin scan returned caution: network access',
        ),
      );
      check(dashboard.calls)
          .not((it) => it.contains('POST /api/gateway/restart?profile=work'));
    });
  });
}

Future<PushBackendException> _backendError(Future<Object?> future) async {
  try {
    await future;
  } on PushBackendException catch (error) {
    return error;
  }
  throw StateError('expected a PushBackendException');
}

final class _Gateway implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final bodies = <Map<String, dynamic>>[];
  int status = 200;
  String? code;
  String? plainBody;
  bool offline = false;
  int pushStatus = 201;
  String? opError;
  List<String> sids = const [];

  List<String> get ops => [for (final body in bodies) body['op'] as String];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (offline) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline',
      );
    }
    final body = jsonDecode(options.data as String) as Map<String, dynamic>;
    bodies.add(body);
    if (plainBody != null) return ResponseBody.fromString(plainBody!, status);
    if (status != 200) {
      return _json({
        'error': {
          'message': 'x',
          'type': 'invalid_request_error',
          'code': code,
        },
      }, status);
    }
    if (opError != null) return _json({'ok': false, 'error': opError});
    return _json(switch (body['op']) {
      'hello' => {
        'ok': true,
        'plugin': 'conduit',
        'version': '1.0.0',
        'proto': 1,
      },
      'test' => {'ok': true, 'push_status': pushStatus},
      'list' => {'ok': true, 'sids': sids},
      _ => {'ok': true},
    });
  }

  ResponseBody _json(Object body, [int status = 200]) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}

final class _Dashboard implements HermesDashboardClient {
  final calls = <String>[];
  final bodies = <Object?>[];
  HermesDashboardResponse hello = const HermesDashboardResponse(
    200,
    '{"ok":true,"plugin":"conduit","version":"1.0.0","proto":1}',
  );
  Map<String, Object?>? hubRow;
  int hubStatus = 200;
  bool signedOut = false;
  bool gatewayIsRunning = false;
  HermesDashboardResponse installResponse = const HermesDashboardResponse(
    200,
    '{"ok":true,"plugin_name":"conduit"}',
  );

  @override
  Future<HermesDashboardResponse> request(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    if (signedOut) throw StateError('Hermes sign-in is required.');
    final suffix = query == null || query.isEmpty
        ? ''
        : '?${query.entries.map((e) => '${e.key}=${e.value}').join('&')}';
    calls.add('$method $path$suffix');
    if (body != null) bodies.add(body);
    return switch (path) {
      '/api/plugins/conduit/v1/hello' => hello,
      '/api/dashboard/plugins/hub' => HermesDashboardResponse(
        hubStatus,
        jsonEncode({
          'plugins': [?hubRow],
        }),
      ),
      '/api/dashboard/agent-plugins/install' => installResponse,
      _ => const HermesDashboardResponse(200, '{"ok":true}'),
    };
  }

  @override
  Future<bool> gatewayRunning() async => gatewayIsRunning;

  @override
  void close() {}
}
