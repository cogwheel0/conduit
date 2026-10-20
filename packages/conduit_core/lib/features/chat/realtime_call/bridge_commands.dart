/// The commands a realtime call sends over a bridge.
///
/// Open WebUI's bridge accepts exactly these shapes: a command with any other
/// key, `event_id` included, ends the call. Direct calls translate the same
/// commands on the device (see `RealtimeCallProtocol`), so both share one
/// engine.
library;

/// How a delegated chat turn ended, as reported to the voice.
enum BridgeTurnStatus { completed, failed, cancelled, deferred }

/// What the voice says about a delegated turn while it is still open.
enum BridgeCallStatus { working, approval, deferred }

/// How a requested avatar gesture went. Conduit renders no avatar, so it only
/// ever answers [unavailable] or [cancelled].
enum BridgeAnimationStatus { started, busy, unavailable, cancelled }

abstract final class BridgeCommands {
  static const ping = <String, Object?>{'type': 'bridge.ping'};

  static const clearInput = <String, Object?>{
    'type': 'input_audio_buffer.clear',
  };

  /// [audio] is base64 PCM16 at 24 kHz, at most one second.
  static Map<String, Object?> appendAudio(String audio) => {
    'type': 'input_audio_buffer.append',
    'audio': audio,
  };

  static Map<String, Object?> cancelResponse(String responseId) => {
    'type': 'response.cancel',
    'response_id': responseId,
  };

  /// Tells the voice how much of an item the user heard before speaking over
  /// it, so its memory of the conversation matches what was said.
  static Map<String, Object?> truncate({
    required String itemId,
    required int contentIndex,
    required int audioEndMs,
  }) => {
    'type': 'conversation.item.truncate',
    'item_id': itemId,
    'content_index': contentIndex,
    'audio_end_ms': audioEndMs,
  };

  /// Replaces the chat snapshot the voice answers from.
  static Map<String, Object?> context(List<Map<String, String>> messages) => {
    'type': 'bridge.context',
    'messages': messages,
  };

  /// Asks the voice to answer a transcribed input.
  static Map<String, Object?> respondToInput(String itemId) => {
    'type': 'bridge.respond',
    'item_id': itemId,
  };

  /// Hands the voice a delegated turn's outcome.
  static Map<String, Object?> result({
    required String callId,
    required BridgeTurnStatus status,
    required String answer,
  }) => {
    'type': 'bridge.result',
    'call_id': callId,
    'status': status.name,
    'answer': answer,
  };

  /// Asks the voice to speak a result it was handed.
  static Map<String, Object?> respondToResult(String callId) => {
    'type': 'bridge.respond',
    'call_id': callId,
  };

  static Map<String, Object?> status(BridgeCallStatus status) => {
    'type': 'bridge.status',
    'status': status.name,
  };

  static Map<String, Object?> animationResult({
    required String callId,
    required BridgeAnimationStatus status,
  }) => {
    'type': 'bridge.animation.result',
    'call_id': callId,
    'status': status.name,
  };

  static Map<String, Object?> animationRespond(String responseId) => {
    'type': 'bridge.animation.respond',
    'response_id': responseId,
  };
}
