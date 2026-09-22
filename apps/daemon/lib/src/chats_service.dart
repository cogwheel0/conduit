import 'dart:async';

import 'package:conduit_core/models/chat_message.dart' as core;
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

/// Implements `chats.*` over the core's conversation providers (M3).
///
/// Reads `conversationsProvider` rather than the DAO directly. That provider
/// is what merges the Open WebUI chats with the direct-local ones, applies
/// the archived/pinned ordering and owns the paging cursor -- reimplementing
/// any of that here would give the desktop a list that disagrees with the
/// mobile app's for the same account.
final class ChatsService {
  ChatsService(this._container);

  final ProviderContainer _container;

  Conversations get _conversations =>
      _container.read(conversationsProvider.notifier);

  /// The conversation list, after making sure it reflects the server.
  ///
  /// `conversationsProvider` projects the *local database*, which only holds
  /// what the sync engine has pulled. On mobile the pull is driven by
  /// `syncTriggers`, which watches app lifecycle and connectivity; the
  /// sidecar has neither, so it asks directly.
  ///
  /// Once per call rather than on a timer: the renderer reads this when a
  /// window opens, when the session changes and when the daemon says
  /// `chats.changed`, which is exactly when a refresh is worth its round
  /// trip.
  Future<ChatList> list() async {
    await _pull('chats.list');
    final conversations = await _container.read(conversationsProvider.future);
    return _project(conversations);
  }

  /// Asks the sync engine to catch up, and tolerates it declining.
  ///
  /// `requestPull` returns null when the engine is inert -- no database, no
  /// server, reviewer mode -- and that is a legitimate state, not an error:
  /// the local list is then simply what there is.
  Future<void> _pull(String reason) async {
    try {
      await _container
          .read(syncEngineProvider.notifier)
          .requestPull(reason: reason);
    } on Object catch (error) {
      DebugLogger.error('pull-failed', scope: 'daemon/chats', error: error);
    }
  }

  Future<ChatList> loadMore() async {
    await _conversations.loadMore();
    return list();
  }

  /// One conversation with its transcript.
  ///
  /// Returns null rather than throwing for an unknown id: a window restored
  /// onto a chat that has since been deleted elsewhere is an ordinary thing,
  /// not an error worth a banner.
  Future<ChatDetail?> get(String id) async {
    final conversations = await _container.read(conversationsProvider.future);
    final conversation = conversations
        .where((candidate) => candidate.id == id)
        .firstOrNull;
    if (conversation == null) return null;

    return ChatDetail(
      summary: _summarize(conversation),
      messages: conversation.messages.map(_message).toList(growable: false),
    );
  }

  Future<ChatSearchResults> search(ChatSearchQuery query) async {
    final trimmed = query.query.trim();
    // An empty query is not a search for everything. Returning the whole
    // history here would look like a working search and be one of the
    // slowest things the app can do.
    if (trimmed.isEmpty) return const ChatSearchResults();

    final conversations = await _container.read(conversationsProvider.future);
    final lowered = trimmed.toLowerCase();
    final hits = <ChatSearchHit>[];
    for (final conversation in conversations) {
      if (hits.length >= query.limit) break;
      if (!conversation.title.toLowerCase().contains(lowered)) continue;
      hits.add(
        ChatSearchHit(
          chatId: conversation.id,
          title: conversation.title,
          updatedAtMs: conversation.updatedAt.millisecondsSinceEpoch,
        ),
      );
    }
    return ChatSearchResults(hits: hits);
  }

  // -----------------------------------------------------------------------
  // Mutations
  // -----------------------------------------------------------------------
  //
  // Each writes to the server and then republishes the conversation list,
  // because `conversationsProvider` is a projection of the local database
  // and the server write does not touch it. Without the refresh the sidebar
  // keeps showing the old title until something else happens to invalidate
  // it, which reads as the rename having failed.

  Future<ChatList> rename(String id, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a chat title must not be empty',
      );
    }
    await _api.updateConversation(id, title: trimmed);
    return _refresh();
  }

  Future<ChatList> setPinned(String id, {required bool value}) async {
    await _api.pinConversation(id, value);
    return _refresh();
  }

  Future<ChatList> setArchived(String id, {required bool value}) async {
    await _api.archiveConversation(id, value);
    return _refresh();
  }

  Future<ChatList> delete(String id) async {
    await _api.deleteConversation(id);
    // The local row too. A pull reconciles additions and edits, but a row the
    // server no longer has is not something the next pull will mention -- so
    // without this the conversation stays in the sidebar until something
    // else happens to evict it, which reads as the delete having failed.
    _conversations.removeConversation(id);
    return _refresh();
  }

  Future<ChatShare> share(String id) async {
    final shareId = await _api.shareConversation(id);
    await _refresh();
    return ChatShare(chatId: id, shareId: shareId);
  }

  Future<ChatShare> unshare(String id) async {
    await _api.deleteSharedConversation(id);
    await _refresh();
    return ChatShare(chatId: id);
  }

  ApiService get _api {
    final api = _container.read(apiServiceProvider);
    if (api == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'sign in before changing a conversation',
      );
    }
    return api;
  }

  /// Re-reads the list after a server write.
  ///
  /// Pulls first: the write went to the server, and the list is a projection
  /// of the local database, so invalidating alone would re-read the same
  /// stale rows and report the rename as having done nothing.
  Future<ChatList> _refresh() async {
    await _pull('chats.mutation');
    _container.invalidate(conversationsProvider);
    return list();
  }

  ChatList _project(List<Conversation> conversations) => ChatList(
    chats: conversations.map(_summarize).toList(growable: false),
    hasMore: _conversations.hasMoreRegularChats(),
    archivedCount: _conversations.archivedChatCount(),
  );

  static ChatSummary _summarize(Conversation conversation) => ChatSummary(
    id: conversation.id,
    title: conversation.title,
    updatedAtMs: conversation.updatedAt.millisecondsSinceEpoch,
    pinned: conversation.pinned,
    archived: conversation.archived,
    folderId: conversation.folderId,
    model: conversation.model,
    tags: conversation.tags,
    // Whether, not what: a share id is a public URL, and the sidebar only
    // needs to show a badge.
    shared: (conversation.shareId ?? '').isNotEmpty,
  );

  static ChatMessageDto _message(core.ChatMessage message) => ChatMessageDto(
    id: message.id,
    role: message.role,
    content: message.content,
    timestampMs: message.timestamp.millisecondsSinceEpoch,
    model: message.model,
    streaming: message.isStreaming,
    errorCode: message.error == null ? null : ConduitErrorCodes.serverError,
  );
}
