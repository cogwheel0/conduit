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

  /// Sends a frame to the client, completing once the client has taken it.
  /// It may complete late, after frames the client sends meanwhile: the
  /// host waits on it only inside the one stream's serving task, never while
  /// taking a frame ([receiveBytes]).
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
      eventGate: session._held,
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

  /// A frame of the byte routes from the client.
  ///
  /// The calling contract, which a binding follows:
  /// * Frames may be passed one at a time, each awaited before the next: this
  ///   never waits on a route or on a send ([sendBytes] may complete late,
  ///   even after later frames), only on taking the frame.
  /// * A stream's frames come in order: `open`, its body's chunks, `end`.
  /// * A frame the host cannot take for a stream it can name (one it cannot
  ///   read, a chunk after `end`, a second `open` on a live number) ends
  ///   that stream with an `error` and no answer, so a body never reaches a
  ///   route short.
  /// * Every stream the host serves ends with exactly one `end` (answered
  ///   whole) or `error` (failed, refused or cancelled) from the host. Its
  ///   number is free once the client has that frame, even before its
  ///   answer to it: an `open` on the number then is a new stream, and a
  ///   cancel or a stray frame for it is not the old one's. Each state and
  ///   what every frame does in it are tabled in
  ///   `docs/internals/phone-protocol-host.md`.
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
      // One whose stream can be named ends it: its body is never taken short.
      if (frame.length >= 4) {
        final id = ByteData.sublistView(frame).getUint32(0);
        _streams[id]?.stop('a frame of this stream could not be read');
      }
      return;
    }
    final stream = _streams[decoded.stream];
    switch (decoded.kind) {
      case ByteFrameKind.open:
        _open(decoded);
      case ByteFrameKind.chunk:
        if (stream == null) {
          // Answered or failed already: what it was still sending is not
          // wanted (the host said so, or ended the stream).
          return;
        }
        if (stream.endedByClient) {
          // The body the route took was short of this.
          stream.stop('a chunk came after the body ended');
          return;
        }
        stream.push(Uint8List.fromList(decoded.payload));
      case ByteFrameKind.end:
        stream?.endByClient();
      case ByteFrameKind.cancel:
        // At once: nothing more of the stream is sent, and its last frame
        // (`error`) comes from its serving task when that has let go.
        stream?.stop('cancelled');
      case ByteFrameKind.responseHead || ByteFrameKind.error:
        DebugLogger.warning(
          'byte-frame-from-client',
          scope: 'protocol/host',
          data: {'kind': decoded.kind.name},
        );
    }
  }

  void _open(ByteFrame frame) {
    final id = frame.stream;
    if (_stopping != null) {
      unawaited(_fail(id, 'the protocol host is stopping'));
      return;
    }
    if (_streams[id] case final live?) {
      // Neither request can be told apart from the other from here on.
      live.stop('stream $id was opened twice');
      return;
    }
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
      unawaited(_fail(id, 'a byte stream opens with its request as JSON'));
      return;
    }
    try {
      _attach();
    } on StateError catch (error) {
      _streams.remove(id);
      unawaited(_fail(id, error.message));
      return;
    }
    unawaited(_serve(id, request, path));
  }

  Future<void> _serve(int id, ByteRequest request, String path) async {
    final stream = _streams[id]!;
    try {
      final ByteResponse response;
      if (ProtocolByteRoutes.isTunnel(path.startsWith('/') ? path : '/$path')) {
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
      if (stream.finishBody() && !stream.stopped) {
        await _send(stream, ByteFrame(id, ByteFrameKind.cancel));
      }
      if (stream.stopped || _stopping != null) {
        return await _endStopped(id, stream);
      }
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
      await _send(
        stream,
        ByteFrame(id, ByteFrameKind.responseHead, payload: head),
      );
      final body = switch (response.body) {
        null => Uint8List(0),
        final String text => utf8.encode(text),
        final Uint8List bytes => bytes,
        final List<int> bytes => Uint8List.fromList(bytes),
        final other => throw StateError('a byte body of ${other.runtimeType}'),
      };
      for (var at = 0; at < body.length; at += ByteFrame.maxChunk) {
        if (stream.stopped || _stopping != null) {
          return await _endStopped(id, stream);
        }
        final end = at + ByteFrame.maxChunk < body.length
            ? at + ByteFrame.maxChunk
            : body.length;
        final chunk = Uint8List.sublistView(body, at, end);
        await _send(stream, ByteFrame(id, ByteFrameKind.chunk, payload: chunk));
      }
      if (stream.stopped || _stopping != null) {
        return await _endStopped(id, stream);
      }
      await _finish(id, stream, ByteFrame(id, ByteFrameKind.end));
    } on Object catch (error, stack) {
      DebugLogger.error(
        'byte-route-failed',
        scope: 'protocol/host',
        error: error,
        stackTrace: stack,
      );
      stream.finishBody();
      if (stream.stopped || _stopping != null) {
        return await _endStopped(id, stream);
      }
      await _finish(id, stream, _error(id, 'the route failed'));
    } finally {
      // Whatever way it ended, it is let go of.
      _letGo(id, stream);
    }
  }

  /// Ends [stream] with [terminal], its one last frame: decided here, so
  /// from now on the stream is out of [_streams]. A cancel or a bad frame
  /// for its number is not for it, an `open` on its number is a new stream,
  /// and the terminal frame's send, even failing, touches nothing else.
  Future<void> _finish(int id, _ByteStream stream, ByteFrame terminal) async {
    if (stream.finished) return;
    _letGo(id, stream);
    await _send(stream, terminal);
  }

  /// A stopped stream's end: the reason it was stopped for, if the client is
  /// to hear it; nothing when the transport failed or the host is stopping.
  Future<void> _endStopped(int id, _ByteStream stream) async {
    final reason = _stopping == null ? stream.stopReason : null;
    if (reason == null) return _letGo(id, stream);
    await _finish(id, stream, _error(id, reason));
  }

  void _letGo(int id, _ByteStream stream) {
    stream.finished = true;
    if (identical(_streams[id], stream)) _streams.remove(id);
  }

  ByteFrame _error(int id, String reason) => ByteFrame(
    id,
    ByteFrameKind.error,
    payload: Uint8List.fromList(utf8.encode(reason)),
  );

  /// Sends [frame] of [stream]. One the client could not take ends that
  /// stream there, and only that one (not another on its number since).
  Future<void> _send(_ByteStream stream, ByteFrame frame) async {
    try {
      await _sendBytes(frame.encode());
    } on Object catch (error, stack) {
      DebugLogger.error(
        'byte-frame-send-failed',
        scope: 'protocol/host',
        error: error,
        stackTrace: stack,
      );
      stream.stop(null);
    }
  }

  /// Refuses [id] before it is a stream: its one frame.
  Future<void> _fail(int id, String reason) async {
    try {
      await _sendBytes(_error(id, reason).encode());
    } on Object catch (error, stack) {
      DebugLogger.error(
        'byte-frame-send-failed',
        scope: 'protocol/host',
        error: error,
        stackTrace: stack,
      );
    }
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
      stream.stop(null);
    }
    _streams.clear();
    if (_ownsMedia) _media.close();
    await services.dispose();
  }
}

/// One of the client's sessions on an [InProcessProtocolHost].
///
/// The transport has no backpressure of its own, so the session counts the
/// messages the client has not yet taken. Past the host's limit, an
/// answer's intermediate streaming frames are held back ([_HeldFrames]).
final class InProcessSession {
  InProcessSession._(this.id, this._send, this._limit, EventBus events) {
    _held = _HeldFrames(this, events);
    _channel.foreign.stream.listen(_forward);
  }

  final String id;
  final Future<void> Function(String message) _send;
  final int _limit;
  final StreamChannelController<String> _channel =
      StreamChannelController<String>(sync: true);
  late final RpcSession _rpc;
  late final _HeldFrames _held;

  /// Messages handed to the transport and not yet taken.
  int _unacknowledged = 0;

  /// Events the gate let through that the peer has yet to hand over (it
  /// does a step later): counted from the gate on, or a burst would get
  /// past the limit before any of it was counted.
  int _eventsOnTheWay = 0;
  bool _closed = false;

  /// How the peer begins an event notification
  /// (`{"jsonrpc":"2.0","method":"event","params":…}`), told from a reply or
  /// a request by this alone: the host sends no request named `event`.
  static final String _eventPrefix = () {
    final sample = jsonEncode(<String, Object>{
      'jsonrpc': '2.0',
      'method': kEventNotification,
      'params': 0,
    });
    return sample.substring(0, sample.length - 2);
  }();
  final Completer<void> _ended = Completer<void>();

  /// Completes when the session has ended, however it ended: closed here,
  /// by the host stopping, or because its transport failed. The binding
  /// tells the client then.
  Future<void> get closed => _ended.future;

  bool get _behind => _unacknowledged + _eventsOnTheWay >= _limit;

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
    if (!_ended.isCompleted) _ended.complete();
  }

  /// Hands [message] to the transport. One it fails to take ends the
  /// session there: the client would otherwise read the next as if nothing
  /// were missing (an event, or a call's reply), so it is told the session
  /// ended, reconnects, and a new session catches up. A send that throws
  /// ends it before anything else is sent; one that fails later can only end
  /// it then.
  void _forward(String message) {
    if (_closed) return;
    final Future<void> sent;
    try {
      sent = _send(message);
    } on Object catch (error, stack) {
      _failed(error, stack);
      return;
    }
    if (_eventsOnTheWay > 0 && message.startsWith(_eventPrefix)) {
      _eventsOnTheWay--;
    }
    _unacknowledged++;
    unawaited(
      sent.then((_) {
        _unacknowledged--;
        if (!_closed && !_behind) _held.release(null, whileRoom: true);
      }, onError: _failed),
    );
  }

  /// An event the gate lets through: in flight from now.
  void _countAhead() => _eventsOnTheWay++;

  void _failed(Object error, StackTrace stack) {
    DebugLogger.error(
      'protocol-send-failed',
      scope: 'protocol/host',
      error: error,
      stackTrace: stack,
    );
    unawaited(close());
  }
}

/// A session's frames held back while its client is behind.
///
/// Only an answer's intermediate streaming frames (`turn.delta`,
/// `turn.blocks`) are held, each in place of the last of its kind for the
/// same answer (event, chat and `messageId`): every one carries the whole
/// state so far. Nothing else is ever held or dropped, and a frame held is
/// refused before it is numbered, so the client sees no gap.
///
/// A held frame is never sent after a newer state for the same answer, by
/// any path: whatever else reaches the client for that chat, published or
/// sent straight to the session (a catch-up), goes after what is held for
/// it, and a frame of the same kind for the same answer replaces it. A chat
/// the client stops watching is owed nothing held, and frames held under an
/// id a chat leaves (`route.remap`) move to its new one.
final class _HeldFrames implements EventGate {
  _HeldFrames(this._session, this._events);

  final InProcessSession _session;
  final EventBus _events;
  final Map<
    String,
    ({String event, String scope, Map<String, dynamic> payload})
  >
  _held = {};
  bool _releasing = false;

  static bool _intermediate(String event) =>
      event == ConduitEvents.turnDelta || event == ConduitEvents.turnBlocks;

  /// The answer a frame is the whole state of. A frame naming no message
  /// stands for its chat's.
  static String _key(
    String event,
    String scope,
    Map<String, dynamic> payload,
  ) => '$event $scope ${payload['messageId'] ?? ''}';

  void clear() => _held.clear();

  @override
  bool admit(String event, String? scope, Map<String, dynamic> payload) {
    if (_session._closed) return true;
    if (event == ConduitEvents.routeRemap) {
      _move(payload);
    } else if (scope != null) {
      if (_intermediate(event) && _session._behind) {
        final key = _key(event, scope, payload);
        _held.remove(key);
        _held[key] = (event: event, scope: scope, payload: payload);
        return false;
      }
      _before(event, scope, payload);
    }
    _session._countAhead();
    return true;
  }

  @override
  void direct(String event, String? scope, Map<String, dynamic> payload) {
    if (_session._closed) return;
    if (!_releasing && scope != null) _before(event, scope, payload);
    _session._countAhead();
  }

  @override
  void filterChanged() {
    _held.removeWhere(
      (_, held) => !_events.wantedBy(_session.id, held.event, held.scope),
    );
  }

  /// [event] is about to reach the client for [scope]: what is held for the
  /// chat goes first, but for the one it supersedes.
  void _before(String event, String scope, Map<String, dynamic> payload) {
    if (_held.isEmpty) return;
    if (_intermediate(event)) _held.remove(_key(event, scope, payload));
    release(scope);
  }

  /// Frames held under a chat's old id go on under its new one, where its
  /// turn now streams; a newer one held there already stands.
  void _move(Map<String, dynamic> remap) {
    final from = remap['fromId'];
    final to = remap['toId'];
    if (from is! String || to is! String || from == to) return;
    final moving = [
      for (final entry in _held.entries)
        if (entry.value.scope == from) entry,
    ];
    for (final entry in moving) {
      _held.remove(entry.key);
      final payload = <String, dynamic>{...entry.value.payload};
      if (payload['chatId'] == from) payload['chatId'] = to;
      _held.putIfAbsent(
        _key(entry.value.event, to, payload),
        () => (event: entry.value.event, scope: to, payload: payload),
      );
    }
  }

  /// Sends what is held, for [scope] or for every chat, in the order it was
  /// held. [whileRoom]: only until the client is at the limit again, as a
  /// catch-up on acknowledgements is; what stays held keeps its place, and
  /// still goes before anything else for its chat.
  void release(String? scope, {bool whileRoom = false}) {
    final going = [
      for (final entry in _held.entries)
        if (scope == null || entry.value.scope == scope) entry.key,
    ];
    _releasing = true;
    try {
      for (final key in going) {
        if (whileRoom && _session._behind) break;
        final held = _held.remove(key);
        if (held == null) continue;
        if (!_events.wantedBy(_session.id, held.event, held.scope)) continue;
        _events.sendTo(
          _session.id,
          held.event,
          scope: held.scope,
          payload: held.payload,
        );
      }
    } finally {
      _releasing = false;
    }
  }
}

/// One request on the byte routes and its answer.
final class _ByteStream {
  /// The body, which takes each chunk as it comes: every route reads its
  /// whole body, so holding the client back gains nothing.
  final StreamController<List<int>> body = StreamController<List<int>>();
  bool _bodyDone = false;

  /// The client sent `end`.
  bool endedByClient = false;

  /// Nothing more of the answer is sent; [stopReason], if any, is the
  /// stream's last frame.
  bool stopped = false;
  String? stopReason;

  /// Its last frame is decided (and it is out of the host's streams):
  /// nothing changes it from here.
  bool finished = false;

  void push(Uint8List chunk) {
    if (!_bodyDone) body.add(chunk);
  }

  void endByClient() {
    endedByClient = true;
    _endBody();
  }

  void _endBody() {
    if (_bodyDone) return;
    _bodyDone = true;
    unawaited(body.close());
  }

  /// No more of the body is taken. True when some of it was still to come.
  bool finishBody() {
    final open = !_bodyDone;
    _endBody();
    return open;
  }

  /// Ends the stream: a route still reading its body fails, so a body never
  /// reaches it short, and nothing of the answer is sent. [reason] is told
  /// to the client as the stream's last frame; none when the transport
  /// itself failed. A route already answering runs on (a route cannot be
  /// stopped), and its answer is dropped.
  void stop(String? reason) {
    if (stopped || finished) return;
    stopped = true;
    stopReason = reason;
    if (!_bodyDone) {
      _bodyDone = true;
      body.addError(const ByteStreamCancelled());
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
