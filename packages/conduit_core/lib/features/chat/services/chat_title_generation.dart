import 'package:conduit_core/utils/persisted_message_content.dart';

/// What Open WebUI's title task is asked for when the user generates a title
/// for a saved chat: its messages and the model to ask.
typedef ChatTitleRequest = ({String model, List<Map<String, dynamic>> messages});

/// The title request for [chat], a chat as `GET /api/v1/chats/{id}` returns
/// it, or null when it holds no messages or names no model.
///
/// Mirrors the Generate button of Open WebUI 0.13's chat list and chat title
/// (`generateTitleHandler` in `ChatItem.svelte`): the messages are the
/// chat's current branch, each as the text of its output when it has any and
/// its content otherwise, falling back to the flat `messages` list of a chat
/// stored before the history tree. The model is [selectedModelId], the model
/// picked in the open chat, then the newest answer's model on that branch,
/// then the chat's first model, each only when [isServerModel] accepts it: a
/// turn answered by a Direct or Hermes model records an id the server does
/// not have, and asking for it would always fail.
ChatTitleRequest? chatTitleRequest(
  Map<String, dynamic> chat, {
  String? selectedModelId,
  bool Function(String modelId)? isServerModel,
}) {
  bool usable(Object? id) =>
      id is String && id.isNotEmpty && (isServerModel?.call(id) ?? true);

  final content = chat['chat'];
  if (content is! Map) return null;

  final branch = <Map<dynamic, dynamic>>[];
  final history = content['history'];
  final historyMessages = history is Map ? history['messages'] : null;
  final currentId = history is Map ? history['currentId'] : null;
  if (historyMessages is Map && currentId != null) {
    final seen = <Object?>{};
    Object? id = currentId;
    while (id != null && seen.add(id)) {
      final message = historyMessages[id];
      if (message is! Map) break;
      branch.add(message);
      id = message['parentId'];
    }
    branch.setAll(0, branch.reversed.toList());
  }
  // A history whose current message cannot be found reads the flat list,
  // as the chat's own parsing does.
  if (branch.isEmpty && content['messages'] is List) {
    for (final message in content['messages'] as List) {
      if (message is Map) branch.add(message);
    }
  }

  final messages = <Map<String, dynamic>>[
    for (final message in branch)
      if (message['role'] is String)
        {'role': message['role'], 'content': _messageText(message)},
  ];
  if (messages.isEmpty) return null;

  final selected = selectedModelId?.trim();
  String? model = usable(selected) ? selected : null;
  if (model == null) {
    for (final message in branch.reversed) {
      final answerModel = message['model'];
      if (message['role'] == 'assistant' && usable(answerModel)) {
        model = answerModel as String;
        break;
      }
    }
  }
  if (model == null) {
    final models = content['models'];
    if (models is List) {
      for (final candidate in models) {
        if (usable(candidate)) {
          model = candidate as String;
          break;
        }
      }
    }
  }
  if (model == null) return null;
  return (model: model, messages: messages);
}

String _messageText(Map<dynamic, dynamic> message) {
  final output = message['output'];
  if (output is List) {
    final text = outputItemsMessageText(output);
    if (text.isNotEmpty) return text;
  }
  final content = message['content'];
  if (content is String) return content;
  // A turn saved with images keeps its content as parts; its text parts are
  // what the chat reader shows.
  if (content is List) {
    final text = StringBuffer();
    for (final part in content) {
      if (part is Map && part['type'] == 'text' && part['text'] is String) {
        text.write(part['text']);
      }
    }
    return text.toString();
  }
  return '';
}
