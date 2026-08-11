import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

import '../../../shared/utils/utf16_sanitizer.dart';
import '../models/terminal_models.dart';
import '../providers/terminal_providers.dart';
import '../services/terminal_service.dart';

typedef TerminalContextValidator =
    bool Function(TerminalServerInfo server, String sessionScopeId);

/// Owns the interactive terminal session and its WebSocket lifecycle.
///
/// Selection and tab-visibility policy stay with [TerminalTab]; this controller
/// only connects the selected server, streams terminal I/O, and publishes the
/// resulting connection state.
class TerminalSessionController {
  TerminalSessionController({
    required WidgetRef ref,
    required TerminalContextValidator isCurrentContext,
  }) : _ref = ref,
       _isCurrentContext = isCurrentContext {
    terminal.onOutput = _handleTerminalOutput;
    terminal.onResize = _handleTerminalResize;
  }

  final WidgetRef _ref;
  final TerminalContextValidator _isCurrentContext;

  final Terminal terminal = Terminal(maxLines: 5000);
  final TerminalController terminalController = TerminalController();

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
        _ref.read(terminalConnectionStateProvider).isConnecting ||
        !_isCurrentContext(server, sessionScopeId)) {
      return;
    }

    final token = service.authTokenForServer(server);
    if (token == null || token.isEmpty) {
      _ref
          .read(terminalConnectionStateProvider.notifier)
          .set(const TerminalConnectionState.error());
      onFailure();
      return;
    }

    final connectionGeneration = ++_connectionGeneration;
    _ref
        .read(terminalConnectionStateProvider.notifier)
        .set(const TerminalConnectionState.connecting());

    try {
      final session = await service.createSession(
        server,
        sessionScopeId: sessionScopeId,
      );
      if (!_isCurrentConnection(server, sessionScopeId, connectionGeneration)) {
        return;
      }

      final channel = _ref.read(terminalChannelConnectorProvider)(
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

      _ref.read(terminalActiveSessionProvider.notifier).set(session);
      _ref
          .read(terminalConnectionStateProvider.notifier)
          .set(const TerminalConnectionState.connected());

      channel.sink.add(
        jsonEncode(<String, dynamic>{'type': 'auth', 'token': token}),
      );
      _sendResizeEvent();
      _pingTimer = Timer.periodic(
        const Duration(seconds: 25),
        (_) => _sendPingEvent(),
      );
    } catch (_) {
      if (!_isCurrentConnection(server, sessionScopeId, connectionGeneration)) {
        return;
      }
      _ref.read(terminalActiveSessionProvider.notifier).clear();
      _ref
          .read(terminalConnectionStateProvider.notifier)
          .set(const TerminalConnectionState.error());
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

    _ref.read(terminalActiveSessionProvider.notifier).clear();
    _ref
        .read(terminalConnectionStateProvider.notifier)
        .set(const TerminalConnectionState.disconnected());
    if (showClosedBanner) {
      terminal.write('\r\n[$_disconnectedLabel]\r\n');
    }
  }

  void clear() {
    terminal.buffer.clear();
    terminal.buffer.setCursor(0, 0);
  }

  void dispose() {
    _disposed = true;
    _connectionGeneration++;
    _pingTimer?.cancel();
    _pingTimer = null;
    unawaited(_channelSubscription?.cancel() ?? Future<void>.value());
    unawaited(_channel?.sink.close() ?? Future<void>.value());
    _channelSubscription = null;
    _channel = null;
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
      terminal.write(sanitizeUtf16(event));
      return;
    }
    if (event is List<int>) {
      terminal.write(sanitizeUtf16(utf8.decode(event, allowMalformed: true)));
      return;
    }
    if (event is ByteBuffer) {
      terminal.write(
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

  void _handleTerminalResize(
    int width,
    int height,
    int pixelWidth,
    int pixelHeight,
  ) {
    _sendResizeEvent();
  }

  void _sendResizeEvent() {
    _channel?.sink.add(
      jsonEncode(<String, dynamic>{
        'type': 'resize',
        'cols': terminal.viewWidth,
        'rows': terminal.viewHeight,
      }),
    );
  }

  void _sendPingEvent() {
    _channel?.sink.add(jsonEncode(const <String, dynamic>{'type': 'ping'}));
  }
}
