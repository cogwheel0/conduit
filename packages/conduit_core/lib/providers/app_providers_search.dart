part of 'app_providers.dart';

// Search query provider
@Riverpod(keepAlive: true)
class SearchQuery extends _$SearchQuery {
  @override
  String build() => '';

  void set(String query) => state = query;
}

/// Offline full-text search over the synced Drift history (CDT-RFC-001 Phase 4).
///
/// Runs ranked FTS5 search via [SearchDao.search] and maps the hits to the same
/// list-summary [Conversation] shape the server search returns, so callers can
/// treat online and offline results identically. Returns `[]` when there is no
/// active database (no server / reviewer mode) or before the index is built
/// (the DAO short-circuits on the `fts_built` gate). Results are already bm25
/// ascending (most relevant first); order is preserved.
Future<List<Conversation>> _offlineSearch(
  Ref ref,
  String query, {
  ChatStorageKind? storage,
}) async {
  try {
    final repository = ref.read(chatDatabaseRepositoryProvider);
    final hits = storage == null
        ? await repository.searchMergedChats(query, limit: 50)
        : await repository.searchChatsInStorage(
            query,
            storage: storage,
            limit: 50,
          );
    return hits
        .map((located) {
          return withChatStorageProvenance(
            conversationFromSearchHit(located.hit),
            located.storage,
          );
        })
        .toList(growable: false);
  } catch (e) {
    DebugLogger.error('offline-search-failed', scope: 'search', error: e);
    return const [];
  }
}

// Server-side search provider for chats, with an offline FTS5 fallback.
@riverpod
Future<List<Conversation>> serverSearch(Ref ref, String query) async {
  final trimmedQuery = query.trim();
  if (trimmedQuery.isEmpty) {
    // Return empty list for empty query instead of all conversations
    return [];
  }

  if (ref.watch(reviewerModeProvider)) {
    final conversations =
        ref.watch(conversationsProvider).asData?.value ??
        const <Conversation>[];
    final lowerQuery = trimmedQuery.toLowerCase();
    return conversations
        .where((conversation) {
          return conversation.title.toLowerCase().contains(lowerQuery) ||
              conversation.messages.any(
                (message) => message.content.toLowerCase().contains(lowerQuery),
              );
        })
        .toList(growable: false);
  }

  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    // Offline: serve ranked results straight from the local
    // FTS index over synced history (CDT-RFC-001 Phase 4 acceptance).
    DebugLogger.log('offline-search', scope: 'search');
    return _offlineSearch(ref, trimmedQuery);
  }

  try {
    DebugLogger.log(
      'server-search',
      scope: 'search',
      data: {'length': trimmedQuery.length},
    );

    // Use the new server-side search API
    final localResultsFuture = _offlineSearch(
      ref,
      trimmedQuery,
      storage: ChatStorageKind.directLocal,
    );
    final chatHits = await api.searchChats(
      query: trimmedQuery,
      archived: false, // Only search non-archived conversations
      limit: 50,
      sortBy: 'updated_at',
      sortOrder: 'desc',
    );
    // Server search results are explicitly scoped before they are merged with
    // the independent on-device index. Equal raw ids are valid across stores.
    final List<Conversation> conversations = chatHits
        .map(
          (conversation) => withChatStorageProvenance(
            conversation,
            ChatStorageKind.openWebUi,
          ),
        )
        .toList();

    // Perform message-level search and merge chat hits
    try {
      final messageHits = await api.searchMessages(
        query: trimmedQuery,
        limit: 100,
      );

      // Build a set of conversation IDs already present from chat search
      final existingIds = conversations.map(conversationScopedId).toSet();

      // Extract chat ids from message hits (supporting multiple key casings)
      final messageChatIds = <String>{};
      for (final hit in messageHits) {
        final chatId =
            (hit['chat_id'] ?? hit['chatId'] ?? hit['chatID']) as String?;
        if (chatId != null && chatId.isNotEmpty) {
          messageChatIds.add(chatId);
        }
      }

      // Determine which chat ids we still need to fetch
      final idsToFetch = messageChatIds
          .where(
            (id) => !existingIds.contains(
              ChatStorageIdentity(
                rawId: id,
                storage: ChatStorageKind.openWebUi,
              ).scopedId,
            ),
          )
          .toList();

      // Fetch conversations for those ids in parallel (cap to avoid overload)
      const maxFetch = 50;
      final fetchList = idsToFetch.take(maxFetch).toList();
      if (fetchList.isNotEmpty) {
        DebugLogger.log(
          'fetch-from-messages',
          scope: 'search',
          data: {'count': fetchList.length},
        );
        final fetched = await Future.wait(
          fetchList.map((id) async {
            try {
              return await api.getConversation(id);
            } catch (_) {
              return null;
            }
          }),
        );

        // Merge fetched conversations
        for (final conv in fetched) {
          if (conv != null) {
            final scoped = withChatStorageProvenance(
              conv,
              ChatStorageKind.openWebUi,
            );
            if (existingIds.add(conversationScopedId(scoped))) {
              conversations.add(scoped);
            }
          }
        }

        // Optional: sort by updated date desc to keep results consistent
        conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      }
    } catch (e) {
      DebugLogger.error('message-search-failed', scope: 'search', error: e);
    }

    // Server search cannot see chats intentionally kept in the dedicated
    // direct-local database. Merge ranked local results after the remote
    // response, preserving remote ordering and avoiding duplicate server rows.
    final existingIds = conversations.map(conversationScopedId).toSet();
    final localResults = await localResultsFuture;
    for (final local in localResults) {
      if (existingIds.add(conversationScopedId(local))) {
        conversations.add(local);
      }
    }

    DebugLogger.log(
      'server-results',
      scope: 'search',
      data: {'count': conversations.length},
    );
    return conversations;
  } catch (e) {
    DebugLogger.error('server-search-failed', scope: 'search', error: e);

    // Fallback to the offline FTS index when the server search fails. This is a
    // ranked search across ALL synced history (not just the in-memory page),
    // matching the offline path (CDT-RFC-001 Phase 4).
    DebugLogger.log('fallback-offline', scope: 'search');
    return _offlineSearch(ref, trimmedQuery);
  }
}

final filteredConversationsProvider = Provider<List<Conversation>>((ref) {
  final conversations = ref.watch(conversationsProvider);
  final query = ref.watch(searchQueryProvider);

  // Use server-side search when there's a query
  if (query.trim().isNotEmpty) {
    final searchResults = ref.watch(serverSearchProvider(query));
    return searchResults.maybeWhen(
      data: (results) => results,
      loading: () {
        // While server search is loading, show local filtered results
        return conversations.maybeWhen(
          data: (convs) => convs.where((conv) {
            return !conv.archived &&
                (conv.title.toLowerCase().contains(query.toLowerCase()) ||
                    conv.messages.any(
                      (msg) => msg.content.toLowerCase().contains(
                        query.toLowerCase(),
                      ),
                    ));
          }).toList(),
          orElse: () => [],
        );
      },
      error: (_, stackTrace) {
        // On error, fallback to local search
        return conversations.maybeWhen(
          data: (convs) => convs.where((conv) {
            return !conv.archived &&
                (conv.title.toLowerCase().contains(query.toLowerCase()) ||
                    conv.messages.any(
                      (msg) => msg.content.toLowerCase().contains(
                        query.toLowerCase(),
                      ),
                    ));
          }).toList(),
          orElse: () => [],
        );
      },
      orElse: () => [],
    );
  }

  // When no search query, show all non-archived conversations
  return conversations.maybeWhen(
    data: (convs) {
      if (ref.watch(reviewerModeProvider)) {
        return convs; // Already filtered above for demo
      }
      // Filter out archived conversations (they should be in a separate view)
      final filtered = convs.where((conv) => !conv.archived).toList();

      // Sort: pinned conversations first, then by updated date
      filtered.sort((a, b) {
        // Pinned conversations come first
        if (a.pinned && !b.pinned) return -1;
        if (!a.pinned && b.pinned) return 1;

        // Within same pin status, sort by updated date (newest first)
        return b.updatedAt.compareTo(a.updatedAt);
      });

      return filtered;
    },
    orElse: () => [],
  );
});

// Provider for archived conversations
final archivedConversationsProvider = Provider<List<Conversation>>((ref) {
  final conversations = ref.watch(conversationsProvider);

  return conversations.maybeWhen(
    data: (convs) {
      if (ref.watch(reviewerModeProvider)) {
        return convs.where((c) => c.archived).toList();
      }
      // Only show archived conversations
      final archived = convs.where((conv) => conv.archived).toList();

      // Sort by updated date (newest first)
      archived.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      return archived;
    },
    orElse: () => [],
  );
});
