import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit/features/hermes/models/hermes_job.dart';
import 'package:conduit/features/hermes/models/hermes_toolset.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _CaptureInterceptor extends Interceptor {
  _CaptureInterceptor(this.responseFor);

  final Object? Function(RequestOptions) responseFor;
  final List<RequestOptions> requests = [];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests.add(options);
    handler.resolve(
      Response<dynamic>(
        requestOptions: options,
        data: responseFor(options),
        statusCode: 200,
      ),
    );
  }
}

HermesApiService _service(_CaptureInterceptor capture) {
  final dio = Dio()..interceptors.add(capture);
  return HermesApiService(
    config: const HermesConfig(
      enabled: true,
      baseUrl: 'http://host:8642/v1',
      apiKey: 'k',
    ),
    dio: dio,
  );
}

void main() {
  group('HermesCapabilities.fromJson', () {
    test('honors an explicit false and defaults the rest to true', () {
      final caps = HermesCapabilities.fromJson({
        'features': {'run_approval': false},
        'endpoints': {'jobs': '/api/jobs'},
      });
      check(caps.runApproval).isFalse();
      check(caps.jobs).isTrue();
      check(caps.skills).isTrue();
      check(caps.sessions).isTrue();
    });

    test('empty payload keeps management optimistic but images disabled', () {
      final caps = HermesCapabilities.fromJson(const {});
      check(caps.runApproval).isTrue();
      check(caps.toolsets).isTrue();
      check(caps.inputImages).isFalse();
    });

    test('null feature values remain optimistic', () {
      final caps = HermesCapabilities.fromJson({
        'features': {'skills': null},
      });
      check(caps.skills).isTrue();
    });

    test('image input follows advertised Responses streaming support', () {
      final viaFeature = HermesCapabilities.fromJson({
        'features': {'responses_api': true, 'responses_streaming': true},
      });
      final viaEndpoint = HermesCapabilities.fromJson({
        'endpoints': {
          'responses': {'method': 'POST', 'path': '/v1/responses'},
        },
      });
      final disabled = HermesCapabilities.fromJson({
        'features': {'responses_api': true, 'responses_streaming': false},
        'endpoints': {
          'responses': {'method': 'POST', 'path': '/v1/responses'},
        },
      });
      final conflictingFlags = HermesCapabilities.fromJson({
        'responses_streaming': true,
        'features': {'responses_streaming': false},
      });
      final oldSessionOnly = HermesCapabilities.fromJson({
        'features': {'session_chat_streaming': true},
        'endpoints': {
          'session_chat_stream': {
            'method': 'POST',
            'path': '/api/sessions/{session_id}/chat/stream',
          },
        },
      });

      check(viaFeature.inputImages).isTrue();
      check(viaEndpoint.inputImages).isTrue();
      check(disabled.inputImages).isFalse();
      check(conflictingFlags.inputImages).isFalse();
      check(oldSessionOnly.inputImages).isFalse();
    });

    test('malformed Responses endpoint does not enable image input', () {
      final wrongMethod = HermesCapabilities.fromJson({
        'endpoints': {
          'responses': {'method': 'GET', 'path': '/v1/responses'},
        },
      });
      final wrongPath = HermesCapabilities.fromJson({
        'endpoints': {
          'responses': {'method': 'POST', 'path': '/v1/runs'},
        },
      });
      final apiWithoutStreaming = HermesCapabilities.fromJson({
        'features': {'responses_api': true},
      });

      check(wrongMethod.inputImages).isFalse();
      check(wrongPath.inputImages).isFalse();
      check(apiWithoutStreaming.inputImages).isFalse();
    });
  });

  group('model parsing', () {
    test('HermesToolset parses tools and skips nameless', () {
      check(HermesToolset.fromJson({'tools': []})).isNull();
      final ts = HermesToolset.fromJson({
        'name': 'web',
        'label': 'Web search',
        'tools': [
          'search',
          {'name': 'fetch'},
        ],
      });
      check(ts!.label).equals('Web search');
      check(ts.tools).deepEquals(['search', 'fetch']);
    });

    test('HermesJob derives enabled from paused and skips no-id', () {
      check(HermesJob.fromJson({'prompt': 'x'})).isNull();
      final job = HermesJob.fromJson({
        'id': 'j1',
        'prompt': 'Daily digest',
        'cron': '0 9 * * *',
        'paused': true,
      });
      check(job!.schedule).equals('0 9 * * *');
      check(job.enabled).isFalse();
    });

    test('HermesJob keeps structured schedules editable', () {
      final interval = HermesJob.fromJson({
        'id': 'interval',
        'prompt': 'Recurring',
        'schedule': {'kind': 'interval', 'minutes': 30, 'display': 'every 30m'},
        'schedule_display': 'Every 30 minutes',
      });
      final once = HermesJob.fromJson({
        'id': 'once',
        'prompt': 'One shot',
        'schedule': {
          'kind': 'once',
          'run_at': '2027-04-05T09:30:00+00:00',
          'display': 'once at 2027-04-05 09:30',
        },
        'schedule_display': 'once at 2027-04-05 09:30',
      });
      final cron = HermesJob.fromJson({
        'id': 'cron',
        'prompt': 'Cron',
        'schedule': {
          'kind': 'cron',
          'expr': '0 9 * * *',
          'display': 'Every morning',
        },
        'schedule_display': 'Every morning',
      });

      check(interval!.schedule).equals('every 30m');
      check(once!.schedule).equals('2027-04-05T09:30:00+00:00');
      check(cron!.schedule).equals('0 9 * * *');
    });
  });

  group('HermesApiService tier-1 endpoints', () {
    test('capabilities / toolsets / getRun target the right paths', () async {
      final capture = _CaptureInterceptor((req) {
        if (req.path.endsWith('/toolsets')) {
          return {
            'toolsets': [
              {'name': 'web', 'tools': []},
            ],
          };
        }
        if (req.path.contains('/runs/')) return {'status': 'completed'};
        return {'features': {}};
      });
      final service = _service(capture);

      await service.getCapabilities();
      final toolsets = await service.listToolsets();
      await service.getRun('r1');

      check(
        capture.requests[0].path,
      ).equals('http://host:8642/v1/capabilities');
      check(capture.requests[1].path).equals('http://host:8642/v1/toolsets');
      check(capture.requests[2].path).equals('http://host:8642/v1/runs/r1');
      check(toolsets.single['name']).equals('web');
    });

    test('jobs CRUD + lifecycle hit the right paths and bodies', () async {
      final capture = _CaptureInterceptor((_) => {'id': 'j1'});
      final service = _service(capture);

      await service.createJob(
        name: 'Daily summary',
        prompt: 'p',
        schedule: '0 9 * * *',
      );
      await service.updateJob('j1', enabled: false);
      await service.pauseJob('j1');
      await service.resumeJob('j1');
      await service.runJob('j1');
      await service.deleteJob('j1');

      check(capture.requests[0].path).equals('http://host:8642/api/jobs');
      check((capture.requests[0].data as Map)['name']).equals('Daily summary');
      check((capture.requests[0].data as Map)['schedule']).equals('0 9 * * *');
      check(capture.requests[1].method).equals('PATCH');
      check((capture.requests[1].data as Map)['enabled']).equals(false);
      check(
        capture.requests[2].path,
      ).equals('http://host:8642/api/jobs/j1/pause');
      check(
        capture.requests[3].path,
      ).equals('http://host:8642/api/jobs/j1/resume');
      check(
        capture.requests[4].path,
      ).equals('http://host:8642/api/jobs/j1/run');
      check(capture.requests[5].method).equals('DELETE');
    });

    test('job creation enforces the current server text contract', () async {
      final capture = _CaptureInterceptor((_) => {'id': 'j1'});
      final service = _service(capture);

      await expectLater(
        service.createJob(name: '', prompt: 'p', schedule: '0 9 * * *'),
        throwsArgumentError,
      );
      await expectLater(
        service.createJob(
          name: List<String>.filled(
            kMaxHermesJobNameCharacters + 1,
            'n',
          ).join(),
          prompt: 'p',
          schedule: '0 9 * * *',
        ),
        throwsArgumentError,
      );
      await expectLater(
        service.createJob(
          name: 'Name',
          prompt: List<String>.filled(
            kMaxHermesJobPromptCharacters + 1,
            'p',
          ).join(),
          schedule: '0 9 * * *',
        ),
        throwsArgumentError,
      );
      check(capture.requests).isEmpty();
    });

    test(
      'job ingestion filters hostile and credential-reflecting ids',
      () async {
        const apiSecret = 'configured-api-secret';
        const sessionSecret = 'configured-session-secret';
        final oversizedId = List<String>.filled(
          kMaxHermesOpaqueIdentifierCharacters + 1,
          'a',
        ).join();
        final capture = _CaptureInterceptor(
          (_) => {
            'jobs': [
              {'id': 'job-safe', 'prompt': 'safe'},
              {'job_id': 'legacy-safe', 'prompt': 'legacy'},
              {'id': 'prefix-$apiSecret-suffix'},
              {'id': sessionSecret},
              {'id': 'bad\ncontrol'},
              {'id': oversizedId},
              {'id': ' padded '},
              {'id': 42},
            ],
          },
        );
        final service = HermesApiService(
          config: const HermesConfig(
            enabled: true,
            baseUrl: 'http://host:8642/v1',
            apiKey: apiSecret,
            sessionKey: sessionSecret,
          ),
          dio: Dio()..interceptors.add(capture),
        );

        final jobs = await service.listJobs();

        check(
          capture.requests.single.queryParameters['include_disabled'],
        ).equals(true);
        check(
          jobs.map((job) => job['id'] ?? job['job_id']).toList(),
        ).deepEquals(['job-safe', 'legacy-safe']);
      },
    );

    test('short credentials do not hide ordinary job ids', () async {
      final capture = _CaptureInterceptor(
        (_) => {
          'jobs': [
            {'id': 'abcdef123456', 'prompt': 'contains short API key'},
            {'id': 'bcdef1234567', 'prompt': 'contains short session key'},
            {'id': 'a', 'prompt': 'is the API key'},
            {'id': 'b', 'prompt': 'is the session key'},
          ],
        },
      );
      final service = HermesApiService(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'http://host:8642/v1',
          apiKey: 'a',
          sessionKey: 'b',
        ),
        dio: Dio()..interceptors.add(capture),
      );

      final jobs = await service.listJobs();

      check(
        jobs.map((job) => job['id']).toList(),
      ).deepEquals(['abcdef123456', 'bcdef1234567']);
    });
  });

  test('hermesJobsProvider parses the job list', () async {
    final capture = _CaptureInterceptor(
      (_) => {
        'jobs': [
          {'id': 'j1', 'prompt': 'A', 'schedule': '0 9 * * *'},
          {'no': 'id'},
        ],
      },
    );
    final container = ProviderContainer(
      overrides: [
        hermesApiServiceProvider.overrideWithValue(_service(capture)),
      ],
    );
    addTearDown(container.dispose);

    final jobs = await container.read(hermesJobsProvider.future);
    check(jobs).has((j) => j.length, 'length').equals(1);
    check(jobs.single.id).equals('j1');
  });
}
