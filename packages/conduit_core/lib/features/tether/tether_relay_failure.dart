/// How a request Open WebUI relayed to one of the user's devices through
/// Tether failed, read from the server's own words (Open WebUI 0.13.4,
/// `utils/tether.py`).
library;

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
TetherRelayFailure? tetherRelayFailureOf(Object? error) {
  if (error is Map) {
    if (error['code'] == 'tether_interrupted') {
      return TetherRelayFailure.interrupted;
    }
    for (final key in const ['error', 'detail', 'message']) {
      final failure = tetherRelayFailureOf(error[key]);
      if (failure != null) return failure;
    }
    return null;
  }
  if (error is! String) return null;
  final text = error.toLowerCase();
  if (text.contains('tether_interrupted') ||
      text.contains('tether connection interrupted')) {
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
