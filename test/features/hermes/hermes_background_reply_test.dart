import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/testing/fake_app_lifecycle.dart';
import 'package:conduit_core/ports/app_lifecycle.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final class _MockWebSocketChannel extends Mock implements WebSocketChannel {}

final class _MockWebSocketSink extends Mock implements WebSocketSink {}

/// Minimal gateway stub: answers `session.create` WITHOUT a `running` field,
/// which is what a real Hermes 0.20.x gateway does, then lets the test push
/// `session.info` frames by hand.
final class _GatewayHarness {
  _GatewayHarness() {
    when(() => channel.ready).thenAnswer((_) async {});
    when(() => channel.stream).thenAnswer((_) {
      // The client subscribes inside connect(); announce readiness right after
      // so the handshake completes without the test guessing at timing.
      scheduleMicrotask(ready);
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
      final error = errorResponder(method);
      if (error != null) {
        scheduleMicrotask(
          () => incoming.add(
            jsonEncode({'jsonrpc': '2.0', 'id': id, 'error': error}),
          ),
        );
        return;
      }
      final result = responder(method);
      if (result == null) return;
      scheduleMicrotask(
        () => incoming.add(
          jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
        ),
      );
    });
  }

  final channel = _MockWebSocketChannel();
  final sink = _MockWebSocketSink();
  final incoming = StreamController<dynamic>.broadcast();
  final sent = <Map<String, dynamic>>[];

  Map<String, dynamic>? Function(String method) responder = (_) => null;

  /// When non-null for a method, the gateway answers with a JSON-RPC error
  /// instead of a result.
  Map<String, dynamic>? Function(String method) errorResponder = (_) => null;

  void ready() {
    if (incoming.isClosed) return;
    incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': {}},
      }),
    );
  }

  /// Pushes the `session.info` the gateway emits when a turn settles.
  void sessionInfo(String runtimeId, {required bool running}) => incoming.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {
        'type': 'session.info',
        'session_id': runtimeId,
        'payload': {'running': running},
      },
    }),
  );

  /// Pushes a turn event for [runtimeId], e.g. `message.start`.
  void event(
    String runtimeId,
    String type, [
    Map<String, dynamic> payload = const {},
  ]) => incoming.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {'type': type, 'session_id': runtimeId, 'payload': payload},
    }),
  );

  Future<void> dispose() => incoming.close();
}

Dio _statusDio([_StubAdapter? adapter]) {
  final dio = Dio();
  dio.httpClientAdapter = adapter ?? _StubAdapter();
  return dio;
}

/// Serves `/api/status` (auth not required) so `_connect` can reach the socket,
/// and records every REST URI so tests can assert profile scoping.
final class _StubAdapter implements HttpClientAdapter {
  _StubAdapter();
  final List<Map<String, dynamic>> messages = const [];
  final Map<String, dynamic>? agentConfig = null, modelSummary = null;
  final requested = <Uri>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri);
    final settings = switch (options.uri.path) {
      '/api/config' => agentConfig == null ? null : {'config': agentConfig},
      '/api/model/info' => modelSummary,
      _ => null,
    };
    if (settings != null) {
      return ResponseBody.fromString(
        jsonEncode(settings),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (options.uri.path.endsWith('/read-data-url')) {
      return ResponseBody.fromString(
        jsonEncode({'dataUrl': 'data:text/plain;base64,SGVsbG8='}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (options.uri.path.endsWith('/messages')) {
      return ResponseBody.fromString(
        jsonEncode({'messages': messages}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    final body = jsonEncode({
      'version': '0.20.1',
      'auth_required': false,
      'gateway_running': true,
    });
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

final class _TimeoutAdapter extends _StubAdapter {
  bool fail = false;
  int failures = 0;
  DioExceptionType failureType = DioExceptionType.connectionTimeout;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) {
    if (fail) {
      failures++;
      throw DioException(
        requestOptions: options,
        type: failureType,
        message: 'Simulated connection timeout',
        response: failureType == DioExceptionType.badResponse
            ? Response(requestOptions: options, statusCode: 401)
            : null,
      );
    }
    return super.fetch(options, stream, cancelFuture);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  });
  tearDown(PreferencesStore.debugReset);

  test(
    'Desktop server approval reaches the turn and replies to its wire id',
    () async {
      final harness = _GatewayHarness();
      final service = HermesDesktopApiService(
        config: HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          mode: HermesBackendMode.desktopGateway,
          desktopCredentials: HermesDesktopCredentials(
            legacyToken: 'test-token',
          ),
        ),
        dio: _statusDio(),
        rpc: HermesDesktopRpcClient(
          channelFactory: (_, _, {httpClient}) => harness.channel,
        ),
      );
      addTearDown(() async {
        service.close();
        await harness.dispose();
      });
      harness.responder = (method) => switch (method) {
        'session.resume' => {
          'session_id': 'runtime-1',
          'stored_session_id': 'stored-1',
          'running': false,
        },
        'prompt.submit' => {'status': 'streaming'},
        'config.get' => {'value': 'medium'},
        _ => const {},
      };
      final response = await service.streamDesktopResponse(
        HermesChatInput.text('Install the requested plugin'),
        sessionId: 'stored-1',
        options: const HermesDesktopSessionOptions(),
      );
      final approval = Completer<HermesApprovalRequested>();
      final events = <HermesRunEvent>[];
      final done = Completer<void>();
      response.events.listen((event) {
        events.add(event);
        if (event is HermesApprovalRequested && !approval.isCompleted) {
          approval.complete(event);
        }
      }, onDone: done.complete);
      harness.event('runtime-1', 'message.start');
      harness.incoming.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 'srq-012345abcdef',
          'method': 'approval',
          'params': {
            'session_id': 'runtime-1',
            'request_id': 'approval-queue-1',
            'command': 'hermes plugins install example --enable',
            'choices': ['once', 'deny'],
          },
        }),
      );
      final requested = await approval.future.timeout(
        const Duration(seconds: 2),
      );
      expect(requested.approvalId, 'approval-queue-1');
      expect(requested.choices, ['once', 'deny']);
      expect(
        harness.sent.where((frame) => frame['id'] == 'srq-012345abcdef'),
        isEmpty,
      );
      await service.resolveApprovalChoice(
        'runtime-1',
        approvalId: requested.approvalId,
        choice: 'once',
      );
      expect(
        harness.sent.singleWhere((frame) => frame['id'] == 'srq-012345abcdef'),
        {
          'jsonrpc': '2.0',
          'id': 'srq-012345abcdef',
          'result': {'choice': 'once'},
        },
      );
      expect(
        harness.sent.where((frame) => frame['method'] == 'approval.respond'),
        isEmpty,
      );
      harness.sessionInfo('runtime-1', running: false);
      await done.future.timeout(const Duration(seconds: 2));
      expect(events.whereType<HermesRunError>(), isEmpty);
    },
  );

  for (final recoverInBackground in [false, true]) {
    test(
      'accepted reply survives background timeout and recovers ${recoverInBackground ? "in background" : "on return"} without resending',
      () async {
        final harness = _GatewayHarness();
        final adapter = _TimeoutAdapter();
        final lifecycle = FakeAppLifecycle();
        final rpc = HermesDesktopRpcClient(
          channelFactory: (_, _, {httpClient}) => harness.channel,
        );
        final service = HermesDesktopApiService(
          config: HermesConfig(
            enabled: true,
            baseUrl: 'https://hermes.example',
            mode: HermesBackendMode.desktopGateway,
            desktopCredentials: HermesDesktopCredentials(
              legacyToken: 'test-token',
            ),
          ),
          dio: _statusDio(adapter),
          rpc: rpc,
        );
        service.startLifecycleObservation(lifecycle);
        addTearDown(() async {
          service.close();
          await harness.dispose();
          await lifecycle.dispose();
        });
        harness.responder = (method) => switch (method) {
          'session.resume' => {
            'session_id': 'runtime-1',
            'stored_session_id': 'stored-1',
            'running': false,
          },
          'prompt.submit' => {'status': 'streaming'},
          'config.get' => {'value': 'medium'},
          _ => const {},
        };
        final response = await service.streamDesktopResponse(
          HermesChatInput.text('hello'),
          sessionId: 'stored-1',
          options: const HermesDesktopSessionOptions(),
        );
        final events = <HermesRunEvent>[];
        var ended = false;
        final done = Completer<void>();
        response.events.listen(
          events.add,
          onDone: () {
            ended = true;
            done.complete();
          },
        );
        harness.event('runtime-1', 'message.start');
        harness.event('runtime-1', 'message.delta', {'text': 'Working'});
        await Future<void>.delayed(Duration.zero);
        lifecycle.emit(AppLifecyclePhase.paused);
        adapter.fail = true;
        harness.incoming.addError(StateError('Transport lost'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(adapter.failures, greaterThan(0));
        expect(ended, isFalse);
        expect(events.whereType<HermesRunError>(), isEmpty);
        adapter.fail = false;
        if (!recoverInBackground) lifecycle.emit(AppLifecyclePhase.resumed);
        await done.future.timeout(const Duration(seconds: 4));
        expect(events.whereType<HermesRunError>(), isEmpty);
        expect(events.whereType<HermesRunDone>(), hasLength(1));
        expect(
          harness.sent.where((frame) => frame['method'] == 'prompt.submit'),
          hasLength(1),
        );
      },
    );
  }

  test(
    'closing while background recovery is waiting settles the active stream',
    () async {
      final harness = _GatewayHarness();
      final adapter = _TimeoutAdapter();
      final lifecycle = FakeAppLifecycle();
      final service = HermesDesktopApiService(
        config: HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          mode: HermesBackendMode.desktopGateway,
          desktopCredentials: HermesDesktopCredentials(
            legacyToken: 'test-token',
          ),
        ),
        dio: _statusDio(adapter),
        rpc: HermesDesktopRpcClient(
          channelFactory: (_, _, {httpClient}) => harness.channel,
        ),
      );
      service.startLifecycleObservation(lifecycle);
      addTearDown(() async {
        service.close();
        await harness.dispose();
        await lifecycle.dispose();
      });
      harness.responder = (method) => switch (method) {
        'session.resume' => {
          'session_id': 'runtime-1',
          'stored_session_id': 'stored-1',
          'running': false,
        },
        'config.get' => {'value': 'medium'},
        _ => const {},
      };
      final response = await service.streamDesktopResponse(
        HermesChatInput.text('hello'),
        sessionId: 'stored-1',
        options: const HermesDesktopSessionOptions(),
      );
      final events = response.events.toList();
      lifecycle.emit(AppLifecyclePhase.paused);
      adapter.fail = true;
      harness.incoming.addError(StateError('Transport lost'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      service.close();
      final closedEvents = await events.timeout(const Duration(seconds: 1));
      expect(closedEvents.whereType<HermesRunError>(), hasLength(1));
    },
  );

  test('Stop during background retry settles without resubmitting', () async {
    final harness = _GatewayHarness();
    final adapter = _TimeoutAdapter();
    final lifecycle = FakeAppLifecycle();
    final service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
        desktopCredentials: HermesDesktopCredentials(legacyToken: 'test-token'),
      ),
      dio: _statusDio(adapter),
      rpc: HermesDesktopRpcClient(
        channelFactory: (_, _, {httpClient}) => harness.channel,
      ),
    );
    service.startLifecycleObservation(lifecycle);
    addTearDown(() async {
      service.close();
      await harness.dispose();
      await lifecycle.dispose();
    });
    harness.responder = (method) => switch (method) {
      'session.resume' => {
        'session_id': 'runtime-1',
        'stored_session_id': 'stored-1',
        'running': false,
      },
      'config.get' => {'value': 'medium'},
      _ => const {},
    };
    final cancellation = CancelToken();
    final response = await service.streamDesktopResponse(
      HermesChatInput.text('hello'),
      sessionId: 'stored-1',
      options: const HermesDesktopSessionOptions(),
      cancelToken: cancellation,
    );
    final events = response.events.toList();
    lifecycle.emit(AppLifecyclePhase.paused);
    adapter.fail = true;
    harness.incoming.addError(StateError('Transport lost'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    cancellation.cancel('User stopped');
    await events.timeout(const Duration(seconds: 1));
    expect(
      harness.sent.where((frame) => frame['method'] == 'prompt.submit'),
      hasLength(1),
    );
  });

  test(
    'authentication failures in the background still surface immediately',
    () async {
      final harness = _GatewayHarness();
      final adapter = _TimeoutAdapter();
      final lifecycle = FakeAppLifecycle();
      final service = HermesDesktopApiService(
        config: HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          mode: HermesBackendMode.desktopGateway,
          desktopCredentials: HermesDesktopCredentials(
            legacyToken: 'test-token',
          ),
        ),
        dio: _statusDio(adapter),
        rpc: HermesDesktopRpcClient(
          channelFactory: (_, _, {httpClient}) => harness.channel,
        ),
      );
      service.startLifecycleObservation(lifecycle);
      addTearDown(() async {
        service.close();
        await harness.dispose();
        await lifecycle.dispose();
      });
      harness.responder = (method) => switch (method) {
        'session.resume' => {
          'session_id': 'runtime-1',
          'stored_session_id': 'stored-1',
          'running': false,
        },
        'config.get' => {'value': 'medium'},
        _ => const {},
      };
      final response = await service.streamDesktopResponse(
        HermesChatInput.text('hello'),
        sessionId: 'stored-1',
        options: const HermesDesktopSessionOptions(),
      );
      final events = response.events.toList();
      lifecycle.emit(AppLifecyclePhase.paused);
      adapter.failureType = DioExceptionType.badResponse;
      adapter.fail = true;
      harness.incoming.addError(StateError('Transport lost'));
      expect(
        (await events.timeout(const Duration(seconds: 1)))
            .whereType<HermesRunError>(),
        hasLength(1),
      );
    },
  );
}
