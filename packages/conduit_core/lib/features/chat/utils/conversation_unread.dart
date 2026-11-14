import 'package:conduit_core/models/conversation.dart';

/// Whether [conversation] shows as unread in a chat list: something arrived
/// since the account last read it (its `updatedAt` is after `lastReadAt`), or
/// it was never read. Never while it is [selected] (open on screen) or
/// [generating] (its answer is still being written), and never for a chat
/// without an id.
bool isConversationUnread(
  Conversation conversation, {
  bool selected = false,
  bool generating = false,
}) {
  if (conversation.id.isEmpty || selected || generating) return false;
  final lastReadAt = conversation.lastReadAt;
  if (lastReadAt == null) return true;
  return conversation.updatedAt.isAfter(lastReadAt);
}
