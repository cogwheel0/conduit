import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_run_event.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
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

final class _MutableRecoveryClock {
  Duration elapsed = Duration.zero;

  Duration call() => elapsed;

  void advance(Duration duration) => elapsed += duration;
}

final class _AdvancingCaptureInterceptor extends _CaptureInterceptor {
  _AdvancingCaptureInterceptor(
    super.responseData, {
    required this.clock,
    required this.advances,
  });

  final _MutableRecoveryClock clock;
  final List<Duration> advances;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests.add(options);
    final requestIndex = requests.length - 1;
    if (requestIndex < advances.length) {
      clock.advance(advances[requestIndex]);
    }
    handler.resolve(
      Response<dynamic>(
        requestOptions: options,
        data: responseData,
        statusCode: 200,
      ),
    );
  }
}

HermesApiService _service(
  _CaptureInterceptor interceptor, {
  String? session,
  HermesStreamLimits streamLimits = const HermesStreamLimits(),
  Duration Function()? recoveryClock,
}) {
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
    streamLimits: streamLimits,
    recoveryClock: recoveryClock,
  );
}

enum _HermesStreamEndpoint { runs, responses }

extension on _HermesStreamEndpoint {
  String get label => switch (this) {
    _HermesStreamEndpoint.runs => 'runEvents',
    _HermesStreamEndpoint.responses => 'streamResponse',
  };
}

Future<List<HermesRunEvent>> _collectEvents(
  HermesApiService service,
  _HermesStreamEndpoint endpoint,
  CancelToken cancelToken,
) async {
  final stream = switch (endpoint) {
    _HermesStreamEndpoint.runs => service.runEvents(
      'run-1',
      cancelToken: cancelToken,
    ),
    _HermesStreamEndpoint.responses => (await service.streamResponse(
      HermesChatInput.text('hello'),
      cancelToken: cancelToken,
    )).events,
  };
  return stream.toList();
}

final class _SseSource {
  _SseSource({
    this.initialFrame,
    this.repeatingFrame,
    this.hostileCancel = false,
  }) {
    _controller = StreamController<Uint8List>(
      onListen: () {
        final initial = initialFrame;
        if (initial != null) {
          _controller.add(Uint8List.fromList(utf8.encode(initial)));
        }
        final repeating = repeatingFrame;
        if (repeating != null) {
          _timer = Timer.periodic(const Duration(milliseconds: 2), (_) {
            if (!_controller.isClosed) {
              _controller.add(Uint8List.fromList(utf8.encode(repeating)));
            }
          });
        }
      },
      onCancel: _handleCancel,
    );
  }

  final String? initialFrame;
  final String? repeatingFrame;
  final bool hostileCancel;
  final Completer<void> cancellationStarted = Completer<void>();
  late final StreamController<Uint8List> _controller;
  Timer? _timer;

  Future<void>? _handleCancel() {
    _timer?.cancel();
    if (!cancellationStarted.isCompleted) cancellationStarted.complete();
    if (hostileCancel) return Completer<void>().future;
    return null;
  }

  ResponseBody get body => ResponseBody(
    _controller.stream,
    200,
    headers: {
      Headers.contentTypeHeader: ['text/event-stream'],
    },
  );

  void dispose() {
    _timer?.cancel();
    if (!_controller.isClosed) unawaited(_controller.close());
  }
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

    test('health and stop diagnostics never log provider data', () async {
      const apiKey = 'health-api-secret';
      const sessionKey = 'health-session-secret';
      const runId = 'provider-run-id-secret';
      const stackSecret = 'provider-api-stack-secret';
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.reject(
            DioException(
              requestOptions: options,
              error: '$apiKey $sessionKey provider-error-secret',
              stackTrace: StackTrace.fromString(stackSecret),
            ),
          ),
        ),
      );
      final service = HermesApiService(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'http://host:8642',
          apiKey: apiKey,
          sessionKey: sessionKey,
        ),
        dio: dio,
      );
      final logs = <String>[];
      final previousDebugPrint = debugPrint;
      debugPrint = (value, {wrapWidth}) {
        if (value != null) logs.add(value);
      };

      try {
        check(await service.health()).isFalse();
        await check(service.stopRun(runId)).throws<DioException>();
      } finally {
        debugPrint = previousDebugPrint;
      }

      final combinedLogs = logs.join('\n');
      check(combinedLogs).contains('health-check-failed');
      check(combinedLogs).contains('stop-run-failed');
      check(combinedLogs).not((value) => value.contains(apiKey));
      check(combinedLogs).not((value) => value.contains(sessionKey));
      check(combinedLogs).not((value) => value.contains(runId));
      check(combinedLogs).not((value) => value.contains(stackSecret));
      check(
        combinedLogs,
      ).not((value) => value.contains('provider-error-secret'));
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
      check(req.responseType).equals(ResponseType.stream);
    });

    test(
      'createRun accepts only strict non-secret string identifiers',
      () async {
        final invalidIds = <Object?>[
          {
            'nested': ['run'],
          },
          List<String>.filled(
            kMaxHermesOpaqueIdentifierCharacters + 1,
            'a',
          ).join(),
          'run\ncontrol',
          'prefix-secret-suffix',
        ];

        for (final invalidId in invalidIds) {
          final capture = _CaptureInterceptor({'run_id': invalidId});
          await check(
            _service(capture).createRun(input: 'hello'),
          ).throws<FormatException>();
        }
      },
    );

    test('createRun bounds its response body before JSON decode', () async {
      final cancelToken = CancelToken();
      final capture = _CaptureInterceptor(
        ResponseBody.fromString(
          jsonEncode({
            'run_id': List<String>.filled(
              kMaxHermesCreateResponseBytes,
              'x',
            ).join(),
          }),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );

      await check(
        _service(capture).createRun(input: 'hello', cancelToken: cancelToken),
      ).throws<FormatException>();

      check(cancelToken.isCancelled).isTrue();
      check(hermesCancellationWasInternal(cancelToken)).isTrue();
      check(capture.requests.single.responseType).equals(ResponseType.stream);
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
      'getRun bounds the streamed recovery body before JSON decode',
      () async {
        final cancelToken = CancelToken();
        final capture = _CaptureInterceptor(
          ResponseBody.fromString(
            jsonEncode({
              'status': 'completed',
              'output': List<String>.filled(128, 'x').join(),
            }),
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          ),
        );
        final service = _service(
          capture,
          streamLimits: const HermesStreamLimits(
            maxBytes: 64,
            maxCharacters: 1024,
          ),
        );

        await check(
          service.getRun('r1', cancelToken: cancelToken),
        ).throws<HermesStreamGuardException>();

        check(cancelToken.isCancelled).isTrue();
        check(capture.requests.single.responseType).equals(ResponseType.stream);
      },
    );

    test('getRun accepts an empty content-length header list', () async {
      final capture = _CaptureInterceptor(
        ResponseBody.fromString(
          '{"status":"completed","output":"done"}',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
            Headers.contentLengthHeader: const <String>[],
          },
        ),
      );

      final run = await _service(capture).getRun('r1');

      check(run['status']).equals('completed');
      check(run['output']).equals('done');
    });

    test('decoded recovery maps obey aggregate string limits', () async {
      final cancelToken = CancelToken();
      final capture = _CaptureInterceptor({
        'status': 'completed',
        'output': 'five!',
      });
      final service = _service(
        capture,
        streamLimits: const HermesStreamLimits(maxCharacters: 4),
      );

      await check(
        service.getRun('r1', cancelToken: cancelToken),
      ).throws<HermesStreamGuardException>();

      check(cancelToken.isCancelled).isTrue();
    });

    test('recovery polls get independent transfer budgets', () async {
      final cancelToken = CancelToken();
      final service = _service(
        _CaptureInterceptor({'status': 'completed', 'output': '0123456789'}),
        streamLimits: const HermesStreamLimits(
          maxBytes: 60,
          maxCharacters: 1024,
        ),
      );

      check(
        (await service.getRun('r1', cancelToken: cancelToken))['output'],
      ).equals('0123456789');
      check(
        (await service.getRun('r1', cancelToken: cancelToken))['output'],
      ).equals('0123456789');
      check(
        (await service.getRun('r1', cancelToken: cancelToken))['output'],
      ).equals('0123456789');

      check(cancelToken.isCancelled).isFalse();
    });

    for (final endpoint in const ['getRun', 'getResponse']) {
      test('$endpoint polls share one cumulative recovery deadline', () async {
        final clock = _MutableRecoveryClock();
        final capture = _AdvancingCaptureInterceptor(
          const {'status': 'running', 'output': ''},
          clock: clock,
          advances: const [Duration(seconds: 6), Duration(seconds: 5)],
        );
        final cancelToken = CancelToken();
        final service = _service(
          capture,
          streamLimits: const HermesStreamLimits(
            idleTimeout: Duration(seconds: 30),
            maxDuration: Duration(seconds: 10),
          ),
          recoveryClock: clock.call,
        );

        Future<Map<String, dynamic>> poll() => endpoint == 'getRun'
            ? service.getRun('r1', cancelToken: cancelToken)
            : service.getResponse('resp-1', cancelToken: cancelToken);

        check((await poll())['status']).equals('running');
        await check(poll()).throws<HermesStreamGuardException>();

        check(capture.requests).length.equals(2);
        check(
          capture.requests[1].receiveTimeout,
        ).equals(const Duration(seconds: 4));
        check(cancelToken.isCancelled).isTrue();
      });
    }

    test('getRun enforces recovery-body idle timeout before cleanup', () async {
      final source = _SseSource(hostileCancel: true);
      addTearDown(source.dispose);
      final cancelToken = CancelToken();
      final service = _service(
        _CaptureInterceptor(source.body),
        streamLimits: const HermesStreamLimits(
          idleTimeout: Duration(milliseconds: 15),
          maxDuration: Duration(seconds: 1),
          maxBytes: 1024,
          maxCharacters: 1024,
        ),
      );

      await expectLater(
        service.getRun('r1', cancelToken: cancelToken),
        throwsA(isA<HermesStreamGuardException>()),
      );
      check(cancelToken.isCancelled).isTrue();
      await source.cancellationStarted.future.timeout(
        const Duration(seconds: 1),
      );
    });

    for (final endpoint in _HermesStreamEndpoint.values) {
      group('${endpoint.label} stream guards', () {
        test('rejects endless tiny deltas at the character budget', () async {
          final source = _SseSource(
            repeatingFrame:
                'event: response.output_text.delta\n'
                'data: {"delta":"x"}\n\n',
          );
          addTearDown(source.dispose);
          final capture = _CaptureInterceptor(source.body);
          final cancelToken = CancelToken();
          final service = _service(
            capture,
            streamLimits: const HermesStreamLimits(
              idleTimeout: Duration(seconds: 1),
              maxDuration: Duration(seconds: 1),
              maxCharacters: 3,
              maxEvents: 100,
            ),
          );

          await expectLater(
            _collectEvents(service, endpoint, cancelToken),
            throwsA(
              isA<HermesStreamGuardException>().having(
                (error) => error.message,
                'message',
                contains('size limit'),
              ),
            ),
          );

          check(cancelToken.isCancelled).isTrue();
          await source.cancellationStarted.future.timeout(
            const Duration(seconds: 1),
          );
        });

        test('rejects endless valid events at the event budget', () async {
          final source = _SseSource(
            repeatingFrame:
                'event: response.output_text.delta\n'
                'data: {"delta":"x"}\n\n',
          );
          addTearDown(source.dispose);
          final cancelToken = CancelToken();
          final service = _service(
            _CaptureInterceptor(source.body),
            streamLimits: const HermesStreamLimits(
              idleTimeout: Duration(seconds: 1),
              maxDuration: Duration(seconds: 1),
              maxCharacters: 100,
              maxEvents: 3,
            ),
          );

          await expectLater(
            _collectEvents(service, endpoint, cancelToken),
            throwsA(
              isA<HermesStreamGuardException>().having(
                (error) => error.message,
                'message',
                contains('event limit'),
              ),
            ),
          );

          check(cancelToken.isCancelled).isTrue();
        });

        test('enforces idle timeout without waiting for cleanup', () async {
          final source = _SseSource(hostileCancel: true);
          addTearDown(source.dispose);
          final cancelToken = CancelToken();
          final service = _service(
            _CaptureInterceptor(source.body),
            streamLimits: const HermesStreamLimits(
              idleTimeout: Duration(milliseconds: 15),
              maxDuration: Duration(seconds: 1),
              maxCharacters: 100,
              maxEvents: 100,
            ),
          );

          await expectLater(
            _collectEvents(
              service,
              endpoint,
              cancelToken,
            ).timeout(const Duration(seconds: 1)),
            throwsA(
              isA<HermesStreamGuardException>().having(
                (error) => error.message,
                'message',
                contains('idle'),
              ),
            ),
          );

          check(cancelToken.isCancelled).isTrue();
        });

        test('heartbeats cannot defeat the absolute deadline', () async {
          final source = _SseSource(repeatingFrame: ': heartbeat\n\n');
          addTearDown(source.dispose);
          final cancelToken = CancelToken();
          final service = _service(
            _CaptureInterceptor(source.body),
            streamLimits: const HermesStreamLimits(
              idleTimeout: Duration(seconds: 1),
              maxDuration: Duration(milliseconds: 20),
              maxCharacters: 100,
              maxEvents: 100,
            ),
          );

          await expectLater(
            _collectEvents(service, endpoint, cancelToken),
            throwsA(
              isA<HermesStreamGuardException>().having(
                (error) => error.message,
                'message',
                contains('time limit'),
              ),
            ),
          );

          check(cancelToken.isCancelled).isTrue();
        });

        test('ignored heartbeats consume the raw transfer budget', () async {
          final source = _SseSource(
            repeatingFrame: ': provider heartbeat payload\n\n',
            hostileCancel: true,
          );
          addTearDown(source.dispose);
          final cancelToken = CancelToken();
          final service = _service(
            _CaptureInterceptor(source.body),
            streamLimits: const HermesStreamLimits(
              idleTimeout: Duration(seconds: 1),
              maxDuration: Duration(seconds: 1),
              maxBytes: 64,
              maxRawFrames: 100,
              maxCharacters: 100,
              maxEvents: 100,
            ),
          );

          await expectLater(
            _collectEvents(
              service,
              endpoint,
              cancelToken,
            ).timeout(const Duration(seconds: 1)),
            throwsA(
              isA<HermesStreamGuardException>().having(
                (error) => error.message,
                'message',
                contains('transfer limit'),
              ),
            ),
          );

          check(cancelToken.isCancelled).isTrue();
          await source.cancellationStarted.future.timeout(
            const Duration(seconds: 1),
          );
        });

        test('malformed JSON consumes the raw frame budget', () async {
          final source = _SseSource(repeatingFrame: 'data: {not-json}\n\n');
          addTearDown(source.dispose);
          final cancelToken = CancelToken();
          final service = _service(
            _CaptureInterceptor(source.body),
            streamLimits: const HermesStreamLimits(
              idleTimeout: Duration(seconds: 1),
              maxDuration: Duration(seconds: 1),
              maxBytes: 4096,
              maxRawFrames: 3,
              maxCharacters: 100,
              maxEvents: 100,
            ),
          );

          await expectLater(
            _collectEvents(service, endpoint, cancelToken),
            throwsA(
              isA<HermesStreamGuardException>().having(
                (error) => error.message,
                'message',
                contains('frame limit'),
              ),
            ),
          );

          check(cancelToken.isCancelled).isTrue();
        });

        test('accepts exact raw byte and frame boundaries', () async {
          const payload = ': heartbeat\r\n\r\ndata: [DONE]\r\n\r\n';
          final body = ResponseBody.fromString(
            payload,
            200,
            headers: {
              Headers.contentTypeHeader: ['text/event-stream'],
            },
          );
          final cancelToken = CancelToken();
          final service = _service(
            _CaptureInterceptor(body),
            streamLimits: HermesStreamLimits(
              idleTimeout: const Duration(seconds: 1),
              maxDuration: const Duration(seconds: 1),
              maxBytes: utf8.encode(payload).length,
              maxRawFrames: 2,
              maxCharacters: 100,
              maxEvents: 100,
            ),
          );

          final events = await _collectEvents(service, endpoint, cancelToken);

          check(events).length.equals(1);
          check(events.single).isA<HermesRunDone>();
          check(cancelToken.isCancelled).isTrue();
        });

        test('counts CRLF frame boundaries split across chunks once', () async {
          final chunks = <Uint8List>[
            Uint8List.fromList(utf8.encode(': heartbeat\r')),
            Uint8List.fromList(utf8.encode('\n\r')),
            Uint8List.fromList(utf8.encode('\ndata: [DONE]\r')),
            Uint8List.fromList(utf8.encode('\n\r')),
            Uint8List.fromList(utf8.encode('\n')),
          ];
          final body = ResponseBody(
            Stream<Uint8List>.fromIterable(chunks),
            200,
            headers: {
              Headers.contentTypeHeader: ['text/event-stream'],
            },
          );
          final cancelToken = CancelToken();
          final service = _service(
            _CaptureInterceptor(body),
            streamLimits: const HermesStreamLimits(
              idleTimeout: Duration(seconds: 1),
              maxDuration: Duration(seconds: 1),
              maxBytes: 64,
              maxRawFrames: 2,
              maxCharacters: 100,
              maxEvents: 100,
            ),
          );

          final events = await _collectEvents(service, endpoint, cancelToken);

          check(events).length.equals(1);
          check(events.single).isA<HermesRunDone>();
          check(cancelToken.isCancelled).isTrue();
        });

        test('event-only terminal cancels transport and completes', () async {
          final source = _SseSource(
            initialFrame: 'event: run.completed\ndata:\n\n',
          );
          addTearDown(source.dispose);
          final cancelToken = CancelToken();
          final service = _service(
            _CaptureInterceptor(source.body),
            streamLimits: const HermesStreamLimits(
              idleTimeout: Duration(seconds: 1),
              maxDuration: Duration(seconds: 1),
              maxCharacters: 100,
              maxEvents: 100,
            ),
          );

          final events = await _collectEvents(
            service,
            endpoint,
            cancelToken,
          ).timeout(const Duration(seconds: 1));

          check(events.whereType<HermesRunDone>().length).equals(1);
          check(cancelToken.isCancelled).isTrue();
          await source.cancellationStarted.future.timeout(
            const Duration(seconds: 1),
          );
        });

        test('premature EOF leaves the token available for recovery', () async {
          final body = ResponseBody.fromString(
            'event: run.started\ndata: {}\n\n',
            200,
            headers: {
              Headers.contentTypeHeader: ['text/event-stream'],
            },
          );
          final cancelToken = CancelToken();
          final service = _service(_CaptureInterceptor(body));

          final events = await _collectEvents(service, endpoint, cancelToken);

          check(events.whereType<HermesLifecycle>().length).equals(1);
          check(cancelToken.isCancelled).isFalse();
        });

        test('malformed UTF-8 remains observable after cancellation', () async {
          final body = ResponseBody(
            Stream<Uint8List>.value(Uint8List.fromList(const [0xFF])),
            200,
            headers: {
              Headers.contentTypeHeader: ['text/event-stream'],
            },
          );
          final cancelToken = CancelToken();
          final service = _service(_CaptureInterceptor(body));

          await check(
            _collectEvents(service, endpoint, cancelToken),
          ).throws<FormatException>();

          check(cancelToken.isCancelled).isTrue();
        });
      });
    }

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
        check(req.receiveTimeout).equals(kHermesStreamIdleTimeout);
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

    test('getResponse rejects deeply nested recovery JSON safely', () async {
      final cancelToken = CancelToken();
      final nested =
          '${List<String>.filled(kMaxHermesRecoveryJsonDepth, '[').join()}0${List<String>.filled(kMaxHermesRecoveryJsonDepth, ']').join()}';
      final capture = _CaptureInterceptor(
        ResponseBody.fromString(
          '{"output":$nested}',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );

      await check(
        _service(capture).getResponse('resp_1', cancelToken: cancelToken),
      ).throws<HermesStreamGuardException>();

      check(cancelToken.isCancelled).isTrue();
    });

    test(
      'getResponse rejects a wide decoded payload before queueing it',
      () async {
        final cancelToken = CancelToken();
        final capture = _CaptureInterceptor({
          'output': List<Object?>.filled(
            kMaxHermesRecoveryJsonNodes,
            null,
            growable: false,
          ),
        });

        await check(
          _service(capture).getResponse('resp_1', cancelToken: cancelToken),
        ).throws<HermesStreamGuardException>();

        check(cancelToken.isCancelled).isTrue();
        check(hermesCancellationWasInternal(cancelToken)).isTrue();
      },
    );

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

    test(
      'resolveApproval posts the official deny choice and legacy fields',
      () async {
        final capture = _CaptureInterceptor({});
        await _service(
          capture,
        ).resolveApproval('r1', approvalId: 'a1', approved: false);
        final req = capture.requests.single;
        check(req.path).equals('http://host:8642/v1/runs/r1/approval');
        check(req.data as Map<String, dynamic>).deepEquals({
          'choice': 'deny',
          'approval_id': 'a1',
          'approved': false,
          'decision': 'deny',
        });
      },
    );

    test('resolveApproval maps approval to the official once choice', () async {
      final capture = _CaptureInterceptor({});
      await _service(
        capture,
      ).resolveApproval('r1', approvalId: 'a1', approved: true);

      check(capture.requests.single.data as Map<String, dynamic>).deepEquals({
        'choice': 'once',
        'approval_id': 'a1',
        'approved': true,
        'decision': 'approve',
      });
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
