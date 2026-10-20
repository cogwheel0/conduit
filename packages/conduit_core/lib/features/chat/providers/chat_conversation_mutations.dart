part of 'chat_providers.dart';

/// Reads [provider] through [ref] with its static type intact.
///
/// The mutations below are called with a widget's `ref`, which the core
/// cannot name, so [ref] is dynamic. Reading through it directly would make
/// every result dynamic too, and extension members (`asData`, drift's column
/// operators) and closure inference do not survive that.
T _readProvider<T>(dynamic ref, ProviderListenable<T> provider) =>
    ref.read<T>(provider) as T;

Conversation? _listedConversationForSelection(dynamic ref, String selectionId) {
  final identity = ChatStorageIdentity.parse(selectionId);
  final conversations = _readProvider(ref, conversationsProvider).asData?.value;
  if (conversations == null) return null;
  if (identity.storage != null) {
    return conversations
        .where(
          (conversation) =>
              conversationMatchesScopedId(conversation, selectionId),
        )
        .firstOrNull;
  }
  final candidates = conversations
      .where((conversation) => conversation.id == identity.rawId)
      .toList(growable: false);
  return candidates
          .where((conversation) => !isDirectLocalConversation(conversation))
          .firstOrNull ??
      candidates.firstOrNull;
}

bool _activeConversationMatchesSelection(
  Conversation? active,
  String selectionId,
) {
  if (active == null) return false;
  final identity = ChatStorageIdentity.parse(selectionId);
  if (identity.storage != null) {
    return conversationMatchesScopedId(active, selectionId);
  }
  return active.id == identity.rawId && !isDirectLocalConversation(active);
}

String _directLocalSelectionId(ChatStorageIdentity identity) {
  if (identity.storage != null &&
      identity.storage != ChatStorageKind.directLocal) {
    throw StateError('The selected chat is not stored on this device.');
  }
  return identity.storage == ChatStorageKind.directLocal
      ? identity.scopedId
      : ChatStorageIdentity(
          rawId: identity.rawId,
          storage: ChatStorageKind.directLocal,
        ).scopedId;
}

Future<void> renameDirectLocalConversation(
  dynamic ref,
  String conversationId,
  String title,
) async {
  final identity = ChatStorageIdentity.parse(conversationId);
  final rawId = identity.rawId;
  final selectionId = _directLocalSelectionId(identity);
  final now = DateTime.now();
  final locks = _readProvider(ref, chatLocksProvider);
  final db = _readProvider(ref, directLocalDatabaseProvider);
  await locks.runExclusive(
    rawId,
    () => db.chatsDao.updateLocalOnlyEnvelope(
      rawId,
      title: Value(title),
      updatedAt: Value(now.millisecondsSinceEpoch ~/ 1000),
    ),
  );
  _readProvider(ref, conversationsProvider.notifier).updateConversation(
    selectionId,
    (conversation) => conversation.copyWith(title: title, updatedAt: now),
  );
  final active = _readProvider(ref, activeConversationProvider);
  if (_activeConversationMatchesSelection(active, selectionId)) {
    _readProvider(
      ref,
      activeConversationProvider.notifier,
    ).set(active!.copyWith(title: title, updatedAt: now));
  }
}

Future<void> deleteDirectLocalConversation(
  dynamic ref,
  String conversationId,
) async {
  final identity = ChatStorageIdentity.parse(conversationId);
  final rawId = identity.rawId;
  final selectionId = _directLocalSelectionId(identity);
  final locks = _readProvider(ref, chatLocksProvider);
  final db = _readProvider(ref, directLocalDatabaseProvider);
  await locks.runExclusive(rawId, () => db.chatsDao.deleteLocalOnlyChat(rawId));
  _readProvider(
    ref,
    conversationsProvider.notifier,
  ).removeConversation(selectionId);
}

// Pin/Unpin conversation
Future<void> pinConversation(
  dynamic ref,
  String conversationId,
  bool pinned,
) async {
  final identity = ChatStorageIdentity.parse(conversationId);
  final rawId = identity.rawId;
  final localConversation = _listedConversationForSelection(
    ref,
    conversationId,
  );
  if (identity.storage == ChatStorageKind.directLocal ||
      isDirectLocalConversation(localConversation)) {
    final locks = _readProvider(ref, chatLocksProvider);
    final db = _readProvider(ref, directLocalDatabaseProvider);
    await locks.runExclusive(
      rawId,
      () => db.chatsDao.updateLocalOnlyEnvelope(
        rawId,
        pinned: Value(pinned),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch ~/ 1000),
      ),
    );
    _readProvider(ref, conversationsProvider.notifier).updateConversation(
      conversationId,
      (conversation) =>
          conversation.copyWith(pinned: pinned, updatedAt: DateTime.now()),
    );
    final active = _readProvider(ref, activeConversationProvider);
    if (_activeConversationMatchesSelection(active, conversationId)) {
      _readProvider(
        ref,
        activeConversationProvider.notifier,
      ).set(active!.copyWith(pinned: pinned));
    }
    return;
  }
  try {
    final api = _readProvider(ref, apiServiceProvider);
    if (api == null) throw Exception('No API service available');

    await api.pinConversation(rawId, pinned);

    _readProvider(
      ref,
      conversationsProvider.notifier,
    ).updateConversationFromRemote(
      conversationId,
      (conversation) =>
          conversation.copyWith(pinned: pinned, updatedAt: DateTime.now()),
    );

    // Refresh conversations list to reflect the change
    refreshConversationsCache(ref);

    // Update active conversation if it's the one being pinned
    final activeConversation = _readProvider(ref, activeConversationProvider);
    if (_activeConversationMatchesSelection(
      activeConversation,
      conversationId,
    )) {
      _readProvider(
        ref,
        activeConversationProvider.notifier,
      ).set(activeConversation!.copyWith(pinned: pinned));
    }
  } catch (e) {
    DebugLogger.log(
      'Error ${pinned ? 'pinning' : 'unpinning'} conversation: $e',
      scope: 'chat/providers',
    );
    rethrow;
  }
}

// Archive/Unarchive conversation
Future<void> archiveConversation(
  dynamic ref,
  String conversationId,
  bool archived,
) async {
  final identity = ChatStorageIdentity.parse(conversationId);
  final rawId = identity.rawId;
  final api = _readProvider(ref, apiServiceProvider);
  final activeConversation = _readProvider(ref, activeConversationProvider);
  final listedConversation = _listedConversationForSelection(
    ref,
    conversationId,
  );
  final leavingActiveConversation =
      archived &&
      _activeConversationMatchesSelection(activeConversation, conversationId);
  final previousFilterIds = leavingActiveConversation
      ? List<String>.of(_readProvider(ref, selectedFilterIdsProvider))
      : const <String>[];

  if (identity.storage == ChatStorageKind.directLocal ||
      isDirectLocalConversation(listedConversation)) {
    final locks = _readProvider(ref, chatLocksProvider);
    final db = _readProvider(ref, directLocalDatabaseProvider);
    await locks.runExclusive(
      rawId,
      () => db.chatsDao.updateLocalOnlyEnvelope(
        rawId,
        archived: Value(archived),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch ~/ 1000),
      ),
    );
    _readProvider(ref, conversationsProvider.notifier).updateConversation(
      conversationId,
      (conversation) =>
          conversation.copyWith(archived: archived, updatedAt: DateTime.now()),
    );
    if (_activeConversationMatchesSelection(
      activeConversation,
      conversationId,
    )) {
      if (archived) {
        clearSelectedFiltersForConversationBoundary(ref);
        _readProvider(ref, activeConversationProvider.notifier).clear();
        _readProvider(ref, chatMessagesProvider.notifier).clearMessages();
      } else {
        _readProvider(
          ref,
          activeConversationProvider.notifier,
        ).set(activeConversation!.copyWith(archived: false));
      }
    }
    return;
  }

  // Update local state first
  if (_activeConversationMatchesSelection(activeConversation, conversationId) &&
      archived) {
    clearSelectedFiltersForConversationBoundary(ref);
    _readProvider(ref, activeConversationProvider.notifier).clear();
    _readProvider(ref, chatMessagesProvider.notifier).clearMessages();
  }

  try {
    if (api == null) throw Exception('No API service available');

    await api.archiveConversation(rawId, archived);

    _readProvider(
      ref,
      conversationsProvider.notifier,
    ).updateConversationFromRemote(
      conversationId,
      (conversation) =>
          conversation.copyWith(archived: archived, updatedAt: DateTime.now()),
    );

    // Refresh conversations list to reflect the change
    refreshConversationsCache(ref);
  } catch (e) {
    DebugLogger.log(
      'Error ${archived ? 'archiving' : 'unarchiving'} conversation: $e',
      scope: 'chat/providers',
    );

    // If server operation failed and we archived locally, restore the conversation
    if (_activeConversationMatchesSelection(
          activeConversation,
          conversationId,
        ) &&
        archived) {
      _readProvider(
        ref,
        activeConversationProvider.notifier,
      ).set(activeConversation);
      _readProvider(
        ref,
        selectedFilterIdsProvider.notifier,
      ).set(previousFilterIds);
      // Messages will be restored through the listener
    }

    rethrow;
  }
}

// Share conversation
Future<String?> shareConversation(dynamic ref, String conversationId) async {
  try {
    final api = _readProvider(ref, apiServiceProvider);
    if (api == null) throw Exception('No API service available');
    final rawId = ChatStorageIdentity.parse(conversationId).rawId;

    final shareId = await api.shareConversation(rawId);
    if (!identical(_readProvider(ref, apiServiceProvider), api)) return shareId;

    _readProvider(
      ref,
      conversationsProvider.notifier,
    ).updateConversationFromRemote(
      conversationId,
      (Conversation conversation) =>
          conversation.copyWith(shareId: shareId, updatedAt: DateTime.now()),
    );

    // Refresh conversations list to reflect the change
    refreshConversationsCache(ref);

    final activeConversation = _readProvider(ref, activeConversationProvider);
    if (activeConversation != null &&
        conversationMatchesScopedId(activeConversation, conversationId)) {
      _readProvider(
        ref,
        activeConversationProvider.notifier,
      ).set(activeConversation.copyWith(shareId: shareId));
    }

    return shareId;
  } catch (e) {
    DebugLogger.log('Error sharing conversation: $e', scope: 'chat/providers');
    rethrow;
  }
}

Future<void> deleteSharedConversation(
  dynamic ref,
  String conversationId,
) async {
  try {
    final api = _readProvider(ref, apiServiceProvider);
    if (api == null) throw Exception('No API service available');
    final rawId = ChatStorageIdentity.parse(conversationId).rawId;

    await api.deleteSharedConversation(rawId);
    if (!identical(_readProvider(ref, apiServiceProvider), api)) return;

    _readProvider(
      ref,
      conversationsProvider.notifier,
    ).updateConversationFromRemote(
      conversationId,
      (Conversation conversation) =>
          conversation.copyWith(shareId: null, updatedAt: DateTime.now()),
    );

    refreshConversationsCache(ref);

    final activeConversation = _readProvider(ref, activeConversationProvider);
    if (activeConversation != null &&
        conversationMatchesScopedId(activeConversation, conversationId)) {
      _readProvider(
        ref,
        activeConversationProvider.notifier,
      ).set(activeConversation.copyWith(shareId: null));
    }
  } catch (e) {
    DebugLogger.log(
      'Error deleting shared conversation link: $e',
      scope: 'chat/providers',
    );
    rethrow;
  }
}

// Clone conversation
Future<void> cloneConversation(dynamic ref, String conversationId) async {
  try {
    final api = _readProvider(ref, apiServiceProvider);
    if (api == null) throw Exception('No API service available');

    final clonedConversation = await api.cloneConversation(conversationId);

    // Set the cloned conversation as active
    clearSelectedFiltersForConversationBoundary(ref);
    _readProvider(
      ref,
      activeConversationProvider.notifier,
    ).set(clonedConversation);
    // Load messages through the listener mechanism
    // The ChatMessagesNotifier will automatically load messages when activeConversation changes

    // Refresh conversations list to show the new conversation
    _readProvider(ref, conversationsProvider.notifier).upsertConversation(
      clonedConversation.copyWith(updatedAt: DateTime.now()),
      trustFolderConversation:
          clonedConversation.folderId != null &&
          clonedConversation.folderId!.isNotEmpty,
    );
    refreshConversationsCache(ref);
  } catch (e) {
    DebugLogger.log('Error cloning conversation: $e', scope: 'chat/providers');
    rethrow;
  }
}
