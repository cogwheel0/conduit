import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../models/server_config.dart';
import '../models/socket_health.dart';
import '../utils/debug_logger.dart';
import 'socket_tls_override.dart';

typedef SocketChatEventHandler =
    void Function(
      Map<String, dynamic> event,
      void Function(dynamic response)? ack,
    );

typedef SocketChannelEventHandler =
    void Function(
      Map<String, dynamic> event,
      void Function(dynamic response)? ack,
    );

class SocketService with WidgetsBindingObserver {
  final ServerConfig serverConfig;
  final bool websocketOnly;
  final bool allowWebsocketUpgrade;
  io.Socket? _socket;
  String? _authToken;
  bool _isConnecting = false;
  bool _isAppForeground = true;
  Timer? _heartbeatTimer;
  bool _forcePollingFallback = false;

  /// Heartbeat interval matching OpenWebUI's 30-second interval.
  static const Duration _heartbeatInterval = Duration(seconds: 30);

  /// Tracks the last heartbeat round-trip latency in milliseconds.
  int _lastHeartbeatLatencyMs = -1;

  /// Timestamp of the last successful heartbeat response.
  DateTime? _lastSuccessfulHeartbeat;

  /// Count of reconnection attempts since service creation.
  int _reconnectCount = 0;

  /// Completer for event-based connection waiting.
  Completer<void>? _connectionCompleter;

  /// Stream controller for socket health updates.
  final _healthController = StreamController<SocketHealth>.broadcast();

  /// Stream that emits socket health updates.
  Stream<SocketHealth> get healthStream => _healthController.stream;

  /// Current heartbeat latency in milliseconds (-1 if unknown).
  int get lastHeartbeatLatencyMs => _lastHeartbeatLatencyMs;

  /// Last successful heartbeat timestamp.
  DateTime? get lastSuccessfulHeartbeat => _lastSuccessfulHeartbeat;

  /// Number of reconnections since service creation.
  int get reconnectCount => _reconnectCount;

  /// Current transport type ('websocket', 'polling', or 'unknown').
  String get currentTransport {
    final engine = _socket?.io.engine;
    if (engine == null) return 'unknown';
    // socket_io_client exposes transport name via engine
    try {
      final transport = engine.transport;
      if (transport != null) {
        return transport.name ?? 'unknown';
      }
    } catch (_) {}
    return 'unknown';
  }

  /// Returns current socket health snapshot.
  SocketHealth get currentHealth => SocketHealth(
    latencyMs: _lastHeartbeatLatencyMs,
    isConnected: isConnected,
    transport: currentTransport,
    reconnectCount: _reconnectCount,
    lastHeartbeat: _lastSuccessfulHeartbeat,
  );

  final Map<String, _ChatEventRegistration> _chatEventHandlers = {};
  final Map<String, _ChannelEventRegistration> _channelEventHandlers = {};
  int _handlerSeed = 0;

  // ---------------------------------------------------------------------------
  // Event buffering for timing races
  // ---------------------------------------------------------------------------
  // The backend may emit socket events before the streaming handler registers.
  // This buffer captures events for a specific chat_id and replays them when
  // a handler is added. Mirrors OpenWebUI's approach of registering global
  // listeners before sending the HTTP request.

  final Map<String, List<(Map<String, dynamic>, void Function(dynamic)?)>>
  _eventBuffer = {};

  /// Start buffering events for a chat_id. Call this BEFORE sending the
  /// HTTP request so events that arrive early aren't lost.
  void startBuffering(String chatId) {
    _eventBuffer[chatId] = [];
  }

  /// Stop buffering and discard any remaining events for a chat_id.
  void stopBuffering(String chatId) {
    _eventBuffer.remove(chatId);
  }

  /// Remove and return all buffered events for a chat_id.
  /// Used when the buffer needs to be replayed outside of addChatEventHandler.
  List<(Map<String, dynamic>, void Function(dynamic)?)>? drainBuffer(
    String chatId,
  ) {
    return _eventBuffer.remove(chatId);
  }

  /// Stream controller that emits when a socket reconnection occurs.
  /// Listeners can use this to sync state after a reconnect.
  final _reconnectController = StreamController<void>.broadcast();

  /// Stream that emits when a socket reconnection occurs.
  Stream<void> get onReconnect => _reconnectController.stream;

  SocketService({
    required this.serverConfig,
    String? authToken,
    this.websocketOnly = false,
    this.allowWebsocketUpgrade = true,
  }) : _authToken = authToken {
    final binding = WidgetsBinding.instance;
    final lifecycle = binding.lifecycleState;
    _isAppForeground =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    binding.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isAppForeground = state == AppLifecycleState.resumed;
  }

  String? get sessionId => _socket?.id;
  io.Socket? get socket => _socket;
  String? get authToken => _authToken;

  bool get isConnected => _socket?.connected == true;
  bool get isAppForeground => _isAppForeground;

  Future<void> connect({bool force = false}) async {
    if (_socket != null && _socket!.connected && !force) return;
    if (_isConnecting && !force) return;

    _isConnecting = true;

    DebugLogger.log(
      'Connecting to socket',
      scope: 'socket',
      data: {'force': force, 'serverUrl': serverConfig.url},
    );

    // Stop any existing heartbeat before disposing old socket
    _stopHeartbeat();

    try {
      final existing = _socket;
      if (existing != null) {
        _unbindCoreSocketHandlers(existing);
        existing.dispose();
      }
    } catch (_) {}

    String base = serverConfig.url.replaceFirst(RegExp(r'/+$'), '');
    // Normalize accidental ":0" ports or invalid port values in stored URL
    try {
      final u = Uri.parse(base);
      if (u.hasPort && u.port == 0) {
        // Drop the explicit :0 to fall back to scheme default (80/443)
        base = '${u.scheme}://${u.host}${u.path.isEmpty ? '' : u.path}';
      }
    } catch (_) {}
    final path = '/ws/socket.io';

    final usePollingFallback = _forcePollingFallback;
    final effectiveWebsocketOnly = websocketOnly && !usePollingFallback;
    final usePollingOnly = !effectiveWebsocketOnly && !allowWebsocketUpgrade;
    final transports = effectiveWebsocketOnly
        ? const ['websocket']
        : usePollingOnly
        ? const ['polling']
        : const ['polling', 'websocket'];

    final builder = io.OptionBuilder()
        // Transport selection switches between WebSocket-only and polling fallback
        .setTransports(transports)
        .setRememberUpgrade(!effectiveWebsocketOnly && allowWebsocketUpgrade)
        .setUpgrade(!effectiveWebsocketOnly && allowWebsocketUpgrade)
        // Tune reconnect/backoff and timeouts
        // Note: In socket_io_client, pass a very large number for "unlimited" attempts.
        // Using double.maxFinite.toInt() ensures unlimited reconnection attempts.
        .setReconnectionAttempts(double.maxFinite.toInt())
        .setReconnectionDelay(1000)
        .setReconnectionDelayMax(5000)
        .setRandomizationFactor(0.5)
        .setTimeout(20000)
        .setPath(path);

    // Merge Authorization (if any) with user-defined custom headers for the
    // Socket.IO handshake. Avoid overriding reserved headers.
    final Map<String, String> extraHeaders = {};
    if (_authToken != null && _authToken!.isNotEmpty) {
      extraHeaders['Authorization'] = 'Bearer $_authToken';
      builder.setAuth({'token': _authToken});
    }
    if (serverConfig.customHeaders.isNotEmpty) {
      final reserved = {
        'authorization',
        'content-type',
        'accept',
        // Socket/WebSocket reserved or managed by client/runtime
        'host',
        'origin',
        'connection',
        'upgrade',
        'sec-websocket-key',
        'sec-websocket-version',
        'sec-websocket-extensions',
        'sec-websocket-protocol',
      };
      serverConfig.customHeaders.forEach((key, value) {
        final lower = key.toLowerCase();
        if (!reserved.contains(lower) && value.isNotEmpty) {
          // Do not overwrite Authorization we already set from authToken
          if (lower == 'authorization' &&
              extraHeaders.containsKey('Authorization')) {
            return;
          }
          extraHeaders[key] = value;
        }
      });
    }
    if (extraHeaders.isNotEmpty) {
      builder.setExtraHeaders(extraHeaders);
    }

    try {
      _socket = createSocketWithOptionalBadCertOverride(
        base,
        builder,
        serverConfig,
      );
      _bindCoreSocketHandlers();
    } catch (_) {
      _isConnecting = false;
      rethrow;
    }
  }

  /// Update the auth token used by the socket service.
  /// If connected, emits a best-effort rejoin with the new token.
  void updateAuthToken(String? token) {
    _authToken = token;
    if (_socket?.connected == true &&
        _authToken != null &&
        _authToken!.isNotEmpty) {
      try {
        _socket!.emit('user-join', {
          'auth': {'token': _authToken},
        });
      } catch (_) {}
    }
  }

  SocketEventSubscription addChatEventHandler({
    String? conversationId,
    String? sessionId,
    bool requireFocus = true,
    required SocketChatEventHandler handler,
  }) {
    final id = _nextHandlerId();
    _chatEventHandlers[id] = _ChatEventRegistration(
      id: id,
      conversationId: conversationId,
      sessionId: sessionId,
      requireFocus: requireFocus,
      handler: handler,
    );

    // Replay buffered events for this conversation. This handles the timing
    // race where the backend emits events before the handler is registered.
    if (conversationId != null && _eventBuffer.containsKey(conversationId)) {
      final buffered = _eventBuffer.remove(conversationId)!;
      if (buffered.isNotEmpty) {
        DebugLogger.log(
          'Replaying ${buffered.length} buffered events for $conversationId',
          scope: 'socket/dispatch',
        );
        for (final (map, ackFn) in buffered) {
          try {
            handler(map, ackFn);
          } catch (_) {}
        }
      }
    }

    return SocketEventSubscription(
      () => _chatEventHandlers.remove(id),
      handlerId: id,
    );
  }

  SocketEventSubscription addChannelEventHandler({
    String? conversationId,
    String? sessionId,
    bool requireFocus = true,
    required SocketChannelEventHandler handler,
  }) {
    final id = _nextHandlerId();
    _channelEventHandlers[id] = _ChannelEventRegistration(
      id: id,
      conversationId: conversationId,
      sessionId: sessionId,
      requireFocus: requireFocus,
      handler: handler,
    );
    return SocketEventSubscription(
      () => _channelEventHandlers.remove(id),
      handlerId: id,
    );
  }

  void clearChatEventHandlers() {
    _chatEventHandlers.clear();
  }

  void clearChannelEventHandlers() {
    _channelEventHandlers.clear();
  }

  /// Update the session ID for a chat event handler registration.
  /// Used when socket reconnects and gets a new session ID.
  void updateChatHandlerSessionId(String handlerId, String newSessionId) {
    final existing = _chatEventHandlers[handlerId];
    if (existing != null) {
      _chatEventHandlers[handlerId] = _ChatEventRegistration(
        id: existing.id,
        conversationId: existing.conversationId,
        sessionId: newSessionId,
        requireFocus: existing.requireFocus,
        handler: existing.handler,
      );
    }
  }

  /// Update the session ID for a channel event handler registration.
  /// Used when socket reconnects and gets a new session ID.
  void updateChannelHandlerSessionId(String handlerId, String newSessionId) {
    final existing = _channelEventHandlers[handlerId];
    if (existing != null) {
      _channelEventHandlers[handlerId] = _ChannelEventRegistration(
        id: existing.id,
        conversationId: existing.conversationId,
        sessionId: newSessionId,
        requireFocus: existing.requireFocus,
        handler: existing.handler,
      );
    }
  }

  /// Update session IDs for all handlers matching a conversation ID.
  /// Called after socket reconnection to update handlers with the new session.
  void updateSessionIdForConversation(
    String conversationId,
    String newSessionId,
  ) {
    for (final entry in _chatEventHandlers.entries.toList()) {
      if (entry.value.conversationId == conversationId) {
        _chatEventHandlers[entry.key] = _ChatEventRegistration(
          id: entry.value.id,
          conversationId: entry.value.conversationId,
          sessionId: newSessionId,
          requireFocus: entry.value.requireFocus,
          handler: entry.value.handler,
        );
      }
    }
    for (final entry in _channelEventHandlers.entries.toList()) {
      if (entry.value.conversationId == conversationId) {
        _channelEventHandlers[entry.key] = _ChannelEventRegistration(
          id: entry.value.id,
          conversationId: entry.value.conversationId,
          sessionId: newSessionId,
          requireFocus: entry.value.requireFocus,
          handler: entry.value.handler,
        );
      }
    }
  }

  /// Emits an event with the given [data] to the server.
  void emit(String event, dynamic data) {
    _socket?.emit(event, data);
  }

  // Subscribe to an arbitrary socket.io event (used for dynamic tool channels)
  void onEvent(String eventName, void Function(dynamic data) handler) {
    _socket?.on(eventName, handler);
  }

  void offEvent(String eventName) {
    _socket?.off(eventName);
  }

  void dispose() {
    _stopHeartbeat();
    try {
      final existing = _socket;
      if (existing != null) {
        _unbindCoreSocketHandlers(existing);
        existing.dispose();
      }
    } catch (_) {}
    _socket = null;
    WidgetsBinding.instance.removeObserver(this);
    _chatEventHandlers.clear();
    _channelEventHandlers.clear();
    _reconnectController.close();
    _healthController.close();
    _connectionCompleter?.completeError(StateError('Service disposed'));
    _connectionCompleter = null;
  }

  /// Ensures there is an active connection and waits for it.
  ///
  /// Uses event-based waiting instead of polling for efficiency.
  /// Returns true if connected by the end of the timeout.
  Future<bool> ensureConnected({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (isConnected) return true;

    // Create a completer for event-based waiting if not already waiting
    _connectionCompleter ??= Completer<void>();

    try {
      await connect();
    } catch (_) {}

    // If already connected after connect() call, return immediately
    if (isConnected) {
      _connectionCompleter = null;
      return true;
    }

    // Wait for connection event or timeout
    try {
      await _connectionCompleter!.future.timeout(timeout);
      return isConnected;
    } on TimeoutException {
      _connectionCompleter = null;
      return isConnected;
    } catch (_) {
      _connectionCompleter = null;
      return isConnected;
    }
  }

  void _bindCoreSocketHandlers() {
    final socket = _socket;
    if (socket == null) return;

    _unbindCoreSocketHandlers(socket);

    socket
      ..on('events', _handleChatEvent)
      ..on('chat-events', _handleChatEvent)
      ..on('events:channel', _handleChannelEvent)
      ..on('channel-events', _handleChannelEvent)
      ..on('connect', _handleConnect)
      ..on('connect_error', _handleConnectError)
      ..on('reconnect_attempt', _handleReconnectAttempt)
      ..on('reconnect', _handleReconnect)
      ..on('reconnect_failed', _handleReconnectFailed)
      ..on('disconnect', _handleDisconnect);
  }

  void _unbindCoreSocketHandlers(io.Socket socket) {
    socket
      ..off('events', _handleChatEvent)
      ..off('chat-events', _handleChatEvent)
      ..off('events:channel', _handleChannelEvent)
      ..off('channel-events', _handleChannelEvent)
      ..off('connect', _handleConnect)
      ..off('connect_error', _handleConnectError)
      ..off('reconnect_attempt', _handleReconnectAttempt)
      ..off('reconnect', _handleReconnect)
      ..off('reconnect_failed', _handleReconnectFailed)
      ..off('disconnect', _handleDisconnect);
  }

  void _handleConnect(dynamic _) {
    _isConnecting = false;

    // Reset polling fallback on successful connection - allows retrying
    // WebSocket-only mode after conditions improve (fixes permanent fallback)
    _forcePollingFallback = false;

    DebugLogger.log(
      'Socket connected',
      scope: 'socket',
      data: {'sessionId': _socket?.id, 'transport': currentTransport},
    );

    if (_authToken != null && _authToken!.isNotEmpty) {
      _socket?.emit('user-join', {
        'auth': {'token': _authToken},
      });
    }

    // Start heartbeat timer to keep connection alive
    _startHeartbeat();

    // Complete any pending connection waiters
    _connectionCompleter?.complete();
    _connectionCompleter = null;

    // Emit health update
    _emitHealthUpdate();
  }

  void _handleReconnectAttempt(dynamic attempt) {
    _isConnecting = true;
    DebugLogger.log(
      'Socket reconnection attempt',
      scope: 'socket',
      data: {'attempt': attempt},
    );
  }

  void _handleReconnect(dynamic attempt) {
    _isConnecting = false;
    _reconnectCount++;

    // Reset polling fallback on successful reconnection
    _forcePollingFallback = false;

    DebugLogger.log(
      'Socket reconnected',
      scope: 'socket',
      data: {
        'attempt': attempt,
        'sessionId': _socket?.id,
        'transport': currentTransport,
        'totalReconnects': _reconnectCount,
      },
    );

    if (_authToken != null && _authToken!.isNotEmpty) {
      _socket?.emit('user-join', {
        'auth': {'token': _authToken},
      });
    }

    // Restart heartbeat after reconnection
    _startHeartbeat();

    // Complete any pending connection waiters
    _connectionCompleter?.complete();
    _connectionCompleter = null;

    // Notify listeners that a reconnection occurred so they can refresh state
    if (!_reconnectController.isClosed) {
      _reconnectController.add(null);
    }

    // Emit health update
    _emitHealthUpdate();
  }

  void _handleConnectError(dynamic err) {
    _isConnecting = false;
    DebugLogger.error(
      'Socket connection error',
      scope: 'socket',
      error: err,
      data: {'serverUrl': serverConfig.url},
    );

    // If WebSocket-only handshake fails, retry once with polling+websocket
    // transports to avoid endless spinners (issue #172).
    if (websocketOnly && !_forcePollingFallback) {
      _forcePollingFallback = true;
      DebugLogger.warning(
        'WebSocket connect failed; retrying with polling fallback',
        scope: 'socket',
        data: {'reason': err?.toString()},
      );
      unawaited(connect(force: true));
    }
  }

  void _handleReconnectFailed(dynamic _) {
    _isConnecting = false;
    DebugLogger.error(
      'Socket reconnection failed after all attempts',
      scope: 'socket',
      data: {'serverUrl': serverConfig.url},
    );
  }

  void _handleDisconnect(dynamic reason) {
    _isConnecting = false;
    DebugLogger.warning(
      'Socket disconnected',
      scope: 'socket',
      data: {'reason': reason?.toString()},
    );

    // Stop heartbeat when disconnected
    _stopHeartbeat();

    // Reset latency info on disconnect
    _lastHeartbeatLatencyMs = -1;

    // Fail any pending connection waiters
    _connectionCompleter?.completeError(
      StateError('Socket disconnected: $reason'),
    );
    _connectionCompleter = null;

    // Emit health update
    _emitHealthUpdate();
  }

  /// Starts the heartbeat timer to keep the connection alive.
  /// Sends a heartbeat event every 30 seconds matching OpenWebUI's behavior.
  /// Tracks round-trip latency for connection health monitoring.
  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      if (_socket?.connected != true) return;

      final start = DateTime.now();

      // Track pending heartbeat for latency measurement
      _pendingHeartbeatStart = start;

      // Emit heartbeat - OpenWebUI server may or may not acknowledge
      _socket?.emit('heartbeat', <String, dynamic>{});

      // Update latency based on successful emission (approximation)
      // For true RTT, we'd need server to echo back, but most Socket.IO
      // servers don't ack heartbeat events explicitly
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_pendingHeartbeatStart == start && _socket?.connected == true) {
          // If still connected after 100ms, consider heartbeat successful
          _lastHeartbeatLatencyMs = DateTime.now()
              .difference(start)
              .inMilliseconds;
          _lastSuccessfulHeartbeat = DateTime.now();
          _pendingHeartbeatStart = null;
          _emitHealthUpdate();
        }
      });
    });
  }

  DateTime? _pendingHeartbeatStart;

  /// Stops the heartbeat timer.
  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Emits a health update to listeners.
  void _emitHealthUpdate() {
    if (!_healthController.isClosed) {
      _healthController.add(currentHealth);
    }
  }

  void _handleChatEvent(dynamic data, [dynamic ack]) {
    // For sio.call() events, the Dart socket.io client may deliver the
    // payload as a List with the ack callback as the last element.
    // Extract both the map and the ack from the list.
    dynamic effectiveAck = ack;
    dynamic effectiveData = data;
    if (data is List && data.isNotEmpty) {
      if (data.last is Function) {
        effectiveAck ??= data.last;
        effectiveData = data.length == 2
            ? data.first
            : data.sublist(0, data.length - 1);
      }
    }

    final map = _coerceToMap(effectiveData);
    if (map == null) return;

    final ackFn = _wrapAck(effectiveAck);
    final sessionId = _extractSessionId(map);
    final chatId = map['chat_id']?.toString();
    final channelId = _extractChannelId(map);

    for (final registration in List<_ChatEventRegistration>.from(
      _chatEventHandlers.values,
    )) {
      if (!_shouldDeliver(
        registration.conversationId,
        registration.sessionId,
        chatId,
        sessionId,
        registration.requireFocus,
        incomingChannelId: channelId,
      )) {
        continue;
      }

      try {
        registration.handler(map, ackFn);
      } catch (_) {}
      return; // Delivered to first matching handler
    }
    // Buffer event if we're pre-buffering for this chat_id
    if (chatId != null && _eventBuffer.containsKey(chatId)) {
      _eventBuffer[chatId]!.add((Map<String, dynamic>.from(map), ackFn));
    }
  }

  void _handleChannelEvent(dynamic data, [dynamic ack]) {
    // Same List/ack extraction as _handleChatEvent
    dynamic effectiveAck = ack;
    dynamic effectiveData = data;
    if (data is List && data.isNotEmpty) {
      if (data.last is Function) {
        effectiveAck ??= data.last;
        effectiveData = data.length == 2
            ? data.first
            : data.sublist(0, data.length - 1);
      }
    }

    final map = _coerceToMap(effectiveData);
    if (map == null) return;

    final ackFn = _wrapAck(effectiveAck);
    final sessionId = _extractSessionId(map);
    final chatId = map['chat_id']?.toString();
    final channelId = _extractChannelId(map);

    for (final registration in List<_ChannelEventRegistration>.from(
      _channelEventHandlers.values,
    )) {
      if (!_shouldDeliver(
        registration.conversationId,
        registration.sessionId,
        chatId,
        sessionId,
        registration.requireFocus,
        incomingChannelId: channelId,
      )) {
        continue;
      }

      try {
        registration.handler(map, ackFn);
      } catch (_) {}
    }
  }

  bool _shouldDeliver(
    String? registeredConversationId,
    String? registeredSessionId,
    String? incomingConversationId,
    String? incomingSessionId,
    bool requireFocus, {
    String? incomingChannelId,
  }) {
    final matchesConversation =
        registeredConversationId == null ||
        (incomingConversationId != null &&
            registeredConversationId == incomingConversationId) ||
        (incomingChannelId != null &&
            registeredConversationId == incomingChannelId);
    final matchesSession =
        registeredSessionId != null &&
        incomingSessionId != null &&
        registeredSessionId == incomingSessionId;

    // Must match either conversation or session to be considered
    if (!matchesConversation && !matchesSession) {
      return false;
    }

    // If no focus requirement, always deliver
    if (!requireFocus) {
      return true;
    }

    // Session-targeted messages always bypass focus check (critical for
    // background streaming - done/delta events must arrive even when backgrounded)
    if (matchesSession) {
      return true;
    }

    // FIX for issue #172: If conversation matches (even without session match),
    // still deliver when app is in foreground. This handles socket reconnection
    // where session_id changes but chat_id stays the same.
    if (matchesConversation && registeredConversationId != null) {
      return _isAppForeground;
    }

    return _isAppForeground;
  }

  Map<String, dynamic>? _coerceToMap(dynamic data) {
    if (data is Map<String, dynamic>) {
      return data;
    }
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    // socket.io may wrap event data in a List (e.g. from sio.call() or
    // when the server emits multiple arguments). Extract the first Map.
    if (data is List && data.isNotEmpty) {
      final first = data.first;
      if (first is Map<String, dynamic>) return first;
      if (first is Map) return Map<String, dynamic>.from(first);
    }
    return null;
  }

  void Function(dynamic response)? _wrapAck(dynamic ack) {
    if (ack is! Function) return null;
    return (dynamic payload) {
      try {
        if (payload is List) {
          Function.apply(ack, payload);
        } else if (payload == null) {
          Function.apply(ack, const []);
        } else {
          Function.apply(ack, [payload]);
        }
      } catch (_) {}
    };
  }

  String? _extractSessionId(Map<String, dynamic> event) {
    String? candidate;

    if (event['session_id'] != null) {
      candidate = event['session_id'].toString();
    }

    final data = event['data'];
    if (data is Map) {
      if (candidate == null && data['session_id'] != null) {
        candidate = data['session_id'].toString();
      }
      if (candidate == null && data['sessionId'] != null) {
        candidate = data['sessionId'].toString();
      }
      final inner = data['data'];
      if (inner is Map) {
        if (candidate == null && inner['session_id'] != null) {
          candidate = inner['session_id'].toString();
        }
        if (candidate == null && inner['sessionId'] != null) {
          candidate = inner['sessionId'].toString();
        }
      }
    }

    return candidate;
  }

  String? _extractChannelId(Map<String, dynamic> event) {
    String? candidate;

    if (event['channel_id'] != null) {
      candidate = event['channel_id'].toString();
    }
    if (candidate == null && event['channelId'] != null) {
      candidate = event['channelId'].toString();
    }

    final data = event['data'];
    if (data is Map) {
      if (candidate == null && data['channel_id'] != null) {
        candidate = data['channel_id'].toString();
      }
      if (candidate == null && data['channelId'] != null) {
        candidate = data['channelId'].toString();
      }
      final inner = data['data'];
      if (inner is Map) {
        if (candidate == null && inner['channel_id'] != null) {
          candidate = inner['channel_id'].toString();
        }
        if (candidate == null && inner['channelId'] != null) {
          candidate = inner['channelId'].toString();
        }
      }
    }

    return candidate;
  }

  String _nextHandlerId() {
    _handlerSeed += 1;
    return _handlerSeed.toString();
  }
}

class SocketEventSubscription {
  SocketEventSubscription(this._dispose, {this.handlerId});

  final VoidCallback _dispose;
  final String? handlerId;
  bool _isDisposed = false;

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _dispose();
  }
}

class _ChatEventRegistration {
  _ChatEventRegistration({
    required this.id,
    required this.handler,
    this.conversationId,
    this.sessionId,
    this.requireFocus = true,
  });

  final String id;
  final String? conversationId;
  final String? sessionId;
  final bool requireFocus;
  final SocketChatEventHandler handler;
}

class _ChannelEventRegistration {
  _ChannelEventRegistration({
    required this.id,
    required this.handler,
    this.conversationId,
    this.sessionId,
    this.requireFocus = true,
  });

  final String id;
  final String? conversationId;
  final String? sessionId;
  final bool requireFocus;
  final SocketChannelEventHandler handler;
}
