part of 'app_providers.dart';

final activeConversationProvider =
    NotifierProvider<ActiveConversationNotifier, Conversation?>(
      ActiveConversationNotifier.new,
    );

enum ActiveConversationRemapNamespace { openWebUi, direct, hermes }

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
  if (isNativeHermesConversation(conversation)) {
    return ActiveConversationRemapNamespace.hermes;
  }
  if (conversation.metadata['backend'] == 'direct' ||
      storage == ChatStorageKind.directLocal) {
    return ActiveConversationRemapNamespace.direct;
  }
  return ActiveConversationRemapNamespace.openWebUi;
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
  LocatedConversation? located;
  try {
    located = await repository.loadConversation(
      rawConversationId,
      preferred: preferredStorage,
      locationIsCurrent: (location) =>
          location.storage != ChatStorageKind.openWebUi ||
          (openWebUiOwnership != null &&
              identical(location.database, openWebUiOwnership.database) &&
              openWebUiConversationReadIsCurrent(ref, openWebUiOwnership)),
      offload: (envelope) => ref
          .read(workerManagerProvider)
          .schedule(
            parseFullConversationModelWorker,
            envelope,
            debugLabel: 'db.assembleConversation',
          ),
    );
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
      schedulePullChatNow(
        ref,
        rawConversationId,
        ownership: openWebUiOwnership,
      );
    }
    return local;
  }

  if (preferredStorage == ChatStorageKind.directLocal) {
    throw StateError('On-device conversation is unavailable');
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
  final fullConversation = await api.getConversation(rawConversationId);
  if (!openWebUiConversationReadIsCurrent(ref, openWebUiOwnership)) {
    throw OpenWebUiConversationOwnershipException(
      OpenWebUiConversationOwnershipFailureReason.changedWhileFetching,
    );
  }
  DebugLogger.log(
    'load-ok',
    scope: 'conversation',
    data: {'messages': fullConversation.messages.length},
  );
  // Materialize the local row so the next open is DB-first. Another user's
  // chat (shared folder) stays network-only: the sync store would otherwise
  // push edits to it and it can never appear in this user's chat list.
  if (!isReadOnlySharedConversation(
    fullConversation,
    ref.read(currentUserProvider2)?.id,
  )) {
    schedulePullChatNow(ref, rawConversationId, ownership: openWebUiOwnership);
  }

  return withChatStorageProvenance(fullConversation, ChatStorageKind.openWebUi);
}
