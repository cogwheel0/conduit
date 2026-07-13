import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_run_event.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openai_dart/openai_dart.dart' as openai;

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
    test('disables redirects on injected clients to protect secrets', () {
      final dio = Dio();
      HermesApiService(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'http://host:8642',
          apiKey: 'secret',
          sessionKey: 'memory',
        ),
        dio: dio,
      );

      check(dio.options.followRedirects).isFalse();
    });

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

    test('getRun unwraps common response envelopes', () async {
      final capture = _CaptureInterceptor({
        'data': {'id': 'r1', 'status': 'completed', 'output': 'done'},
      });

      final run = await _service(capture).getRun('r1');

      check(run['status']).equals('completed');
      check(run['output']).equals('done');
    });

    test('getRun rejects non-object responses', () async {
      final capture = _CaptureInterceptor('not an object');

      await check(_service(capture).getRun('r1')).throws<FormatException>();
    });

    test(
      'streamResponse sends chained multimodal input and exposes session',
      () async {
        final body = ResponseBody.fromString(
          'event: response.created\n'
          'data: {"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}\n\n'
          'event: response.output_text.delta\n'
          'data: {"type":"response.output_text.delta","delta":"hello"}\n\n'
          'event: response.completed\n'
          'data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hello"}]}]}}\n\n',
          200,
          headers: {
            Headers.contentTypeHeader: ['text/event-stream'],
            'x-hermes-session-id': ['server-session'],
          },
        );
        final capture = _CaptureInterceptor(body);
        final cancelToken = CancelToken();
        final history = <Map<String, dynamic>>[
          {'role': 'user', 'content': 'earlier'},
          {'role': 'assistant', 'content': 'answer'},
        ];
        final responseStream = await _service(capture, session: 'mem-key')
            .streamResponse(
              HermesChatInput.multimodal([
                HermesInputTextPart('look'),
                HermesInputImagePart('https://example.com/image.png'),
              ]),
              instructions: 'Be concise',
              sessionId: 'client-session',
              previousResponseId: 'resp_0',
              conversationHistory: history,
              cancelToken: cancelToken,
            );
        final events = await responseStream.events.toList();

        check(responseStream.sessionId).equals('server-session');
        check(
          events.whereType<HermesResponseCreated>().map((e) => e.responseId),
        ).deepEquals(['resp_1', 'resp_1']);
        check(
          events.whereType<HermesTokenDelta>().single.content,
        ).equals('hello');
        check(
          events.whereType<HermesFinalOutput>().single.text,
        ).equals('hello');
        check(events.last).isA<HermesRunDone>();

        final req = capture.requests.single;
        check(req.path).equals('http://host:8642/v1/responses');
        check(req.method).equals('POST');
        check(req.cancelToken).identicalTo(cancelToken);
        check(req.receiveTimeout).equals(Duration.zero);
        check(req.headers['X-Hermes-Session-Id']).equals('client-session');
        check(req.headers['X-Hermes-Session-Key']).equals('mem-key');
        check(req.headers['Accept']).equals('text/event-stream');
        final data = req.data as Map;
        check(data['input'] as List).deepEquals([
          {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': 'look'},
              {
                'type': 'input_image',
                'image_url': 'https://example.com/image.png',
              },
            ],
          },
        ]);
        check(data['model']).equals('hermes-agent');
        check(data['stream']).equals(true);
        check(data['store']).equals(true);
        check(data['instructions']).equals('Be concise');
        check(data['previous_response_id']).equals('resp_0');
        check(data['conversation_history'] as List).deepEquals(history);
        check(data.containsKey('conversation')).isFalse();

        final sdkRequest = openai.CreateResponseRequest.fromJson(
          data.cast<String, dynamic>(),
        );
        check(sdkRequest.model).equals('hermes-agent');
        check(sdkRequest.input).isA<openai.ResponseInputItems>();
        check(sdkRequest.stream).equals(true);
        check(sdkRequest.store).equals(true);
        check(sdkRequest.instructions).equals('Be concise');
        check(sdkRequest.previousResponseId).equals('resp_0');
      },
    );

    test('streamResponse rejects competing continuation mechanisms', () async {
      final capture = _CaptureInterceptor({});

      await check(
        _service(capture).streamResponse(
          HermesChatInput.text('hello'),
          conversation: 'conversation-1',
          previousResponseId: 'resp_0',
        ),
      ).throws<ArgumentError>();
      check(capture.requests).isEmpty();
    });

    test(
      'streamResponse layers named conversation over SDK text input',
      () async {
        final capture = _CaptureInterceptor(
          ResponseBody.fromString(
            'data: [DONE]\n\n',
            200,
            headers: {
              Headers.contentTypeHeader: ['text/event-stream'],
            },
          ),
        );

        final stream = await _service(capture).streamResponse(
          HermesChatInput.text('hello'),
          conversation: 'project-chat',
        );
        final events = await stream.events.toList();

        check(events.single).isA<HermesRunDone>();
        final data = (capture.requests.single.data as Map)
            .cast<String, dynamic>();
        check(data['model']).equals('hermes-agent');
        check(data['input']).equals('hello');
        check(data['conversation']).equals('project-chat');
        check(data.containsKey('previous_response_id')).isFalse();
        final sdkRequest = openai.CreateResponseRequest.fromJson(data);
        check(sdkRequest.input).isA<openai.ResponseInputText>();
      },
    );

    test('getResponse encodes identity and forwards cancellation', () async {
      final capture = _CaptureInterceptor({
        'id': 'resp/1#fragment',
        'status': 'completed',
      });
      final cancelToken = CancelToken();

      final response = await _service(
        capture,
      ).getResponse('resp/1#fragment', cancelToken: cancelToken);

      check(response['status']).equals('completed');
      final req = capture.requests.single;
      check(
        req.path,
      ).equals('http://host:8642/v1/responses/resp%2F1%23fragment');
      check(req.cancelToken).identicalTo(cancelToken);
    });

    test('getResponse rejects a non-object payload', () async {
      final capture = _CaptureInterceptor('not an object');

      await check(
        _service(capture).getResponse('resp_1'),
      ).throws<FormatException>();
    });

    test(
      'stopRun forwards cancellation and propagates request errors',
      () async {
        final cancelToken = CancelToken();
        final capture = _CaptureInterceptor({});
        await _service(capture).stopRun('r1', cancelToken: cancelToken);
        check(capture.requests.single.cancelToken).identicalTo(cancelToken);

        final dio = Dio();
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.reject(
              DioException(requestOptions: options, error: 'offline'),
            ),
          ),
        );
        final failing = HermesApiService(
          config: const HermesConfig(
            enabled: true,
            baseUrl: 'http://host:8642',
            apiKey: 'secret',
          ),
          dio: dio,
        );

        await expectLater(failing.stopRun('r1'), throwsA(isA<DioException>()));
      },
    );

    test('resolveApproval posts the decision to the run', () async {
      final capture = _CaptureInterceptor({});
      await _service(
        capture,
      ).resolveApproval('r1', approvalId: 'a1', approved: false);
      final req = capture.requests.single;
      check(req.path).equals('http://host:8642/v1/runs/r1/approval');
      check((req.data as Map)['approval_id']).equals('a1');
      check((req.data as Map)['approved']).equals(false);
    });

    test('approval identifiers cannot inject URI path or fragments', () async {
      final capture = _CaptureInterceptor({});
      await _service(capture).resolveApproval(
        'r1/stop#',
        approvalId: 'approval/../evil#',
        approved: true,
      );
      final req = capture.requests.single;
      check(req.path).equals('http://host:8642/v1/runs/r1%2Fstop%23/approval');
      check((req.data as Map)['approval_id']).equals('approval/../evil#');
    });
  });
}
