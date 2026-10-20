import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:conduit_core/utils/utf16_sanitizer.dart';

import '../models/terminal_models.dart';
import '../services/terminal_service.dart';
import 'terminal_controller_gateways.dart';
import 'terminal_screen.dart';

typedef TerminalContextValidator = bool Function(
  TerminalServerInfo server,
  String sessionScopeId,
);

/// Owns the interactive terminal session and its WebSocket lifecycle.
///
/// Selection and tab-visibility policy stay with the terminal tab; this
/// controller only connects the selected server, streams terminal I/O between
/// the socket and the [screen], and publishes the resulting connection state.
class TerminalSessionController {
  TerminalSessionController({
    required TerminalSessionGateway gateway,
    required TerminalContextValidator isCurrentContext,
    required this.screen,
  }) : _gateway = gateway,
       _isCurrentContext = isCurrentContext {
    screen
      ..onOutput = _handleTerminalOutput
      ..onResize = _sendResize;
  }

  final TerminalSessionGateway _gateway;
  final TerminalContextValidator _isCurrentContext;

  /// The emulator the session reads from and writes to.
  final TerminalScreen screen;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSubscription;
  Timer? _pingTimer;
  int _connectionGeneration = 0;
  String _disconnectedLabel = '';
  bool _disposed = false;

  Future<void> connect(
    TerminalService service,
    TerminalServerInfo server, {
    required String sessionScopeId,
    required String disconnectedLabel,
    required void Function() onFailure,
  }) async {
    if (_disposed ||
        _gateway.connectionState.isConnecting ||
        !_isCurrentContext(server, sessionScopeId)) {
      return;
    }

    final token = service.authTokenForServer(server);
    if (token == null || token.isEmpty) {
      _gateway.setConnectionState(const TerminalConnectionState.error());
      onFailure();
      return;
    }

    final connectionGeneration = ++_connectionGeneration;
    _gateway.setConnectionState(const TerminalConnectionState.connecting());

    try {
      final session = await service.createSession(
        server,
        sessionScopeId: sessionScopeId,
      );
      if (!_isCurrentConnection(server, sessionScopeId, connectionGeneration)) {
        return;
      }

      final channel = _gateway.openChannel(
        service.buildWebSocketUri(server, session.sessionId),
        kind: server.kind,
      );
      await channel.ready;

      if (!_isCurrentConnection(server, sessionScopeId, connectionGeneration)) {
        await channel.sink.close();
        return;
      }

      _disconnectedLabel = disconnectedLabel;
      _channel = channel;
      _channelSubscription = channel.stream.listen(
        _handleTerminalEvent,
        onDone: () => _handleTerminalDisconnect(
          connectionGeneration: connectionGeneration,
          showClosedBanner: true,
        ),
        onError: (_) => _handleTerminalDisconnect(
          connectionGeneration: connectionGeneration,
          showClosedBanner: false,
        ),
      );

      _gateway.setActiveSession(session);
      _gateway.setConnectionState(const TerminalConnectionState.connected());

      channel.sink.add(
        jsonEncode(
          buildTerminalWebSocketAuthPayload(
            server,
            token: token,
            sessionScopeId: sessionScopeId,
          ),
        ),
      );
      _sendResize(screen.columns, screen.rows);
      _pingTimer = Timer.periodic(
        const Duration(seconds: 25),
        (_) => _sendPingEvent(),
      );
    } catch (_) {
      if (!_isCurrentConnection(server, sessionScopeId, connectionGeneration)) {
        return;
      }
      _gateway.setActiveSession(null);
      _gateway.setConnectionState(const TerminalConnectionState.error());
      onFailure();
    }
  }

  Future<void> disconnect({
    required bool showClosedBanner,
    int? expectedConnectionGeneration,
  }) async {
    if (_disposed) {
      return;
    }
    if (expectedConnectionGeneration != null &&
        expectedConnectionGeneration != _connectionGeneration) {
      return;
    }

    final pingTimer = _pingTimer;
    final channelSubscription = _channelSubscription;
    final channel = _channel;
    final disconnectGeneration = ++_connectionGeneration;

    _pingTimer = null;
    _channelSubscription = null;
    _channel = null;

    pingTimer?.cancel();
    try {
      await channelSubscription?.cancel();
    } catch (_) {}
    try {
      await channel?.sink.close();
    } catch (_) {}
    if (_disposed || disconnectGeneration != _connectionGeneration) {
      return;
    }

    _gateway.setActiveSession(null);
    _gateway.setConnectionState(const TerminalConnectionState.disconnected());
    if (showClosedBanner) {
      screen.write('\r\n[$_disconnectedLabel]\r\n');
    }
  }

  void clear() => screen.clear();

  void dispose() {
    _disposed = true;
    _connectionGeneration++;
    _pingTimer?.cancel();
    _pingTimer = null;
    unawaited(_channelSubscription?.cancel() ?? Future<void>.value());
    unawaited(_channel?.sink.close() ?? Future<void>.value());
    _channelSubscription = null;
    _channel = null;
    screen
      ..onOutput = null
      ..onResize = null;
  }

  bool _isCurrentConnection(
    TerminalServerInfo server,
    String sessionScopeId,
    int connectionGeneration,
  ) {
    return connectionGeneration == _connectionGeneration &&
        _isCurrentContext(server, sessionScopeId);
  }

  void _handleTerminalEvent(dynamic event) {
    if (event is String) {
      screen.write(sanitizeUtf16(event));
      return;
    }
    if (event is List<int>) {
      screen.write(sanitizeUtf16(utf8.decode(event, allowMalformed: true)));
      return;
    }
    if (event is ByteBuffer) {
      screen.write(
        sanitizeUtf16(utf8.decode(event.asUint8List(), allowMalformed: true)),
      );
    }
  }

  void _handleTerminalDisconnect({
    required int connectionGeneration,
    required bool showClosedBanner,
  }) {
    if (_disposed || connectionGeneration != _connectionGeneration) {
      return;
    }
    unawaited(
      disconnect(
        showClosedBanner: showClosedBanner,
        expectedConnectionGeneration: connectionGeneration,
      ),
    );
  }

  void _handleTerminalOutput(String data) {
    _channel?.sink.add(utf8.encode(data));
  }

  void _sendResize(int columns, int rows) {
    _channel?.sink.add(
      jsonEncode(<String, dynamic>{
        'type': 'resize',
        'cols': columns,
        'rows': rows,
      }),
    );
  }

  void _sendPingEvent() {
    _channel?.sink.add(jsonEncode(const <String, dynamic>{'type': 'ping'}));
  }
}
