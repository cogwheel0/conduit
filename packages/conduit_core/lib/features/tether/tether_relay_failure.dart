/// How a request Open WebUI relayed to one of the user's devices through
/// Tether failed, read from the server's own words (Open WebUI 0.13.4,
/// `utils/tether.py`).
///
/// Read once, where the failure arrives, and kept with the message's error
/// (`ChatMessageError.relay`): what shows the error reads that field.
library;

import 'dart:convert';

import 'package:conduit_core/models/chat_message.dart' show TetherRelayFailure;

export 'package:conduit_core/models/chat_message.dart' show TetherRelayFailure;

/// What Open WebUI 0.13.4's completion router reports for any failure before
/// the model's answer began, a relay's included: the relay's own words never
/// reach the client then (`routers/openai.py`, `generate_chat_completion`).
const String _serverConnectionError = 'Open WebUI: Server Connection Error';

/// The relay failure [error] reports, or null when it is not one.
///
/// [error] is a message, or a body such as a tool's result or a terminal's
/// 502 (`{"error": ..., "code": "tether_interrupted"}`).
///
/// [viaTether] says the request went to one of the user's devices, as the
/// request recorded when it was sent. The server's generic connection error
/// then stands for a relay that failed before the device answered. Whether
/// the device ran it cannot be told from that, so it reads as
/// [TetherRelayFailure.interrupted].
TetherRelayFailure? tetherRelayFailureOf(
  Object? error, {
  bool viaTether = false,
}) {
  if (error is Map) {
    if (error['code'] == 'tether_interrupted') {
      return TetherRelayFailure.interrupted;
    }
    for (final key in const ['error', 'detail', 'message']) {
      final failure = tetherRelayFailureOf(error[key], viaTether: viaTether);
      if (failure != null) return failure;
    }
    return null;
  }
  if (error is! String) return null;
  final trimmed = error.trim();
  if (trimmed.startsWith('{')) {
    try {
      final body = jsonDecode(trimmed);
      if (body is Map) return tetherRelayFailureOf(body, viaTether: viaTether);
    } on FormatException {
      // Words that start with a brace.
    }
  }
  if (viaTether && trimmed == _serverConnectionError) {
    return TetherRelayFailure.interrupted;
  }
  return _relayFailureInWords(trimmed);
}

/// The status Starlette puts before an `HTTPException`'s detail when the
/// exception is written as text ("503: Tether is offline.").
final RegExp _statusPrefix = RegExp(r'^\d{3}: ');

/// The relay failure [words] are, in Open WebUI 0.13.4's own words for it
/// (`utils/tether.py`), or null. Those are the whole message: as the server
/// sends them, after the status a written `HTTPException` starts with, or
/// after a terminal proxy's "Terminal proxy error: " (`routers/terminals.py`).
/// Words that only quote them, such as another model's error, are not one.
TetherRelayFailure? _relayFailureInWords(String words) {
  var text = words.toLowerCase();
  const proxied = 'terminal proxy error: ';
  if (text.startsWith(proxied)) text = text.substring(proxied.length);
  text = text.replaceFirst(_statusPrefix, '');
  // RelayInterrupted: "Tether connection interrupted: <reason>. The
  // operation may have completed. ..."
  if (text.startsWith('tether connection interrupted:')) {
    return TetherRelayFailure.interrupted;
  }
  if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  return switch (text) {
    'tether has too many active operations' => TetherRelayFailure.busy,
    'tether service is unavailable' ||
    'tether is offline' => TetherRelayFailure.unavailable,
    _ => null,
  };
}
