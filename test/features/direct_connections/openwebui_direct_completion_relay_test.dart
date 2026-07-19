import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/services/openwebui_direct_completion_relay.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OpenWebUiDirectCompletionRelay', () {
    test(
      'posts the server form and relays bounded raw streaming lines',
      () async {
        final http = _RecordingHttpAdapter(
          response: _streamResponse(<List<int>>[
            utf8.encode('data: {"choices":[{"delta":{"content":"hel'),
            utf8.encode('lo"}}]}\r'),
            utf8.encode('\n\n  \ndata: [DONE]'),
          ], contentType: 'text/event-stream'),
        );
        final order = <String>[];
        final emitted = <({String channel, Object payload})>[];
        final acknowledgements = <Object?>[];
        final relay = OpenWebUiDirectCompletionRelay(
          emitChannel: (channel, payload) {
            order.add('emit');
            emitted.add((channel: channel, payload: payload));
            return true;
          },
          dioFactory: (_) => _dio(http),
          closeClients: false,
        );
        final formData = <String, dynamic>{
          'model': 'prefix.untrusted-model',
          'stream': true,
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Hello'},
          ],
          'temperature': 0.25,
          'tools': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'function'},
          ],
        };

        final run = relay.start(
          profile: _profile(),
          trustedRemoteModelId: 'trusted-model',
          trustedUrlIndex: 2,
          expectedAccountId: 'user-1',
          expectedSessionId: 'socket-1',
          payload: _payload(formData: formData, urlIndex: '2'),
          acknowledge: (value) {
            order.add('ack');
            acknowledgements.add(value);
          },
        );
        await run.done;

        expect(http.requests, hasLength(1));
        final request = http.requests.single;
        expect(request.method, 'POST');
        expect(
          request.uri.toString(),
          'https://provider.test/v1/chat/completions',
        );
        expect(request.headers['Authorization'], 'Bearer provider-secret');
        expect(request.headers['X-Tenant'], 'tenant-a');
        final posted = (request.data as Map).cast<String, dynamic>();
        expect(posted['model'], 'trusted-model');
        expect(posted['stream'], isTrue);
        expect(posted['messages'], formData['messages']);
        expect(posted['temperature'], 0.25);
        expect(posted['tools'], formData['tools']);
        expect(formData['model'], 'prefix.untrusted-model');

        expect(acknowledgements, <Object?>[
          const <String, dynamic>{'status': true},
        ]);
        expect(order.first, 'ack');
        expect(emitted, <({String channel, Object payload})>[
          (
            channel: 'user-1:socket-1:request-1',
            payload: 'data: {"choices":[{"delta":{"content":"hello"}}]}',
          ),
          (channel: 'user-1:socket-1:request-1', payload: 'data: [DONE]'),
          (
            channel: 'user-1:socket-1:request-1',
            payload: const <String, dynamic>{'done': true},
          ),
        ]);
        expect(run.isCancelled, isFalse);
      },
    );

    test(
      'relays many tiny chunks without retaining per-chunk cancellation',
      () async {
        const chunkCount = 20000;
        final http = _RecordingHttpAdapter(
          response: _streamResponse(<List<int>>[
            for (var index = 0; index < chunkCount; index++) const <int>[0x78],
            const <int>[0x0a],
          ], contentType: 'text/event-stream'),
        );
        final acknowledgements = <Object?>[];
        final emitted = <Object>[];
        final relay = OpenWebUiDirectCompletionRelay(
          emitChannel: (_, payload) => _recordEmission(emitted, payload),
          dioFactory: (_) => _dio(http),
          closeClients: false,
        );

        final run = relay.start(
          profile: _profile(),
          trustedRemoteModelId: 'trusted-model',
          trustedUrlIndex: 2,
          expectedAccountId: 'user-1',
          expectedSessionId: 'socket-1',
          payload: _payload(
            formData: <String, dynamic>{'model': 'model', 'stream': true},
          ),
          acknowledge: acknowledgements.add,
        );
        await run.done;

        expect(acknowledgements, <Object?>[
          const <String, dynamic>{'status': true},
        ]);
        expect(emitted, <Object>[
          String.fromCharCodes(List<int>.filled(chunkCount, 0x78)),
          const <String, dynamic>{'done': true},
        ]);
      },
    );

    test('ignores buffered and later lines after the first terminal', () async {
      final http = _RecordingHttpAdapter(
        response: _streamResponse(<List<int>>[
          utf8.encode('data: [DONE]\ndata: must-not-relay\n'),
          utf8.encode('data: also-must-not-relay\n'),
        ], contentType: 'text/event-stream'),
      );
      final emitted = <Object>[];
      final relay = OpenWebUiDirectCompletionRelay(
        emitChannel: (_, payload) => _recordEmission(emitted, payload),
        dioFactory: (_) => _dio(http),
        closeClients: false,
      );

      final run = relay.start(
        profile: _profile(),
        trustedRemoteModelId: 'trusted-model',
        trustedUrlIndex: 2,
        expectedAccountId: 'user-1',
        expectedSessionId: 'socket-1',
        payload: _payload(
          formData: <String, dynamic>{'model': 'model', 'stream': true},
        ),
        acknowledge: (_) {},
      );
      await run.done;

      expect(emitted, <Object>[
        'data: [DONE]',
        const <String, dynamic>{'done': true},
      ]);
    });

    test('treats every error after terminal as a drain failure', () async {
      final terminalBytes = utf8.encode('data: [DONE]\n');
      final http = _TerminalThenOversizedStreamHttpAdapter(
        terminalBytes: terminalBytes,
        trailingBytes: utf8.encode('trailing bytes beyond the transfer budget'),
      );
      final emitted = <Object>[];
      final relay = OpenWebUiDirectCompletionRelay(
        emitChannel: (_, payload) => _recordEmission(emitted, payload),
        dioFactory: (_) => _dio(http),
        closeClients: false,
        maxStreamBytes: terminalBytes.length + 1,
      );

      final run = relay.start(
        profile: _profile(),
        trustedRemoteModelId: 'trusted-model',
        trustedUrlIndex: 2,
        expectedAccountId: 'user-1',
        expectedSessionId: 'socket-1',
        payload: _payload(
          formData: <String, dynamic>{'model': 'model', 'stream': true},
        ),
        acknowledge: (_) {},
      );
      await run.done;
      await http.cancelled.future.timeout(const Duration(seconds: 1));

      expect(emitted, <Object>[
        'data: [DONE]',
        const <String, dynamic>{'done': true},
      ]);
    });

    test(
      'returns provider JSON through the acknowledgement when not streaming',
      () async {
        final http = _RecordingHttpAdapter(
          response: _streamResponse(<List<int>>[
            utf8.encode('{"id":"completion-1","choices":[]}'),
          ], contentType: 'application/json'),
        );
        final acknowledgements = <Object?>[];
        final emitted = <Object>[];
        final relay = OpenWebUiDirectCompletionRelay(
          emitChannel: (_, payload) => _recordEmission(emitted, payload),
          dioFactory: (_) => _dio(http),
          closeClients: false,
        );

        final run = relay.start(
          profile: _profile(),
          trustedRemoteModelId: 'trusted-model',
          trustedUrlIndex: 2,
          expectedAccountId: 'user-1',
          expectedSessionId: 'socket-1',
          payload: _payload(
            formData: <String, dynamic>{
              'model': 'prefix.untrusted-model',
              'stream': false,
              'messages': const <Object>[],
            },
          ),
          acknowledge: acknowledgements.add,
        );
        await run.done;

        expect(acknowledgements, <Object?>[
          <String, dynamic>{'id': 'completion-1', 'choices': <Object>[]},
        ]);
        expect(emitted, <Object>[
          const <String, dynamic>{'done': true},
        ]);
        expect((http.requests.single.data as Map)['model'], 'trusted-model');
      },
    );

    test(
      'standalone relay reuses one keep-alive connection for clean streams',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var requestCount = 0;
        final remotePorts = <int>{};
        final serverErrors = <Object>[];
        server.listen((request) async {
          try {
            requestCount++;
            remotePorts.add(request.connectionInfo!.remotePort);
            await utf8.decoder.bind(request).join();
            request.response
              ..persistentConnection = true
              ..headers.contentType = ContentType(
                'text',
                'event-stream',
                charset: 'utf-8',
              );
            request.response.write(
              'data: {"choices":[{"delta":{"content":"$requestCount"}}]}\n\n',
            );
            request.response.write('data: [DONE]\n\n');
            await request.response.close();
          } catch (error) {
            serverErrors.add(error);
          }
        });
        final relay = OpenWebUiDirectCompletionRelay(
          emitChannel: (_, _) => true,
        );
        final profile = _profile().copyWith(
          baseUrl: 'http://${server.address.address}:${server.port}/v1',
        );

        try {
          for (var index = 1; index <= 2; index++) {
            final acknowledgements = <Object?>[];
            final run = relay.start(
              profile: profile,
              trustedRemoteModelId: 'trusted-model',
              trustedUrlIndex: 2,
              expectedAccountId: 'user-1',
              expectedSessionId: 'socket-1',
              payload: _payload(
                formData: <String, dynamic>{'model': 'model', 'stream': true},
              ),
              acknowledge: acknowledgements.add,
            );
            await run.done;
            expect(acknowledgements, <Object?>[
              const <String, dynamic>{'status': true},
            ]);
          }
          expect(requestCount, 2);
          expect(remotePorts, hasLength(1));
          expect(
            serverErrors,
            isEmpty,
            reason: 'responses must not be aborted',
          );
        } finally {
          relay.dispose();
          await server.close(force: true);
        }
      },
    );

    test(
      'failed success-drain aborts transport before the run releases ownership',
      () async {
        final http = _TerminalThenPendingStreamHttpAdapter();
        final emitted = <Object>[];
        final relay = OpenWebUiDirectCompletionRelay(
          emitChannel: (_, payload) => _recordEmission(emitted, payload),
          dioFactory: (_) => _dio(http),
          closeClients: false,
          successDrainTimeout: const Duration(milliseconds: 10),
        );

        final run = relay.start(
          profile: _profile(),
          trustedRemoteModelId: 'trusted-model',
          trustedUrlIndex: 2,
          expectedAccountId: 'user-1',
          expectedSessionId: 'socket-1',
          payload: _payload(
            formData: <String, dynamic>{'model': 'model', 'stream': true},
          ),
          acknowledge: (_) {},
        );
        await run.done.timeout(const Duration(seconds: 1));

        expect(run.isCancelled, isFalse);
        expect(http.cancelled.isCompleted, isTrue);
        expect(emitted, <Object>[
          'data: [DONE]',
          const <String, dynamic>{'done': true},
        ]);
      },
    );

    test(
      'rejects a mismatched model URL index without contacting provider',
      () async {
        final http = _RecordingHttpAdapter(
          response: _streamResponse(const <List<int>>[]),
        );
        final acknowledgements = <Object?>[];
        final emitted = <Object>[];
        final relay = OpenWebUiDirectCompletionRelay(
          emitChannel: (_, payload) => _recordEmission(emitted, payload),
          dioFactory: (_) => _dio(http),
          closeClients: false,
        );

        final run = relay.start(
          profile: _profile(),
          trustedRemoteModelId: 'trusted-model',
          trustedUrlIndex: 2,
          expectedAccountId: 'user-1',
          expectedSessionId: 'socket-1',
          payload: _payload(
            formData: <String, dynamic>{
              'model': 'untrusted-model',
              'stream': true,
            },
            urlIndex: 3,
          ),
          acknowledge: acknowledgements.add,
        );
        await run.done;

        expect(http.requests, isEmpty);
        expect(acknowledgements, <Object?>[
          const <String, dynamic>{
            'status': false,
            'error': 'Open WebUI sent an invalid direct-completion request.',
          },
        ]);
        expect(emitted, <Object>[
          const <String, dynamic>{'done': true},
        ]);
      },
    );

    test('does not emit to a channel for a foreign socket session', () async {
      final http = _RecordingHttpAdapter(
        response: _streamResponse(const <List<int>>[]),
      );
      final acknowledgements = <Object?>[];
      final emitted = <Object>[];
      final relay = OpenWebUiDirectCompletionRelay(
        emitChannel: (_, payload) => _recordEmission(emitted, payload),
        dioFactory: (_) => _dio(http),
        closeClients: false,
      );
      final payload = _payload(
        formData: <String, dynamic>{'model': 'model', 'stream': true},
      )..['session_id'] = 'foreign-socket';

      final run = relay.start(
        profile: _profile(),
        trustedRemoteModelId: 'trusted-model',
        trustedUrlIndex: 2,
        expectedAccountId: 'user-1',
        expectedSessionId: 'socket-1',
        payload: payload,
        acknowledge: acknowledgements.add,
      );
      await run.done;

      expect(http.requests, isEmpty);
      expect((acknowledgements.single as Map)['status'], isFalse);
      expect(emitted, isEmpty);
    });

    test(
      'relays a structured error when streaming fails after acknowledgement',
      () async {
        final http = _RecordingHttpAdapter(
          response: _streamResponse(<List<int>>[
            utf8.encode('12345\n'),
          ], contentType: 'text/event-stream'),
        );
        final acknowledgements = <Object?>[];
        final emitted = <Object>[];
        final relay = OpenWebUiDirectCompletionRelay(
          emitChannel: (_, payload) => _recordEmission(emitted, payload),
          dioFactory: (_) => _dio(http),
          closeClients: false,
          maxStreamCharacters: 4,
        );

        final run = relay.start(
          profile: _profile(),
          trustedRemoteModelId: 'trusted-model',
          trustedUrlIndex: 2,
          expectedAccountId: 'user-1',
          expectedSessionId: 'socket-1',
          payload: _payload(
            formData: <String, dynamic>{'model': 'model', 'stream': true},
          ),
          acknowledge: acknowledgements.add,
        );
        await run.done;

        expect(acknowledgements, <Object?>[
          const <String, dynamic>{'status': true},
        ]);
        expect(emitted, <Object>[
          const <String, dynamic>{
            'error': <String, dynamic>{
              'message':
                  'The provider response exceeded Conduit\'s size limit.',
            },
          },
          const <String, dynamic>{'done': true},
        ]);
      },
    );

    test(
      'cancellation aborts a streaming relay and still emits done',
      () async {
        final http = _PendingStreamHttpAdapter();
        final acknowledged = Completer<void>();
        final emitted = <Object>[];
        final relay = OpenWebUiDirectCompletionRelay(
          emitChannel: (_, payload) => _recordEmission(emitted, payload),
          dioFactory: (_) => _dio(http),
          closeClients: false,
        );

        final run = relay.start(
          profile: _profile(),
          trustedRemoteModelId: 'trusted-model',
          trustedUrlIndex: 2,
          expectedAccountId: 'user-1',
          expectedSessionId: 'socket-1',
          payload: _payload(
            formData: <String, dynamic>{'model': 'model', 'stream': true},
          ),
          acknowledge: (_) {
            if (!acknowledged.isCompleted) acknowledged.complete();
          },
        );
        await acknowledged.future;
        await run.cancel();

        expect(run.isCancelled, isTrue);
        expect(emitted, <Object>[
          const <String, dynamic>{'done': true},
        ]);
        await http.cancelled.future;
      },
    );

    test('sanitizes credentials from pre-stream RPC errors', () async {
      final acknowledgements = <Object?>[];
      final emitted = <Object>[];
      final relay = OpenWebUiDirectCompletionRelay(
        emitChannel: (_, payload) => _recordEmission(emitted, payload),
        dioFactory: (_) => throw const DirectProviderException(
          'Authorization: Bearer provider-secret',
        ),
      );

      final run = relay.start(
        profile: _profile(),
        trustedRemoteModelId: 'trusted-model',
        trustedUrlIndex: 2,
        expectedAccountId: 'user-1',
        expectedSessionId: 'socket-1',
        payload: _payload(
          formData: <String, dynamic>{'model': 'model', 'stream': true},
        ),
        acknowledge: acknowledgements.add,
      );
      await run.done;

      final error = (acknowledgements.single as Map)['error'] as String;
      expect(error, isNot(contains('provider-secret')));
      expect(error, contains('[REDACTED]'));
      expect(emitted, <Object>[
        const <String, dynamic>{'done': true},
      ]);
    });
  });
}

bool _recordEmission(List<Object> emitted, Object payload) {
  emitted.add(payload);
  return true;
}

DirectConnectionProfile _profile() => DirectConnectionProfile(
  id: 'server-profile',
  name: 'Server profile',
  adapterKey: kOpenAiCompatibleAdapterKey,
  baseUrl: 'https://provider.test/v1',
  apiKey: 'provider-secret',
  customHeaders: const <String, String>{'X-Tenant': 'tenant-a'},
);

Map<String, dynamic> _payload({
  required Map<String, dynamic> formData,
  Object urlIndex = 2,
}) => <String, dynamic>{
  'session_id': 'socket-1',
  'channel': 'user-1:socket-1:request-1',
  'form_data': formData,
  'model': <String, dynamic>{
    'id': formData['model'],
    'direct': true,
    'urlIdx': urlIndex,
  },
};

Dio _dio(HttpClientAdapter adapter) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  return dio;
}

ResponseBody _streamResponse(
  List<List<int>> chunks, {
  String contentType = 'application/json',
}) => ResponseBody(
  Stream<Uint8List>.fromIterable(chunks.map<Uint8List>(Uint8List.fromList)),
  200,
  headers: <String, List<String>>{
    'content-type': <String>[contentType],
  },
);

final class _RecordingHttpAdapter implements HttpClientAdapter {
  _RecordingHttpAdapter({required this.response});

  final ResponseBody response;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return response;
  }

  @override
  void close({bool force = false}) {}
}

final class _PendingStreamHttpAdapter implements HttpClientAdapter {
  final Completer<void> cancelled = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    late final StreamController<Uint8List> controller;
    controller = StreamController<Uint8List>();
    unawaited(
      cancelFuture?.then<void>((_) {
            if (!cancelled.isCompleted) cancelled.complete();
            unawaited(controller.close());
          }) ??
          Future<void>.value(),
    );
    return ResponseBody(
      controller.stream,
      200,
      headers: const <String, List<String>>{
        'content-type': <String>['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _TerminalThenPendingStreamHttpAdapter implements HttpClientAdapter {
  final Completer<void> cancelled = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final controller = StreamController<Uint8List>();
    unawaited(
      cancelFuture?.then<void>((_) async {
            if (!cancelled.isCompleted) cancelled.complete();
            await controller.close();
          }) ??
          Future<void>.value(),
    );
    scheduleMicrotask(
      () => controller.add(Uint8List.fromList(utf8.encode('data: [DONE]\n'))),
    );
    return ResponseBody(
      controller.stream,
      200,
      headers: const <String, List<String>>{
        'content-type': <String>['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _TerminalThenOversizedStreamHttpAdapter
    implements HttpClientAdapter {
  _TerminalThenOversizedStreamHttpAdapter({
    required this.terminalBytes,
    required this.trailingBytes,
  });

  final List<int> terminalBytes;
  final List<int> trailingBytes;
  final Completer<void> cancelled = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    late final StreamController<Uint8List> controller;
    controller = StreamController<Uint8List>(
      onListen: () {
        controller
          ..add(Uint8List.fromList(terminalBytes))
          ..add(Uint8List.fromList(trailingBytes));
      },
    );
    unawaited(
      cancelFuture?.then<void>((_) async {
            if (!cancelled.isCompleted) cancelled.complete();
            await controller.close();
          }) ??
          Future<void>.value(),
    );
    return ResponseBody(
      controller.stream,
      200,
      headers: const <String, List<String>>{
        'content-type': <String>['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
