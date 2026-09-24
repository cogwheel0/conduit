part of 'chat_providers.dart';

Conversation? _listedConversationForSelection(
  WidgetRef ref,
  String selectionId,
) {
  final identity = ChatStorageIdentity.parse(selectionId);
  final conversations = ref.read(conversationsProvider).asData?.value;
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
  WidgetRef ref,
  String conversationId,
  String title,
) async {
  final identity = ChatStorageIdentity.parse(conversationId);
  final rawId = identity.rawId;
  final selectionId = _directLocalSelectionId(identity);
  final now = DateTime.now();
  final locks = ref.read(chatLocksProvider);
  final db = ref.read(directLocalDatabaseProvider);
  await locks.runExclusive(
    rawId,
    () => db.chatsDao.updateLocalOnlyEnvelope(
      rawId,
      title: Value(title),
      updatedAt: Value(now.millisecondsSinceEpoch ~/ 1000),
    ),
  );
  ref
      .read(conversationsProvider.notifier)
      .updateConversation(
        selectionId,
        (conversation) => conversation.copyWith(title: title, updatedAt: now),
      );
  final active = ref.read(activeConversationProvider);
  if (_activeConversationMatchesSelection(active, selectionId)) {
    ref
        .read(activeConversationProvider.notifier)
        .set(active!.copyWith(title: title, updatedAt: now));
  }
}

Future<void> deleteDirectLocalConversation(
  WidgetRef ref,
  String conversationId,
) async {
  final identity = ChatStorageIdentity.parse(conversationId);
  final rawId = identity.rawId;
  final selectionId = _directLocalSelectionId(identity);
  final locks = ref.read(chatLocksProvider);
  final db = ref.read(directLocalDatabaseProvider);
  await locks.runExclusive(rawId, () => db.chatsDao.deleteLocalOnlyChat(rawId));
  ref.read(conversationsProvider.notifier).removeConversation(selectionId);
}

// Pin/Unpin conversation
Future<void> pinConversation(
  WidgetRef ref,
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
    final locks = ref.read(chatLocksProvider);
    final db = ref.read(directLocalDatabaseProvider);
    await locks.runExclusive(
      rawId,
      () => db.chatsDao.updateLocalOnlyEnvelope(
        rawId,
        pinned: Value(pinned),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch ~/ 1000),
      ),
    );
    ref
        .read(conversationsProvider.notifier)
        .updateConversation(
          conversationId,
          (conversation) =>
              conversation.copyWith(pinned: pinned, updatedAt: DateTime.now()),
        );
    final active = ref.read(activeConversationProvider);
    if (_activeConversationMatchesSelection(active, conversationId)) {
      ref
          .read(activeConversationProvider.notifier)
          .set(active!.copyWith(pinned: pinned));
    }
    return;
  }
  try {
    final api = ref.read(apiServiceProvider);
    if (api == null) throw Exception('No API service available');

    await api.pinConversation(rawId, pinned);

    ref
        .read(conversationsProvider.notifier)
        .updateConversationFromRemote(
          conversationId,
          (conversation) =>
              conversation.copyWith(pinned: pinned, updatedAt: DateTime.now()),
        );

    // Refresh conversations list to reflect the change
    refreshConversationsCache(ref);

    // Update active conversation if it's the one being pinned
    final activeConversation = ref.read(activeConversationProvider);
    if (_activeConversationMatchesSelection(
      activeConversation,
      conversationId,
    )) {
      ref
          .read(activeConversationProvider.notifier)
          .set(activeConversation!.copyWith(pinned: pinned));
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
  WidgetRef ref,
  String conversationId,
  bool archived,
) async {
  final identity = ChatStorageIdentity.parse(conversationId);
  final rawId = identity.rawId;
  final api = ref.read(apiServiceProvider);
  final activeConversation = ref.read(activeConversationProvider);
  final listedConversation = _listedConversationForSelection(
    ref,
    conversationId,
  );
  final leavingActiveConversation =
      archived &&
      _activeConversationMatchesSelection(activeConversation, conversationId);
  final previousFilterIds = leavingActiveConversation
      ? List<String>.of(ref.read(selectedFilterIdsProvider))
      : const <String>[];

  if (identity.storage == ChatStorageKind.directLocal ||
      isDirectLocalConversation(listedConversation)) {
    final locks = ref.read(chatLocksProvider);
    final db = ref.read(directLocalDatabaseProvider);
    await locks.runExclusive(
      rawId,
      () => db.chatsDao.updateLocalOnlyEnvelope(
        rawId,
        archived: Value(archived),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch ~/ 1000),
      ),
    );
    ref
        .read(conversationsProvider.notifier)
        .updateConversation(
          conversationId,
          (conversation) => conversation.copyWith(
            archived: archived,
            updatedAt: DateTime.now(),
          ),
        );
    if (_activeConversationMatchesSelection(
      activeConversation,
      conversationId,
    )) {
      if (archived) {
        clearSelectedFiltersForConversationBoundary(ref);
        ref.read(activeConversationProvider.notifier).clear();
        ref.read(chatMessagesProvider.notifier).clearMessages();
      } else {
        ref
            .read(activeConversationProvider.notifier)
            .set(activeConversation!.copyWith(archived: false));
      }
    }
    return;
  }

  // Update local state first
  if (_activeConversationMatchesSelection(activeConversation, conversationId) &&
      archived) {
    clearSelectedFiltersForConversationBoundary(ref);
    ref.read(activeConversationProvider.notifier).clear();
    ref.read(chatMessagesProvider.notifier).clearMessages();
  }

  try {
    if (api == null) throw Exception('No API service available');

    await api.archiveConversation(rawId, archived);

    ref
        .read(conversationsProvider.notifier)
        .updateConversationFromRemote(
          conversationId,
          (conversation) => conversation.copyWith(
            archived: archived,
            updatedAt: DateTime.now(),
          ),
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
      ref.read(activeConversationProvider.notifier).set(activeConversation);
      ref.read(selectedFilterIdsProvider.notifier).set(previousFilterIds);
      // Messages will be restored through the listener
    }

    rethrow;
  }
}

// Share conversation
Future<String?> shareConversation(dynamic ref, String conversationId) async {
  try {
    final api = ref.read(apiServiceProvider);
    if (api == null) throw Exception('No API service available');
    final rawId = ChatStorageIdentity.parse(conversationId).rawId;

    final shareId = await api.shareConversation(rawId);
    if (!identical(ref.read(apiServiceProvider), api)) return shareId;

    ref
        .read(conversationsProvider.notifier)
        .updateConversationFromRemote(
          conversationId,
          (Conversation conversation) => conversation.copyWith(
            shareId: shareId,
            updatedAt: DateTime.now(),
          ),
        );

    // Refresh conversations list to reflect the change
    refreshConversationsCache(ref);

    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation != null &&
        conversationMatchesScopedId(activeConversation, conversationId)) {
      ref
          .read(activeConversationProvider.notifier)
          .set(activeConversation.copyWith(shareId: shareId));
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
    final api = ref.read(apiServiceProvider);
    if (api == null) throw Exception('No API service available');
    final rawId = ChatStorageIdentity.parse(conversationId).rawId;

    await api.deleteSharedConversation(rawId);
    if (!identical(ref.read(apiServiceProvider), api)) return;

    ref
        .read(conversationsProvider.notifier)
        .updateConversationFromRemote(
          conversationId,
          (Conversation conversation) =>
              conversation.copyWith(shareId: null, updatedAt: DateTime.now()),
        );

    refreshConversationsCache(ref);

    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation != null &&
        conversationMatchesScopedId(activeConversation, conversationId)) {
      ref
          .read(activeConversationProvider.notifier)
          .set(activeConversation.copyWith(shareId: null));
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
Future<void> cloneConversation(WidgetRef ref, String conversationId) async {
  try {
    final api = ref.read(apiServiceProvider);
    if (api == null) throw Exception('No API service available');

    final clonedConversation = await api.cloneConversation(conversationId);

    // Set the cloned conversation as active
    clearSelectedFiltersForConversationBoundary(ref);
    ref.read(activeConversationProvider.notifier).set(clonedConversation);
    // Load messages through the listener mechanism
    // The ChatMessagesNotifier will automatically load messages when activeConversation changes

    // Refresh conversations list to show the new conversation
    ref
        .read(conversationsProvider.notifier)
        .upsertConversation(
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
