part of 'app_providers.dart';

final activeConversationProvider =
    NotifierProvider<ActiveConversationNotifier, Conversation?>(
      ActiveConversationNotifier.new,
    );

enum ActiveConversationRemapNamespace { openWebUi, direct, hermes, libreChat }

@immutable
class ActiveConversationInPlaceRemap {
  const ActiveConversationInPlaceRemap({
    required this.fromId,
    required this.toId,
    this.namespace = ActiveConversationRemapNamespace.openWebUi,
    this.openWebUiDatabase,
    this.openWebUiApi,
    this.openWebUiAuthSessionEpoch,
  });

  final String fromId;
  final String toId;
  final ActiveConversationRemapNamespace namespace;
  final Object? openWebUiDatabase;
  final Object? openWebUiApi;
  final Object? openWebUiAuthSessionEpoch;

  bool matches(
    String? previousId,
    String? nextId, {
    ActiveConversationRemapNamespace? namespace,
  }) =>
      previousId == fromId &&
      nextId == toId &&
      (namespace == null || this.namespace == namespace);

  bool matchesOpenWebUiContext({
    required Object? database,
    required Object? api,
    required Object? authSessionEpoch,
  }) =>
      namespace == ActiveConversationRemapNamespace.openWebUi &&
      identical(openWebUiDatabase, database) &&
      identical(openWebUiApi, api) &&
      identical(openWebUiAuthSessionEpoch, authSessionEpoch);
}

final activeConversationInPlaceRemapProvider =
    NotifierProvider<
      ActiveConversationInPlaceRemapNotifier,
      ActiveConversationInPlaceRemap?
    >(ActiveConversationInPlaceRemapNotifier.new);

class ActiveConversationInPlaceRemapNotifier
    extends Notifier<ActiveConversationInPlaceRemap?> {
  @override
  ActiveConversationInPlaceRemap? build() => null;

  void mark({
    required String fromId,
    required String toId,
    ActiveConversationRemapNamespace namespace =
        ActiveConversationRemapNamespace.openWebUi,
  }) {
    Object? database;
    Object? api;
    Object? authSessionEpoch;
    if (namespace == ActiveConversationRemapNamespace.openWebUi) {
      // Remapping the durable row has already happened by the time this
      // navigation marker is emitted. A temporarily failing context provider
      // must not poison the remap stream or leave the UI on the deleted local
      // id. Capture what is available; the later exact-context check fails
      // closed when any captured component cannot be reproduced.
      try {
        database = ref.read(appDatabaseProvider);
      } catch (_) {}
      try {
        api = ref.read(apiServiceProvider);
      } catch (_) {}
      try {
        authSessionEpoch = ref.read(openWebUiAuthSessionEpochProvider);
      } catch (_) {}
    }
    state = ActiveConversationInPlaceRemap(
      fromId: fromId,
      toId: toId,
      namespace: namespace,
      openWebUiDatabase: database,
      openWebUiApi: api,
      openWebUiAuthSessionEpoch: authSessionEpoch,
    );
  }
}

bool isActiveConversationInPlaceRemap(
  dynamic ref,
  String? previousId,
  String? nextId,
) {
  try {
    if (previousId == null || nextId == null) return false;
    final previousIdentity = ChatStorageIdentity.parse(previousId);
    final nextIdentity = ChatStorageIdentity.parse(nextId);
    if (previousIdentity.storage != null &&
        nextIdentity.storage != null &&
        previousIdentity.storage != nextIdentity.storage) {
      return false;
    }
    final active = ref.read(activeConversationProvider) as Conversation?;
    if (active == null || !conversationMatchesScopedId(active, nextId)) {
      return false;
    }
    final namespace = _activeConversationRemapNamespaceFor(active);
    final remap = ref.read(activeConversationInPlaceRemapProvider);
    if (remap?.matches(
          previousIdentity.rawId,
          nextIdentity.rawId,
          namespace: namespace,
        ) !=
        true) {
      return false;
    }
    if (namespace != ActiveConversationRemapNamespace.openWebUi) return true;
    return remap!.matchesOpenWebUiContext(
      database: ref.read(appDatabaseProvider),
      api: ref.read(apiServiceProvider),
      authSessionEpoch: ref.read(openWebUiAuthSessionEpochProvider),
    );
  } catch (_) {
    return false;
  }
}

class ActiveConversationNotifier extends Notifier<Conversation?> {
  @override
  Conversation? build() => null;

  void set(Conversation? conversation) {
    final previous = state;
    final selectionChanged = previous == null
        ? conversation != null
        : conversation == null ||
              !isSameStoredConversation(previous, conversation);
    if (selectionChanged) {
      ref.read(hermesSessionNavigationEpochProvider.notifier).bump();
    }
    state = conversation;
  }

  void remapIdInPlace({required String fromId, required String toId}) {
    final current = state;
    if (current == null || current.id != fromId) return;
    final namespace = _activeConversationRemapNamespaceFor(current);
    ref
        .read(activeConversationInPlaceRemapProvider.notifier)
        .mark(fromId: fromId, toId: toId, namespace: namespace);
    state = inheritNativeHermesConversationProvenance(
      current,
      current.copyWith(id: toId),
    );
  }

  void clear() {
    ref.read(hermesSessionNavigationEpochProvider.notifier).bump();
    state = null;
  }
}

ActiveConversationRemapNamespace _activeConversationRemapNamespaceFor(
  Conversation conversation,
) {
  final storage = chatStorageKindOf(conversation);
  // Storage ownership and the transport used by the latest turn are separate.
  // A direct/Hermes turn inside a server-owned chat still needs the exact
  // OpenWebUI database/API remap fence.
  if (storage == ChatStorageKind.openWebUi) {
    return ActiveConversationRemapNamespace.openWebUi;
  }
  if (storage == ChatStorageKind.libreChat) {
    return ActiveConversationRemapNamespace.libreChat;
  }
  if (isNativeHermesConversation(conversation)) {
    return ActiveConversationRemapNamespace.hermes;
  }
  if (conversation.metadata['backend'] == 'direct' ||
      storage == ChatStorageKind.directLocal) {
    return ActiveConversationRemapNamespace.direct;
  }
  return ActiveConversationRemapNamespace.openWebUi;
}

/// Settles each Direct answer stored as still being written while no run
/// here writes it: the process that ran it quit or died mid-reply. Without
/// it the chat would open writing, with Stop offered for nothing and Send
/// refused. Returns whether there was one: the caller reads the chat again,
/// as a run may also have finished or replaced it meanwhile.
///
/// Under the chat's lock, so a run's own writes, which take it too, land
/// whole before or after; one that started after the check here writes its
/// placeholder over the settled row. Only the message's payload changes: the
/// chat keeps its time, so opening it does not move it in the list or mark
/// it for a push to the server (and so for another device's Unread); a row
/// already owed to the server stays dirty, its push still to go.
Future<bool> _settleOrphanedDirectAnswers(
  Ref ref,
  Conversation conversation, {
  required String chatId,
  required ChatDatabaseLocation location,
}) async {
  final registry = ref.read(directRunRegistryProvider);
  final orphans = <String>[
    for (final message in conversation.messages)
      if (message.role == 'assistant' &&
          message.isStreaming &&
          message.metadata?['transport'] == kDirectTransport &&
          !registry.hasLiveIntentForMessage(message.id))
        message.id,
  ];
  if (orphans.isEmpty) return false;
  try {
    final messages = location.database.messagesDao;
    await ref.read(chatLocksProvider).runExclusive(chatId, () async {
      for (final id in orphans) {
        if (registry.hasLiveIntentForMessage(id)) continue;
        final row = await messages.getMessage(chatId, id);
        if (row == null) continue;
        final payload = jsonDecode(row.payload);
        if (payload is! Map || payload['isStreaming'] != true) continue;
        await messages.markAssistantStopped(
          chatId: chatId,
          messageId: id,
          keepDirty: true,
        );
      }
    });
  } catch (error, stackTrace) {
    DebugLogger.error(
      'orphaned-direct-settle-failed',
      scope: 'conversation',
      error: error,
      stackTrace: stackTrace,
      data: {'id': chatId},
    );
  }
  return true;
}

// Provider to load full conversation with messages
@riverpod
Future<Conversation> loadConversation(Ref ref, String conversationId) {
  final keepAliveLink = ref.keepAlive();
  return _loadConversation(
    ref,
    conversationId,
  ).whenComplete(keepAliveLink.close);
}

Future<Conversation> _loadConversation(Ref ref, String conversationId) async {
  final identity = ChatStorageIdentity.parse(conversationId);
  final rawConversationId = identity.rawId;
  // Preserve database provenance from the selected summary when possible.
  // Prefixing makes locally-created ids collision-resistant, while the marker
  // handles imported or legacy rows whose ids do collide.
  Conversation? summary;
  final active = ref.read(activeConversationProvider);
  final activeConfirmsOpenWebUiOwnership =
      identity.storage == null &&
      chatStorageKindOf(active) == ChatStorageKind.openWebUi;
  if (active != null &&
      (identity.storage != null || activeConfirmsOpenWebUiOwnership) &&
      conversationMatchesScopedId(active, conversationId)) {
    // Legacy callers still pass raw OpenWebUI ids. An explicitly annotated
    // active summary can restore that ownership while the merged list loads;
    // a Direct-local or unannotated active row is never trusted for this.
    summary = active;
  } else {
    final conversations = ref.read(conversationsProvider).asData?.value;
    if (conversations != null) {
      final index = _conversationIndexForSelection(
        conversations,
        conversationId,
      );
      if (index >= 0) {
        summary = conversations[index];
      }
    }
  }
  final preferredStorage =
      identity.storage ??
      (rawConversationId.startsWith('direct-local:')
          ? ChatStorageKind.directLocal
          : null) ??
      chatStorageKindOf(summary);

  final openWebUiOwnership = captureOpenWebUiConversationRead(ref);
  final repository = ref.read(chatDatabaseRepositoryProvider);
  // The LibreChat account's database as the load starts. An account switch
  // replaces it; a chat read from the old one must never be handed to the
  // account that took over.
  final libreChatDatabase = repository.libreChatLocation?.database;
  bool libreChatReadIsCurrent(AppDatabase? database) =>
      libreChatDatabase != null &&
      identical(database, libreChatDatabase) &&
      identical(
        ref.read(chatDatabaseRepositoryProvider).libreChatLocation?.database,
        libreChatDatabase,
      );
  Future<LocatedConversation?> readStored() => repository.loadConversation(
    rawConversationId,
    preferred: preferredStorage,
    locationIsCurrent: (location) => switch (location.storage) {
      ChatStorageKind.openWebUi =>
        openWebUiOwnership != null &&
            identical(location.database, openWebUiOwnership.database) &&
            openWebUiConversationReadIsCurrent(ref, openWebUiOwnership),
      ChatStorageKind.libreChat => libreChatReadIsCurrent(location.database),
      ChatStorageKind.directLocal => true,
    },
    offload: (envelope) => ref
        .read(workerManagerProvider)
        .schedule(
          parseFullConversationModelWorker,
          envelope,
          debugLabel: 'db.assembleConversation',
        ),
  );
  LocatedConversation? located;
  try {
    located = await readStored();
    // Read again once an orphaned Direct answer is settled: every message
    // is then as stored, the settled one finished and one that a run
    // finished, or took over, meanwhile as that run left it.
    if (located != null &&
        await _settleOrphanedDirectAnswers(
          ref,
          located.conversation,
          chatId: rawConversationId,
          location: located.location,
        )) {
      located = await readStored() ?? located;
    }
  } catch (error, stackTrace) {
    DebugLogger.error(
      'load-failed',
      scope: 'conversation/cache',
      error: error,
      stackTrace: stackTrace,
      data: {
        'id': conversationId,
        'storage': preferredStorage?.name ?? 'unknown',
      },
    );
    // Only an explicitly OpenWebUI-owned summary may use the network fallback.
    // Unknown provenance can mean the same raw id exists in both stores; in
    // that case fetching OpenWebUI would silently cross the storage boundary.
    if (preferredStorage != ChatStorageKind.openWebUi) {
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
  if (located != null) {
    if (located.location.storage == ChatStorageKind.openWebUi &&
        (openWebUiOwnership == null ||
            !identical(
              located.location.database,
              openWebUiOwnership.database,
            ) ||
            !openWebUiConversationReadIsCurrent(ref, openWebUiOwnership))) {
      throw OpenWebUiConversationOwnershipException(
        OpenWebUiConversationOwnershipFailureReason.changedWhileLoading,
      );
    }
    if (located.location.storage == ChatStorageKind.libreChat &&
        !libreChatReadIsCurrent(located.location.database)) {
      throw const LibreChatAccountChangedException();
    }
    final local = withChatStorageProvenance(
      located.conversation,
      located.location.storage,
    );
    DebugLogger.log(
      'load-local-ok',
      scope: 'conversation',
      data: {
        'id': conversationId,
        'messages': local.messages.length,
        'storage': located.location.storage.name,
      },
    );
    if (located.location.storage == ChatStorageKind.openWebUi) {
      await scheduleOpenedChatRefresh(
        ref,
        rawConversationId,
        ownership: openWebUiOwnership,
      );
      // Sizing the refresh awaited the database; recheck before handing out
      // this account's chat.
      if (openWebUiOwnership == null ||
          !openWebUiConversationReadIsCurrent(ref, openWebUiOwnership)) {
        throw OpenWebUiConversationOwnershipException(
          OpenWebUiConversationOwnershipFailureReason.changedWhileLoading,
        );
      }
    }
    return local;
  }

  if (preferredStorage == ChatStorageKind.directLocal) {
    throw StateError('On-device conversation is unavailable');
  }
  // A LibreChat chat is never fetched from Open WebUI, whatever its id: one
  // not stored yet, or without its messages, comes from its own server. So
  // does any chat of unknown provenance while a LibreChat account owns the
  // Chats tab, since Open WebUI is parked.
  if (preferredStorage == ChatStorageKind.libreChat ||
      (preferredStorage == null &&
          ref.read(primaryAccountKindProvider) ==
              PrimaryAccountKind.libreChat)) {
    // No LibreChat account owned the Chats tab as the load started (Open
    // WebUI does, or LibreChat's store is not open yet): its server is not
    // asked for a chat that tab could not show.
    if (libreChatDatabase == null) {
      throw StateError('LibreChat conversation is unavailable');
    }
    // A new chat whose first reply is still being written here is not
    // pulled until it ends: it opens as the run named it, and the run puts
    // its messages back.
    final started = ref
        .read(libreChatActiveGenerationsProvider.notifier)
        .startedChat(rawConversationId);
    if (started != null) {
      return withChatStorageProvenance(started, ChatStorageKind.libreChat);
    }
    final pulled = await ref
        .read(libreChatPrimarySyncProvider)
        .pullChatNow(rawConversationId);
    // The pull read the database of the account in use when it started.
    if (!libreChatReadIsCurrent(libreChatDatabase)) {
      throw const LibreChatAccountChangedException();
    }
    if (pulled == null) {
      throw StateError('LibreChat conversation is unavailable');
    }
    DebugLogger.log(
      'load-librechat-ok',
      scope: 'conversation',
      data: {'messages': pulled.messages.length},
    );
    return withChatStorageProvenance(pulled, ChatStorageKind.libreChat);
  }

  if (openWebUiOwnership == null ||
      !openWebUiConversationReadIsCurrent(ref, openWebUiOwnership)) {
    throw OpenWebUiConversationOwnershipException(
      OpenWebUiConversationOwnershipFailureReason.unavailable,
    );
  }
  final api = openWebUiOwnership.api;
  if (api == null) {
    throw Exception('No API service available');
  }

  DebugLogger.log(
    'load-start',
    scope: 'conversation',
    data: {'id': conversationId},
  );
  // Materialize the local row so the next open is DB-first, from the same
  // download. Another user's chat (shared folder) stays network-only: the
  // sync store would otherwise push edits to it and it can never appear in
  // this user's chat list.
  final currentUserId = ref.read(currentUserProvider2)?.id;
  var fullConversation = await fetchChatNowForOpen(
    ref,
    rawConversationId,
    storeIf: (response) =>
        !isReadOnlySharedOwner(response['user_id']?.toString(), currentUserId),
  );
  if (!openWebUiConversationReadIsCurrent(ref, openWebUiOwnership)) {
    throw OpenWebUiConversationOwnershipException(
      OpenWebUiConversationOwnershipFailureReason.changedWhileFetching,
    );
  }
  if (fullConversation == null) {
    // The sync engine had nothing to give: fetch directly and store it in the
    // background instead. Bound to the session just checked: another can sign
    // in while the deletes still to land are read.
    final authSnapshot = api.captureAuthSnapshot();
    try {
      fullConversation = await readChatWithoutUnsentDeletes(
        ref,
        api,
        openWebUiOwnership.database,
        rawConversationId,
        authSnapshot: authSnapshot,
      );
    } on DioException {
      if (api.authSnapshotIsCurrent(authSnapshot)) rethrow;
      throw OpenWebUiConversationOwnershipException(
        OpenWebUiConversationOwnershipFailureReason.changedWhileFetching,
      );
    }
    if (!openWebUiConversationReadIsCurrent(ref, openWebUiOwnership)) {
      throw OpenWebUiConversationOwnershipException(
        OpenWebUiConversationOwnershipFailureReason.changedWhileFetching,
      );
    }
    if (!isReadOnlySharedConversation(
      fullConversation,
      ref.read(currentUserProvider2)?.id,
    )) {
      schedulePullChatNow(
        ref,
        rawConversationId,
        ownership: openWebUiOwnership,
      );
    }
  }
  DebugLogger.log(
    'load-ok',
    scope: 'conversation',
    data: {'messages': fullConversation.messages.length},
  );

  return withChatStorageProvenance(fullConversation, ChatStorageKind.openWebUi);
}
