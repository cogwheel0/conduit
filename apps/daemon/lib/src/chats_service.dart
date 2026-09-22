import 'dart:async';

import 'package:conduit_core/models/chat_message.dart' as core;
import 'package:conduit_core/database/database_provider.dart';
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
    return _project(conversations, await _folders());
  }

  /// The account's folders, or none.
  ///
  /// Empty rather than an error when they will not load: a server without
  /// the folders feature, or a sync that has not landed yet, should leave
  /// the sidebar a flat list, not a broken one.
  Future<List<FolderSummary>> _folders() async {
    try {
      final folders = await _container.read(foldersProvider.future);
      return <FolderSummary>[
        for (final folder in folders)
          FolderSummary(
            id: folder.id,
            name: folder.name,
            parentId: folder.parentId,
            expanded: folder.isExpanded,
          ),
      ];
    } on Object catch (error) {
      DebugLogger.error('folders-failed', scope: 'daemon/chats', error: error);
      return const <FolderSummary>[];
    }
  }

  /// Pages archived chats into the list, or out of it (WP-3.1).
  Future<ChatList> setArchivedVisible({required bool visible}) async {
    await _conversations.setArchivedChatsVisible(visible);
    return list();
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
    final summary = conversations
        .where((candidate) => candidate.id == id)
        .firstOrNull;
    if (summary == null) return null;

    // The list carries envelopes only -- `conversationFromListEntry` builds
    // a summary with no message bodies, deliberately, because the sidebar
    // does not need them and loading 200 transcripts to draw a list would
    // be absurd. Reading `summary.messages` here therefore returned an
    // empty transcript for every conversation that was not created in this
    // session: the app could list two hundred chats and open none of them.
    //
    // `loadConversationProvider` is the loader that assembles a full
    // conversation from the database, with the network as a fallback.
    Conversation? full;
    try {
      full = await _container.read(loadConversationProvider(id).future);
    } on Object catch (error, stackTrace) {
      // A transcript that will not load is worth showing the envelope for
      // rather than pretending the conversation does not exist.
      DebugLogger.error(
        'chat-load-failed',
        scope: 'daemon/chats',
        error: error,
        stackTrace: stackTrace,
        data: <String, Object?>{'id': id},
      );
    }
    final conversation = full ?? summary;

    return ChatDetail(
      summary: _summarize(conversation),
      messages: conversation.messages.map(_message).toList(growable: false),
    );
  }

  /// Full-text search over titles and message bodies.
  ///
  /// Uses the database's FTS index rather than filtering the loaded page in
  /// memory: the sidebar holds one page, and a search that only looked at
  /// what is already on screen would silently miss everything older -- which
  /// is worse than no search, because it looks like it worked.
  Future<ChatSearchResults> search(ChatSearchQuery query) async {
    final trimmed = query.query.trim();
    // An empty query is not a search for everything. Returning the whole
    // history here would look like a working search and be one of the
    // slowest things the app can do.
    if (trimmed.isEmpty) return const ChatSearchResults();

    final database = _container.read(appDatabaseProvider);
    if (database == null) {
      // No local database yet -- the account has not been certified. Falling
      // back to a title scan of the loaded page would be worse than saying
      // nothing, because a few results look like all of them.
      return const ChatSearchResults();
    }

    final hits = await database.searchDao.search(trimmed, limit: query.limit);
    return ChatSearchResults(
      hits: hits
          .map(
            (hit) => ChatSearchHit(
              chatId: hit.chatId,
              title: hit.title,
              // As the index produced it. Re-deriving a snippet in the UI
              // would mean reimplementing the tokenizer to agree with it.
              snippet: hit.snippet,
              // `SearchHit.updatedAt` is epoch *seconds* -- the chat rows
              // store Open WebUI's own units -- while the wire carries
              // milliseconds. Passing it through unscaled dates every result
              // to 1970.
              updatedAtMs: hit.updatedAt * 1000,
            ),
          )
          .toList(growable: false),
    );
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

  ChatList _project(
    List<Conversation> conversations,
    List<FolderSummary> folders,
  ) => ChatList(
    chats: conversations.map(_summarize).toList(growable: false),
    hasMore: _conversations.hasMoreRegularChats(),
    archivedCount: _conversations.archivedChatCount(),
    archivedVisible: _conversations.archivedChatsVisible(),
    folders: folders,
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
