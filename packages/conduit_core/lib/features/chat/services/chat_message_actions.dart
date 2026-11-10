/// Chat page message actions: deleting a message group, re-sending an
/// edited user message, and undoing a Hermes chat's last turn.
///
/// The page owns only the presentation (the confirmation dialog, the edit
/// field and the error toast); the transcript, conversation and server
/// mutations live here, where they are tested without Flutter.
library;

import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/services/chat_transport_dispatch.dart';
import 'package:conduit_core/features/chat/utils/file_utils.dart';
import 'package:conduit_core/features/chat/utils/message_targeting.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart'
    show hermesApiServiceProvider;
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_history_edit.dart';
import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart';
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

  /// The server rejected a delete. The transcript, active conversation and
  /// list entry were restored, except for messages the server had already
  /// deleted, which stay removed; the host should report an error.
  persistFailed,
}

/// Deletes every row of one grouped response (or one user message) from the
/// active chat, as the Flutter page's `_deleteMessageGroup` did after its
/// confirmation.
///
/// Ids are applied bottom-up so each removal only reparents rows already
/// visited. A removed streaming message has its transport stopped first. For
/// a server-backed chat each id is deleted on the server; a failure restores
/// the state captured before the delete, minus the ids the server confirmed,
/// so the transcript never shows a message the server no longer has.
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
  final deletedOnServer = <String>[];
  try {
    for (final id in orderedIds) {
      await api.deleteConversationMessage(updatedConversation.id, id);
      deletedOnServer.add(id);
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
    // Put back only what the server still has: replay the confirmed deletes
    // onto the transcript captured before this call.
    var restoredMessages = latestMessages;
    for (final id in deletedOnServer) {
      restoredMessages = message_tree.deleteOpenWebUiMessageFromChatMessages(
        restoredMessages,
        id,
      );
    }
    final restoredConversation = deletedOnServer.isEmpty
        ? activeConversation
        : inheritNativeHermesConversationProvenance(
            activeConversation,
            activeConversation.copyWith(messages: restoredMessages),
          );
    messagesNotifier.setMessages(restoredMessages);
    ref.read(activeConversationProvider.notifier).set(restoredConversation);
    ref
        .read(conversationsProvider.notifier)
        .updateConversation(
          restoredConversation.id,
          (_) => restoredConversation,
        );
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
  // One turn at a time in a LibreChat chat: refused before the transcript
  // changes, so nothing it shows goes and the edit can be sent once the
  // reply is done.
  final openChat = ref.read(activeConversationProvider) as Conversation?;
  if (isLibreChatConversation(openChat) &&
      isLibreChatReplyRunning(ref, openChat)) {
    throw const LibreChatReplyRunningException();
  }

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
      isLibreChatConversation(active)
          ? reattachLibreChatFiles(ref, original)
          : editedMessageAttachmentIds(original),
      toolIds: toolIds.isNotEmpty ? toolIds : null,
      onAssistantPlaceholderCreated: (handle) => pendingSend = handle,
    );
    return true;
  } catch (error) {
    recoverFailedChatSend(ref, error, pendingSend);
    rethrow;
  }
}

/// Sessions with an undo in flight: a second undo would read the same last
/// turn and drop another one on the server.
final Set<String> _hermesUndoing = <String>{};

/// Undoes the last turn of the active Hermes Desktop Gateway chat: its last
/// user message and everything after it leave the chat and the session's
/// stored transcript, so other Hermes apps see the same history.
///
/// A last turn that never reached the session leaves only the chat. One the
/// session holds but cannot be matched for certain, or one followed by turns
/// the chat does not show, is refused rather than dropping the wrong turn.
/// Returns false when there is nothing to undo here, or an undo of this
/// chat is already running.
Future<bool> undoLastHermesTurn(dynamic ref) async {
  final active = ref.read(activeConversationProvider) as Conversation?;
  final service = ref.read(hermesApiServiceProvider);
  final sessionId = active?.metadata['hermesSessionId'];
  if (!isNativeHermesConversation(active) ||
      service is! HermesDesktopApiService ||
      sessionId is! String) {
    return false;
  }
  if (!_hermesUndoing.add(sessionId)) return false;
  try {
    return await _undoLastHermesTurn(ref, active!, service, sessionId);
  } finally {
    _hermesUndoing.remove(sessionId);
  }
}

bool _sameUserTurns(List<ChatMessage> left, List<ChatMessage> right) {
  List<String> turns(List<ChatMessage> messages) => [
    for (final message in messages)
      if (message.role == 'user') message.id,
  ];
  final a = turns(left);
  final b = turns(right);
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

Future<bool> _undoLastHermesTurn(
  dynamic ref,
  Conversation active,
  HermesDesktopApiService service,
  String sessionId,
) async {
  final scopedId = conversationScopedId(active);
  List<ChatMessage> shown() =>
      ref.read(chatMessagesProvider) as List<ChatMessage>;
  final messages = List<ChatMessage>.of(shown());
  final lastUser = messages.lastIndexWhere(
    (message) => message.role == 'user',
  );
  if (lastUser < 0) return false;
  if (messages.any((message) => message.isStreaming)) {
    throw StateError('A reply is still running in this Hermes chat.');
  }

  final transcript = await service.getCurrentSessionMessages(sessionId);
  final userRows = <int>[
    for (var row = 0; row < transcript.length; row++)
      if (hermesTranscriptUserContent(transcript[row]) != null) row,
  ];
  final row = hermesTranscriptUserRowIndex(
    transcript: transcript,
    messages: messages,
    index: lastUser,
  );
  final ordinal = messages
      .take(lastUser)
      .where((message) => message.role == 'user')
      .length;
  final stored = row != null && userRows.isNotEmpty && row == userRows.last;
  if (!stored && (row != null || userRows.length > ordinal)) {
    throw StateError(
      'The last turn could not be found in the Hermes chat. Reopen the chat '
      'and try again.',
    );
  }
  // The legacy undo drops whatever turn is last: one sent from this chat
  // while the transcript was read would be dropped instead.
  if (!_sameUserTurns(shown(), messages)) {
    throw StateError('The Hermes chat changed. Try again.');
  }
  if (stored &&
      !await service.undoLastTurn(
        sessionId,
        rowId: hermesTranscriptRowId(transcript[row]),
      )) {
    // Hermes dropped nothing: the chat keeps the turn the session kept.
    throw StateError('Hermes did not undo the last turn.');
  }

  final current = ref.read(activeConversationProvider) as Conversation?;
  if (current == null || !conversationMatchesScopedId(current, scopedId)) {
    return true;
  }
  // Only the undone turn leaves: anything sent since stays.
  final undone = {for (final message in messages.skip(lastUser)) message.id};
  if (!shown().any((message) => undone.contains(message.id))) {
    // The chat was opened again meanwhile, and its messages may be read
    // from before the undo: it reads the transcript again instead.
    service.refreshShortenedTranscript(sessionId);
    return true;
  }
  final kept = List<ChatMessage>.unmodifiable([
    for (final message in shown())
      if (!undone.contains(message.id)) message,
  ]);
  (ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier)
      .setMessages(kept);
  final updated = inheritNativeHermesConversationProvenance(
    current,
    current.copyWith(messages: kept, updatedAt: DateTime.now()),
  );
  ref.read(activeConversationProvider.notifier).set(updated);
  return true;
}
