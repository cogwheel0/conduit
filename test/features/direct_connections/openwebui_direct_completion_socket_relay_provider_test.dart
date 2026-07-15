import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/models/socket_health.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/socket_service.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/models/openwebui_direct_connection.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit/features/direct_connections/services/openwebui_direct_completion_relay.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('openWebUiDirectCompletionSocketRelayProvider', () {
    test(
      'installs its handler when a listened snapshot finishes loading',
      () async {
        final socket = _FakeSocketService();
        final snapshotController = _DeferredSnapshotController();
        final api = _FakeApiService(socket.serverConfig);
        final container = ProviderContainer(
          overrides: [
            socketServiceProvider.overrideWithValue(socket),
            apiServiceProvider.overrideWithValue(api),
            openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
            directModelRegistryProvider.overrideWithValue(_registry()),
            openWebUiDirectConnectionsProvider.overrideWith(
              () => snapshotController,
            ),
            openWebUiDirectCompletionRelayFactoryProvider.overrideWithValue(
              ({required emitChannel}) => throw StateError('not invoked'),
            ),
          ],
        );
        final relaySubscription = container.listen<void>(
          openWebUiDirectCompletionSocketRelayProvider,
          (previous, next) {},
          fireImmediately: true,
        );
        addTearDown(relaySubscription.close);
        addTearDown(container.dispose);
        addTearDown(socket.dispose);

        expect(socket.registration, isNull);
        snapshotController.publish(_snapshot());
        await container.read(openWebUiDirectConnectionsProvider.future);
        await Future<void>.delayed(Duration.zero);

        expect(socket.registration, isNotNull);
        expect(socket.registration!.requireFocus, isFalse);
      },
    );

    test('rejects a callback captured before snapshot replacement', () async {
      final socket = _FakeSocketService();
      final snapshotController = _MutableSnapshotController(_snapshot());
      final api = _FakeApiService(socket.serverConfig);
      var relayCreations = 0;
      final container = ProviderContainer(
        overrides: [
          socketServiceProvider.overrideWithValue(socket),
          apiServiceProvider.overrideWithValue(api),
          openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
          directModelRegistryProvider.overrideWithValue(_registry()),
          openWebUiDirectConnectionsProvider.overrideWith(
            () => snapshotController,
          ),
          openWebUiDirectCompletionRelayFactoryProvider.overrideWithValue(({
            required emitChannel,
          }) {
            relayCreations += 1;
            throw StateError('not invoked');
          }),
        ],
      );
      final relaySubscription = container.listen<void>(
        openWebUiDirectCompletionSocketRelayProvider,
        (previous, next) {},
        fireImmediately: true,
      );
      addTearDown(relaySubscription.close);
      addTearDown(container.dispose);
      addTearDown(socket.dispose);

      await container.read(openWebUiDirectConnectionsProvider.future);
      await Future<void>.delayed(Duration.zero);
      final staleRegistration = socket.registration!;

      snapshotController.replace(_snapshot());
      await Future<void>.delayed(Duration.zero);
      expect(socket.registration, isNot(same(staleRegistration)));

      final acknowledgements = <Object?>[];
      staleRegistration.handler(
        _requestEnvelope(
          urlIndex: 2,
          wireModelId: 'server-prefix.remote-model',
        ),
        acknowledgements.add,
      );

      expect(relayCreations, 0);
      expect(socket.emissions, isEmpty);
      expect(acknowledgements, <Object?>[
        const <String, dynamic>{
          'status': false,
          'error': 'The direct connection session changed.',
        },
      ]);
    });

    test('rejects an emitter captured before snapshot replacement', () async {
      final socket = _FakeSocketService();
      final snapshotController = _MutableSnapshotController(_snapshot());
      final api = _FakeApiService(socket.serverConfig);
      late OpenWebUiDirectChannelEmitter capturedEmitter;
      final container = ProviderContainer(
        overrides: [
          socketServiceProvider.overrideWithValue(socket),
          apiServiceProvider.overrideWithValue(api),
          openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
          directModelRegistryProvider.overrideWithValue(_registry()),
          openWebUiDirectConnectionsProvider.overrideWith(
            () => snapshotController,
          ),
          openWebUiDirectCompletionRelayFactoryProvider.overrideWithValue(({
            required emitChannel,
          }) {
            capturedEmitter = emitChannel;
            throw StateError('capture the emitter without starting a relay');
          }),
        ],
      );
      final relaySubscription = container.listen<void>(
        openWebUiDirectCompletionSocketRelayProvider,
        (previous, next) {},
        fireImmediately: true,
      );
      addTearDown(relaySubscription.close);
      addTearDown(container.dispose);
      addTearDown(socket.dispose);

      await container.read(openWebUiDirectConnectionsProvider.future);
      await Future<void>.delayed(Duration.zero);
      final acknowledgements = <Object?>[];
      socket.registration!.handler(
        _requestEnvelope(
          urlIndex: 2,
          wireModelId: 'server-prefix.remote-model',
        ),
        acknowledgements.add,
      );
      expect((acknowledgements.single as Map)['status'], isFalse);

      snapshotController.replace(_snapshot());
      await Future<void>.delayed(Duration.zero);

      expect(
        capturedEmitter(
          'user-1:socket-1:late-request',
          'data: should not escape',
        ),
        isFalse,
      );
      expect(socket.emissions, isEmpty);
    });

    test(
      'routes a trusted request to the indexed provider and relays raw SSE',
      () async {
        final socket = _FakeSocketService();
        final http = _RecordingHttpAdapter(
          response: _streamResponse(<List<int>>[
            utf8.encode('data: {"choices":[{"delta":{"content":"Hi"}}]}\n'),
            utf8.encode('\ndata: [DONE]\n'),
          ]),
        );
        final snapshot = _snapshot();
        final container = _container(
          socket: socket,
          snapshot: snapshot,
          relayFactory: ({required emitChannel}) =>
              OpenWebUiDirectCompletionRelay(
                emitChannel: emitChannel,
                dioFactory: (_) => _dio(http),
                closeClients: false,
              ),
        );
        addTearDown(container.dispose);
        addTearDown(socket.dispose);

        await container.read(openWebUiDirectConnectionsProvider.future);
        container.read(openWebUiDirectCompletionSocketRelayProvider);
        expect(socket.registration, isNotNull);
        expect(socket.registration!.requireFocus, isFalse);

        final acknowledgements = <Object?>[];
        socket.registration!.handler(
          _requestEnvelope(
            urlIndex: 2,
            wireModelId: 'server-prefix.remote-model',
          ),
          acknowledgements.add,
        );
        await socket.doneEmission;

        expect(http.requests, hasLength(1));
        final request = http.requests.single;
        expect(
          request.uri.toString(),
          'https://provider.test/v1/chat/completions',
        );
        expect(request.headers['Authorization'], 'Bearer provider-secret');
        final posted = (request.data as Map).cast<String, dynamic>();
        expect(posted['model'], 'remote-model');
        expect(posted['temperature'], 0.4);
        expect(posted['stream'], isTrue);

        expect(acknowledgements, <Object?>[
          const <String, dynamic>{'status': true},
        ]);
        expect(socket.emissions, <_Emission>[
          const _Emission(
            expectedSessionId: 'socket-1',
            event: 'user-1:socket-1:request-1',
            data: 'data: {"choices":[{"delta":{"content":"Hi"}}]}',
          ),
          const _Emission(
            expectedSessionId: 'socket-1',
            event: 'user-1:socket-1:request-1',
            data: 'data: [DONE]',
          ),
          const _Emission(
            expectedSessionId: 'socket-1',
            event: 'user-1:socket-1:request-1',
            data: <String, dynamic>{'done': true},
          ),
        ]);
      },
    );

    test('rejects an untrusted URL index without provider I/O', () async {
      final socket = _FakeSocketService();
      final http = _RecordingHttpAdapter(
        response: _streamResponse(const <List<int>>[]),
      );
      var relayCreations = 0;
      final container = _container(
        socket: socket,
        snapshot: _snapshot(),
        relayFactory: ({required emitChannel}) {
          relayCreations += 1;
          return OpenWebUiDirectCompletionRelay(
            emitChannel: emitChannel,
            dioFactory: (_) => _dio(http),
            closeClients: false,
          );
        },
      );
      addTearDown(container.dispose);
      addTearDown(socket.dispose);

      await container.read(openWebUiDirectConnectionsProvider.future);
      container.read(openWebUiDirectCompletionSocketRelayProvider);
      final acknowledgements = <Object?>[];
      socket.registration!.handler(
        _requestEnvelope(
          urlIndex: 9,
          wireModelId: 'server-prefix.remote-model',
        ),
        acknowledgements.add,
      );
      await Future<void>.delayed(Duration.zero);

      expect(relayCreations, 0);
      expect(http.requests, isEmpty);
      expect(socket.emissions, isEmpty);
      expect(acknowledgements, <Object?>[
        const <String, dynamic>{
          'status': false,
          'error': 'The direct connection is unavailable.',
        },
      ]);
    });

    test('rejects a model outside the trusted indexed binding', () async {
      final socket = _FakeSocketService();
      var relayCreations = 0;
      final container = _container(
        socket: socket,
        snapshot: _snapshot(),
        relayFactory: ({required emitChannel}) {
          relayCreations += 1;
          throw StateError('not invoked');
        },
      );
      addTearDown(container.dispose);
      addTearDown(socket.dispose);

      await container.read(openWebUiDirectConnectionsProvider.future);
      container.read(openWebUiDirectCompletionSocketRelayProvider);
      final acknowledgements = <Object?>[];
      socket.registration!.handler(
        _requestEnvelope(
          urlIndex: 2,
          wireModelId: 'server-prefix.untrusted-model',
        ),
        acknowledgements.add,
      );
      await Future<void>.delayed(Duration.zero);

      expect(relayCreations, 0);
      expect(socket.emissions, isEmpty);
      expect(acknowledgements, <Object?>[
        const <String, dynamic>{
          'status': false,
          'error': 'The direct model is unavailable.',
        },
      ]);
    });
  });
}

ProviderContainer _container({
  required _FakeSocketService socket,
  required OpenWebUiDirectConnectionsSnapshot snapshot,
  required OpenWebUiDirectCompletionRelayFactory relayFactory,
}) {
  final api = _FakeApiService(socket.serverConfig);
  return ProviderContainer(
    overrides: [
      socketServiceProvider.overrideWithValue(socket),
      apiServiceProvider.overrideWithValue(api),
      openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
      directModelRegistryProvider.overrideWithValue(_registry()),
      openWebUiDirectConnectionsProvider.overrideWith(
        () => _SnapshotController(snapshot),
      ),
      openWebUiDirectCompletionRelayFactoryProvider.overrideWithValue(
        relayFactory,
      ),
    ],
  );
}

OpenWebUiDirectConnectionsSnapshot _snapshot() {
  final profile = _profile();
  return OpenWebUiDirectConnectionsSnapshot(
    serverId: 'server-1',
    accountId: 'user-1',
    records: <OpenWebUiDirectConnectionRecord>[
      OpenWebUiDirectConnectionRecord(
        index: 2,
        profile: profile,
        revision: 'record-revision',
        rawConfig: const <String, dynamic>{},
        authType: 'bearer',
        compatibility: OpenWebUiDirectConnectionCompatibility.compatible,
      ),
    ],
    ui: const <String, dynamic>{},
    documentRevision: 'document-revision',
  );
}

DirectConnectionProfile _profile() => DirectConnectionProfile(
  id: 'server-profile',
  name: 'Server profile',
  adapterKey: kOpenAiCompatibleAdapterKey,
  baseUrl: 'https://provider.test/v1',
  modelIdPrefix: 'server-prefix',
  apiKey: 'provider-secret',
);

DirectModelRegistry _registry() => DirectModelRegistry()
  ..replaceProfileModels(
    _profile(),
    <DirectRemoteModel>[DirectRemoteModel(id: 'remote-model')],
    source: DirectModelSource.openWebUi,
    openWebUiUrlIndex: 2,
  );

Map<String, dynamic> _requestEnvelope({
  required int urlIndex,
  required String wireModelId,
}) => <String, dynamic>{
  'data': <String, dynamic>{
    'type': 'request:chat:completion',
    'data': <String, dynamic>{
      'session_id': 'socket-1',
      'channel': 'user-1:socket-1:request-1',
      'form_data': <String, dynamic>{
        'model': wireModelId,
        'stream': true,
        'messages': const <Object>[],
        'temperature': 0.4,
      },
      'model': <String, dynamic>{
        'id': wireModelId,
        'direct': true,
        'urlIdx': urlIndex,
      },
    },
  },
};

final class _SnapshotController extends OpenWebUiDirectConnectionsController {
  _SnapshotController(this.snapshot);

  final OpenWebUiDirectConnectionsSnapshot snapshot;

  @override
  Future<OpenWebUiDirectConnectionsSnapshot?> build() async => snapshot;
}

final class _DeferredSnapshotController
    extends OpenWebUiDirectConnectionsController {
  final Completer<OpenWebUiDirectConnectionsSnapshot?> _snapshot =
      Completer<OpenWebUiDirectConnectionsSnapshot?>();

  @override
  Future<OpenWebUiDirectConnectionsSnapshot?> build() => _snapshot.future;

  void publish(OpenWebUiDirectConnectionsSnapshot value) {
    _snapshot.complete(value);
  }
}

final class _MutableSnapshotController
    extends OpenWebUiDirectConnectionsController {
  _MutableSnapshotController(this.initial);

  final OpenWebUiDirectConnectionsSnapshot initial;

  @override
  Future<OpenWebUiDirectConnectionsSnapshot?> build() async => initial;

  void replace(OpenWebUiDirectConnectionsSnapshot value) {
    state = AsyncData<OpenWebUiDirectConnectionsSnapshot?>(value);
  }
}

final class _CapturedRegistration {
  const _CapturedRegistration({
    required this.requireFocus,
    required this.handler,
  });

  final bool requireFocus;
  final SocketChatEventHandler handler;
}

final class _FakeSocketService implements SocketService {
  @override
  final ServerConfig serverConfig = const ServerConfig(
    id: 'server-1',
    name: 'Server',
    url: 'https://openwebui.test',
  );

  final StreamController<void> _reconnectController =
      StreamController<void>.broadcast();
  final StreamController<SocketHealth> _healthController =
      StreamController<SocketHealth>.broadcast();
  final Completer<void> _doneEmission = Completer<void>();
  final List<_Emission> emissions = <_Emission>[];
  _CapturedRegistration? registration;

  @override
  bool get isConnected => true;

  @override
  String? get sessionId => 'socket-1';

  @override
  Stream<void> get onReconnect => _reconnectController.stream;

  @override
  Stream<SocketHealth> get healthStream => _healthController.stream;

  Future<void> get doneEmission => _doneEmission.future;

  @override
  SocketEventSubscription addChatEventHandler({
    String? conversationId,
    String? sessionId,
    String? messageId,
    bool requireFocus = true,
    required SocketChatEventHandler handler,
  }) {
    final captured = _CapturedRegistration(
      requireFocus: requireFocus,
      handler: handler,
    );
    registration = captured;
    return SocketEventSubscription(() {
      if (identical(registration, captured)) registration = null;
    }, handlerId: 'openwebui-direct-relay-test');
  }

  @override
  bool emitForSession(String expectedSessionId, String event, dynamic data) {
    if (expectedSessionId != sessionId) return false;
    emissions.add(
      _Emission(
        expectedSessionId: expectedSessionId,
        event: event,
        data: data as Object,
      ),
    );
    if (data is Map && data['done'] == true && !_doneEmission.isCompleted) {
      _doneEmission.complete();
    }
    return true;
  }

  @override
  Future<void> dispose() async {
    await _reconnectController.close();
    await _healthController.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _FakeApiService implements ApiService {
  _FakeApiService(this.serverConfig);

  @override
  final ServerConfig serverConfig;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _Emission {
  const _Emission({
    required this.expectedSessionId,
    required this.event,
    required this.data,
  });

  final String expectedSessionId;
  final String event;
  final Object data;

  @override
  bool operator ==(Object other) =>
      other is _Emission &&
      other.expectedSessionId == expectedSessionId &&
      other.event == event &&
      _deepEquals(other.data, data);

  @override
  int get hashCode => Object.hash(expectedSessionId, event, data);

  @override
  String toString() =>
      '_Emission(session: $expectedSessionId, event: $event, data: $data)';
}

bool _deepEquals(Object? left, Object? right) {
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_deepEquals(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (!_deepEquals(left[i], right[i])) return false;
    }
    return true;
  }
  return left == right;
}

Dio _dio(HttpClientAdapter adapter) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  return dio;
}

ResponseBody _streamResponse(List<List<int>> chunks) => ResponseBody(
  Stream<Uint8List>.fromIterable(chunks.map<Uint8List>(Uint8List.fromList)),
  200,
  headers: const <String, List<String>>{
    'content-type': <String>['text/event-stream'],
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
