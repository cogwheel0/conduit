import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/models/hermes_job_delivery.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

typedef _Request = ({String method, String path, Map<String, String> query});

/// Answers dashboard REST requests from a `METHOD /path` table and records
/// each request with its JSON body.
final class _RoutesAdapter implements HttpClientAdapter {
  _RoutesAdapter([Map<String, (int, Object?)>? routes]) : routes = routes ?? {};

  final Map<String, (int, Object?)> routes;
  final requests = <_Request>[];
  final bodies = <String, Object?>{};

  /// When set, the next request waits for it before it is answered.
  Completer<void>? hold;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final key = '${options.method} ${options.uri.path}';
    if (options.uri.path != '/api/status') {
      requests.add((
        method: options.method,
        path: options.uri.path,
        query: options.uri.queryParameters,
      ));
      bodies[key] = options.data;
    }
    final held = hold;
    hold = null;
    await held?.future;
    final (status, body) =
        routes[key] ??
        switch (options.uri.path) {
          '/api/status' => (
            200,
            {'auth_required': false, 'gateway_running': true},
          ),
          '/api/cron/jobs' when options.method == 'GET' => (200, <Object>[]),
          _ => (200, {'ok': true}),
        };
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

final class _MockWebSocketChannel extends Mock implements WebSocketChannel {}

final class _MockWebSocketSink extends Mock implements WebSocketSink {}

/// A dashboard sign-in's bridge that records which requests were urgent.
final class _UrgencyBridge implements HermesDashboardBridge {
  final urgent = <String, bool>{};

  @override
  Future<({int status, String body})> request(
    String method,
    Uri url, {
    String? body,
    bool urgent = false,
  }) async {
    this.urgent['$method ${url.path}'] = urgent;
    return url.path.endsWith('/cancel')
        ? (status: 200, body: '{"cancelled":true,"execution_id":"exec-1"}')
        : (status: 200, body: '{}');
  }

  @override
  Future<void> reload() async {}

  @override
  Future<void> close() async {}
}

/// Switches the connection a container's providers read.
final class _Connection extends Notifier<HermesBackendService?> {
  _Connection(this.initial);

  final HermesBackendService initial;

  @override
  HermesBackendService? build() => initial;

  void use(HermesBackendService service) => state = service;
}

/// A gateway socket that answers every request: [results] by method, else an
/// empty object; [errors] by method as JSON-RPC errors; never [silent] ones.
final class _Gateway {
  _Gateway({
    this.results = const {},
    this.errors = const {},
    this.silent = const {},
  }) {
    when(() => channel.ready).thenAnswer((_) async {});
    when(() => channel.stream).thenAnswer((_) {
      scheduleMicrotask(
        () => incoming.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {'type': 'gateway.ready', 'payload': {}},
          }),
        ),
      );
      return incoming.stream;
    });
    when(() => channel.sink).thenReturn(sink);
    when(() => sink.close()).thenAnswer((_) async {});
    when(() => sink.add(any())).thenAnswer((invocation) {
      final frame = Map<String, dynamic>.from(
        jsonDecode(invocation.positionalArguments.single as String) as Map,
      );
      sent.add(frame);
      final id = frame['id'];
      if (id == null) return;
      final method = frame['method']?.toString() ?? '';
      if (silent.contains(method)) return;
      final error = errors[method];
      scheduleMicrotask(
        () => incoming.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            if (error != null)
              'error': error
            else
              'result': results[method] ?? {},
          }),
        ),
      );
    });
  }

  final Map<String, Object?> results;
  final Map<String, Map<String, Object?>> errors;
  final Set<String> silent;
  final channel = _MockWebSocketChannel();
  final sink = _MockWebSocketSink();
  final incoming = StreamController<dynamic>.broadcast();
  final sent = <Map<String, dynamic>>[];

  Iterable<Map<String, dynamic>> calls(String method) =>
      sent.where((frame) => frame['method'] == method);
}

HermesDesktopApiService _service(_RoutesAdapter adapter, [_Gateway? gateway]) {
  final service = HermesDesktopApiService(
    config: HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example',
      mode: HermesBackendMode.desktopGateway,
      desktopProfile: 'ops',
      desktopCredentials: HermesDesktopCredentials(legacyToken: 'token'),
    ),
    dio: Dio()..httpClientAdapter = adapter,
    rpc: gateway == null
        ? null
        : HermesDesktopRpcClient(
            channelFactory: (_, _, {httpClient}) => gateway.channel,
          ),
  );
  addTearDown(service.close);
  if (gateway != null) addTearDown(gateway.incoming.close);
  return service;
}

const _cancel = 'POST /api/cron/jobs/job-1/cancel';

void main() {
  test('a new job sends its delivery and only an explicit policy', () async {
    final adapter = _RoutesAdapter({
      'POST /api/cron/jobs': (200, {'id': 'job-1'}),
    });
    final service = _service(adapter);

    await service.createJob(
      name: 'Digest',
      prompt: 'Summarize the notes',
      schedule: '0 7 * * *',
    );
    check(adapter.bodies['POST /api/cron/jobs']).isA<Map>().deepEquals({
      'name': 'Digest',
      'prompt': 'Summarize the notes',
      'schedule': '0 7 * * *',
      'deliver': 'local',
    });

    await service.createJob(
      name: 'Digest',
      prompt: 'Summarize the notes',
      schedule: '0 7 * * *',
      deliver: 'telegram,room:standup@ops',
      catchUp: HermesJobCatchUp.skip,
    );
    check(adapter.bodies['POST /api/cron/jobs']).isA<Map>().deepEquals({
      'name': 'Digest',
      'prompt': 'Summarize the notes',
      'schedule': '0 7 * * *',
      'deliver': 'telegram,room:standup@ops',
      'catch_up': false,
    });
    check(adapter.requests.last.query).deepEquals({'profile': 'ops'});
  });

  test('an edit sends only the delivery and policy it changes', () async {
    final adapter = _RoutesAdapter();
    final service = _service(adapter);
    const key = 'PUT /api/cron/jobs/job-1';

    await service.updateJob('job-1', name: 'Renamed');
    check(adapter.bodies[key]).isA<Map>().deepEquals({
      'updates': {'name': 'Renamed'},
    });

    await service.updateJob(
      'job-1',
      deliver: 'bot-chat:research',
      catchUp: HermesJobCatchUp.hermesDefault,
    );
    check(adapter.bodies[key]).isA<Map>().deepEquals({
      'updates': {'deliver': 'bot-chat:research', 'catch_up': null},
    });

    await service.updateJob('job-1', catchUp: HermesJobCatchUp.runOnce);
    check(adapter.bodies[key]).isA<Map>().deepEquals({
      'updates': {'catch_up': true},
    });
  });

  test('stop reads the attempt Hermes cancelled', () async {
    final adapter = _RoutesAdapter({
      _cancel: (
        200,
        {
          'success': true,
          'cancelled': true,
          'execution_id': 'exec-7',
          'job_id': 'job-1',
        },
      ),
    });

    final result = await _service(adapter).stopJobRun('job-1');

    check(result.cancelled).isTrue();
    check(result.executionId).equals('exec-7');
    check(adapter.requests.single)
      ..has((r) => r.method, 'method').equals('POST')
      ..has((r) => r.path, 'path').equals('/api/cron/jobs/job-1/cancel')
      ..has((r) => r.query, 'query').deepEquals({'profile': 'ops'});
  });

  test('a dashboard sign-in sends Stop ahead of a waiting Run now', () async {
    final bridge = _UrgencyBridge();
    final service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
        desktopAuthKind: HermesDesktopAuthKind.dashboardCookie,
      ),
      dashboardBridgeFactory: ({required root, required accessHeaders}) =>
          bridge,
    );
    addTearDown(service.close);

    await service.runJob('job-1');
    final result = await service.stopJobRun('job-1');

    check(result.executionId).equals('exec-1');
    check(bridge.urgent).deepEquals({
      'POST /api/cron/jobs/job-1/trigger': false,
      'POST /api/cron/jobs/job-1/cancel': true,
    });
  });

  test('stop with nothing in flight says so', () async {
    final adapter = _RoutesAdapter({
      _cancel: (200, {'success': true, 'cancelled': false}),
    });

    final result = await _service(adapter).stopJobRun('job-1');

    check(result.cancelled).isFalse();
    check(result.executionId).isNull();
  });

  test('a dashboard without the cancel route asks for an update', () async {
    for (final reply in [
      (405, {'detail': 'Method Not Allowed'}),
      (404, {'detail': 'Not Found'}),
    ]) {
      final service = _service(_RoutesAdapter({_cancel: reply}));

      await check(
        service.stopJobRun('job-1'),
      ).throws<HermesJobStopUnsupportedException>();
    }
  });

  test('stopping a job that is gone is a failure, not an update', () async {
    final service = _service(
      _RoutesAdapter({
        _cancel: (404, {'detail': 'Job not found'}),
      }),
    );

    await check(service.stopJobRun('job-1')).throws<
      HermesDesktopHttpException
    >((error) => error.has((e) => e.status, 'status').equals(404));
  });

  test('delivery targets come from the dashboard', () async {
    final adapter = _RoutesAdapter({
      'GET /api/cron/delivery-targets': (
        200,
        {
          'targets': [
            {'id': 'local', 'name': 'Local (save only)'},
            {'id': 'slack', 'name': 'Slack', 'home_target_set': false},
          ],
        },
      ),
    });

    final targets = await _service(adapter).listJobDeliveryTargets();

    check(targets.map((t) => t['id']).toList()).deepEquals(['local', 'slack']);
    check(adapter.requests.single.query).deepEquals({'profile': 'ops'});
  });

  group('rooms', () {
    test('are listed over groups.list, page by page', () async {
      var page = 0;
      final gateway = _Gateway();
      when(() => gateway.sink.add(any())).thenAnswer((invocation) {
        final frame = Map<String, dynamic>.from(
          jsonDecode(invocation.positionalArguments.single as String) as Map,
        );
        gateway.sent.add(frame);
        final id = frame['id'];
        if (id == null) return;
        final result = frame['method'] == 'groups.list'
            ? (page++ == 0
                  ? {
                      'rooms': [
                        {'room_id': 'standup', 'name': 'Daily standup'},
                        {'room_id': '', 'name': 'Broken'},
                      ],
                      'next_offset': 100,
                    }
                  : {
                      'rooms': [
                        {'room_id': 'retro', 'name': 'Retro'},
                      ],
                      'next_offset': null,
                    })
            : <String, Object?>{};
        scheduleMicrotask(
          () => gateway.incoming.add(
            jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
          ),
        );
      });

      final rooms = await _service(_RoutesAdapter(), gateway).listRooms();

      check(rooms.map((room) => room.id).toList())
          .deepEquals(['standup', 'retro']);
      final calls = gateway.calls('groups.list').toList();
      check(calls.length).equals(2);
      check(calls.first['params'] as Map).deepEquals({
        'profile': 'ops',
        'include_disbanded': false,
        'limit': 100,
        'offset': 0,
      });
      check((calls.last['params'] as Map)['offset']).equals(100);
    });

    test('are empty on a gateway without them', () async {
      for (final code in [-32601, 4000]) {
        final gateway = _Gateway(
          errors: {
            'groups.list': {'code': code, 'message': 'unsupported'},
          },
        );

        final rooms = await _service(_RoutesAdapter(), gateway).listRooms();

        check(rooms).isEmpty();
      }
    });
  });

  group('jobs controller', () {
    ProviderContainer containerFor(HermesDesktopApiService service) {
      final container = ProviderContainer(
        overrides: [
          hermesApiServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('creates and edits with delivery and policy', () async {
      final adapter = _RoutesAdapter({
        'POST /api/cron/jobs': (200, {'id': 'job-1'}),
      });
      final jobs = containerFor(_service(adapter)).read(
        hermesJobsProvider.notifier,
      );

      await jobs.create(
        name: 'Digest',
        prompt: 'Summarize the notes',
        schedule: '0 7 * * *',
        deliver: 'slack',
        catchUp: HermesJobCatchUp.runOnce,
      );
      check(
        (adapter.bodies['POST /api/cron/jobs'] as Map)['deliver'],
      ).equals('slack');
      check(
        (adapter.bodies['POST /api/cron/jobs'] as Map)['catch_up'],
      ).equals(true);

      await jobs.edit('job-1', name: 'Renamed');
      check(adapter.bodies['PUT /api/cron/jobs/job-1']).isA<Map>().deepEquals({
        'updates': {'name': 'Renamed'},
      });
    });

    test('stop is unsupported on the API server', () async {
      final container = ProviderContainer(
        overrides: [
          hermesApiServiceProvider.overrideWithValue(
            HermesApiService(
              config: const HermesConfig(
                enabled: true,
                baseUrl: 'https://hermes.example',
                apiKey: 'synthetic-key',
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await check(
        container.read(hermesJobsProvider.notifier).stopRun('job-1'),
      ).throws<HermesJobStopUnsupportedException>();
      check(
        await container.read(hermesJobDeliveryOptionsProvider.future),
      ).isNull();
    });

    test('quiet refresh replaces the list without a loading state', () async {
      final adapter = _RoutesAdapter();
      final container = containerFor(_service(adapter));
      await container.read(hermesJobsProvider.future);
      adapter.routes['GET /api/cron/jobs'] = (
        200,
        [
          {
            'id': 'job-1',
            'prompt': 'Summarize the notes',
            'schedule': '0 7 * * *',
            'latest_execution': {'id': 'exec-1', 'status': 'running'},
          },
        ],
      );
      final states = <AsyncValue<List<HermesJob>>>[];
      container.listen(hermesJobsProvider, (_, next) => states.add(next));

      final jobs = await container
          .read(hermesJobsProvider.notifier)
          .refreshQuietly();

      check(jobs).isNotNull().length.equals(1);
      check(jobs!.single.runInFlight).isTrue();
      check(states.map((s) => s.isLoading)).every((s) => s.isFalse());
    });

    test('a quiet refresh never shares a request of the previous '
        'connection', () async {
      Map<String, Object?> job(String id) => {
        'id': id,
        'prompt': 'Summarize the notes',
        'schedule': '0 7 * * *',
      };
      final adapterA = _RoutesAdapter({
        'GET /api/cron/jobs': (200, [job('job-a')]),
      });
      final adapterB = _RoutesAdapter({
        'GET /api/cron/jobs': (200, [job('job-b')]),
      });
      final serviceA = _service(adapterA);
      final serviceB = _service(adapterB);
      final connection = NotifierProvider<_Connection, HermesBackendService?>(
        () => _Connection(serviceA),
      );
      final container = ProviderContainer(
        overrides: [
          hermesApiServiceProvider.overrideWith((ref) => ref.watch(connection)),
        ],
      );
      addTearDown(container.dispose);
      container.listen(hermesJobsProvider, (_, _) {});
      await container.read(hermesJobsProvider.future);
      final jobs = container.read(hermesJobsProvider.notifier);

      // A's refresh is still waiting when the user switches to B.
      final held = adapterA.hold = Completer<void>();
      final staleRefresh = jobs.refreshQuietly();
      await pumpEventQueue();
      container.read(connection.notifier).use(serviceB);
      await container.read(hermesJobsProvider.future);

      final fresh = jobs.refreshQuietly();
      held.complete();
      check(await fresh).isNotNull().single.has((j) => j.id, 'id').equals(
        'job-b',
      );
      check(await staleRefresh).isNull();
      check(
        container.read(hermesJobsProvider).value!.map((j) => j.id),
      ).deepEquals(['job-b']);
    });

    test('a delivery list that stalls is not waited for', () {
      fakeAsync((async) {
        final adapter = _RoutesAdapter({
          'GET /api/cron/delivery-targets': (
            200,
            {
              'targets': [
                {'id': 'slack', 'name': 'Slack', 'home_target_set': true},
              ],
            },
          ),
        });
        // The gateway never answers groups.list.
        final gateway = _Gateway(silent: {'groups.list'});
        final container = containerFor(_service(adapter, gateway));
        HermesDeliveryOptions? options;
        final subscription = container.listen(
          hermesJobDeliveryOptionsProvider,
          (_, next) => options = next.asData?.value ?? options,
        );
        async.elapse(const Duration(seconds: 11));

        check(options).isNotNull().has(
          (o) => o.options.map((option) => option.target).toList(),
          'targets',
        ).deepEquals(['local', 'slack']);
        final listsBefore = gateway.calls('groups.list').length;

        // The list that timed out is asked for again later.
        async.elapse(kHermesDeliveryRetryDelay);
        async.flushMicrotasks();
        check(gateway.calls('groups.list').length).isGreaterThan(listsBefore);
        subscription.close();
      });
    });

    test('delivery options combine targets, bots, and rooms', () async {
      final adapter = _RoutesAdapter({
        'GET /api/cron/delivery-targets': (
          200,
          {
            'targets': [
              {'id': 'local', 'name': 'Local (save only)'},
              {'id': 'slack', 'name': 'Slack', 'home_target_set': true},
              {'id': 'bot-chat:research', 'name': 'Bot Chat (research)'},
            ],
          },
        ),
      });
      final gateway = _Gateway(
        results: {
          'profiles.list': {
            'bot_mode_protocol': true,
            'profiles': [
              {
                'name': 'research',
                'ui_meta': {
                  'hermes-bots': {'title': 'Research'},
                },
              },
            ],
          },
          'groups.list': {
            'rooms': [
              {'room_id': 'standup', 'name': 'Daily standup'},
            ],
          },
        },
      );
      final container = containerFor(_service(adapter, gateway));

      final options = await container.read(
        hermesJobDeliveryOptionsProvider.future,
      );

      check(options).isNotNull();
      check(options!.options.map((o) => o.target).toList()).deepEquals([
        'local',
        'slack',
        'bot-chat:research',
        'room:standup@ops',
      ]);
      check(options.optionFor('bot-chat:research')!.name).equals('Research');
      check(options.optionFor('room:standup@ops')!.kind)
          .equals(HermesDeliveryKind.room);
    });
  });
}
