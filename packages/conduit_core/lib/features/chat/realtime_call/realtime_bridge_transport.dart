import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/services/direct_http_client.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/network/no_redirect_web_socket.dart';
import 'package:conduit_core/services/server_tls_http_client_factory.dart';
import 'package:conduit_core/services/socket_service.dart';

import 'bridge_commands.dart';
import 'realtime_call_protocol.dart';

/// Opens the WebSocket a bridge runs over.
typedef RealtimeSocketConnector = WebSocketChannel Function(
  Uri uri,
  Map<String, String> headers, {
  HttpClient? httpClient,
});

/// The voice a ready bridge speaks with.
typedef RealtimeBridgeReady = ({String model, String voice});

/// A bridge could not start or keep a call; [message] is safe to show.
final class RealtimeBridgeException implements Exception {
  const RealtimeBridgeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One realtime call's connection to its voice: Open WebUI's server bridge,
/// or the provider itself with the bridge run on the device.
///
/// Both deliver the provider's `response.*`, `conversation.item.*` and
/// `input_audio_buffer.*` events and `bridge.pong`, and take the commands in
/// [BridgeCommands].
abstract interface class RealtimeBridgeTransport {
  /// Connects and returns once the voice is ready to talk.
  Future<RealtimeBridgeReady> open();

  /// The voice's events, once [open] returned. Listened to once.
  Stream<Map<String, Object?>> get events;

  void send(Map<String, Object?> command);

  /// Completes when the connection is gone: with why, or null after [close].
  Future<String?> get closed;

  Future<void> close();
}

/// `wss://…/api/v1/audio/realtime` on the Open WebUI server at [serverUrl].
Uri openWebUiRealtimeUri(String serverUrl) {
  final base = Uri.parse(serverUrl.trim());
  final path = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  return base.replace(
    scheme: base.scheme == 'http' ? 'ws' : 'wss',
    path: '$path/api/v1/audio/realtime',
    query: null,
    fragment: null,
  );
}

/// The Realtime API socket of [profile] for [model].
Uri directRealtimeUri(DirectConnectionProfile profile, String model) {
  final base = profile.requestBaseUri();
  final apiVersion = profile.apiVersion;
  return base.replace(
    scheme: base.scheme == 'http' ? 'ws' : 'wss',
    path: '${base.path}realtime',
    queryParameters: {
      'model': model,
      if (profile.adapterKey == kOpenAiCompatibleAdapterKey &&
          apiVersion != null)
        'api-version': apiVersion,
    },
  );
}

const _maxFrameCharacters = 512 * 1024;

/// A JSON-framed WebSocket bridge: everything but its handshake and what its
/// frames mean.
abstract base class _SocketBridge implements RealtimeBridgeTransport {
  _SocketBridge(this._connect);

  final RealtimeSocketConnector _connect;
  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _subscription;
  final _events = StreamController<Map<String, Object?>>();
  final _closed = Completer<String?>();
  final _ready = Completer<RealtimeBridgeReady>();

  Uri get uri;
  Map<String, String> get headers;
  HttpClient? get httpClient => null;
  Duration get readyTimeout;

  /// Called once the socket is open.
  void onOpen();

  /// Handles one decoded frame. May throw [RealtimeProtocolException].
  void onFrame(Map<String, Object?> frame);

  bool get isReady => _ready.isCompleted;

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<String?> get closed => _closed.future;

  @override
  Future<RealtimeBridgeReady> open() async {
    // A call that ended first opens no socket nothing would close.
    if (_closed.isCompleted) {
      throw const RealtimeBridgeException('The call ended.');
    }
    final channel = _channel = _connect(uri, headers, httpClient: httpClient);
    _subscription = channel.stream.listen(
      _frame,
      onError: (Object _) => finish('Voice connection failed.'),
      onDone: () => finish('Voice connection closed.'),
    );
    try {
      await channel.ready;
    } on Object {
      finish('Voice connection failed.');
    }
    if (!_closed.isCompleted) onOpen();
    return _ready.future.timeout(
      readyTimeout,
      onTimeout: () {
        finish('Voice connection timed out.');
        throw const RealtimeBridgeException('Voice connection timed out.');
      },
    );
  }

  void _frame(Object? data) {
    if (data is! String || data.length > _maxFrameCharacters) {
      return finish('Invalid voice event.');
    }
    final Object? frame;
    try {
      frame = jsonDecode(data);
    } on FormatException {
      return finish('Invalid voice event.');
    }
    if (frame is! Map<String, Object?>) return finish('Invalid voice event.');
    try {
      onFrame(frame);
    } on RealtimeProtocolException catch (error) {
      finish(error.message);
    }
  }

  void markReady(RealtimeBridgeReady ready) {
    if (!_ready.isCompleted && !_closed.isCompleted) _ready.complete(ready);
  }

  void emit(Map<String, Object?> event) {
    if (!_events.isClosed) _events.add(event);
  }

  void write(Map<String, Object?> frame) {
    if (!_closed.isCompleted) _channel?.sink.add(jsonEncode(frame));
  }

  /// Ends the bridge, with why it ended unless the call closed it.
  void finish(String? message) {
    if (_closed.isCompleted) return;
    _closed.complete(message);
    if (!_ready.isCompleted) {
      _ready.completeError(
        RealtimeBridgeException(message ?? 'The call ended.'),
      );
      // Nobody may be waiting for it any more.
      unawaited(_ready.future.then((_) {}, onError: (Object _) {}));
    }
    unawaited(_subscription?.cancel());
    unawaited(_channel?.sink.close());
    unawaited(_events.close());
  }

  @override
  Future<void> close() async => finish(null);
}

/// A call through an Open WebUI server's realtime bridge. The server holds
/// the provider key and checks every command; the session token signs in.
final class OpenWebUiRealtimeBridge extends _SocketBridge {
  OpenWebUiRealtimeBridge({
    required this.server,
    required this.token,
    required this.modelId,
    this.chatId,
    HttpClient? httpClient,
    RealtimeSocketConnector connect = connectNoRedirectWebSocket,
  }) : _httpClient = httpClient,
       super(connect);

  final ServerConfig server;
  final String token;
  final String modelId;

  /// The server's id of the chat, or null for a chat it does not have yet.
  final String? chatId;
  final HttpClient? _httpClient;

  @override
  Uri get uri => openWebUiRealtimeUri(server.url);

  // The session token travels in the first frame, as the server expects.
  @override
  Map<String, String> get headers => openWebUiWebSocketHeaders(server);

  @override
  HttpClient? get httpClient => _httpClient;

  @override
  Duration get readyTimeout => const Duration(seconds: 45);

  @override
  void onOpen() => write({
    'type': 'auth',
    'token': token,
    'model_id': modelId,
    'chat_id': ?chatId,
  });

  @override
  void onFrame(Map<String, Object?> frame) {
    final type = frame['type'];
    if (type == 'bridge.error') {
      final message = frame['message'];
      return finish(message is String ? message : 'Voice connection failed.');
    }
    if (isReady) return emit(frame);
    if (type != 'bridge.ready') return;
    final model = frame['model'];
    final voice = frame['voice'];
    if (frame['sample_rate'] != 24000 || model is! String || voice is! String) {
      throw const RealtimeProtocolException('Unsupported voice audio.');
    }
    markReady((model: model, voice: voice));
  }

  @override
  void send(Map<String, Object?> command) => write(command);
}

/// A call straight to a Direct connection's Realtime API, with Open WebUI's
/// bridge run on the device by [RealtimeCallProtocol].
final class DirectRealtimeBridge extends _SocketBridge {
  DirectRealtimeBridge({
    required this.profile,
    required this.model,
    required this.voice,
    required this.transcriptionModel,
    this.instructions,
    RealtimeSocketConnector connect = connectNoRedirectWebSocket,
  }) : super(connect);

  final DirectConnectionProfile profile;
  final String model;
  final String voice;
  final String transcriptionModel;
  final String? instructions;
  final _protocol = RealtimeCallProtocol();
  var _configuring = false;

  @override
  Uri get uri => directRealtimeUri(profile, model);

  @override
  Map<String, String> get headers => directRequestHeaders(profile);

  @override
  HttpClient? get httpClient {
    final tls = directTlsServerConfig(profile);
    return ServerTlsHttpClientFactory.requiresCustomHttpClient(tls)
        ? ServerTlsHttpClientFactory.createHttpClient(tls)
        : null;
  }

  @override
  Duration get readyTimeout => const Duration(seconds: 30);

  @override
  void onOpen() {}

  @override
  void onFrame(Map<String, Object?> frame) {
    final type = frame['type'];
    if (!isReady) {
      if (type == 'session.created' && !_configuring) {
        _configuring = true;
        write(
          directRealtimeSessionUpdate(
            voice: voice,
            transcriptionModel: transcriptionModel,
            instructions: instructions,
          ),
        );
      } else if (type == 'session.updated' && _configuring) {
        markReady((model: model, voice: voice));
      } else {
        finish(
          'The voice provider rejected the call. Check the Voice '
          "provider's realtime model, voice and transcription model.",
        );
      }
      return;
    }
    if (type == 'error') {
      final error = frame['error'];
      // The voice may finish a cancellation before the call's own arrives.
      if (error is Map && error['code'] == 'response_cancel_not_active') return;
      // Provider error text can carry prompts or keys, so it is not shown.
      return finish('The voice provider rejected a request.');
    }
    _protocol.observe(frame);
    if (type is String &&
        (type.startsWith('response.') ||
            type.startsWith('conversation.item.') ||
            type.startsWith('input_audio_buffer.'))) {
      emit(frame);
    }
  }

  @override
  void send(Map<String, Object?> command) {
    if (command['type'] == 'bridge.ping' && command.length == 1) {
      // Nothing between the call and its bridge to check: answer at once.
      return scheduleMicrotask(() => emit(const {'type': 'bridge.pong'}));
    }
    try {
      _protocol.command(command).forEach(write);
    } on RealtimeProtocolException catch (error) {
      finish(error.message);
    }
  }
}
