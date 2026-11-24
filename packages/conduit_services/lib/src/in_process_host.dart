import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit_core/ports/flush_scheduler.dart';
import 'package:conduit_core/ports/paths_port.dart';
import 'package:conduit_core/ports/post_frame_scheduler.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show activeServerProvider;
import 'package:conduit_core/providers/host_ports.dart'
    show flushSchedulerProvider, postFrameSchedulerProvider;
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:stream_channel/stream_channel.dart';

import 'byte_frames.dart';
import 'byte_routes.dart';
import 'event_bus.dart';
import 'local_transcriber.dart';
import 'media_service.dart';
import 'protocol_services.dart';
import 'rpc_session.dart';
import 'settled.dart';
import 'system_service.dart';
import 'window_ports.dart';

/// The protocol's services inside an app, for a client in the same process
/// (the phone's Swift screens), over the app's own container.
///
/// The app keeps its container, and everything it binds there: this host
/// runs the services in shared mode ([ProtocolHostPorts.sharesAppContainer])
/// and never disposes the container. It talks to its client through
/// messages only, whatever carries them: each session's JSON-RPC as
/// strings, and the byte routes as [ByteFrame]s.
///
/// Nothing is built until the client first opens a session or a byte
/// stream, so an app that never shows a protocol screen pays nothing.
final class InProcessProtocolHost {
  InProcessProtocolHost({
    required ProviderContainer container,
    required SystemService system,
    required WindowPorts window,
    required Future<void> Function(Uint8List frame) sendBytes,
    PathsPort? paths,
    LocalTranscriber? localTranscriber,
    MediaService? media,
    this.maxUnacknowledged = 64,
  }) : _container = container,
       _sendBytes = sendBytes,
       _ownsMedia = media == null {
    _media = media ?? MediaService(ownServer: _activeServerUrl);
    services = ProtocolServices(
      events: EventBus(),
      system: system,
      ports: ProtocolHostPorts(
        window: window,
        paths: paths,
        localTranscriber: localTranscriber,
        sharesAppContainer: true,
        // A protocol chat may stream with no Flutter frame to come: its
        // flushes cannot wait for one.
        chatScopeOverrides: () => <Override>[
          flushSchedulerProvider.overrideWithValue(
            const MicrotaskFlushScheduler(),
          ),
          postFrameSchedulerProvider.overrideWithValue(
            const MicrotaskPostFrameScheduler(),
          ),
        ],
      ),
    );
    _routes = ProtocolByteRoutes(
      services: () => services.isAttached ? services : null,
      media: _media,
    );
  }

  final ProviderContainer _container;
  final Future<void> Function(Uint8List frame) _sendBytes;

  /// How many messages a session may have sent and not yet had taken
  /// before it holds back a chat's streaming frames ([InProcessSession]).
  final int maxUnacknowledged;

  /// What this host serves.
  late final ProtocolServices services;

  late final MediaService _media;
  final bool _ownsMedia;
  late final ProtocolByteRoutes _routes;

  final Map<String, InProcessSession> _sessions = <String, InProcessSession>{};
  final Map<int, _ByteStream> _streams = <int, _ByteStream>{};

  Future<void>? _stopping;
  bool _attachTried = false;
  Object? _attachFailure;

  /// The active account's server, which `/media` may reach although it is
  /// on this device.
  Future<Uri?> _activeServerUrl() async {
    if (_stopping != null) return null;
    final server = await readSettled(_container, activeServerProvider.future);
    return server == null ? null : Uri.tryParse(server.url);
  }

  void _attach() {
    if (!_attachTried) {
      _attachTried = true;
      try {
        services.attach(_container);
      } on Object catch (error) {
        _attachFailure = error;
      }
    }
    if (_attachFailure case final failure?) {
      throw StateError('the protocol services could not start: $failure');
    }
  }

  /// Opens session [sessionId], whose messages to the client go through
  /// [send]. [send] completes once the client has taken the message: until
  /// then it counts against [maxUnacknowledged].
  InProcessSession open(
    String sessionId, {
    required Future<void> Function(String message) send,
  }) {
    if (_stopping != null) throw StateError('the protocol host is stopping');
    if (_sessions.containsKey(sessionId)) {
      throw StateError('session $sessionId is already open');
    }
    _attach();
    final session = InProcessSession._(
      sessionId,
      send,
      maxUnacknowledged,
      services.events,
    );
    session._rpc = services.openSession(
      session._channel.local,
      sessionId: sessionId,
      admitEvent: session._admit,
    );
    _sessions[sessionId] = session;
    unawaited(
      session._rpc.listen().whenComplete(() {
        if (identical(_sessions[sessionId], session)) {
          _sessions.remove(sessionId);
        }
      }),
    );
    return session;
  }

  /// A frame of the byte routes from the client. Completes once the host
  /// has taken it: a body chunk once the route reading it is ready for more,
  /// so the client sends the next one then.
  ///
  /// The host keeps no part of [frame]: a chunk is copied before a route
  /// sees it ([ByteRequest.read]).
  Future<void> receiveBytes(Uint8List frame) async {
    final ByteFrame decoded;
    try {
      decoded = ByteFrame.decode(frame);
    } on FormatException catch (error) {
      DebugLogger.warning(
        'bad-byte-frame',
        scope: 'protocol/host',
        data: {'reason': error.message},
      );
      return;
    }
    final stream = _streams[decoded.stream];
    switch (decoded.kind) {
      case ByteFrameKind.open:
        await _open(decoded);
      case ByteFrameKind.chunk:
        await stream?.push(Uint8List.fromList(decoded.payload));
      case ByteFrameKind.end:
        stream?.endBody();
      case ByteFrameKind.cancel:
        stream?.cancel();
      case ByteFrameKind.responseHead || ByteFrameKind.error:
        DebugLogger.warning(
          'byte-frame-from-client',
          scope: 'protocol/host',
          data: {'kind': decoded.kind.name},
        );
    }
  }

  Future<void> _open(ByteFrame frame) async {
    final id = frame.stream;
    if (_stopping != null) {
      return _fail(id, 'the protocol host is stopping');
    }
    if (_streams.containsKey(id)) return _fail(id, 'stream $id is open');
    final ByteRequest request;
    final String path;
    try {
      final open = jsonDecode(utf8.decode(frame.payload)) as Map;
      path = open['path'] as String;
      final query = open['query'] as String?;
      final headers = (open['headers'] as Map? ?? const <String, Object?>{})
          .map((name, value) => MapEntry('$name'.toLowerCase(), '$value'));
      final stream = _ByteStream();
      _streams[id] = stream;
      request = ByteRequest(
        method: open['method'] as String,
        url: Uri(
          path: path.startsWith('/') ? path.substring(1) : path,
          query: query == null || query.isEmpty ? null : query,
        ),
        headers: headers,
        read: () => stream.body.stream,
      );
    } on Object {
      _streams.remove(id);
      return _fail(id, 'a byte stream opens with its request as JSON');
    }
    try {
      _attach();
    } on StateError catch (error) {
      _streams.remove(id);
      return _fail(id, error.message);
    }
    unawaited(_serve(id, request, path));
  }

  Future<void> _serve(int id, ByteRequest request, String path) async {
    final stream = _streams[id]!;
    try {
      final ByteResponse response;
      if (_routes.tunnel(path.startsWith('/') ? path : '/$path') != null) {
        // A tunnel needs a socket both ways; this host carries none.
        response = const ByteResponse(
          501,
          body: 'tunnels are not offered by this host',
        );
      } else {
        response =
            await (_routes.handle(request) ??
                Future<ByteResponse>.value(
                  const ByteResponse(404, body: 'no such endpoint'),
                ));
      }
      // Answered: whatever of the body is still to come is not wanted.
      if (stream.finishBody() && !stream.cancelled) {
        await _send(ByteFrame(id, ByteFrameKind.cancel));
      }
      if (stream.cancelled || _stopping != null) return;
      if (response.failure case final failure?) {
        DebugLogger.error(
          failure.what,
          scope: 'protocol/host',
          error: failure.error,
          stackTrace: failure.stack,
        );
      }
      final head = utf8.encode(
        jsonEncode(<String, Object?>{
          'status': response.status,
          'headers': response.headers,
        }),
      );
      if (!await _send(
        ByteFrame(id, ByteFrameKind.responseHead, payload: head),
      )) {
        return;
      }
      final body = switch (response.body) {
        null => Uint8List(0),
        final String text => utf8.encode(text),
        final Uint8List bytes => bytes,
        final List<int> bytes => Uint8List.fromList(bytes),
        final other => throw StateError('a byte body of ${other.runtimeType}'),
      };
      for (var at = 0; at < body.length; at += ByteFrame.maxChunk) {
        if (stream.cancelled || _stopping != null) return;
        final end = at + ByteFrame.maxChunk < body.length
            ? at + ByteFrame.maxChunk
            : body.length;
        final chunk = Uint8List.sublistView(body, at, end);
        if (!await _send(ByteFrame(id, ByteFrameKind.chunk, payload: chunk))) {
          return;
        }
      }
      if (stream.cancelled || _stopping != null) return;
      await _send(ByteFrame(id, ByteFrameKind.end));
    } on Object catch (error, stack) {
      DebugLogger.error(
        'byte-route-failed',
        scope: 'protocol/host',
        error: error,
        stackTrace: stack,
      );
      stream.finishBody();
      if (!stream.cancelled) await _fail(id, 'the route failed');
    } finally {
      if (identical(_streams[id], stream)) _streams.remove(id);
    }
  }

  /// Sends [frame], answering whether the client took it. One it could not
  /// take ends the stream there.
  Future<bool> _send(ByteFrame frame) async {
    try {
      await _sendBytes(frame.encode());
      return true;
    } on Object catch (error, stack) {
      DebugLogger.error(
        'byte-frame-send-failed',
        scope: 'protocol/host',
        error: error,
        stackTrace: stack,
      );
      _streams[frame.stream]?.cancel();
      return false;
    }
  }

  Future<void> _fail(int id, String reason) async {
    await _send(
      ByteFrame(
        id,
        ByteFrameKind.error,
        payload: Uint8List.fromList(utf8.encode(reason)),
      ),
    );
  }

  /// Stops the services, in the order `conduitd` stops them: no new
  /// sessions or streams, the sessions closed, the transports closed, the
  /// byte streams ended, then the services. The app's container is left as
  /// it was, and stays the app's. Once however often it is called.
  Future<void> dispose() => _stopping ??= _stop();

  Future<void> _stop() async {
    for (final session in _sessions.values.toList()) {
      await session.close();
    }
    _sessions.clear();
    await services.closeTransports();
    for (final stream in _streams.values.toList()) {
      stream.cancel();
    }
    _streams.clear();
    if (_ownsMedia) _media.close();
    await services.dispose();
  }
}

/// One of the client's sessions on an [InProcessProtocolHost].
///
/// The transport has no backpressure of its own, so the session counts the
/// messages the client has not yet taken. Past the host's limit, a chat's
/// intermediate streaming frames (`turn.delta`, `turn.blocks`) are held
/// back instead of sent, each replaced by the next: every one carries the
/// whole state so far. What is held goes when the client catches up, and
/// before any other event for that chat, so nothing after it overtakes it.
/// Nothing else is ever held or dropped, and a frame held back is never
/// numbered, so the client sees no gap ([EventBus.attach]).
final class InProcessSession {
  InProcessSession._(this.id, this._send, this._limit, this._events) {
    _channel.foreign.stream.listen(_forward);
  }

  final String id;
  final Future<void> Function(String message) _send;
  final int _limit;
  final EventBus _events;
  final StreamChannelController<String> _channel =
      StreamChannelController<String>(sync: true);
  late final RpcSession _rpc;

  int _unacknowledged = 0;
  final Map<
    String,
    ({String event, String scope, Map<String, dynamic> payload})
  >
  _held = {};
  bool _closed = false;

  /// A message from the client.
  void receive(String message) {
    if (_closed) return;
    _channel.foreign.sink.add(message);
  }

  /// Ends the session, as the client leaving does. Once however often it is
  /// called.
  Future<void> close() async {
    _closed = true;
    _held.clear();
    // The client's side ends too: the session's peer finishes only then.
    await _channel.foreign.sink.close();
    await _rpc.close();
  }

  void _forward(String message) {
    _unacknowledged++;
    unawaited(
      Future<void>.sync(() => _send(message))
          .catchError((Object error, StackTrace stack) {
            DebugLogger.error(
              'protocol-send-failed',
              scope: 'protocol/host',
              error: error,
              stackTrace: stack,
            );
          })
          .whenComplete(() {
            _unacknowledged--;
            if (!_closed && _unacknowledged < _limit) _release(null);
          }),
    );
  }

  static bool _intermediate(String event) =>
      event == ConduitEvents.turnDelta || event == ConduitEvents.turnBlocks;

  /// The answer a frame is the whole state of: a comparison streams several
  /// in one chat. A frame naming no message stands for its chat's.
  static String _key(
    String event,
    String scope,
    Map<String, dynamic> payload,
  ) => '$event $scope ${payload['messageId'] ?? ''}';

  bool _admit(String event, String? scope, Map<String, dynamic> payload) {
    if (_closed || scope == null) return true;
    final intermediate = _intermediate(event);
    if (intermediate && _unacknowledged >= _limit) {
      final key = _key(event, scope, payload);
      _held.remove(key);
      _held[key] = (event: event, scope: scope, payload: payload);
      return false;
    }
    if (_held.isNotEmpty) {
      // This one is newer than one of its kind held for the chat.
      if (intermediate) _held.remove(_key(event, scope, payload));
      _release(scope);
    }
    return true;
  }

  /// Sends what is held, for [scope] or for every chat.
  void _release(String? scope) {
    final going = [
      for (final entry in _held.entries)
        if (scope == null || entry.value.scope == scope) entry,
    ];
    for (final entry in going) {
      _held.remove(entry.key);
      final held = entry.value;
      // A chat the client stopped watching meanwhile is owed nothing.
      if (!_events.wantedBy(id, held.event, held.scope)) continue;
      _events.sendTo(id, held.event, scope: held.scope, payload: held.payload);
    }
  }
}

/// One request on the byte routes and its answer.
final class _ByteStream {
  _ByteStream() {
    body = StreamController<List<int>>(
      onListen: _wake,
      onResume: _wake,
      onCancel: () {
        _bodyDone = true;
        _wake();
      },
    );
  }

  late final StreamController<List<int>> body;
  bool _bodyDone = false;
  bool cancelled = false;
  Completer<void>? _ready;

  void _wake() {
    _ready?.complete();
    _ready = null;
  }

  /// Hands [chunk] to the route once it is reading.
  Future<void> push(Uint8List chunk) async {
    while (!_bodyDone && (!body.hasListener || body.isPaused)) {
      await (_ready ??= Completer<void>()).future;
    }
    if (_bodyDone) return;
    body.add(chunk);
  }

  void endBody() {
    if (_bodyDone) return;
    _bodyDone = true;
    _wake();
    unawaited(body.close());
  }

  /// No more of the body is taken. True when some of it was still to come.
  bool finishBody() {
    final open = !_bodyDone;
    endBody();
    return open;
  }

  /// The client abandoned the request: a route reading its body fails, and
  /// nothing of the answer is sent.
  void cancel() {
    if (cancelled) return;
    cancelled = true;
    if (!_bodyDone) {
      _bodyDone = true;
      body.addError(const ByteStreamCancelled());
      _wake();
      unawaited(body.close());
    }
  }
}

/// A byte stream's body ended because the client abandoned the request.
final class ByteStreamCancelled implements Exception {
  const ByteStreamCancelled();

  @override
  String toString() => 'the client abandoned the request';
}
