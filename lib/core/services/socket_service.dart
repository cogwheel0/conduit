import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../models/server_config.dart';
import '../models/socket_health.dart';
import '../network/conduit_user_agent.dart';
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

typedef SocketFactory =
    io.Socket Function(
      String base,
      io.OptionBuilder builder,
      ServerConfig serverConfig,
    );

class SocketService with WidgetsBindingObserver {
  final ServerConfig serverConfig;
  final bool websocketOnly;
  final bool allowWebsocketUpgrade;
  final SocketFactory _socketFactory;
  final Duration _resumeReconnectWatchdogTimeout;
  io.Socket? _socket;
  String? _authToken;
  bool _isConnecting = false;
  Completer<void>? _pendingForcedConnect;
  bool _disposed = false;
  bool _isAppForeground = true;
  bool _wasBackgrounded = false;
  bool _resumeReconnectInFlight = false;
  bool _signalReconnectOnConnect = false;
  bool _hasNetwork = true;
  int _backgroundActivityLeases = 0;
  final Set<String> _backgroundLeaseHandlerIds = <String>{};
  Timer? _heartbeatTimer;
  Timer? _resumeReconnectWatchdogTimer;
  bool _forcePollingFallback = false;

  /// Heartbeat interval matching OpenWebUI's 30-second interval.
  static const Duration _heartbeatInterval = Duration(seconds: 30);
  static const Duration _defaultResumeReconnectWatchdogTimeout = Duration(
    seconds: 30,
  );

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
  final Map<String, List<void Function(dynamic)>> _dynamicEventHandlers = {};
  int _handlerSeed = 0;

  // ---------------------------------------------------------------------------
  // Event buffering for timing races
  // ---------------------------------------------------------------------------
  // The backend may emit socket events before the streaming handler registers.
  // This buffer captures events for a specific conversation/session/message
  // scope and replays them when a matching handler is added. This is
  // especially important for early `request:chat:completion` events that may
  // target a session before the handler attaches.

  final Map<String, _BufferedChatEventScope> _eventBuffer = {};

  String _conversationBufferAlias(String conversationId) =>
      'chat:$conversationId';

  String _sessionBufferAlias(String sessionId) => 'session:$sessionId';

  String _messageBufferAlias(String messageId) => 'message:$messageId';

  Set<String> _bufferAliases({
    String? conversationId,
    String? sessionId,
    String? messageId,
  }) {
    return <String>{
      if (conversationId != null && conversationId.isNotEmpty)
        _conversationBufferAlias(conversationId),
      if (sessionId != null && sessionId.isNotEmpty)
        _sessionBufferAlias(sessionId),
      if (messageId != null && messageId.isNotEmpty)
        _messageBufferAlias(messageId),
    };
  }

  _BufferedChatEventScope? _findBufferScope({
    String? conversationId,
    String? sessionId,
    String? messageId,
  }) {
    for (final alias in _bufferAliases(
      conversationId: conversationId,
      sessionId: sessionId,
      messageId: messageId,
    )) {
      final scope = _eventBuffer[alias];
      if (scope != null) {
        return scope;
      }
    }
    return null;
  }

  void _removeBufferScope(_BufferedChatEventScope scope) {
    for (final alias in scope.aliases) {
      if (identical(_eventBuffer[alias], scope)) {
        _eventBuffer.remove(alias);
      }
    }
  }

  void _removeBufferScopesForAliases(Set<String> aliases) {
    final scopes = <_BufferedChatEventScope>{};
    for (final alias in aliases) {
      final scope = _eventBuffer[alias];
      if (scope != null) {
        scopes.add(scope);
      }
    }
    for (final scope in scopes) {
      _removeBufferScope(scope);
    }
  }

  /// Start buffering events for a pending send before the streaming handler
  /// is attached.
  void startBuffering(String chatId, {String? sessionId, String? messageId}) {
    final aliases = _bufferAliases(
      conversationId: chatId,
      sessionId: sessionId,
      messageId: messageId,
    );
    _removeBufferScopesForAliases(aliases);

    final scope = _BufferedChatEventScope();
    for (final alias in aliases) {
      scope.aliases.add(alias);
      _eventBuffer[alias] = scope;
    }
  }

  /// Stop buffering and discard any remaining buffered events for a pending
  /// send scope.
  void stopBuffering(String chatId, {String? sessionId, String? messageId}) {
    _removeBufferScopesForAliases(
      _bufferAliases(
        conversationId: chatId,
        sessionId: sessionId,
        messageId: messageId,
      ),
    );
  }

  /// Remove and return all buffered events for a pending send scope.
  List<(Map<String, dynamic>, void Function(dynamic)?)>? drainBuffer({
    String? conversationId,
    String? sessionId,
    String? messageId,
  }) {
    final scope = _findBufferScope(
      conversationId: conversationId,
      sessionId: sessionId,
      messageId: messageId,
    );
    if (scope == null) {
      return null;
    }
    _removeBufferScope(scope);
    return List<(Map<String, dynamic>, void Function(dynamic)?)>.from(
      scope.events,
    );
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
    SocketFactory? socketFactory,
    Duration resumeReconnectWatchdogTimeout =
        _defaultResumeReconnectWatchdogTimeout,
  }) : _authToken = authToken,
       _resumeReconnectWatchdogTimeout = resumeReconnectWatchdogTimeout,
       _socketFactory =
           socketFactory ?? createSocketWithOptionalBadCertOverride {
    final binding = WidgetsBinding.instance;
    final lifecycle = binding.lifecycleState;
    _isAppForeground = lifecycle == null || _isLifecycleForeground(lifecycle);
    _wasBackgrounded = lifecycle != null && _isLifecycleBackground(lifecycle);
    binding.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _isAppForeground = false;
        _wasBackgrounded = true;
        _applyTransportActivityPolicy();
        break;
      case AppLifecycleState.inactive:
        _isAppForeground = true;
        break;
      case AppLifecycleState.resumed:
        _isAppForeground = true;
        final resumedFromBackground = _wasBackgrounded;
        if (resumedFromBackground) {
          _wasBackgrounded = false;
          // Arm reconciliation even when reachability is currently false.
          // The next successful foreground connection must still prompt
          // consumers to refresh state missed while backgrounded.
          _signalReconnectOnConnect = true;
        }
        _applyTransportActivityPolicy();
        if (resumedFromBackground) {
          if (_mayMaintainTransport) {
            unawaited(_reconnectAfterResume());
          }
        }
        break;
    }
  }

  static bool _isLifecycleForeground(AppLifecycleState state) =>
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

  static bool _isLifecycleBackground(AppLifecycleState state) =>
      state == AppLifecycleState.paused ||
      state == AppLifecycleState.hidden ||
      state == AppLifecycleState.detached;

  Future<void> _reconnectAfterResume() async {
    // A background activity lease can legitimately keep the existing
    // transport connected while the app is paused. Resuming that transport
    // still requires consumer reconciliation, but replacing it would add a
    // needless handshake and could interrupt the leased stream.
    if (isConnected) {
      _publishPendingResumeReconciliation();
      return;
    }
    if (_resumeReconnectInFlight) return;

    _resumeReconnectInFlight = true;
    _resumeReconnectWatchdogTimer?.cancel();
    _resumeReconnectWatchdogTimer = Timer(
      _resumeReconnectWatchdogTimeout,
      _releaseResumeReconnectAttempt,
    );
    try {
      await connect(force: true);
    } catch (_) {
      // Keep the reconciliation intent. A later explicit/network-triggered
      // connection can still succeed after a transient factory/transport
      // failure and must notify consumers exactly once.
      _releaseResumeReconnectAttempt();
    }
  }

  void _releaseResumeReconnectAttempt() {
    _resumeReconnectWatchdogTimer?.cancel();
    _resumeReconnectWatchdogTimer = null;
    _resumeReconnectInFlight = false;
  }

  void _publishPendingResumeReconciliation() {
    final shouldSignalReconnect = _signalReconnectOnConnect;
    _releaseResumeReconnectAttempt();
    if (!shouldSignalReconnect) return;

    _signalReconnectOnConnect = false;
    if (!_reconnectController.isClosed) {
      _reconnectController.add(null);
    }
  }

  void _clearPendingResumeReconnect() {
    _releaseResumeReconnectAttempt();
    _signalReconnectOnConnect = false;
  }

  void _deferOrClearPendingResumeReconnect() {
    _releaseResumeReconnectAttempt();
    if (!_isAppForeground || _disposed) {
      _signalReconnectOnConnect = false;
    }
  }

  String? get sessionId => _socket?.id;
  io.Socket? get socket => _socket;
  String? get authToken => _authToken;

  bool get isConnected => _socket?.connected == true;
  bool get isAppForeground => _isAppForeground;
  int get backgroundActivityLeaseCount => _backgroundActivityLeases;

  /// Keeps an already-owned Socket.IO transport alive while one admitted unit
  /// of work still needs it in the background. Session-level listeners must
  /// not hold this lease permanently; acquire it only for the active operation
  /// and dispose it on every terminal path.
  SocketBackgroundActivityLease acquireBackgroundActivityLease() {
    if (_disposed) return SocketBackgroundActivityLease._(() {});
    _acquireBackgroundActivityLease();
    return SocketBackgroundActivityLease._(_releaseBackgroundActivityLease);
  }

  bool get _mayMaintainTransport =>
      _hasNetwork && (_isAppForeground || _backgroundActivityLeases > 0);

  /// Starts a connection that has no caller awaiting its result while still
  /// observing every asynchronous failure. Lifecycle/provider kicks are
  /// intentionally best-effort, but an ignored error Future would otherwise
  /// escape to the root zone.
  void connectBestEffort({bool force = false, required String reason}) {
    _runBestEffort(() => connect(force: force), reason: reason);
  }

  void _runBestEffort(
    Future<void> Function() operation, {
    required String reason,
  }) {
    unawaited(
      Future<void>.sync(operation).then<void>(
        (_) {},
        onError: (Object error, StackTrace _) {
          DebugLogger.warning(
            'Best-effort socket operation failed',
            scope: 'socket/connect',
            data: {'reason': reason, 'errorType': error.runtimeType.toString()},
          );
        },
      ),
    );
  }

  void _runPendingForcedConnectBestEffort({
    bool forceEvenWithoutWaiter = false,
    required String reason,
  }) {
    _runBestEffort(
      () => _runPendingForcedConnect(
        forceEvenWithoutWaiter: forceEvenWithoutWaiter,
      ),
      reason: reason,
    );
  }

  /// Applies interface reachability to Socket.IO itself, preventing its
  /// internal unlimited reconnect loop from waking the radio while the device
  /// is known to be offline.
  void updateNetworkAvailability(bool available) {
    if (_hasNetwork == available) return;
    _hasNetwork = available;
    _applyTransportActivityPolicy();
    if (_mayMaintainTransport && !isConnected) {
      connectBestEffort(force: true, reason: 'network-available');
    }
  }

  void _acquireBackgroundActivityLease() {
    _backgroundActivityLeases++;
    _applyTransportActivityPolicy();
    // The manager owns initial transport creation. A handler lease may revive
    // a transport that this service already owns, but registering a handler on
    // a detached/test service must not start an unsolicited network request.
    if (_mayMaintainTransport && _socket != null && !isConnected) {
      connectBestEffort(reason: 'background-activity-lease');
    }
  }

  void _releaseBackgroundActivityLease() {
    if (_backgroundActivityLeases > 0) _backgroundActivityLeases--;
    _applyTransportActivityPolicy();
  }

  void _applyTransportActivityPolicy() {
    if (_mayMaintainTransport) {
      _setAutomaticReconnection(true);
      if (isConnected) _startHeartbeat();
      return;
    }
    _stopHeartbeat();
    _setAutomaticReconnection(false);
    final interruptedConnect = _isConnecting;
    if (interruptedConnect) {
      // Socket.IO does not consistently emit `disconnect` when disconnecting
      // an as-yet-unconnected socket. Retire our negotiation state explicitly
      // so foreground/network recovery can create a fresh transport.
      _isConnecting = false;
      _deferOrClearPendingResumeReconnect();
    }
    final socket = _socket;
    try {
      socket?.disconnect();
    } catch (_) {
      // A late Socket.IO `connect` callback can arrive after the manager was
      // already destroyed while negotiating. In that state Socket.disconnect
      // may throw while trying to write its namespace DISCONNECT packet. Close
      // the manager transport directly, then retire the public session state so
      // no caller can observe the stale connection as usable.
      try {
        socket?.io.disconnect();
      } catch (_) {}
      socket?.connected = false;
      socket?.id = null;
    }
    if (socket?.connected == true) {
      // Defensive fallback for platform/client implementations whose
      // disconnect call returns without synchronously retiring session state.
      try {
        socket?.io.disconnect();
      } catch (_) {}
      socket?.connected = false;
      socket?.id = null;
    }
    if (interruptedConnect) {
      _runPendingForcedConnectBestEffort(reason: 'transport-interrupted');
    }
  }

  void _setAutomaticReconnection(bool enabled) {
    try {
      _socket?.io.reconnection = enabled;
    } catch (_) {}
  }

  Future<void> connect({bool force = false}) async {
    if (_disposed) return;
    if (!_mayMaintainTransport) return;
    if (_socket != null && _socket!.connected && !force) return;
    if (_isConnecting) {
      if (!force) return;
      // A forced lifecycle/network refresh must not dispose an attempt that is
      // still negotiating. Coalesce all force requests and start exactly one
      // fresh attempt after the current socket reports a terminal event.
      return (_pendingForcedConnect ??= Completer<void>()).future;
    }

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
    } catch (e, st) {
      DebugLogger.error(
        'failed disposing previous socket on reconnect',
        error: e,
        stackTrace: st,
        scope: 'socket',
      );
    }

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
    final Map<String, String> extraHeaders = {
      ConduitUserAgent.headerName: ConduitUserAgent.value,
    };
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
        'user-agent',
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
      _socket = _socketFactory(base, builder, serverConfig);
      _bindCoreSocketHandlers();
      _bindDynamicSocketHandlers(_socket);
      _setAutomaticReconnection(_mayMaintainTransport);
    } catch (_) {
      _isConnecting = false;
      _runPendingForcedConnectBestEffort(reason: 'socket-factory-failure');
      rethrow;
    }
  }

  Future<void> _runPendingForcedConnect({
    bool forceEvenWithoutWaiter = false,
  }) async {
    final pending = _pendingForcedConnect;
    if (pending == null && !forceEvenWithoutWaiter) return;
    _pendingForcedConnect = null;

    if (_disposed || !_mayMaintainTransport) {
      if (pending != null && !pending.isCompleted) pending.complete();
      return;
    }

    try {
      await connect(force: true);
      if (pending != null && !pending.isCompleted) pending.complete();
    } catch (error, stackTrace) {
      if (pending != null && !pending.isCompleted) {
        pending.completeError(error, stackTrace);
      } else {
        // The best-effort wrapper observes this future. Without a waiter there
        // is no completer to carry the failure, so swallowing here would make
        // a failed forced fallback invisible even to structured diagnostics.
        Error.throwWithStackTrace(error, stackTrace);
      }
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
    String? messageId,
    bool requireFocus = true,
    bool keepsAliveInBackground = false,
    required SocketChatEventHandler handler,
  }) {
    if (keepsAliveInBackground) _acquireBackgroundActivityLease();
    final id = _nextHandlerId();
    if (keepsAliveInBackground) _backgroundLeaseHandlerIds.add(id);
    _chatEventHandlers[id] = _ChatEventRegistration(
      id: id,
      conversationId: conversationId,
      sessionId: sessionId,
      messageId: messageId,
      requireFocus: requireFocus,
      handler: handler,
    );

    // Replay buffered events for this scope. This handles the timing race
    // where the backend emits events before the handler is registered.
    final buffered = drainBuffer(
      conversationId: conversationId,
      sessionId: sessionId,
      messageId: messageId,
    );
    if (buffered != null) {
      if (buffered.isNotEmpty) {
        DebugLogger.log(
          'Replaying ${buffered.length} buffered events '
          '(chat=${conversationId ?? "<none>"}, '
          'session=${sessionId ?? "<none>"}, '
          'message=${messageId ?? "<none>"})',
          scope: 'socket/dispatch',
        );
        for (final (map, ackFn) in buffered) {
          try {
            handler(map, ackFn);
          } catch (e, st) {
            DebugLogger.error(
              'buffered socket event handler threw during replay',
              error: e,
              stackTrace: st,
              scope: 'socket/dispatch',
            );
          }
        }
      }
    }

    return SocketEventSubscription(() {
      _chatEventHandlers.remove(id);
      if (_backgroundLeaseHandlerIds.remove(id)) {
        _releaseBackgroundActivityLease();
      }
    }, handlerId: id);
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
    if (_backgroundLeaseHandlerIds.isNotEmpty) {
      _backgroundActivityLeases -= _backgroundLeaseHandlerIds.length;
      if (_backgroundActivityLeases < 0) _backgroundActivityLeases = 0;
      _backgroundLeaseHandlerIds.clear();
      _applyTransportActivityPolicy();
    }
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
        messageId: existing.messageId,
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
          messageId: entry.value.messageId,
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

  /// Emits only through the exact connected Socket.IO session that authorized
  /// a session-scoped RPC.
  ///
  /// Socket IDs change on reconnect. Checking and emitting synchronously keeps
  /// an in-flight direct-provider relay from leaking data into a replacement
  /// account/server session.
  bool emitForSession(String expectedSessionId, String event, dynamic data) {
    final socket = _socket;
    if (expectedSessionId.isEmpty ||
        event.isEmpty ||
        socket == null ||
        socket.connected != true ||
        socket.id != expectedSessionId) {
      return false;
    }
    socket.emit(event, data);
    return true;
  }

  // Subscribe to an arbitrary socket.io event (used for dynamic tool channels)
  void onEvent(String eventName, void Function(dynamic data) handler) {
    _dynamicEventHandlers
        .putIfAbsent(eventName, () => <void Function(dynamic)>[])
        .add(handler);
    _socket?.on(eventName, handler);
  }

  void offEvent(String eventName) {
    final handlers = _dynamicEventHandlers.remove(eventName);
    if (handlers == null) {
      return;
    }
    final socket = _socket;
    if (socket == null) {
      return;
    }
    for (final handler in handlers) {
      socket.off(eventName, handler);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stopHeartbeat();
    _clearPendingResumeReconnect();
    try {
      final existing = _socket;
      if (existing != null) {
        _unbindCoreSocketHandlers(existing);
        _unbindDynamicSocketHandlers(existing);
        existing.dispose();
      }
    } catch (_) {}
    _socket = null;
    WidgetsBinding.instance.removeObserver(this);
    _chatEventHandlers.clear();
    _channelEventHandlers.clear();
    _dynamicEventHandlers.clear();
    _backgroundActivityLeases = 0;
    _backgroundLeaseHandlerIds.clear();
    _reconnectController.close();
    _healthController.close();
    _connectionCompleter?.completeError(StateError('Service disposed'));
    _connectionCompleter = null;
    final pendingForcedConnect = _pendingForcedConnect;
    _pendingForcedConnect = null;
    if (pendingForcedConnect != null && !pendingForcedConnect.isCompleted) {
      // Forced reconnects are best-effort lifecycle work. Complete queued
      // callers normally during teardown to avoid an unhandled async error.
      pendingForcedConnect.complete();
    }
    _isConnecting = false;
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

  void _bindDynamicSocketHandlers(io.Socket? socket) {
    if (socket == null) return;
    for (final entry in _dynamicEventHandlers.entries) {
      for (final handler in entry.value) {
        socket.on(entry.key, handler);
      }
    }
  }

  void _unbindDynamicSocketHandlers(io.Socket socket) {
    for (final entry in _dynamicEventHandlers.entries) {
      for (final handler in entry.value) {
        socket.off(entry.key, handler);
      }
    }
  }

  void _handleConnect(dynamic _) {
    _isConnecting = false;

    // Reset polling fallback on successful connection - allows retrying
    // WebSocket-only mode after conditions improve (fixes permanent fallback)
    _forcePollingFallback = false;

    // The handshake can report success after a lifecycle or reachability gate
    // retired it. Re-check policy before authenticating, completing waiters, or
    // publishing the resume-reconnect signal; none of those consumers may
    // observe a transport that is no longer allowed to remain active.
    if (!_mayMaintainTransport) {
      _applyTransportActivityPolicy();
      _connectionCompleter?.complete();
      _connectionCompleter = null;
      _deferOrClearPendingResumeReconnect();
      _emitHealthUpdate();
      _runPendingForcedConnectBestEffort(reason: 'late-connect-policy-gate');
      return;
    }

    // A force request queued during this handshake owns the next observable
    // session. Replace the transient socket before authenticating it,
    // completing waiters, or publishing reconciliation/health to consumers.
    if (_pendingForcedConnect != null) {
      _runPendingForcedConnectBestEffort(
        reason: 'connect-superseded-before-publish',
      );
      return;
    }

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

    // Start the required OpenWebUI heartbeat only while this transport has a
    // foreground or active-stream reason to stay alive.
    if (_mayMaintainTransport) {
      _startHeartbeat();
    } else {
      _applyTransportActivityPolicy();
    }

    // Complete any pending connection waiters
    _connectionCompleter?.complete();
    _connectionCompleter = null;

    // Emit health update
    _emitHealthUpdate();

    _publishPendingResumeReconciliation();
  }

  void _handleReconnectAttempt(dynamic attempt) {
    if (!_mayMaintainTransport) {
      _applyTransportActivityPolicy();
      return;
    }
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

    // Socket.IO can report a successful reconnect after the app moved to the
    // background or the network gate closed. Re-apply the current policy before
    // joining/authenticating or publishing a reconnect that consumers could
    // mistake for a usable transport.
    if (!_mayMaintainTransport) {
      _applyTransportActivityPolicy();
      _connectionCompleter?.complete();
      _connectionCompleter = null;
      _deferOrClearPendingResumeReconnect();
      _emitHealthUpdate();
      _runPendingForcedConnectBestEffort(reason: 'late-reconnect-policy-gate');
      return;
    }

    if (_pendingForcedConnect != null) {
      _runPendingForcedConnectBestEffort(
        reason: 'reconnect-superseded-before-publish',
      );
      return;
    }

    if (_authToken != null && _authToken!.isNotEmpty) {
      _socket?.emit('user-join', {
        'auth': {'token': _authToken},
      });
    }

    _startHeartbeat();

    // Complete any pending connection waiters
    _connectionCompleter?.complete();
    _connectionCompleter = null;

    // Notify listeners that a reconnection occurred so they can refresh state
    if (!_reconnectController.isClosed) {
      _reconnectController.add(null);
    }
    _clearPendingResumeReconnect();

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
      _runPendingForcedConnectBestEffort(
        forceEvenWithoutWaiter: true,
        reason: 'websocket-polling-fallback',
      );
      return;
    }
    _runPendingForcedConnectBestEffort(reason: 'connect-error');
  }

  void _handleReconnectFailed(dynamic _) {
    _isConnecting = false;
    _deferOrClearPendingResumeReconnect();
    DebugLogger.error(
      'Socket reconnection failed after all attempts',
      scope: 'socket/reconnect',
      data: {'serverUrl': serverConfig.url},
    );
    _runPendingForcedConnectBestEffort(reason: 'reconnect-failed');
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
    _runPendingForcedConnectBestEffort(reason: 'disconnected');
  }

  /// Starts the heartbeat timer to keep the connection alive.
  /// Sends a heartbeat event every 30 seconds matching OpenWebUI's behavior.
  void _startHeartbeat() {
    _stopHeartbeat();
    if (!_mayMaintainTransport || _socket?.connected != true) return;
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      if (!_mayMaintainTransport || _socket?.connected != true) return;

      // Upstream intentionally does not acknowledge this event. Keep latency
      // unknown rather than reporting a local delayed callback as network RTT.
      _socket?.emit('heartbeat', <String, dynamic>{});
      _lastHeartbeatLatencyMs = -1;
      _emitHealthUpdate();
    });
  }

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
    final chatId = _extractConversationId(map);
    final channelId = _extractChannelId(map);
    final messageId = _extractMessageId(map);

    for (final registration in List<_ChatEventRegistration>.from(
      _chatEventHandlers.values,
    )) {
      if (!_shouldDeliver(
        registration.conversationId,
        registration.sessionId,
        registration.messageId,
        chatId,
        sessionId,
        messageId,
        registration.requireFocus,
        incomingChannelId: channelId,
      )) {
        continue;
      }

      try {
        registration.handler(map, ackFn);
      } catch (_) {}
    }
    // Retain early events for any active pre-buffer scope even if another
    // handler already matched them. This allows passive listeners to coexist
    // with the later-attaching streaming helper without losing task bootstrap
    // events like `request:chat:completion`.
    final bufferScope = _findBufferScope(
      conversationId: chatId,
      sessionId: sessionId,
      messageId: messageId,
    );
    if (bufferScope != null) {
      bufferScope.events.add((Map<String, dynamic>.from(map), ackFn));
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
    final chatId = _extractConversationId(map);
    final channelId = _extractChannelId(map);

    for (final registration in List<_ChannelEventRegistration>.from(
      _channelEventHandlers.values,
    )) {
      if (!_shouldDeliver(
        registration.conversationId,
        registration.sessionId,
        null,
        chatId,
        sessionId,
        null,
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
    String? registeredMessageId,
    String? incomingConversationId,
    String? incomingSessionId,
    String? incomingMessageId,
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
    final matchesMessage =
        registeredMessageId != null &&
        incomingMessageId != null &&
        registeredMessageId == incomingMessageId;

    // Must match either conversation, session, or message to be considered.
    if (!matchesConversation && !matchesSession && !matchesMessage) {
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

    if (matchesMessage) {
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

  String? _extractMessageId(Map<String, dynamic> event) {
    String? candidate;

    if (event['message_id'] != null) {
      candidate = event['message_id'].toString();
    }
    if (candidate == null && event['messageId'] != null) {
      candidate = event['messageId'].toString();
    }

    final data = event['data'];
    if (data is Map) {
      if (candidate == null && data['message_id'] != null) {
        candidate = data['message_id'].toString();
      }
      if (candidate == null && data['messageId'] != null) {
        candidate = data['messageId'].toString();
      }
      final inner = data['data'];
      if (inner is Map) {
        if (candidate == null && inner['message_id'] != null) {
          candidate = inner['message_id'].toString();
        }
        if (candidate == null && inner['messageId'] != null) {
          candidate = inner['messageId'].toString();
        }
      }
    }

    return candidate;
  }

  String? _extractConversationId(Map<String, dynamic> event) {
    String? candidate;

    if (event['chat_id'] != null) {
      candidate = event['chat_id'].toString();
    }
    if (candidate == null && event['chatId'] != null) {
      candidate = event['chatId'].toString();
    }

    final data = event['data'];
    if (data is Map) {
      if (candidate == null && data['chat_id'] != null) {
        candidate = data['chat_id'].toString();
      }
      if (candidate == null && data['chatId'] != null) {
        candidate = data['chatId'].toString();
      }
      final inner = data['data'];
      if (inner is Map) {
        if (candidate == null && inner['chat_id'] != null) {
          candidate = inner['chat_id'].toString();
        }
        if (candidate == null && inner['chatId'] != null) {
          candidate = inner['chatId'].toString();
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

class SocketBackgroundActivityLease {
  SocketBackgroundActivityLease._(this._release);
  SocketBackgroundActivityLease.forTesting(this._release);

  final VoidCallback _release;
  bool _isReleased = false;

  void dispose() {
    if (_isReleased) return;
    _isReleased = true;
    _release();
  }
}

class _ChatEventRegistration {
  _ChatEventRegistration({
    required this.id,
    required this.handler,
    this.conversationId,
    this.sessionId,
    this.messageId,
    this.requireFocus = true,
  });

  final String id;
  final String? conversationId;
  final String? sessionId;
  final String? messageId;
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

final class _BufferedChatEventScope {
  final aliases = <String>{};
  final events = <(Map<String, dynamic>, void Function(dynamic)?)>[];
}
