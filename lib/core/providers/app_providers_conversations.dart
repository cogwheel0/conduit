part of 'app_providers.dart';

@Riverpod(keepAlive: true)
class Conversations extends _$Conversations {
  static const int _regularPageSize = 200;
  static const int _archivedPageSize = 200;

  int _databaseWatchGeneration = 0;
  StreamSubscription<List<LocatedChatListEntry>>? _databaseSubscription;
  StreamSubscription<int>? _archivedCountSubscription;
  Future<void> _databaseWatchCancellation = Future<void>.value();
  Object? _paginationRepository;
  bool? _paginationIncludesOpenWebUi;
  Object? _paginationAuthSessionEpoch;
  int _regularChatLimit = _regularPageSize;
  int _archivedChatLimit = 0;
  bool _hasMoreRegularChats = false;
  bool _isLoadingMoreRegularChats = false;
  int _archivedChatCount = 0;
  bool _hasMoreArchivedChats = false;
  bool _isLoadingMoreArchivedChats = false;
  List<Conversation>? _lastSuccessfulDatabaseProjection;

  bool hasMoreRegularChats() => _hasMoreRegularChats;
  bool isLoadingMoreRegularChats() => _isLoadingMoreRegularChats;
  int archivedChatCount() => _archivedChatCount;
  bool hasMoreArchivedChats() => _hasMoreArchivedChats;
  bool isLoadingMoreArchivedChats() => _isLoadingMoreArchivedChats;
  bool archivedChatsVisible() => _archivedChatLimit > 0;

  @override
  Future<List<Conversation>> build() async {
    ref.watch(_conversationListPageTickProvider);
    final generation = ++_databaseWatchGeneration;
    final previousSubscription = _databaseSubscription;
    final previousArchivedCountSubscription = _archivedCountSubscription;
    _databaseSubscription = null;
    _archivedCountSubscription = null;
    ref.onDispose(() {
      if (generation == _databaseWatchGeneration) {
        _databaseWatchGeneration++;
        final subscription = _databaseSubscription;
        final archivedCountSubscription = _archivedCountSubscription;
        _databaseSubscription = null;
        _archivedCountSubscription = null;
        unawaited(
          _queueDatabaseWatchCancellation(
            subscription,
            archivedCountSubscription,
          ),
        );
      }
    });
    await _queueDatabaseWatchCancellation(
      previousSubscription,
      previousArchivedCountSubscription,
    );
    if (!ref.mounted || generation != _databaseWatchGeneration) {
      return const <Conversation>[];
    }

    if (ref.watch(reviewerModeProvider)) {
      final conversations = _demoConversations();
      // Force the next real database build to establish a fresh ownership
      // context. Demo rows must never become the retained fallback for a
      // production watch that fails before its first emission.
      _paginationRepository = null;
      _paginationIncludesOpenWebUi = null;
      _paginationAuthSessionEpoch = null;
      _lastSuccessfulDatabaseProjection = conversations;
      _hasMoreRegularChats = false;
      _isLoadingMoreRegularChats = false;
      _archivedChatCount = conversations
          .where((chat) => !chat.pinned && chat.archived)
          .length;
      _hasMoreArchivedChats = false;
      _isLoadingMoreArchivedChats = false;
      return conversations;
    }

    final accessPhase = ref.watch(openWebUiDatabaseAccessProvider);
    final certifiedServerId = ref.watch(
      openWebUiCertifiedDatabaseServerProvider,
    );
    final activeServerId = ref.watch(
      activeServerProvider.select((value) => value.asData?.value?.id),
    );
    final openWebUiDatabase = ref.watch(appDatabaseProvider);
    final unmanagedOpenWebUiDatabase =
        openWebUiDatabase != null &&
        ref
                .watch(databaseManagerProvider)
                .serverIdForDatabase(openWebUiDatabase) ==
            null;
    final includeOpenWebUi =
        accessPhase == OpenWebUiDatabaseAccessPhase.open &&
        ((certifiedServerId != null && certifiedServerId == activeServerId) ||
            unmanagedOpenWebUiDatabase);

    // Rebuild the repository when the active Open WebUI database changes. The
    // direct-local database is independent and remains available while signed
    // out or while switching servers.
    final repository = ref.watch(chatDatabaseRepositoryProvider);
    final authSessionEpoch = ref.watch(openWebUiAuthSessionEpochProvider);
    if (!identical(_paginationRepository, repository) ||
        _paginationIncludesOpenWebUi != includeOpenWebUi ||
        !identical(_paginationAuthSessionEpoch, authSessionEpoch)) {
      _lastSuccessfulDatabaseProjection = null;
      _paginationRepository = repository;
      _paginationIncludesOpenWebUi = includeOpenWebUi;
      _paginationAuthSessionEpoch = authSessionEpoch;
      _regularChatLimit = _regularPageSize;
      _archivedChatLimit = 0;
      _hasMoreRegularChats = false;
      _isLoadingMoreRegularChats = false;
      _archivedChatCount = 0;
      _hasMoreArchivedChats = false;
      _isLoadingMoreArchivedChats = false;
    }

    final completer = Completer<List<Conversation>>();
    // Cold-start instrumentation (CDT-RFC-001 §10 Budget 1): time from build()
    // start to the FIRST narrow-projection emission. Numeric-only data (no chat
    // content) so nothing untrusted is logged.
    final coldStart = Stopwatch()..start();
    final listStream = includeOpenWebUi
        ? repository.watchMergedChatList(
            regularLimit: _regularChatLimit + 1,
            archivedLimit: _archivedChatLimit > 0 ? _archivedChatLimit + 1 : 0,
          )
        : repository.watchDirectLocalChatList(
            regularLimit: _regularChatLimit + 1,
            archivedLimit: _archivedChatLimit > 0 ? _archivedChatLimit + 1 : 0,
          );
    final archivedCountStream = includeOpenWebUi
        ? repository.watchMergedArchivedChatCount()
        : repository.watchDirectLocalArchivedChatCount();
    final archivedCountSubscription = archivedCountStream.listen(
      (count) {
        if (generation != _databaseWatchGeneration) return;
        final normalizedCount = math.max(0, count);
        final changed = normalizedCount != _archivedChatCount;
        _archivedChatCount = normalizedCount;
        _hasMoreArchivedChats = _archivedChatCount > _archivedChatLimit;
        if (changed && completer.isCompleted && ref.mounted) {
          final current = state.asData?.value;
          if (current != null) {
            state = AsyncData<List<Conversation>>(
              List<Conversation>.unmodifiable(current),
            );
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (generation != _databaseWatchGeneration) return;
        DebugLogger.error(
          'archived-count-watch-failed',
          scope: 'conversations/watch',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
    _archivedCountSubscription = archivedCountSubscription;
    final subscription = listStream.listen(
      (entries) {
        if (generation != _databaseWatchGeneration) return;
        final activeEntries = entries
            .where(
              (located) => !located.entry.pinned && !located.entry.archived,
            )
            .toList(growable: false);
        final archivedEntries = entries
            .where((located) => !located.entry.pinned && located.entry.archived)
            .toList(growable: false);
        final includedUnpinned = <LocatedChatListEntry>{
          ...activeEntries.take(_regularChatLimit),
          ...archivedEntries.take(_archivedChatLimit),
        };
        final pagedEntries = entries
            .where(
              (located) =>
                  located.entry.pinned || includedUnpinned.contains(located),
            )
            .toList(growable: false);
        _hasMoreRegularChats = activeEntries.length > _regularChatLimit;
        _isLoadingMoreRegularChats = false;
        _hasMoreArchivedChats =
            archivedEntries.length > _archivedChatLimit ||
            _archivedChatCount > _archivedChatLimit;
        _isLoadingMoreArchivedChats = false;
        final conversations = List<Conversation>.unmodifiable(
          pagedEntries.map((located) {
            return withChatStorageProvenance(
              conversationFromListEntry(located.entry),
              located.storage,
            );
          }),
        );
        _lastSuccessfulDatabaseProjection = conversations;
        if (!completer.isCompleted) {
          coldStart.stop();
          DebugLogger.log(
            'cold-start-ms',
            scope: 'perf/list',
            data: {'ms': coldStart.elapsedMilliseconds, 'rows': entries.length},
          );
          completer.complete(conversations);
          return;
        }
        // Drift invalidates table watchers on ANY chats write, including
        // sync-cycle upserts that change nothing — every background pull
        // re-emitted an identical projection here as fresh objects, and the
        // drawer rebuilt every mounted tile for it. Conversation is freezed
        // (structural ==), so drop emissions that match the PUBLISHED state
        // exactly; comparing against the published value (not the previous
        // raw projection) keeps emissions that must correct a diverged
        // optimistic in-memory update flowing through.
        if (const ListEquality<Object?>().equals(
          state.asData?.value,
          conversations,
        )) {
          return;
        }
        if (ref.mounted) {
          state = AsyncData<List<Conversation>>(conversations);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (generation != _databaseWatchGeneration) return;
        _isLoadingMoreRegularChats = false;
        _isLoadingMoreArchivedChats = false;
        DebugLogger.error(
          'watch-failed',
          scope: 'conversations/watch',
          error: error,
          stackTrace: stackTrace,
        );
        if (!completer.isCompleted) {
          final retained = _lastSuccessfulDatabaseProjection;
          if (retained != null) {
            // A pagination/replacement watch can fail before its first row.
            // Keep the last projection from this exact repository/account
            // context instead of publishing a synthetic empty conversation
            // list. A true cold-start failure remains observable below.
            completer.complete(List<Conversation>.unmodifiable(retained));
          } else {
            completer.completeError(error, stackTrace);
          }
        } else if (ref.mounted) {
          final current = state.asData?.value;
          if (current != null) {
            state = AsyncData<List<Conversation>>(
              List<Conversation>.unmodifiable(current),
            );
          }
        }
      },
    );
    _databaseSubscription = subscription;
    return completer.future;
  }

  Future<void> _queueDatabaseWatchCancellation(
    StreamSubscription<List<LocatedChatListEntry>>? subscription, [
    StreamSubscription<int>? archivedCountSubscription,
  ]) {
    final prior = _databaseWatchCancellation;
    final cancellation = () async {
      await prior;
      try {
        await subscription?.cancel();
      } catch (_) {
        // A stale/closed Drift executor must not reject an async provider build
        // or escape as an unhandled error during provider disposal.
        try {
          DebugLogger.error(
            'watch-cancel-failed',
            scope: 'conversations/watch',
          );
        } catch (_) {}
      }
      try {
        await archivedCountSubscription?.cancel();
      } catch (_) {
        try {
          DebugLogger.error(
            'archived-count-watch-cancel-failed',
            scope: 'conversations/watch',
          );
        } catch (_) {}
      }
    }();
    _databaseWatchCancellation = cancellation;
    return cancellation;
  }

  /// Refreshing pulls changed rows and reconciles remote deletions; the
  /// database stream delivers the result. Folders are part of every pull
  /// cycle, so [includeFolders] needs no extra work.
  Future<void> refresh({
    bool includeFolders = false,
    bool forceFresh = false,
  }) async {
    final folderConversationRefresh = ref.read(
      _folderConversationRefreshTickProvider.notifier,
    );
    // Local-only direct chats are already live through Drift. Refresh the
    // optional Open WebUI side when it is available.
    if (ref.read(appDatabaseProvider) != null &&
        ref.read(isAuthenticatedProvider2)) {
      final syncEngine = ref.read(syncEngineProvider.notifier);
      await syncEngine.requestPull(reason: 'refresh');
      // A normal pull uses the 24-hour background deletion throttle. A user
      // initiated refresh must also run the unthrottled reconcile so chats
      // deleted from another Open WebUI client disappear immediately.
      await syncEngine.reconcileNow();
    }
    folderConversationRefresh.bumpIfMounted();
  }

  /// Expands the live database window; the replacement stream remains the
  /// source of truth and includes all pinned rows regardless of age.
  Future<void> loadMore() async {
    if (_isLoadingMoreRegularChats || !_hasMoreRegularChats) return;
    _isLoadingMoreRegularChats = true;
    _regularChatLimit += _regularPageSize;
    ref.read(_conversationListPageTickProvider.notifier).bump();
    await Future<void>.delayed(Duration.zero);
  }

  /// Opens or releases the independently paged archived-row window.
  Future<void> setArchivedChatsVisible(bool visible) async {
    final nextLimit = visible ? _archivedPageSize : 0;
    if ((visible && _archivedChatLimit > 0) ||
        (!visible && _archivedChatLimit == 0)) {
      return;
    }
    _archivedChatLimit = nextLimit;
    _isLoadingMoreArchivedChats = visible;
    _hasMoreArchivedChats = _archivedChatCount > _archivedChatLimit;
    ref.read(_conversationListPageTickProvider.notifier).bump();
    await Future<void>.delayed(Duration.zero);
  }

  /// Expands only the archived-row window; active-chat pagination is untouched.
  Future<void> loadMoreArchived() async {
    if (_archivedChatLimit <= 0 ||
        _isLoadingMoreArchivedChats ||
        !_hasMoreArchivedChats) {
      return;
    }
    _isLoadingMoreArchivedChats = true;
    _archivedChatLimit += _archivedPageSize;
    _hasMoreArchivedChats = _archivedChatCount > _archivedChatLimit;
    ref.read(_conversationListPageTickProvider.notifier).bump();
    await Future<void>.delayed(Duration.zero);
  }

  void removeConversation(String id) {
    final identity = ChatStorageIdentity.parse(id);
    final current = state.asData?.value;
    final index = current == null
        ? -1
        : _conversationIndexForSelection(current, id);
    final removedConversation = index >= 0 ? current![index] : null;
    if (current != null) {
      if (index >= 0) {
        final updated = <Conversation>[...current]..removeAt(index);
        _replaceState(updated);
      }
    }
    // The caller already confirmed any required remote deletion. Drop the row
    // from the database that owns it. Local-only direct chats never touch the
    // active Open WebUI database or its outbox.
    final directLocal =
        isDirectLocalConversation(removedConversation) ||
        (removedConversation == null &&
            identity.storage == ChatStorageKind.directLocal);
    final db = directLocal
        ? ref.read(directLocalDatabaseProvider)
        : ref.read(appDatabaseProvider);
    final rawId = identity.rawId;
    if (db == null || isTemporaryChat(rawId)) return;
    final locks = ref.read(chatLocksProvider);
    final folderConversationRefresh = ref.read(
      _folderConversationRefreshTickProvider.notifier,
    );
    unawaited(
      locks
          .runExclusive(
            rawId,
            () => directLocal
                ? db.chatsDao.deleteLocalOnlyChat(rawId)
                : db.chatsDao.hardDelete(rawId),
          )
          .then((_) => folderConversationRefresh.bumpIfMounted())
          .catchError((Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'row-delete-failed',
              scope: 'conversations',
              error: error,
              stackTrace: stackTrace,
              data: {'id': rawId},
            );
          }),
    );
  }

  void upsertConversation(
    Conversation conversation, {
    bool trustFolderConversation = false,
  }) {
    final current = state.asData?.value ?? const <Conversation>[];
    final existingIndex = _conversationIndexForSelection(
      current,
      conversationScopedId(conversation),
    );
    final existing = existingIndex >= 0 ? current[existingIndex] : null;
    var preparedConversation = existing == null
        ? conversation
        : conversation.copyWith(
            lastReadAt: _latestDateTime(
              existing.lastReadAt,
              conversation.lastReadAt,
            ),
          );
    final existingStorage = chatStorageKindOf(existing);
    if (existingStorage != null) {
      preparedConversation = withChatStorageProvenance(
        preparedConversation,
        existingStorage,
      );
    }
    final updated = <Conversation>[...current];
    if (existingIndex >= 0) {
      updated[existingIndex] = preparedConversation;
    } else {
      updated.add(preparedConversation);
    }
    _replaceState(updated);
    _writeEnvelopeStub(preparedConversation);
  }

  void upsertConversations(
    Iterable<Conversation> conversations, {
    bool trustFolderConversations = false,
  }) {
    for (final conversation in conversations) {
      upsertConversation(conversation);
    }
  }

  void updateConversation(
    String id,
    Conversation Function(Conversation conversation) transform, {
    bool trustFolderConversation = false,
  }) {
    final current = state.asData?.value;
    final index = current == null
        ? -1
        : _conversationIndexForSelection(current, id);
    if (current == null || index < 0) {
      // The chat list stream has not loaded yet, or this id is absent from the
      // loaded projection. Request a reconcile pull so the server-confirmed
      // envelope mutation is not lost (mirrors Folders.updateFolder).
      _requestConversationReconcilePull(
        action: current == null ? 'update-cold' : 'update-missing',
      );
      return;
    }
    final existing = current[index];
    var transformed = transform(existing);
    final storage = chatStorageKindOf(existing);
    if (storage != null) {
      transformed = withChatStorageProvenance(transformed, storage);
    }
    final updated = <Conversation>[...current]..[index] = transformed;
    _replaceState(updated);
    _writeEnvelopeUpdate(transformed);
  }

  void _requestConversationReconcilePull({required String action}) {
    _submitReconcilePull(
      ref,
      reason: 'conversations-reconcile',
      scope: 'conversations',
      action: action,
    );
  }

  void markConversationRead(String id, DateTime readAt) {
    if (id.isEmpty) return;
    final identity = ChatStorageIdentity.parse(id);
    final current = state.asData?.value;
    final index = current == null
        ? -1
        : _conversationIndexForSelection(current, id);
    Conversation? target = index >= 0 ? current![index] : null;
    if (current != null) {
      if (index >= 0) {
        final conversation = current[index];
        final existing = conversation.lastReadAt;
        if (existing != null && !readAt.isAfter(existing)) {
          return;
        }
        target = conversation.copyWith(lastReadAt: readAt);
        final updated = <Conversation>[...current]..[index] = target;
        _replaceState(updated);
      }
    }
    final directLocal =
        isDirectLocalConversation(target) ||
        (target == null && identity.storage == ChatStorageKind.directLocal);
    final db = directLocal
        ? ref.read(directLocalDatabaseProvider)
        : ref.read(appDatabaseProvider);
    final rawId = identity.rawId;
    if (db == null || isTemporaryChat(rawId)) return;
    // Pre-existing UI-only read marks come from the device clock; the DAO's
    // max() rule means the column is never lowered and the value never enters
    // watermark logic.
    unawaited(
      db.chatsDao.setLastReadAt(rawId, _epochSecondsOf(readAt)).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        DebugLogger.error(
          'read-mark-failed',
          scope: 'conversations',
          error: error,
          stackTrace: stackTrace,
          data: {'id': rawId},
        );
      }),
    );
  }

  /// Applies a server-confirmed conversation summary mutation.
  void updateConversationFromRemote(
    String id,
    Conversation Function(Conversation conversation) transform,
  ) {
    updateConversation(id, transform);
  }

  /// Applies Open WebUI's `chat:title` event without changing `updatedAt`.
  ///
  /// Title generation updates the server row and blob but does not advance the
  /// server watermark. Persist the event directly so a title cannot remain
  /// stale merely because the row is outside the loaded page.
  void applyServerGeneratedTitle(String serverId, String title) {
    final normalizedTitle = title.trim();
    final identity = ChatStorageIdentity.parse(serverId);
    final rawId = identity.rawId;
    if (rawId.isEmpty ||
        normalizedTitle.isEmpty ||
        identity.storage == ChatStorageKind.directLocal ||
        isTemporaryChat(rawId)) {
      return;
    }

    final db = ref.read(appDatabaseProvider);
    if (db == null) {
      _applyGeneratedTitleToLoadedState(rawId, normalizedTitle);
      return;
    }
    final locks = ref.read(chatLocksProvider);
    unawaited(
      locks
          .runExclusive(
            rawId,
            () =>
                db.chatsDao.updateServerGeneratedTitle(rawId, normalizedTitle),
          )
          .then<void>((persistedTitle) {
            if (persistedTitle != null) {
              _applyGeneratedTitleToLoadedState(rawId, persistedTitle);
            }
          })
          .catchError((Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'generated-title-write-failed',
              scope: 'conversations',
              error: error,
              stackTrace: stackTrace,
              data: {'id': rawId},
            );
          }),
    );
  }

  void _applyGeneratedTitleToLoadedState(String rawId, String title) {
    final scopedId = ChatStorageIdentity(
      rawId: rawId,
      storage: ChatStorageKind.openWebUi,
    ).scopedId;
    final current = state.asData?.value;
    final index = current == null
        ? -1
        : _conversationIndexForSelection(current, scopedId);
    if (current != null && index >= 0 && current[index].title != title) {
      final updated = <Conversation>[...current];
      updated[index] = current[index].copyWith(title: title);
      state = AsyncData<List<Conversation>>(
        List<Conversation>.unmodifiable(updated),
      );
    }

    final active = ref.read(activeConversationProvider);
    if (active != null && conversationMatchesScopedId(active, scopedId)) {
      ref
          .read(activeConversationProvider.notifier)
          .set(active.copyWith(title: title));
    }
  }

  /// Rows are id-keyed in the database; the summary "trust" machinery is
  /// obsolete. Kept as a frozen no-op for callers.
  void trustConversation(String id) {}

  void _replaceState(List<Conversation> conversations) {
    state = AsyncData<List<Conversation>>(_sortByUpdatedAt(conversations));
  }

  void _writeEnvelopeStub(Conversation conversation) {
    final directLocal = isDirectLocalConversation(conversation);
    final db = directLocal
        ? ref.read(directLocalDatabaseProvider)
        : ref.read(appDatabaseProvider);
    if (db == null || isTemporaryChat(conversation.id)) return;
    final lastReadAt = conversation.lastReadAt;
    // ChatLocks discipline: every write touching one chat's rows serializes
    // through the per-chat mutex so a stale optimistic stub can never be
    // ordered after (and overwrite) a concurrent locked pull merge.
    final locks = ref.read(chatLocksProvider);
    final folderConversationRefresh = ref.read(
      _folderConversationRefreshTickProvider.notifier,
    );
    unawaited(
      locks
          .runExclusive(conversation.id, () {
            if (directLocal) {
              return db.chatsDao.updateLocalOnlyEnvelope(
                conversation.id,
                title: Value(conversation.title),
                folderId: Value(conversation.folderId),
                pinned: Value(conversation.pinned),
                archived: Value(conversation.archived),
                updatedAt: Value(_epochSecondsOf(conversation.updatedAt)),
              );
            }
            return db.chatsDao.upsertEnvelopeStub(
              id: conversation.id,
              title: conversation.title,
              createdAt: _epochSecondsOf(conversation.createdAt),
              updatedAt: _epochSecondsOf(conversation.updatedAt),
              pinned: conversation.pinned,
              archived: conversation.archived,
              folderId: Value(conversation.folderId),
              lastReadAt: lastReadAt == null
                  ? null
                  : _epochSecondsOf(lastReadAt),
            );
          })
          .then((_) => folderConversationRefresh.bumpIfMounted())
          .catchError((Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'envelope-stub-failed',
              scope: 'conversations',
              error: error,
              stackTrace: stackTrace,
              data: {'id': conversation.id},
            );
          }),
    );
  }

  void _writeEnvelopeUpdate(Conversation conversation) {
    final directLocal = isDirectLocalConversation(conversation);
    final db = directLocal
        ? ref.read(directLocalDatabaseProvider)
        : ref.read(appDatabaseProvider);
    if (db == null || isTemporaryChat(conversation.id)) return;
    final locks = ref.read(chatLocksProvider);
    final folderConversationRefresh = ref.read(
      _folderConversationRefreshTickProvider.notifier,
    );
    unawaited(
      locks
          .runExclusive(conversation.id, () {
            return directLocal
                ? db.chatsDao.updateLocalOnlyEnvelope(
                    conversation.id,
                    title: Value(conversation.title),
                    folderId: Value(conversation.folderId),
                    pinned: Value(conversation.pinned),
                    archived: Value(conversation.archived),
                    updatedAt: Value(_epochSecondsOf(conversation.updatedAt)),
                  )
                : db.chatsDao.updateEnvelope(
                    conversation.id,
                    title: Value(conversation.title),
                    folderId: Value(conversation.folderId),
                    pinned: Value(conversation.pinned),
                    archived: Value(conversation.archived),
                    updatedAt: Value(_epochSecondsOf(conversation.updatedAt)),
                  );
          })
          .then((_) => folderConversationRefresh.bumpIfMounted())
          .catchError((Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'envelope-update-failed',
              scope: 'conversations',
              error: error,
              stackTrace: stackTrace,
              data: {'id': conversation.id},
            );
          }),
    );
  }

  List<Conversation> _sortByUpdatedAt(List<Conversation> conversations) {
    final sorted = [...conversations];
    sorted.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<Conversation>.unmodifiable(sorted);
  }

  List<Conversation> _demoConversations() => [
    Conversation(
      id: 'demo-conv-1',
      title: 'Welcome to Conduit (Demo)',
      createdAt: DateTime.now().subtract(const Duration(minutes: 15)),
      updatedAt: DateTime.now().subtract(const Duration(minutes: 10)),
      messages: [
        ChatMessage(
          id: 'demo-msg-1',
          role: 'assistant',
          content: '**Welcome to Conduit Demo Mode**\n\nThis is a demo for app review - responses are pre-written, not from real AI.\n\nTry these features:\n• Send messages\n• Attach images\n• Use voice input\n• Switch models (tap header)\n• Create new chats (menu)\n\nAll features work offline. No server needed.',
          timestamp: DateTime.now().subtract(const Duration(minutes: 10)),
          model: 'Gemma 2 Mini (Demo)',
          isStreaming: false,
        ),
      ],
    ),
  ];
}

final _folderConversationRefreshTickProvider =
    NotifierProvider<_FolderConversationRefreshTick, int>(
      _FolderConversationRefreshTick.new,
    );

class _FolderConversationRefreshTick extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;

  void bumpIfMounted() {
    if (!ref.mounted) return;
    bump();
  }
}

/// Loads folder conversation summaries from the local database
/// (CDT-RFC-001 Phase 1: per-folder server fetches are gone; pull sync keeps
/// the rows fresh and `_folderConversationRefreshTickProvider` invalidates
/// after pulls and mutations).
final folderConversationSummariesProvider =
    FutureProvider.family<List<Conversation>, String>((ref, folderId) async {
      ref.watch(_folderConversationRefreshTickProvider);

      if (!ref.watch(isAuthenticatedProvider2) ||
          ref.watch(reviewerModeProvider)) {
        return const <Conversation>[];
      }

      // Other users' chats never enter the local sync store (they are absent
      // from `/api/v1/chats/` and must not be pushed or reconciled), so they
      // are listed from the folder's shared-chats route:
      //  * a folder shared TO this user is served entirely from the network;
      //  * an owned folder unions its local rows with chats that users holding
      //    a write grant created inside it (local wins on id).
      final folder = ref
          .watch(foldersProvider)
          .asData
          ?.value
          .where((folder) => folder.id == folderId)
          .firstOrNull;
      final api = ref.watch(apiServiceProvider);
      final isShared = folder?.shared ?? false;
      List<Conversation> remote = const <Conversation>[];
      if (api != null && folder != null) {
        try {
          final raw = await api.getSharedFolderChats(folderId);
          remote = [
            for (final item in raw)
              Conversation.fromJson(parseConversationSummary(item)),
          ];
        } catch (error, stackTrace) {
          // An owned folder still renders its local rows; a shared one has
          // nothing else to show.
          DebugLogger.error(
            'shared-chats-failed',
            scope: 'folders',
            error: error,
            stackTrace: stackTrace,
            data: {'folderId': folderId, 'shared': isShared},
          );
          if (isShared) rethrow;
        }
      }
      if (isShared) return remote;

      final db = ref.watch(appDatabaseProvider);
      if (db == null) {
        return remote;
      }

      final entries = await db.chatsDao.getChatsInFolder(folderId);
      final local = entries.map(conversationFromListEntry).toList();
      if (remote.isEmpty) return local;
      final localIds = {for (final c in local) c.id};
      return [
        ...local,
        for (final c in remote)
          if (!localIds.contains(c.id)) c,
      ];
    });

/// True when [conversation] belongs to another user (reached through a shared
/// folder). Such chats are viewable but every write is rejected server-side.
/// Fails closed: a known owner with the signed-in user not yet resolved reads
/// as read-only (the auth manager never publishes `authenticated` without a
/// user, so this only bites during hydration).
bool isReadOnlySharedConversation(
  Conversation? conversation,
  String? currentUserId,
) {
  final owner = conversation?.userId;
  return owner != null && owner != currentUserId;
}

/// Whether the current chat session is temporary (not persisted to server).
///
/// When true, conversations use `local:{socketId}` IDs and skip all
/// server persistence. Resets on app restart unless the user has
/// `temporaryChatByDefault` enabled in settings.
@riverpod
class TemporaryChatEnabled extends _$TemporaryChatEnabled {
  @override
  bool build() {
    // Use ref.read (not watch) so settings changes don't reset
    // the ephemeral toggle state mid-conversation.
    final settings = ref.read(appSettingsProvider);
    return settings.temporaryChatByDefault;
  }

  void set(bool value) => state = value;
}

/// Returns true if the given conversation ID represents a temporary chat.
bool isTemporaryChat(String? id) => id != null && id.startsWith('local:');

void markConversationRead(
  dynamic ref,
  String? conversationId, {
  DateTime? readAt,
}) {
  final scopedId = conversationId?.trim();
  if (scopedId == null || scopedId.isEmpty) {
    return;
  }
  final identity = ChatStorageIdentity.parse(scopedId);
  final id = identity.rawId;
  if (isTemporaryChat(id)) {
    return;
  }

  final timestamp = readAt ?? DateTime.now();
  Conversation? targetConversation;
  var resolvedSelectionId = scopedId;
  try {
    final conversations = (ref.read(
      conversationsProvider,
    ) as AsyncValue<List<Conversation>>).asData?.value;
    if (conversations != null) {
      final index = _conversationIndexForSelection(conversations, scopedId);
      if (index >= 0) {
        targetConversation = conversations[index];
        resolvedSelectionId = conversationScopedId(targetConversation);
      }
    }
    ref
        .read(conversationsProvider.notifier)
        .markConversationRead(resolvedSelectionId, timestamp);
  } catch (_) {}

  try {
    final active = ref.read(activeConversationProvider) as Conversation?;
    if (active != null &&
        (targetConversation != null
            ? isSameStoredConversation(active, targetConversation)
            : conversationMatchesScopedId(active, resolvedSelectionId))) {
      targetConversation ??= active;
      final current = active.lastReadAt;
      if (current == null || timestamp.isAfter(current)) {
        ref
            .read(activeConversationProvider.notifier)
            .set(active.copyWith(lastReadAt: timestamp));
      }
    }
  } catch (_) {}

  if (isDirectLocalConversation(targetConversation) ||
      identity.storage == ChatStorageKind.directLocal ||
      (identity.storage == null && id.startsWith('direct-local:'))) {
    return;
  }

  try {
    ref.read(socketServiceProvider)?.emit('events:chat', {
      'chat_id': id,
      'data': {'type': 'last_read_at'},
    });
  } catch (_) {}
}
