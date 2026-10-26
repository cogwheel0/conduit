import 'package:meta/meta.dart';

/// The event an Open WebUI function sends to carry the user on in a new chat
/// with another model: `{type: 'chat:handoff', data: {model_id, prompt}}`.
///
/// Open WebUI forwards any event type from `__event_call__` and
/// `__event_emitter__` unchanged, so no server support is needed.
/// `docs/open-webui-functions.md` documents it for function authors.
const String chatHandoffEventType = 'chat:handoff';

/// How Conduit names itself in its reply to an `execute` call, so a function
/// can tell it from a browser and use [conduitEventCapabilities] instead.
const String conduitClientName = 'conduit';

/// The event types Conduit acts on in place of client-side JavaScript.
const List<String> conduitEventCapabilities = <String>[chatHandoffEventType];

/// Why Conduit did not carry on in a new chat, sent as the reply's `reason`.
enum ChatHandoffRefusal {
  /// `model_id` is missing, empty or not a string, or `prompt` is not a
  /// string.
  invalid('invalid'),

  /// The event is for a chat other than the one open in Conduit.
  notActiveChat('not_active_chat'),

  /// The same handoff already arrived.
  duplicate('duplicate'),

  /// The user is still answering another handoff.
  busy('busy'),

  /// None of the user's Open WebUI models has that id.
  modelUnavailable('model_unavailable'),

  /// The user chose to stay in the chat.
  declined('declined'),

  /// This Conduit has nobody to ask.
  unsupported('unsupported'),

  /// Carrying on failed unexpectedly.
  failed('failed');

  const ChatHandoffRefusal(this.reason);

  final String reason;

  Map<String, dynamic> get reply => <String, dynamic>{
    'handled': false,
    'reason': reason,
  };
}

/// The reply once the user agreed and the new chat is open.
const Map<String, dynamic> chatHandoffHandledReply = <String, dynamic>{
  'handled': true,
};

/// What a [chatHandoffEventType] event asks for.
@immutable
class ChatHandoffRequest {
  const ChatHandoffRequest({required this.modelId, this.prompt = ''});

  final String modelId;

  /// Goes into the new chat's composer, unsent; empty for none.
  final String prompt;

  /// Reads the event's `data`, or returns null when it is not a handoff
  /// Conduit can act on. Anything else in it, `files` included, is ignored.
  static ChatHandoffRequest? tryParse(Object? data) {
    if (data is! Map) return null;
    final modelId = data['model_id'];
    final prompt = data['prompt'] ?? '';
    if (modelId is! String || modelId.isEmpty || prompt is! String) {
      return null;
    }
    return ChatHandoffRequest(modelId: modelId, prompt: prompt);
  }
}
