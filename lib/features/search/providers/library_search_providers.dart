import 'dart:async';

import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/note.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum LibrarySearchSource { chats, localChats, folders, notes }

typedef LibrarySearchRequest = ({
  LibrarySearchSource source,
  String query,
  int page,
});

class LibrarySearchResult {
  const LibrarySearchResult({
    required this.id,
    required this.title,
    this.excerpt,
    this.conversation,
  });

  final String id;
  final String title;
  final String? excerpt;
  final Conversation? conversation;
}

typedef LibrarySearchBatch = ({List<LibrarySearchResult> items, bool hasMore});

/// Each source and page has its own lifetime, cancellation, and retry. Changing
/// the query or account cannot publish an old response into the new results.
final librarySearchPageProvider = FutureProvider.autoDispose
    .family<LibrarySearchBatch, LibrarySearchRequest>((ref, request) async {
      final query = request.query.trim();
      if (query.isEmpty) {
        return (items: <LibrarySearchResult>[], hasMore: false);
      }
      ref.watch(openWebUiAuthSessionEpochProvider);
      final online = ref.watch(isOnlineProvider);
      final api = online ? ref.watch(apiServiceProvider) : null;
      final repository = ref.watch(chatDatabaseRepositoryProvider);
      final database = ref.watch(appDatabaseProvider);
      final cancel = CancelToken();
      ref.onDispose(cancel.cancel);
      const pageSize = 60;
      final offset = (request.page - 1) * pageSize;

      switch (request.source) {
        case LibrarySearchSource.chats:
          if (api != null) {
            final chats = await api.searchChatPage(
              query: query,
              page: request.page,
              cancelToken: cancel,
            );
            return (
              items: [
                for (final chat in chats)
                  LibrarySearchResult(
                    id: chat.id,
                    title: chat.title,
                    conversation: withChatStorageProvenance(
                      chat,
                      ChatStorageKind.openWebUi,
                    ),
                  ),
              ],
              hasMore: chats.length == pageSize,
            );
          }
          // Cached server history remains searchable without a connection.
          return _chatHits(
            await repository.searchChatsInStorage(
              query,
              storage: ChatStorageKind.openWebUi,
              limit: pageSize,
              offset: offset,
            ),
          );
        case LibrarySearchSource.localChats:
          return _chatHits(
            await repository.searchChatsInStorage(
              query,
              storage: ChatStorageKind.directLocal,
              limit: pageSize,
              offset: offset,
            ),
          );
        case LibrarySearchSource.folders:
          final folders = await ref.watch(foldersProvider.future);
          final matches = folders
              .where(
                (folder) =>
                    folder.name.toLowerCase().contains(query.toLowerCase()),
              )
              .toList();
          return (
            items: [
              for (final folder in matches.skip(offset).take(pageSize))
                LibrarySearchResult(id: folder.id, title: folder.name),
            ],
            hasMore: matches.length > offset + pageSize,
          );
        case LibrarySearchSource.notes:
          if (api != null) {
            final rows = await api.searchNotes(
              query: query,
              page: request.page,
              cancelToken: cancel,
            );
            return (
              items: [
                for (final row in rows)
                  if (row['id'] case final String id when id.isNotEmpty)
                    LibrarySearchResult(
                      id: id,
                      title: row['title'] as String? ?? '',
                      excerpt: searchExcerpt(
                        Note.fromJson(row).data.content.md,
                        query,
                      ),
                    ),
              ],
              hasMore: rows.length == pageSize,
            );
          }
          final hits =
              await database?.searchDao.searchNotes(
                query,
                limit: pageSize,
                offset: offset,
              ) ??
              [];
          return (
            items: [
              for (final hit in hits)
                LibrarySearchResult(
                  id: hit.chatId,
                  title: hit.title,
                  excerpt: _plainSnippet(hit.snippet),
                ),
            ],
            hasMore: hits.length == pageSize,
          );
      }
    }, retry: (_, _) => null);

LibrarySearchBatch _chatHits(List<LocatedSearchHit> hits) => (
  items: [
    for (final located in hits)
      LibrarySearchResult(
        id: located.hit.chatId,
        title: located.hit.title,
        excerpt: _plainSnippet(located.hit.snippet),
        conversation: withChatStorageProvenance(
          conversationFromSearchHit(located.hit),
          located.storage,
        ),
      ),
  ],
  hasMore: hits.length == 60,
);

String? _plainSnippet(String? value) =>
    value?.replaceAll(RegExp('[\u2068\u2069]'), '');

/// Keep excerpts bounded and centered on the match, including body-only hits.
String? searchExcerpt(String text, String query) {
  final plain = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (plain.isEmpty) return null;
  final match = RegExp(
    RegExp.escape(query),
    caseSensitive: false,
  ).firstMatch(plain);
  final start = ((match?.start ?? 0) - 70).clamp(0, plain.length);
  final end = (start + 220).clamp(0, plain.length);
  return '${start > 0 ? '…' : ''}${plain.substring(start, end)}'
      '${end < plain.length ? '…' : ''}';
}

final libraryChatSnippetProvider = FutureProvider.autoDispose
    .family<String?, ({String id, String query})>((ref, request) async {
      ref.watch(openWebUiAuthSessionEpochProvider);
      final online = ref.watch(isOnlineProvider);
      final api = online ? ref.watch(apiServiceProvider) : null;
      if (api == null) return null;
      final cancel = CancelToken();
      ref.onDispose(cancel.cancel);
      final snippet = await api.getChatSearchSnippet(
        chatId: request.id,
        query: request.query,
        cancelToken: cancel,
      );
      if (ref.mounted) {
        // Recycled tiles reuse completed excerpts, including unsupported ones.
        // Pending requests still cancel immediately when no longer visible.
        final cache = ref.keepAlive();
        final expiry = Timer(const Duration(minutes: 2), cache.close);
        ref.onDispose(expiry.cancel);
      }
      return snippet;
    });
