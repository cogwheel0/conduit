/// Chat page message actions: deleting a message group and re-sending an
/// edited user message.
///
/// The page owns only the presentation (the confirmation dialog, the edit
/// field and the error toast); the transcript, conversation and server
/// mutations live here, where they are tested without Flutter.
library;

import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/services/chat_transport_dispatch.dart';
import 'package:conduit_core/features/chat/utils/file_utils.dart';
import 'package:conduit_core/features/chat/utils/message_targeting.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/utils/message_tree_utils.dart' as message_tree;

/// Every message id that deleting [messageIds] from [messages] removes
/// (Open WebUI deletes a message with its direct children and reparents the
/// grandchildren). Hosts show its length in the confirmation prompt.
Set<String> chatMessageIdsRemovedByDelete(
  List<ChatMessage> messages,
  List<String> messageIds,
) => <String>{
  for (final id in messageIds)
    ...message_tree.openWebUiDeletedMessageIds(messages, id),
};

/// How a [deleteChatMessageGroup] call ended.
enum ChatMessageDeleteOutcome {
  /// Nothing matched the ids; no state changed.
  nothingToDelete,

  /// Removed locally, and on the server when the chat is server-backed.
  deleted,

  /// The server rejected the delete. The transcript, active conversation and
  /// list entry were restored; the host should report an error.
  persistFailed,
}

/// Deletes every row of one grouped response (or one user message) from the
/// active chat, as the Flutter page's `_deleteMessageGroup` did after its
/// confirmation.
///
/// Ids are applied bottom-up so each removal only reparents rows already
/// visited. A removed streaming message has its transport stopped first. For
/// a server-backed chat each id is deleted on the server; a failure restores
/// the state captured before the delete.
///
/// [isStillCurrent] is checked after the server round trip, before a failure
/// is rolled back (the Flutter page passes its `mounted`).
Future<ChatMessageDeleteOutcome> deleteChatMessageGroup(
  dynamic ref,
  List<String> messageIds, {
  bool Function()? isStillCurrent,
}) async {
  if (messageIds.isEmpty) return ChatMessageDeleteOutcome.nothingToDelete;
  final latestMessages = List<ChatMessage>.from(
    ref.read(chatMessagesProvider) as List<ChatMessage>,
    growable: false,
  );
  final orderedIds = messageIds.reversed.toList(growable: false);
  final removedIds = <String>{};
  var updatedMessages = latestMessages;
  for (final id in orderedIds) {
    removedIds.addAll(
      message_tree.openWebUiDeletedMessageIds(updatedMessages, id),
    );
    updatedMessages = message_tree.deleteOpenWebUiMessageFromChatMessages(
      updatedMessages,
      id,
    );
  }
  if (removedIds.isEmpty) return ChatMessageDeleteOutcome.nothingToDelete;

  final removedStreamingMessage = latestMessages
      .where((candidate) => removedIds.contains(candidate.id))
      .where((candidate) => candidate.isStreaming)
      .firstOrNull;
  final messagesNotifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  if (removedStreamingMessage != null) {
    stopActiveTransport(removedStreamingMessage, ref.read(apiServiceProvider));
    messagesNotifier.cancelActiveMessageStream();
  }
  messagesNotifier.setMessages(updatedMessages);

  final activeConversation =
      ref.read(activeConversationProvider) as Conversation?;
  if (activeConversation == null) return ChatMessageDeleteOutcome.deleted;

  final updatedConversation = inheritNativeHermesConversationProvenance(
    activeConversation,
    activeConversation.copyWith(
      messages: updatedMessages,
      updatedAt: DateTime.now(),
    ),
  );
  ref.read(activeConversationProvider.notifier).set(updatedConversation);
  ref
      .read(conversationsProvider.notifier)
      .updateConversation(updatedConversation.id, (_) => updatedConversation);

  final api = ref.read(apiServiceProvider);
  if (api == null || isTemporaryChat(updatedConversation.id)) {
    return ChatMessageDeleteOutcome.deleted;
  }
  try {
    for (final id in orderedIds) {
      await api.deleteConversationMessage(updatedConversation.id, id);
    }
    ref
        .read(conversationsProvider.notifier)
        .trustConversation(updatedConversation.id);
    return ChatMessageDeleteOutcome.deleted;
  } catch (error, stackTrace) {
    DebugLogger.error(
      'delete-message-persist-failed',
      scope: 'chat/actions',
      error: error,
      stackTrace: stackTrace,
    );
    if (isStillCurrent != null && !isStillCurrent()) {
      return ChatMessageDeleteOutcome.persistFailed;
    }
    messagesNotifier.setMessages(latestMessages);
    ref.read(activeConversationProvider.notifier).set(activeConversation);
    ref
        .read(conversationsProvider.notifier)
        .updateConversation(activeConversation.id, (_) => activeConversation);
    return ChatMessageDeleteOutcome.persistFailed;
  }
}

final RegExp _fileIdPattern = RegExp(r'/api/v1/files/([^/]+)(?:/content)?$');

/// The uploaded-file ids an edited [message] re-sends with its new text.
///
/// Prefers `attachmentIds`; otherwise reads the `files` array, skipping note
/// attachments (a note id is not a file id) and Hermes local descriptors
/// (historical references, not uploads), and taking a file's id from its
/// `id` or its `/api/v1/files/{id}` URL.
List<String>? editedMessageAttachmentIds(ChatMessage message) {
  final attachmentIds = message.attachmentIds;
  if (attachmentIds != null && attachmentIds.isNotEmpty) {
    final ids = attachmentIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (ids.isNotEmpty) return ids;
  }

  final files = message.files;
  if (files == null || files.isEmpty) return null;

  final ids = <String>[];
  final seen = <String>{};
  void addId(String? value) {
    final id = value?.trim();
    if (id == null || id.isEmpty || !seen.add(id)) return;
    ids.add(id);
  }

  for (final file in files) {
    if (file['type'] == 'note') continue;
    if (file['source'] == 'hermes_local') continue;
    final explicitId = file['id']?.toString();
    if (explicitId != null && explicitId.trim().isNotEmpty) {
      addId(explicitId);
      continue;
    }
    final fileUrl = getFileUrl(file);
    if (fileUrl == null) continue;
    addId(_fileIdPattern.firstMatch(fileUrl)?.group(1) ?? fileUrl);
  }
  return ids.isEmpty ? null : ids;
}

/// Re-sends the user message [messageId] with [newText] as a new turn, as
/// the Flutter bubble's inline edit did: a native Hermes chat replays through
/// Hermes; any other chat drops the message and everything after it, then
/// sends the edited text (with the message's uploads and the selected tools)
/// through [durableSend].
///
/// Returns false when there is nothing to do (blank or unchanged text, or
/// the message is gone). A failed send recovers its optimistic assistant and
/// rethrows, so the host can report it.
Future<bool> resendEditedUserMessage(
  dynamic ref, {
  required String messageId,
  required String newText,
}) async {
  final text = newText.trim();
  final messages = ref.read(chatMessagesProvider) as List<ChatMessage>;
  final index = indexOfMessageId(messages, messageId);
  if (index < 0 || text.isEmpty || text == messages[index].content) {
    return false;
  }
  final original = messages[index];

  ChatSendPlaceholderHandle? pendingSend;
  try {
    final active = ref.read(activeConversationProvider) as Conversation?;
    if (isNativeHermesConversation(active)) {
      await regenerateEditedHermesUserMessage(
        ref,
        messageId: messageId,
        content: text,
      );
      return true;
    }
    final keep = truncateMessagesAfterId(
      messages,
      messageId,
      includeTarget: false,
    );
    (ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier)
        .setMessages(keep);
    final toolIds = ref.read(selectedToolIdsProvider) as List<String>;
    await durableSend(
      ref,
      text,
      editedMessageAttachmentIds(original),
      toolIds: toolIds.isNotEmpty ? toolIds : null,
      onAssistantPlaceholderCreated: (handle) => pendingSend = handle,
    );
    return true;
  } catch (error) {
    recoverFailedChatSend(ref, error, pendingSend);
    rethrow;
  }
}
