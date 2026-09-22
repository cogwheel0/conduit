import 'dart:async';

import 'package:conduit_core/models/chat_message.dart' as core;
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
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

  Future<ChatList> list() async {
    final conversations = await _container.read(conversationsProvider.future);
    return _project(conversations);
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
