/// A Bot Mode bot's identity on the chat it opens: written into the
/// conversation's metadata when the roster opens the bot's chat, and read
/// back by the chat page to title the chat with the bot.
library;

import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/models/conversation.dart';

/// What the chat page shows for a bot chat.
typedef HermesBotChatPresentation = ({
  String title,
  String? avatar,
  String shape,
  String color,
  String? imageKind,
});

/// The conversation metadata that marks a chat as [bot]'s, with its avatar
/// data URL when it has one. Empty without a bot.
Map<String, Object> hermesBotChatMetadata({HermesBot? bot, String? avatar}) => {
  if (bot != null) kHermesBotTitleMetadataKey: bot.title,
  kHermesBotAvatarMetadataKey: ?avatar,
  if (bot != null) kHermesBotShapeMetadataKey: bot.avatarShape,
  if (bot != null) kHermesBotColorMetadataKey: bot.avatarColor,
  kHermesBotImageKindMetadataKey: ?bot?.avatarImageKind,
};

/// The bot [conversation] belongs to, or null for any other chat: only a
/// native Hermes conversation with a bot title is a bot chat, and only an
/// image data URL is taken as its avatar.
HermesBotChatPresentation? chatHermesBotPresentation(
  Conversation? conversation,
) {
  if (!isNativeHermesConversation(conversation)) return null;
  final title = conversation!.metadata[kHermesBotTitleMetadataKey];
  if (title is! String || title.trim().isEmpty) return null;
  final avatar = conversation.metadata[kHermesBotAvatarMetadataKey];
  final shape = conversation.metadata[kHermesBotShapeMetadataKey];
  final color = conversation.metadata[kHermesBotColorMetadataKey];
  final imageKind = conversation.metadata[kHermesBotImageKindMetadataKey];
  return (
    title: title.trim(),
    avatar: avatar is String && avatar.startsWith('data:image/')
        ? avatar
        : null,
    shape: shape is String ? shape : 'squircle',
    color: color is String ? color : '#8b5cf6',
    imageKind: imageKind is String ? imageKind : null,
  );
}
