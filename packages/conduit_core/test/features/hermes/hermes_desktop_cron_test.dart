import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

typedef _Request = ({String method, String path, Map<String, String> query});

/// Answers dashboard REST requests from a `METHOD /path` table and records
/// each request with its JSON body.
final class _RoutesAdapter implements HttpClientAdapter {
  _RoutesAdapter([Map<String, (int, Object?)>? routes]) : routes = routes ?? {};

  final Map<String, (int, Object?)> routes;
  final requests = <_Request>[];
  final bodies = <String, Object?>{};

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

HermesDesktopApiService _service(_RoutesAdapter adapter) {
  final service = HermesDesktopApiService(
    config: HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example',
      mode: HermesBackendMode.desktopGateway,
      desktopProfile: 'ops',
      desktopCredentials: HermesDesktopCredentials(legacyToken: 'token'),
    ),
    dio: Dio()..httpClientAdapter = adapter,
  );
  addTearDown(service.close);
  return service;
}

const _cancel = 'POST /api/cron/jobs/job-1/cancel';

void main() {
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
  });
}
