import 'package:conduit_core/models/channel_message.dart';

/// Regex matching OpenWebUI mention tags:
/// `<@M:model_id|Label>` or `<@U:user_id|Name>`.
final mentionRegex = RegExp(r'<@[A-Z]:([^|>]+)\|([^>]+)>');

/// Strips OpenWebUI mention markup, keeping only the
/// display label prefixed with @.
String stripMentions(String content) =>
    content.replaceAllMapped(mentionRegex, (m) => '@${m.group(2)}');

/// Whether [message] was sent by a model (has model_id
/// in meta).
bool isModelMessage(ChannelMessage message) =>
    message.meta?['model_id'] != null;

/// Display name for the message: model name if it's a
/// model response, otherwise the user name.
String messageDisplayName(ChannelMessage message) {
  if (isModelMessage(message)) {
    return message.meta!['model_name'] as String? ??
        message.meta!['model_id'] as String? ??
        'Model';
  }
  return message.userName;
}

/// Who is speaking in [message], for grouping a run of messages under one
/// name: a model by its `meta.model_id`, an app (which has no user id) by
/// the id in its user object, anyone else by their user id.
String? channelMessageSender(ChannelMessage message) {
  if (isModelMessage(message)) {
    return message.meta?['model_id'] as String?;
  }
  return message.userId ?? message.user?.id;
}
