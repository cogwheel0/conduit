import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/ports/app_lifecycle.dart';
import 'package:conduit_core/testing/fake_app_lifecycle.dart';
import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final class _MockWebSocketChannel extends Mock implements WebSocketChannel {}

final class _MockWebSocketSink extends Mock implements WebSocketSink {}

const _sessionNotFound = {'code': 4001, 'message': 'session not found'};
const _unknownMethod = {
  'code': -32601,
  'message': 'unknown method: file.attach',
};

/// One socket to a Desktop Gateway over `/api/ws`. It answers every request
/// with an empty result, except a sessionless `file.attach`, which gets
/// [fileAttach]: how a gateway shows whether it stages uploads.
final class _Socket {
  _Socket(this.fileAttach) {
    when(() => channel.ready).thenAnswer((_) async {});
    when(() => channel.stream).thenAnswer((_) {
      scheduleMicrotask(_ready);
      // Its own stream, whose cancel completes under fake time: a reconnect
      // cancels the dropped socket's.
      late final StreamSubscription<dynamic> forward;
      final socket = StreamController<dynamic>(
        onCancel: () {
          unawaited(forward.cancel());
          return Future<void>.value();
        },
      );
      forward = incoming.stream.listen(
        socket.add,
        onError: socket.addError,
        onDone: socket.close,
      );
      return socket.stream;
    });
    when(() => channel.sink).thenReturn(sink);
    when(() => sink.close()).thenAnswer((_) async {});
    when(() => sink.add(any())).thenAnswer((invocation) {
      final frame = Map<String, dynamic>.from(
        jsonDecode(invocation.positionalArguments.single as String) as Map,
      );
      final method = frame['method'];
      methods.add(method as String);
      final reply = method == 'file.attach'
          ? {'error': fileAttach}
          : {'result': const <String, Object?>{}};
      scheduleMicrotask(() {
        if (incoming.isClosed) return;
        incoming.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], ...reply}),
        );
      });
    });
  }

  final Map<String, Object?> fileAttach;
  final channel = _MockWebSocketChannel();
  final sink = _MockWebSocketSink();
  final incoming = StreamController<dynamic>.broadcast();
  final methods = <String>[];

  void _ready() {
    if (incoming.isClosed) return;
    incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': <String, Object?>{}},
      }),
    );
  }

  /// The gateway goes away, as it does when it restarts.
  Future<void> drop() => incoming.close();
}

/// Serves `/api/status` with auth off; every other route is missing.
final class _Rest implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final (status, body) = options.uri.path == '/api/status'
        ? (200, {'auth_required': false, 'gateway_running': true})
        : (404, {'detail': 'Not Found'});
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

/// A service whose sockets go, in turn, to each of [sockets].
HermesDesktopApiService _service(List<_Socket> sockets) {
  var connections = 0;
  return HermesDesktopApiService(
    config: HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example',
      mode: HermesBackendMode.desktopGateway,
      desktopCredentials: HermesDesktopCredentials(
        legacyToken: 'session-token',
      ),
    ),
    dio: Dio()..httpClientAdapter = _Rest(),
    rpc: HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => sockets[connections++].channel,
    ),
    gatewayStartRetryDelays: const [Duration.zero],
  );
}

void main() {
  // The gateway names its upload contract only with a session, and a new
  // chat after a launch has none, so a sessionless `file.attach` asks. Only
  // the gateway's own "session not found" shows it has the method, and
  // "unknown method" that it is older. A refusal with no code is the
  // client's own, as when the socket is gone, and a retiring gateway answers
  // before it looks the method up: those say neither, and it is asked again.
  for (final (gateway, error, uploads, asked) in [
    ('a gateway that stages uploads', _sessionNotFound, true, 1),
    ('a gateway older than uploads', _unknownMethod, false, 1),
    (
      'a reply with no code',
      {'message': 'Hermes gateway is not connected.'},
      false,
      2,
    ),
    (
      'a retiring gateway',
      {'code': 5035, 'message': 'backend is retiring; reconnect to continue'},
      false,
      2,
    ),
  ]) {
    test('$gateway is read before any session is opened', () async {
      final socket = _Socket(error);
      final service = _service([socket]);
      addTearDown(() async {
        service.close();
        await socket.drop();
      });

      final first = await service.getCapabilities();
      final second = await service.getCapabilities();

      check(first['desktop_uploads']).equals(uploads);
      check(second['desktop_uploads']).equals(uploads);
      check(socket.methods).not((it) => it.contains('session.create'));
      check(socket.methods).not((it) => it.contains('session.resume'));
      check(socket.methods.where((method) => method == 'file.attach')).length
          .equals(asked);
    });
  }

  // What one gateway said holds for its socket only: the one a reconnect
  // reaches may be older. Photos follow it with no chat open, and without
  // anyone reading the capabilities again.
  test('a reconnect to a gateway older than uploads hides Photos', () {
    fakeAsync((async) {
      final sockets = [_Socket(_sessionNotFound), _Socket(_unknownMethod)];
      final service = _service(sockets);
      final lifecycle = FakeAppLifecycle();
      service.startLifecycleObservation(lifecycle);
      final container = ProviderContainer(
        overrides: [hermesApiServiceProvider.overrideWithValue(service)],
      );
      final photos = <bool>[];
      container.listen(hermesCapabilitiesProvider, (_, next) {
        final capabilities = next.asData?.value;
        if (capabilities != null) photos.add(capabilities.inputImages);
      }, fireImmediately: true);
      async.elapse(Duration.zero);
      check(photos.last).isTrue();

      // The phone sleeps while the gateway is replaced by an older one.
      lifecycle.emit(AppLifecyclePhase.paused);
      unawaited(sockets.first.drop());
      async.elapse(Duration.zero);
      lifecycle.emit(AppLifecyclePhase.resumed);
      async.elapse(Duration.zero);

      check(sockets.last.methods).contains('file.attach');
      check(photos.last).isFalse();
      container.dispose();
      service.close();
      unawaited(sockets.last.drop());
      async.elapse(Duration.zero);
    });
  });
}
