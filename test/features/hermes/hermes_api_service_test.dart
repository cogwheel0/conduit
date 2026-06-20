import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Captures the outgoing request and short-circuits it with a canned response,
/// so we can assert paths/headers/body without a real server.
class _CaptureInterceptor extends Interceptor {
  _CaptureInterceptor(this.responseData);

  final Object? responseData;
  final List<RequestOptions> requests = [];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests.add(options);
    handler.resolve(
      Response<dynamic>(
        requestOptions: options,
        data: responseData,
        statusCode: 200,
      ),
    );
  }
}

HermesApiService _service(_CaptureInterceptor interceptor, {String? session}) {
  final dio = Dio();
  dio.interceptors.add(interceptor);
  return HermesApiService(
    config: HermesConfig(
      enabled: true,
      baseUrl: 'http://host:8642/v1', // trailing /v1 should be normalized away
      apiKey: 'secret',
      sessionKey: session,
    ),
    dio: dio,
  );
}

void main() {
  group('HermesApiService', () {
    test('createRun posts to normalized path with session headers', () async {
      final capture = _CaptureInterceptor({'run_id': 'r1'});
      final service = _service(capture, session: 'mem-key');

      final runId = await service.createRun(
        input: 'hello',
        sessionId: 'conv-1',
        previousResponseId: 'r0',
      );

      check(runId).equals('r1');
      final req = capture.requests.single;
      check(req.path).equals('http://host:8642/v1/runs');
      check(req.method).equals('POST');
      check(req.data as Map).containsKey('input');
      check((req.data as Map)['session_id']).equals('conv-1');
      check((req.data as Map)['previous_response_id']).equals('r0');
      check(req.headers['X-Hermes-Session-Id']).equals('conv-1');
      check(req.headers['X-Hermes-Session-Key']).equals('mem-key');
    });

    test('getModels unwraps the data array', () async {
      final capture = _CaptureInterceptor({
        'data': [
          {'id': 'hermes-1'},
          {'id': 'hermes-2'},
        ],
      });
      final models = await _service(capture).getModels();
      check(models).has((m) => m.length, 'length').equals(2);
      check(models.first['id']).equals('hermes-1');
    });

    test('resolveApproval posts the decision to the run', () async {
      final capture = _CaptureInterceptor({});
      await _service(capture).resolveApproval(
        'r1',
        approvalId: 'a1',
        approved: false,
      );
      final req = capture.requests.single;
      check(req.path).equals('http://host:8642/v1/runs/r1/approval');
      check((req.data as Map)['approval_id']).equals('a1');
      check((req.data as Map)['approved']).equals(false);
    });
  });
}
