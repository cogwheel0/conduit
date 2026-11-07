import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:conduit_core/network/external_link.dart';
import 'package:conduit_core/network/no_redirect_web_socket.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';
import 'package:conduit_core/features/hermes/services/hermes_json_guard.dart';

const int kMaxHermesDesktopFrameBytes = 4 * 1024 * 1024;
const int kMaxHermesDesktopFrameCharacters = 2 * 1024 * 1024;

typedef HermesDesktopChannelFactory = WebSocketChannel Function(
  Uri uri,
  Map<String, String> headers, {
  HttpClient? httpClient,
});

final class HermesDesktopRpcException implements Exception {
  const HermesDesktopRpcException(
    this.message, {
    this.code,
    this.data,
    this.timedOut = false,
    this.disconnected = false,
  });

  final String message;
  final int? code;

  /// The error's `data` member, when Hermes sent one: refusals such as
  /// `{reason: 'SESSION_OWNER_BUSY'}` explain themselves there.
  final Object? data;
  final bool timedOut;
  final bool disconnected;
  bool get deliveryAmbiguous => timedOut || disconnected;

  /// `data.reason`, when Hermes named one.
  String? get reason {
    final data = this.data;
    if (data is! Map) return null;
    return validateHermesBoundedString(data['reason'], maxCharacters: 128);
  }

  @override
  String toString() => message;
}

final class HermesDesktopEvent {
  const HermesDesktopEvent({
    required this.type,
    required this.payload,
    this.sessionId,
    this.seq,
    this.replayEpoch,
    this.executionGeneration,
    this.admissionId,
  });

  final String type;
  final Map<String, dynamic> payload;
  final String? sessionId;

  /// The event's place in its session's replay stream ([replayEpoch]),
  /// stamped by a session authority (the canonical wire).
  final int? seq;
  final String? replayEpoch;

  /// The execution generation of the turn the event belongs to: what a
  /// control (stop, steer, an answer) must name on the canonical wire.
  final int? executionGeneration;

  /// The admission (one submitted prompt) whose turn produced the event.
  final String? admissionId;
}

/// The protocol a gateway's session authority speaks (its Webapp listener):
/// `gateway.ready` says `session_authority: true` and session snapshots name
/// it as `info.desktop_protocol`.
const String kHermesCanonicalGatewayProtocol = 'hermes-gateway-v1';


/// Server→client requests Conduit answers. Since Hermes 0.21.3 the gateway
/// asks for approvals, clarifications, sudo passwords and secrets this way
/// instead of with `*.request` events, and only of a client that advertised
/// `client.capabilities {server_requests: true}`.
const Set<String> kHermesAnsweredServerRequests = {
  'approval',
  'clarify',
  'sudo',
  'secret',
};

/// The JSON-RPC error a client sends for a server request it does not show,
/// when the gateway said it takes declines (`declines_not_shown`).
const int kHermesServerRequestNotShownCode = 4404;

/// One clarify question's card id: the request it belongs to and the
/// question's id. Each question is answered on its own with `clarify.lock`;
/// the last one answers the request.
///
/// Each part escapes `~` and `/` (`~0`, `~1`), so the `/` joining them is
/// the only one: a catalog target such as a skill's `owner/name` survives.
String hermesClarifyCardId(String requestId, String questionId) =>
    '${_escapeCardIdPart(requestId)}/${_escapeCardIdPart(questionId)}';

/// Splits a card id made by [hermesClarifyCardId].
({String requestId, String questionId})? parseHermesClarifyCardId(
  String cardId,
) {
  final parts = cardId.split('/');
  if (parts.length != 2 || parts.any((part) => part.isEmpty)) return null;
  return (
    requestId: _unescapeCardIdPart(parts.first),
    questionId: _unescapeCardIdPart(parts.last),
  );
}

String _escapeCardIdPart(String part) =>
    part.replaceAll('~', '~0').replaceAll('/', '~1');

String _unescapeCardIdPart(String part) =>
    part.replaceAll('~1', '/').replaceAll('~0', '~');

/// The decision events a server→client request stands for, shaped like the
/// `*.request` events earlier gateways sent, so one pipeline shows, persists
/// and restores both. `request_id` is the id Conduit answers with: the
/// request id itself, or a clarify question's card id.
///
/// A chat message holds one decision card, so a clarify request shows its
/// first question still open ([locked] and the replay's `answers` name the
/// ones already answered); the next one follows once that one is locked.
List<HermesDesktopEvent> hermesDesktopEventsForServerRequest({
  required String id,
  required String method,
  required Map<String, dynamic> params,
  Set<String> locked = const {},
}) {
  final requestId = validateHermesOpaqueIdentifier(id);
  final sessionId = params['session_id']?.toString();
  if (requestId == null) return const [];
  final payload = <String, dynamic>{
    for (final entry in params.entries)
      if (entry.key != 'session_id') entry.key: entry.value,
  };
  switch (method) {
    case 'approval':
      return [
        HermesDesktopEvent(
          type: 'approval.request',
          sessionId: sessionId,
          payload: {
            ...payload,
            'request_id': requestId,
            'approval_request_id': params['request_id'],
            'server_request': requestId,
          },
        ),
      ];
    case 'sudo':
      return [
        HermesDesktopEvent(
          type: 'sudo.request',
          sessionId: sessionId,
          payload: {
            ...payload,
            'request_id': requestId,
            'prompt': params['command']?.toString() ?? '',
            'server_request': requestId,
          },
        ),
      ];
    case 'secret':
      return [
        HermesDesktopEvent(
          type: 'secret.request',
          sessionId: sessionId,
          payload: {
            ...payload,
            'request_id': requestId,
            'server_request': requestId,
          },
        ),
      ];
    case 'clarify':
      final questions = params['questions'];
      if (questions is! List) return const [];
      final answered = {
        ...locked,
        if (params['answers'] is Map)
          ...(params['answers'] as Map).keys.map((key) => '$key'),
      };
      final rows = questions.whereType<Map>().take(16).toList();
      for (final (index, question) in rows.indexed) {
        final questionId = validateHermesOpaqueIdentifier(
          question['qid']?.toString(),
        );
        if (questionId == null || answered.contains(questionId)) continue;
        final text = question['question']?.toString() ?? '';
        return [
          HermesDesktopEvent(
            type: 'clarify.request',
            sessionId: sessionId,
            payload: {
              'request_id': hermesClarifyCardId(requestId, questionId),
              'question': rows.length > 1
                  ? '${index + 1}/${rows.length} · $text'
                  : text,
              'choices': question['choices'] is List
                  ? question['choices']
                  : const <Object?>[],
              'multi_select': question['multi_select'] == true,
              'server_request': requestId,
              'question_id': questionId,
            },
          ),
        ];
      }
      return const [];
  }
  return const [];
}

/// One connection target's card id: its operation and the target's name,
/// escaped like [hermesClarifyCardId]. Hermes does not bound target names:
/// one too long for an id is named by a digest (`~h`, which escaping never
/// makes), and the client keeps which name it stands for
/// ([HermesDesktopRpcClient.connectionCardTarget]).
String hermesConnectionCardId(String operationId, String target) {
  final id = hermesClarifyCardId(operationId, target);
  if (validateHermesOpaqueIdentifier(id) != null) return id;
  final digest = sha256.convert(utf8.encode(target)).toString();
  return '${_escapeCardIdPart(operationId)}/~h${digest.substring(0, 32)}';
}

/// Splits a card id made by [hermesConnectionCardId].
({String operationId, String target})? parseHermesConnectionCardId(
  String cardId,
) {
  final parsed = parseHermesClarifyCardId(cardId);
  return parsed == null
      ? null
      : (operationId: parsed.requestId, target: parsed.questionId);
}

/// The MCP setup card for a connection operation's first target still
/// waiting on the user (Hermes 0.22+ `connection.request`, the
/// `manage_connections` card), shaped like earlier gateways'
/// `mcp.setup.request`. Null when no target is waiting. The operation itself
/// installs or enables a `pending` target once the user approves it. An
/// authorization or a hosted connector starts its sign-in before the card
/// is sent: that target is `initiated` with a `connect_url`, and waits on
/// the user opening the link.
///
/// The target named [shown] keeps the card while it waits. Targets named in
/// [passed] had theirs and are not asked about again. A card offered again
/// carries its count from [offers] as `offer`, so a turn that saw the first
/// offer does not drop it as a repeat.
HermesDesktopEvent? hermesDesktopConnectionTargetEvent({
  required String operationId,
  required String? sessionId,
  required Object? targets,
  String? shown,
  Set<String> passed = const {},
  Map<String, int> offers = const {},
}) {
  final raw = _waitingConnectionTarget(targets, shown: shown, passed: passed);
  final name = validateHermesOpaqueIdentifier(raw?['name']?.toString());
  if (raw == null || name == null) return null;
  final launch = raw['launch'];
  final reason = [
    raw['detail'],
    raw['description'],
    raw['instructions'],
    if (launch is Map) launch['target'],
  ].map((value) => value?.toString().trim() ?? '').firstWhere(
    (value) => value.isNotEmpty,
    orElse: () => '',
  );
  final cardId = hermesConnectionCardId(operationId, name);
  return HermesDesktopEvent(
    type: 'mcp.setup.request',
    sessionId: sessionId,
    payload: {
      'request_id': cardId,
      'offer': ?offers[cardId],
      'server': raw['display']?.toString().trim().isNotEmpty == true
          ? raw['display']
          : name,
      'action': raw['action'],
      'kind': raw['kind'],
      'reason': reason,
      'connection_operation': operationId,
      'connection_target': name,
    },
  );
}

/// The target of [targets] whose card to show: [shown] while it waits on
/// the user, else the first waiting one not in [passed].
Map<dynamic, dynamic>? _waitingConnectionTarget(
  Object? targets, {
  String? shown,
  Set<String> passed = const {},
}) {
  if (targets is! List) return null;
  final waiting = [
    for (final raw in targets.whereType<Map>().take(32))
      if (validateHermesOpaqueIdentifier(raw['name']?.toString()) != null &&
          raw['resolved'] != true &&
          (raw['state'] == 'pending' ||
              (raw['state'] == 'initiated' &&
                  _hermesConnectLink(raw['connect_url']) != null)))
        raw,
  ];
  for (final raw in waiting) {
    if (shown != null && raw['name'] == shown) return raw;
  }
  for (final raw in waiting) {
    if (!passed.contains(raw['name'])) return raw;
  }
  return null;
}

/// The sign-in link of the `initiated` target [name] of [targets].
Uri? _connectLinkOf(Object? targets, String? name) {
  if (targets is! List || name == null) return null;
  for (final raw in targets.whereType<Map>().take(32)) {
    if (raw['name'] == name && raw['state'] == 'initiated') {
      return _hermesConnectLink(raw['connect_url']);
    }
  }
  return null;
}

/// A target's sign-in link, when it is one a browser may open.
Uri? _hermesConnectLink(Object? value) {
  if (value is! String) return null;
  final uri = parseAllowedExternalLink(value);
  return uri != null && const {'http', 'https'}.contains(uri.scheme)
      ? uri
      : null;
}

/// A connection operation whose targets are shown one at a time.
final class _OpenConnection {
  _OpenConnection(this.sessionId);

  final String? sessionId;
  String? shownCardId;

  /// The shown target's sign-in link, when its sign-in already started.
  Uri? shownLink;

  /// Targets whose card was shown and then closed: answered here or
  /// elsewhere. One whose sign-in starts later is not asked about again.
  final Set<String> passed = {};

  /// The target name each card shown for this operation stands for.
  final Map<String, String> cardTargets = {};

  /// How many times each card was offered again after it was answered.
  final Map<String, int> offers = {};
}

/// A clarify request being answered one question at a time.
final class _OpenClarify {
  /// [params] replace a [previous] frame's of the same request (a replay
  /// lists the answers locked since); what that one said was answered stays.
  _OpenClarify(this.params, {_OpenClarify? previous}) {
    if (previous == null) return;
    locked.addAll(previous.locked);
    final answers = previous.params['answers'];
    if (answers is Map) locked.addAll(answers.keys.map((key) => '$key'));
  }

  final Map<String, dynamic> params;
  final Set<String> locked = {};

  /// The card shown now, closed when the request is withdrawn.
  String? shownCardId;
}

final class HermesDesktopEventBuffer {
  HermesDesktopEventBuffer({
    this.maximumPerSession = 4096,
    this.maximumSessions = 64,
    this.maximumTotalEvents = 4096,
  }) : assert(maximumPerSession > 0),
       assert(maximumSessions > 0),
       assert(maximumTotalEvents > 0);

  final int maximumPerSession;
  final int maximumSessions;
  final int maximumTotalEvents;
  final LinkedHashMap<String, Queue<HermesDesktopEvent>> _pending =
      LinkedHashMap();
  final Set<String> _active = {};
  int _totalEvents = 0;

  bool add(HermesDesktopEvent event) {
    final sessionId = event.sessionId;
    if (sessionId == null || sessionId.isEmpty || _active.contains(sessionId)) {
      return false;
    }
    if (!_pending.containsKey(sessionId) &&
        _pending.length >= maximumSessions) {
      _removeQueue(_pending.keys.first);
    }
    final queue = _pending.putIfAbsent(sessionId, Queue.new);
    final wasEmpty = queue.isEmpty;
    queue.addLast(event);
    _totalEvents++;
    while (queue.length > maximumPerSession) {
      queue.removeFirst();
      _totalEvents--;
    }
    while (_totalEvents > maximumTotalEvents && _pending.isNotEmpty) {
      final oldest = _pending.entries.first;
      oldest.value.removeFirst();
      _totalEvents--;
      if (oldest.value.isEmpty) _pending.remove(oldest.key);
    }
    return wasEmpty;
  }

  List<HermesDesktopEvent> activate(String sessionId) {
    _active.add(sessionId);
    return _removeQueue(sessionId)?.toList(growable: false) ?? const [];
  }

  void deactivate(String sessionId) => _active.remove(sessionId);

  bool hasPending(String sessionId) => _pending[sessionId]?.isNotEmpty == true;

  List<HermesDesktopEvent> pending(String sessionId) =>
      _pending[sessionId]?.toList(growable: false) ?? const [];

  List<HermesDesktopEvent> take(String sessionId) =>
      _removeQueue(sessionId)?.toList(growable: false) ?? const [];

  void discard(String sessionId) => _removeQueue(sessionId);

  /// Drops [sessionId]'s buffered requests for [requestId]: one closed
  /// (answered, withdrawn, timed out) must not be saved again from here.
  void dropRequest(String sessionId, String requestId) {
    final queue = _pending[sessionId];
    if (queue == null) return;
    final before = queue.length;
    queue.removeWhere(
      (event) =>
          event.type.endsWith('.request') &&
          (event.payload['request_id'] ?? event.payload['id'])?.toString() ==
              requestId,
    );
    _totalEvents -= before - queue.length;
    if (queue.isEmpty) _pending.remove(sessionId);
  }

  Queue<HermesDesktopEvent>? _removeQueue(String sessionId) {
    final removed = _pending.remove(sessionId);
    _totalEvents -= removed?.length ?? 0;
    return removed;
  }

  void clear() {
    _pending.clear();
    _active.clear();
    _totalEvents = 0;
  }
}

/// Bounded JSON-RPC client for Hermes Desktop's `/api/ws` gateway.
final class HermesDesktopRpcClient {
  HermesDesktopRpcClient({
    HermesDesktopChannelFactory? channelFactory,
    this.requestTimeout = const Duration(seconds: 60),
    this.heartbeatInterval = const Duration(seconds: 15),
  }) : _channelFactory = channelFactory ?? connectNoRedirectWebSocket;

  final HermesDesktopChannelFactory _channelFactory;
  final Duration requestTimeout;

  /// How often to ping a gateway that offers `heartbeat`, so a socket that
  /// died while the phone slept is noticed. A ping unanswered for one more
  /// interval drops the socket.
  final Duration heartbeatInterval;
  final _events = StreamController<HermesDesktopEvent>.broadcast();
  final _disconnects = StreamController<void>.broadcast();
  final Map<String, _PendingRpc> _pending = {};
  Map<String, dynamic> _defaultParams = const {};

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  DateTime _lastFrameAt = DateTime.now();
  int _socketGeneration = 0;
  int _requestId = 0;
  bool _ready = false;
  Map<String, dynamic> _readyPayload = const {};
  bool _declinesNotShown = false;

  /// Clarify requests shown and not yet fully answered, by request id.
  final Map<String, _OpenClarify> _clarifies = {};

  /// Connection operations with a target card shown, by operation id.
  final Map<String, _OpenConnection> _connections = {};


  Stream<HermesDesktopEvent> get events => _events.stream;
  Stream<void> get disconnects => _disconnects.stream;
  bool get isReady => _ready;
  int get socketGeneration => _socketGeneration;

  /// The current socket's `gateway.ready` payload.
  Map<String, dynamic> get readyPayload => _readyPayload;

  /// Whether the socket is served by a gateway's session authority (its own
  /// Webapp listener), which speaks the canonical protocol.
  bool get sessionAuthority => _readyPayload['session_authority'] == true;

  /// Connection-wide params merged into every request as a *fallback*.
  /// Callers that pass the same key win (Bot Mode scopes single calls to
  /// another profile without rebuilding the connection).
  void setDefaultParams(Map<String, dynamic> value) {
    _defaultParams = Map.unmodifiable(value);
  }

  Future<void> connect(
    Uri uri, {
    Map<String, String> headers = const {},
    HttpClient? httpClient,
  }) async {
    await disconnect();
    final generation = ++_socketGeneration;
    final channel = _channelFactory(uri, headers, httpClient: httpClient);
    _channel = channel;
    _ready = false;
    _readyPayload = const {};
    _declinesNotShown = false;
    _clarifies.clear();
    _connections.clear();
    final ready = Completer<void>();

    _subscription = channel.stream.listen(
      (raw) => _handleFrame(raw, channel, generation, ready),
      onError: (Object error, StackTrace stackTrace) {
        if (!_owns(channel, generation)) return;
        if (!ready.isCompleted) ready.completeError(error, stackTrace);
        _handleDisconnect(channel, generation);
      },
      onDone: () {
        if (!_owns(channel, generation)) return;
        if (!ready.isCompleted) {
          ready.completeError(
            const HermesDesktopRpcException(
              'Hermes closed the gateway before it became ready.',
            ),
          );
        }
        _handleDisconnect(channel, generation);
      },
      cancelOnError: false,
    );

    try {
      await Future.wait<void>([channel.ready, ready.future])
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      if (_owns(channel, generation)) await disconnect();
      rethrow;
    }
    _advertiseCapabilities(generation);
    if (_readyPayload['heartbeat'] == true) _startHeartbeat(generation);
  }

  /// Tells the gateway this client answers server→client requests. Without
  /// it Hermes withdraws every approval and question at once. The contract
  /// is closed, so the connection's default `profile` must stay out.
  void _advertiseCapabilities(int generation) {
    unawaited(
      request<Object?>(
            'client.capabilities',
            params: const {'server_requests': true},
            includeDefaultParams: false,
            timeout: const Duration(seconds: 15),
          )
          .then((result) {
            if (generation != _socketGeneration || result is! Map) return;
            _declinesNotShown = result['declines_not_shown'] == true;
          })
          .catchError((Object error) {
            DebugLogger.warning(
              'client-capabilities-refused',
              scope: 'hermes/desktop/ws',
              data: {'errorType': error.runtimeType.toString()},
            );
          }),
    );
  }

  /// Pings every [heartbeatInterval]; any frame counts as a sign of life, and
  /// three intervals without one drop the socket so reconnection can start.
  void _startHeartbeat(int generation) {
    _heartbeat?.cancel();
    _lastFrameAt = DateTime.now();
    _heartbeat = Timer.periodic(heartbeatInterval, (timer) {
      final channel = _channel;
      if (generation != _socketGeneration || channel == null) {
        timer.cancel();
        return;
      }
      if (DateTime.now().difference(_lastFrameAt) >= heartbeatInterval * 3) {
        DebugLogger.warning('heartbeat-missed', scope: 'hermes/desktop/ws');
        timer.cancel();
        unawaited(channel.sink.close());
        _handleDisconnect(channel, generation);
        return;
      }
      unawaited(
        request<Object?>(
          'gateway.ping',
          includeDefaultParams: false,
          timeout: heartbeatInterval * 3,
        ).then<void>((_) {}, onError: (Object _) {}),
      );
    });
  }

  Future<T> request<T>(
    String method, {
    Map<String, dynamic> params = const {},
    Duration? timeout,
    bool includeDefaultParams = true,
  }) {
    final channel = _channel;
    if (!_ready || channel == null) {
      return Future<T>.error(
        const HermesDesktopRpcException('Hermes gateway is not connected.'),
      );
    }
    final id = 'mobile-${++_requestId}';
    final completer = Completer<Object?>();
    final timer = Timer(timeout ?? requestTimeout, () {
      final pending = _pending.remove(id);
      pending?.completer.completeError(
        HermesDesktopRpcException(
          'Hermes request timed out: $method',
          timedOut: true,
        ),
      );
    });
    _pending[id] = _PendingRpc(completer, timer);
    try {
      channel.sink.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': {
            if (includeDefaultParams) ..._defaultParams,
            ...params,
          },
        }),
      );
    } catch (error, stackTrace) {
      _pending.remove(id)?.timer.cancel();
      completer.completeError(error, stackTrace);
    }
    return completer.future.then((value) => value as T);
  }

  void _handleFrame(
    Object? raw,
    WebSocketChannel channel,
    int generation,
    Completer<void> ready,
  ) {
    if (!_owns(channel, generation)) return;
    _lastFrameAt = DateTime.now();
    try {
      final String source;
      if (raw is String) {
        source = raw;
      } else if (raw is List<int>) {
        if (raw.length > kMaxHermesDesktopFrameBytes) {
          throw const HermesResponseTooLargeException(
            'Hermes gateway frame is too large.',
          );
        }
        source = utf8.decode(raw);
      } else {
        return;
      }
      if (source.length > kMaxHermesDesktopFrameCharacters ||
          (source.length * 3 > kMaxHermesDesktopFrameBytes &&
              utf8.encode(source).length > kMaxHermesDesktopFrameBytes)) {
        throw const HermesResponseTooLargeException(
          'Hermes gateway frame is too large.',
        );
      }
      validateHermesJsonSource(source);
      final decoded = jsonDecode(source);
      if (decoded is! Map) return;
      final frame = Map<String, dynamic>.from(decoded);
      final id = frame['id']?.toString();
      if (id != null &&
          (frame.containsKey('result') || frame['error'] is Map)) {
        final pending = _pending.remove(id);
        if (pending == null) return;
        pending.timer.cancel();
        final error = frame['error'];
        if (error is Map) {
          pending.completer.completeError(
            HermesDesktopRpcException(
              error['message']?.toString() ?? 'Hermes RPC failed.',
              code: error['code'] is int ? error['code'] as int : null,
              data: error['data'],
            ),
          );
        } else {
          pending.completer.complete(frame['result']);
        }
        return;
      }

      if (frame['method'] == 'event' && frame['params'] is Map) {
        final params = Map<String, dynamic>.from(frame['params'] as Map);
        final type = params['type']?.toString();
        if (type == null || type.isEmpty) return;
        final rawPayload = params['payload'];
        final payload = rawPayload is Map
            ? Map<String, dynamic>.from(rawPayload)
            : <String, dynamic>{};
        if (type == 'gateway.ready') {
          _readyPayload = Map.unmodifiable(payload);
          _ready = true;
          if (!ready.isCompleted) ready.complete();
        }
        final sessionId = params['session_id']?.toString();
        final seq = params['seq'];
        final generation = params['execution_generation'];
        final event = HermesDesktopEvent(
          type: type,
          payload: payload,
          sessionId: sessionId,
          seq: seq is int ? seq : null,
          replayEpoch: validateHermesOpaqueIdentifier(params['replay_epoch']),
          executionGeneration: generation is int ? generation : null,
          admissionId: validateHermesOpaqueIdentifier(params['admission_id']),
        );
        _events.add(event);
        switch (type) {
          case 'request.cancel':
            _withdrawServerRequest(payload, sessionId);
          case 'connection.request':
          case 'connection.update':
            _showConnection(payload, sessionId);
        }
        return;
      }

      if (frame['method'] is String && frame['id'] != null) {
        _handleServerRequest(channel, frame);
      }
    } catch (error) {
      DebugLogger.warning(
        'invalid-frame-dropped',
        scope: 'hermes/desktop/ws',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }

  /// Shows the gateway's questions as decision events. They are answered
  /// later, by RPC (`request.answer`, `clarify.lock`), from whichever socket
  /// is open by then, so nothing is written back here.
  ///
  /// Anything else is a Desktop-only bridge (themes, tours, previews) that
  /// must never reach mobile platform features. Declined with 4404 only when
  /// the gateway takes declines; any other error would settle the request as
  /// unanswered for every client sharing the session, including a Desktop
  /// that could have shown it.
  void _handleServerRequest(
    WebSocketChannel channel,
    Map<String, dynamic> frame,
  ) {
    final id = frame['id'];
    if (_showServerRequest(id, frame['method'], frame['params'])) return;
    if (!_declinesNotShown) return;
    channel.sink.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'error': {
          'code': kHermesServerRequestNotShownCode,
          'message': 'Not shown on mobile',
        },
      }),
    );
  }

  /// Re-shows the requests a `session.resume` snapshot lists as still open
  /// (`open_requests`), for a socket that was not attached when they were
  /// sent. Their ids are unchanged, so answers made now still count.
  void replayOpenRequests(Object? openRequests) {
    if (openRequests is! List) return;
    for (final entry in openRequests.whereType<Map>().take(32)) {
      _showServerRequest(entry['id'], entry['method'], entry['params']);
    }
  }

  /// Emits the decision events for one request; false when it is not one
  /// Conduit answers.
  bool _showServerRequest(Object? id, Object? method, Object? rawParams) {
    if (id is! String ||
        method is! String ||
        !kHermesAnsweredServerRequests.contains(method)) {
      return false;
    }
    final params = rawParams is Map
        ? Map<String, dynamic>.from(rawParams)
        : <String, dynamic>{};
    final open = method == 'clarify'
        ? _OpenClarify(params, previous: _clarifies[id])
        : null;
    final events = hermesDesktopEventsForServerRequest(
      id: id,
      method: method,
      params: params,
      locked: open?.locked ?? const {},
    );
    if (events.isEmpty) return false;
    if (open != null) {
      if (!_clarifies.containsKey(id) && _clarifies.length >= 64) {
        _clarifies.remove(_clarifies.keys.first);
      }
      // A replay that moved on to another question closes the card it
      // replaces: that one is answered, and must not stay actionable.
      final nextCardId = '${events.first.payload['request_id']}';
      final previousCardId = _clarifies[id]?.shownCardId;
      if (previousCardId != null && previousCardId != nextCardId) {
        _events.add(
          HermesDesktopEvent(
            type: 'clarify.expire',
            sessionId: events.first.sessionId,
            payload: {'request_id': previousCardId},
          ),
        );
      }
      _clarifies[id] = open..shownCardId = nextCardId;
    }
    for (final event in events) {
      _events.add(event);
    }
    return true;
  }

  /// Records that the clarify question [cardId] was answered and shows the
  /// request's next open question, if one remains. Returns whether one did.
  ///
  /// [remaining] is `clarify.lock`'s list of the questions still unanswered:
  /// every other one was answered, here or on another surface.
  bool showNextClarifyQuestion(String cardId, {Iterable<String>? remaining}) {
    final parsed = parseHermesClarifyCardId(cardId);
    final open = parsed == null ? null : _clarifies[parsed.requestId];
    if (parsed == null || open == null) return false;
    open.locked.add(parsed.questionId);
    final questions = open.params['questions'];
    if (remaining != null && questions is List) {
      final unanswered = remaining.toSet();
      open.locked
        ..removeAll(unanswered)
        ..addAll(
          questions
              .whereType<Map>()
              .map((question) => question['qid']?.toString())
              .nonNulls
              .where((questionId) => !unanswered.contains(questionId)),
        );
    }
    final events = hermesDesktopEventsForServerRequest(
      id: parsed.requestId,
      method: 'clarify',
      params: open.params,
      locked: open.locked,
    );
    if (events.isEmpty) {
      _clarifies.remove(parsed.requestId);
      return false;
    }
    open.shownCardId = '${events.first.payload['request_id']}';
    _events.add(events.first);
    return true;
  }

  /// Re-shows the connection operation a `session.resume` snapshot lists as
  /// open (`pending_connection`, shaped like `connection.request`).
  void replayPendingConnection(Object? payload, String? sessionId) {
    if (payload is Map) {
      _showConnection(Map<String, dynamic>.from(payload), sessionId);
    }
  }

  /// Keeps a connection operation's card on a target still waiting on the
  /// user. Every frame carries the full target list, so a request, an
  /// update and a resume snapshot are handled alike: the shown card closes
  /// (as an `mcp.setup.expire`) once its target moved on or the operation
  /// settled, and the next waiting target gets its card.
  void _showConnection(Map<String, dynamic> payload, String? sessionId) {
    final operationId = validateHermesOpaqueIdentifier(
      payload['op_id']?.toString(),
    );
    if (operationId == null) return;
    final owner = payload['owner'];
    final session =
        sessionId ??
        (owner is Map ? owner['session_id']?.toString() : null) ??
        _connections[operationId]?.sessionId;
    final open = _connections[operationId] ?? _OpenConnection(session);
    final shown = open.shownCardId;
    final shownTarget = shown == null
        ? null
        : open.cardTargets[shown] ?? parseHermesConnectionCardId(shown)?.target;
    final next = payload['settled'] == true
        ? null
        : hermesDesktopConnectionTargetEvent(
            operationId: operationId,
            sessionId: open.sessionId ?? session,
            targets: payload['targets'],
            shown: shownTarget,
            passed: open.passed,
            offers: open.offers,
          );
    final nextCardId = next?.payload['request_id']?.toString();
    final nextTarget = next?.payload['connection_target']?.toString();
    if (shown != null && shown != nextCardId) {
      if (shownTarget != null) open.passed.add(shownTarget);
      _events.add(
        HermesDesktopEvent(
          type: 'mcp.setup.expire',
          sessionId: open.sessionId ?? session,
          payload: {'request_id': shown},
        ),
      );
    }
    if (payload['settled'] == true) {
      _connections.remove(operationId);
      return;
    }
    // Kept while the operation runs, card or not: a target answered here
    // is not asked about again when its sign-in link arrives later.
    if (!_connections.containsKey(operationId) && _connections.length >= 32) {
      _connections.remove(_connections.keys.first);
    }
    _connections[operationId] = open
      ..shownCardId = nextCardId
      ..shownLink = _connectLinkOf(payload['targets'], nextTarget);
    if (nextCardId != null && nextTarget != null) {
      if (open.cardTargets.length >= 32 &&
          !open.cardTargets.containsKey(nextCardId)) {
        open.cardTargets.remove(open.cardTargets.keys.first);
      }
      open.cardTargets[nextCardId] = nextTarget;
    }
    if (next != null && shown != nextCardId) _events.add(next);
  }

  /// The target name connection card [cardId] stands for; null when its
  /// operation is no longer open and the id carries only a digest.
  String? connectionCardTarget(String cardId) {
    final card = parseHermesConnectionCardId(cardId);
    if (card == null) return null;
    final known = _connections[card.operationId]?.cardTargets[cardId];
    if (known != null) return known;
    return hermesConnectionCardId(card.operationId, card.target) == cardId
        ? card.target
        : null;
  }

  /// Offers connection target [cardId] again with [update]: the frame that
  /// carried a sign-in link the device could not open, or the one that kept
  /// an approved install waiting on credentials. Approving it again retries.
  /// No other card of its operation is displaced.
  void offerConnectionTargetAgain(String cardId, Map<String, dynamic> update) {
    final card = parseHermesConnectionCardId(cardId);
    final open = card == null ? null : _connections[card.operationId];
    if (card == null || open == null) return;
    // Its card was answered; one still counted as shown is shown anew, as
    // a new offer: the turn that saw the first one drops a repeat.
    open.passed.remove(open.cardTargets[cardId] ?? card.target);
    if (open.offers.length >= 32 && !open.offers.containsKey(cardId)) {
      open.offers.remove(open.offers.keys.first);
    }
    open.offers[cardId] = (open.offers[cardId] ?? 0) + 1;
    if (open.shownCardId == cardId) open.shownCardId = null;
    _showConnection(update, open.sessionId);
  }

  /// The sign-in link of the connection target [cardId] while its card is
  /// shown and its sign-in has started: opening it is the user's answer.
  Uri? connectionLink(String cardId) {
    final card = parseHermesConnectionCardId(cardId);
    final open = card == null ? null : _connections[card.operationId];
    return open?.shownCardId == cardId ? open?.shownLink : null;
  }

  /// `request.cancel` withdraws a server request: close its cards the way an
  /// expiry event did on earlier gateways.
  void _withdrawServerRequest(Map<String, dynamic> payload, String? sessionId) {
    final id = validateHermesOpaqueIdentifier(payload['id']?.toString());
    final method = payload['method']?.toString();
    if (id == null || !kHermesAnsweredServerRequests.contains(method)) return;
    final cardIds = method == 'clarify'
        ? [?_clarifies.remove(id)?.shownCardId]
        : [id];
    for (final cardId in cardIds) {
      _events.add(
        HermesDesktopEvent(
          type: '$method.expire',
          sessionId: sessionId,
          payload: {
            'request_id': cardId,
            'reason': payload['reason'],
          },
        ),
      );
    }
  }

  bool _owns(WebSocketChannel channel, int generation) =>
      identical(_channel, channel) && generation == _socketGeneration;

  void _handleDisconnect(WebSocketChannel channel, int generation) {
    if (!_owns(channel, generation)) return;
    _heartbeat?.cancel();
    _heartbeat = null;
    _ready = false;
    _channel = null;
    _rejectPending('Hermes gateway disconnected.');
    _disconnects.add(null);
  }

  void _rejectPending(String message) {
    for (final pending in _pending.values) {
      pending.timer.cancel();
      pending.completer.completeError(
        HermesDesktopRpcException(message, disconnected: true),
      );
    }
    _pending.clear();
  }

  Future<void> disconnect() async {
    _socketGeneration++;
    _heartbeat?.cancel();
    _heartbeat = null;
    _ready = false;
    final subscription = _subscription;
    final channel = _channel;
    _subscription = null;
    _channel = null;
    _rejectPending('Hermes gateway disconnected.');
    await subscription?.cancel();
    await channel?.sink.close();
  }

  Future<void> close() async {
    await disconnect();
    await _events.close();
    await _disconnects.close();
  }
}

final class _PendingRpc {
  const _PendingRpc(this.completer, this.timer);

  final Completer<Object?> completer;
  final Timer timer;
}
