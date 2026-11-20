/// How a request Open WebUI relayed to one of the user's devices through
/// Tether failed, read from the server's own words (Open WebUI 0.13.4,
/// `utils/tether.py`).
library;

import 'dart:convert';

import 'package:conduit_core/models/chat_message.dart';

/// Set on an assistant message whose turn went to a model one of the user's
/// devices offers (`isTetherModel`).
const String kTetherTurnMetadataKey = 'tetherTurn';

/// What Open WebUI 0.13.4's completion router reports for any failure before
/// the model's answer began, a relay's included: the relay's own words never
/// reach the client then (`routers/openai.py`, `generate_chat_completion`).
const String _serverConnectionError = 'Open WebUI: Server Connection Error';

enum TetherRelayFailure {
  /// The relay broke after the request went out (`tether_interrupted`): the
  /// operation may have completed, so it must not be repeated blindly.
  interrupted,

  /// The device is offline, or no longer offers the connection (503).
  unavailable,

  /// The device is running as many relayed operations as it allows (429).
  busy,
}

/// The relay failure [error] reports, or null when it is not one.
///
/// [error] is a message, or a body such as a tool's result or a terminal's
/// 502 (`{"error": ..., "code": "tether_interrupted"}`).
///
/// [viaTether] says the request went to one of the user's devices. The
/// server's generic connection error then stands for a relay that failed
/// before the device answered. Whether the device ran it cannot be told from
/// that, so it reads as [TetherRelayFailure.interrupted].
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
  final text = trimmed.toLowerCase();
  if (text.contains('tether connection interrupted')) {
    return TetherRelayFailure.interrupted;
  }
  if (text.contains('tether has too many active operations')) {
    return TetherRelayFailure.busy;
  }
  if (text.contains('tether service is unavailable') ||
      text.contains('tether is offline')) {
    return TetherRelayFailure.unavailable;
  }
  return null;
}

/// The relay failure [answer]'s error reports, knowing whether its turn went
/// to one of the user's devices ([kTetherTurnMetadataKey]).
TetherRelayFailure? tetherRelayFailureOfAnswer(ChatMessage answer) =>
    tetherRelayFailureOf(
      answer.error?.content,
      viaTether: answer.metadata?[kTetherTurnMetadataKey] == true,
    );
