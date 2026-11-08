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

/// Refuses an Open WebUI-only action on a LibreChat chat, which must never
/// reach Open WebUI's API whatever its raw id.
void _requireNotLibreChat(String conversationId, {Conversation? listed}) {
  if (_isLibreChatSelection(conversationId, listed)) {
    throw StateError('This action is not available for LibreChat chats yet.');
  }
}

bool _isLibreChatSelection(String conversationId, Conversation? listed) =>
    ChatStorageIdentity.parse(conversationId).storage ==
        ChatStorageKind.libreChat ||
    isLibreChatConversation(listed);

/// The signed-in LibreChat account's database, for a write to one of its
/// chats.
AppDatabase _libreChatDatabaseFor(dynamic ref) =>
    _readProvider(ref, chatDatabaseRepositoryProvider)
        .libreChatLocation
        ?.database ??
    (throw StateError('The LibreChat account is not signed in.'));

/// Whether [db] is still the database of the LibreChat account that owns
/// the Chats tab. A write that waited for its chat while the account changed
/// still lands in the account it was made for, but must not touch the chats
/// the new one shows, which can share its ids (a copied server, say).
bool _libreChatDatabaseIsCurrent(dynamic ref, AppDatabase db) => identical(
  _readProvider(
    ref,
    chatDatabaseRepositoryProvider,
  ).libreChatLocation?.database,
  db,
);

/// Runs [write] on LibreChat database [db] under chat [rawId]'s lock,
/// keeping the database open until it is done: an account switch while the
/// write waits for the chat would otherwise close it underneath, and the
/// edit and its queued server change would be lost.
Future<T> _writeLibreChatChat<T>(
  dynamic ref,
  AppDatabase db,
  String rawId,
  Future<T> Function() write,
) async {
  final release = _readProvider(ref, libreChatDatabaseHoldProvider)(db);
  try {
    return await _readProvider(
      ref,
      libreChatChatLocksProvider,
    ).runExclusive<T>(rawId, write);
  } finally {
    await release?.call();
  }
}

/// Runs [work] with LibreChat database [db] held open, so that an account
/// switch meanwhile cannot close it before [work] writes to it: what a
/// server call did is still recorded in the account it was made for.
Future<T> _holdingLibreChatDatabase<T>(
  dynamic ref,
  AppDatabase db,
  Future<T> Function() work,
) async {
  final release = _readProvider(ref, libreChatDatabaseHoldProvider)(db);
  try {
    return await work();
  } finally {
    await release?.call();
  }
}

/// Writes a local envelope change of a LibreChat chat to its account's
/// database, queues it for the server and starts the outbox. The chats list
/// follows the database; the open chat is updated here.
Future<void> _writeLibreChatEnvelope(
  dynamic ref,
  String conversationId, {
  String? title,
  bool? pinned,
  bool? archived,
}) async {
  final rawId = ChatStorageIdentity.parse(conversationId).rawId;
  final db = _libreChatDatabaseFor(ref);
  final now = DateTime.now();
  await _writeLibreChatChat(
    ref,
    db,
    rawId,
    () => db.chatsDao.updateEnvelopeWithOutbox(
      rawId,
      title: title == null ? const Value.absent() : Value(title),
      pinned: pinned == null ? const Value.absent() : Value(pinned),
      archived: archived == null ? const Value.absent() : Value(archived),
      updatedAt: title == null
          ? const Value.absent()
          : Value(now.millisecondsSinceEpoch ~/ 1000),
      enqueue: true,
    ),
  );
  if (!_libreChatDatabaseIsCurrent(ref, db)) return;
  _readProvider(ref, conversationsProvider.notifier).updateConversation(
    conversationId,
    (conversation) => conversation.copyWith(
      title: title ?? conversation.title,
      pinned: pinned ?? conversation.pinned,
      archived: archived ?? conversation.archived,
      updatedAt: title == null ? conversation.updatedAt : now,
    ),
  );
  final active = _readProvider(ref, activeConversationProvider);
  if (_activeConversationMatchesSelection(active, conversationId)) {
    if (archived == true) {
      clearSelectedFiltersForConversationBoundary(ref);
      _readProvider(ref, activeConversationProvider.notifier).clear();
      _readProvider(ref, chatMessagesProvider.notifier).clearMessages();
    } else {
      // Only these fields change: the messages are the ones shown now, which
      // can be newer than the copy the chat opened with.
      _readProvider(ref, activeConversationProvider.notifier).set(
        active!.copyWith(
          title: title ?? active.title,
          pinned: pinned ?? active.pinned,
          archived: archived ?? active.archived,
          messages: _readProvider(ref, chatMessagesProvider),
        ),
      );
    }
  }
  _drainLibreChat(ref);
}

void _drainLibreChat(dynamic ref) {
  final engine = _readProvider(ref, libreChatSyncEngineProvider);
  if (engine == null) return;
  unawaited(
    engine.drain().catchError((Object error, StackTrace stackTrace) {
      DebugLogger.error(
        'drain-failed',
        scope: 'librechat/mutations',
        error: error,
        stackTrace: stackTrace,
      );
    }),
  );
}

/// Renames a LibreChat chat: locally at once, on the server when the outbox
/// drains (now, or once back online).
Future<void> renameLibreChatConversation(
  dynamic ref,
  String conversationId,
  String title,
) => _writeLibreChatEnvelope(ref, conversationId, title: title);

/// Deletes a LibreChat chat: it leaves the list at once, and the server
/// deletes it when the outbox drains. The local row stays as a tombstone
/// until then, so a pull cannot bring it back.
Future<void> deleteLibreChatConversation(
  dynamic ref,
  String conversationId,
) async {
  final rawId = ChatStorageIdentity.parse(conversationId).rawId;
  final db = _libreChatDatabaseFor(ref);
  await _writeLibreChatChat(
    ref,
    db,
    rawId,
    () => db.chatsDao.tombstoneWithOutbox(rawId),
  );
  if (!_libreChatDatabaseIsCurrent(ref, db)) return;
  final active = _readProvider(ref, activeConversationProvider);
  if (_activeConversationMatchesSelection(active, conversationId)) {
    clearSelectedFiltersForConversationBoundary(ref);
    _readProvider(ref, activeConversationProvider.notifier).clear();
    _readProvider(ref, chatMessagesProvider.notifier).clearMessages();
  }
  _drainLibreChat(ref);
}

/// Whether [conversationId] names a LibreChat chat: by its scoped id, or by
/// the listed or open chat it names.
bool _libreChatSelection(dynamic ref, String conversationId) {
  if (_isLibreChatSelection(
    conversationId,
    _listedConversationForSelection(ref, conversationId),
  )) {
    return true;
  }
  final active = _readProvider(ref, activeConversationProvider);
  return _activeConversationMatchesSelection(active, conversationId) &&
      isLibreChatConversation(active);
}

/// Writes a share id the LibreChat server reported to its chat's row, and
/// to the listed and open chat. A server-side fact, so nothing is queued.
///
/// [onlyIf], when given, is asked with the share id the row holds, under the
/// chat's lock; nothing is written when it says no. Returns whether the
/// share id was written.
///
/// [db] is the database of the account that asked the server: the answer
/// is that account's, written there and shown only while it is in use.
Future<bool> _setLibreChatShareId(
  dynamic ref,
  AppDatabase db,
  String conversationId,
  String? shareId, {
  bool Function(String? stored)? onlyIf,
}) async {
  final rawId = ChatStorageIdentity.parse(conversationId).rawId;
  final written = await _writeLibreChatChat(ref, db, rawId, () async {
    if (onlyIf != null &&
        !onlyIf((await db.chatsDao.getChat(rawId))?.shareId)) {
      return false;
    }
    await (db.update(db.chats)..where((t) => t.id.equals(rawId))).write(
      ChatsCompanion(shareId: Value(shareId)),
    );
    return true;
  });
  if (!written || !_libreChatDatabaseIsCurrent(ref, db)) return written;
  _readProvider(ref, conversationsProvider.notifier).updateConversationFromRemote(
    conversationId,
    (Conversation conversation) => conversation.copyWith(shareId: shareId),
  );
  final active = _readProvider(ref, activeConversationProvider);
  if (_activeConversationMatchesSelection(active, conversationId)) {
    _readProvider(
      ref,
      activeConversationProvider.notifier,
    ).set(active!.copyWith(shareId: shareId));
  }
  return true;
}

/// A shared chat's public link and its share id.
typedef ChatShareLink = ({String shareId, String url});

/// Shares [conversationId] and returns its public link: a new share, or the
/// existing one re-snapshotted so the link shows the chat as it is now.
///
/// Open WebUI chats share at `/s/{id}` on their server; LibreChat chats at
/// `/share/{id}` under the base their web app is served from.
Future<ChatShareLink> shareConversationLink(
  dynamic ref,
  String conversationId,
) async {
  if (_libreChatSelection(ref, conversationId)) {
    return _shareLibreChatConversation(ref, conversationId);
  }
  final api = _readProvider(ref, apiServiceProvider);
  if (api == null) throw StateError('API service not available');
  final shareId = await shareConversation(ref, conversationId);
  if (shareId == null || shareId.isEmpty) {
    throw StateError('Server did not return a share ID');
  }
  return (
    shareId: shareId,
    url: buildChatShareUrl(serverUrl: api.baseUrl, shareId: shareId),
  );
}

Future<ChatShareLink> _shareLibreChatConversation(
  dynamic ref,
  String conversationId,
) async {
  final api =
      _readProvider(ref, libreChatApiServiceProvider) ??
      (throw StateError('The LibreChat account is not signed in.'));
  final account =
      _readProvider(ref, activeLibreChatAccountProvider) ??
      (throw StateError('The LibreChat account is not signed in.'));
  final rawId = ChatStorageIdentity.parse(conversationId).rawId;
  final db = _libreChatDatabaseFor(ref);
  return _holdingLibreChatDatabase(ref, db, () async {
    final stored = await db.chatsDao.getChat(rawId);
    final existing = await api.sharedLink(rawId);
    // Only a link the chat already shows is snapshotted again. One made
    // elsewhere (LibreChat's web app, another device) is handed out as it
    // is, since updating it would show its recipients newer messages
    // unasked. Updated, it keeps sharing the chat's files or not, as it was
    // made.
    final shareId = existing == null
        ? await api.createSharedLink(rawId)
        : existing.shareId == stored?.shareId
        ? await api.refreshSharedLink(
            existing.shareId,
            snapshotFiles: existing.snapshotFiles,
          )
        : existing.shareId;
    await _setLibreChatShareId(ref, db, conversationId, shareId);
    return (
      shareId: shareId,
      url: buildLibreChatShareUrl(
        baseUrl: account.server.baseUrl,
        shareId: shareId,
      ),
    );
  });
}

/// Asks LibreChat whether chat [conversationId] has a share link, without
/// publishing anything, and records the answer on the chat. LibreChat's
/// conversation does not carry its link, so one made elsewhere is only known
/// once asked for. Returns the link's share id, or null when it has none.
///
/// With [timeout], it gives up on a server that has not answered by then,
/// and an answer that comes later is dropped: whoever asked has shown the
/// chat without it, and copying must not update a link it never showed.
Future<String?> lookUpLibreChatShareLink(
  dynamic ref,
  String conversationId, {
  Duration? timeout,
}) async {
  final api =
      _readProvider(ref, libreChatApiServiceProvider) ??
      (throw StateError('The LibreChat account is not signed in.'));
  final rawId = ChatStorageIdentity.parse(conversationId).rawId;
  final db = _libreChatDatabaseFor(ref);
  return _holdingLibreChatDatabase(ref, db, () async {
    final known = (await db.chatsDao.getChat(rawId))?.shareId;
    final request = api.sharedLinkId(rawId);
    final shareId = await (timeout == null
        ? request
        : request.timeout(timeout));
    // A link made or deleted while this asked is newer than its answer,
    // which is then dropped for what the chat has now.
    if (await _setLibreChatShareId(
      ref,
      db,
      conversationId,
      shareId,
      onlyIf: (stored) => stored == known,
    )) {
      return shareId;
    }
    return (await db.chatsDao.getChat(rawId))?.shareId;
  });
}

/// Deletes [conversationId]'s share link, from Open WebUI or LibreChat.
Future<void> deleteConversationShareLink(
  dynamic ref,
  String conversationId,
) async {
  if (!_libreChatSelection(ref, conversationId)) {
    return deleteSharedConversation(ref, conversationId);
  }
  final api =
      _readProvider(ref, libreChatApiServiceProvider) ??
      (throw StateError('The LibreChat account is not signed in.'));
  final rawId = ChatStorageIdentity.parse(conversationId).rawId;
  final db = _libreChatDatabaseFor(ref);
  await _holdingLibreChatDatabase(ref, db, () async {
    final shareId = await api.sharedLinkId(rawId);
    if (shareId != null) await api.deleteSharedLink(shareId);
    await _setLibreChatShareId(ref, db, conversationId, null);
  });
}

/// Copies LibreChat chat [conversationId] into a new chat on the server --
/// up to [upToMessageId] (a branch) or whole (a duplicate) -- stores the
/// copy in the account's database and returns it, ready to open.
Future<Conversation> copyLibreChatConversation(
  dynamic ref,
  String conversationId, {
  String? upToMessageId,
}) async {
  final api =
      _readProvider(ref, libreChatApiServiceProvider) ??
      (throw StateError('The LibreChat account is not signed in.'));
  final engine =
      _readProvider(ref, libreChatSyncEngineProvider) ??
      (throw StateError('The LibreChat account is not signed in.'));
  final rawId = ChatStorageIdentity.parse(conversationId).rawId;
  final copy = await _holdingLibreChatDatabase(ref, engine.db, () async {
    final copy = upToMessageId == null
        ? await api.duplicate(rawId)
        : await api.fork(rawId, messageId: upToMessageId);
    await engine.storeFetched(copy.conversation, copy.messages);
    return copy;
  });
  final now = DateTime.now();
  return withChatStorageProvenance(
    stampLibreChatProvenance(
      Conversation(
        id: copy.conversation.conversationId,
        title: copy.conversation.title,
        createdAt: copy.conversation.createdAt?.toLocal() ?? now,
        updatedAt: copy.conversation.updatedAt?.toLocal() ?? now,
      ),
    ),
    ChatStorageKind.libreChat,
  );
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
  if (_isLibreChatSelection(conversationId, localConversation)) {
    await _writeLibreChatEnvelope(ref, conversationId, pinned: pinned);
    return;
  }
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

/// Marks an Open WebUI chat unread, as the web sidebar's "Mark as unread"
/// does. The dot shows at once; if the server refuses, the earlier read time
/// comes back unless the chat was read again meanwhile.
Future<void> markConversationUnread(dynamic ref, String conversationId) async {
  final identity = ChatStorageIdentity.parse(conversationId);
  final rawId = identity.rawId;
  final localConversation = _listedConversationForSelection(
    ref,
    conversationId,
  );
  if (identity.storage == ChatStorageKind.directLocal ||
      isDirectLocalConversation(localConversation)) {
    throw StateError('On-device chats have no server read state.');
  }
  final api = _readProvider(ref, apiServiceProvider);
  if (api == null) throw Exception('No API service available');
  // Held for the whole request: a late answer must settle the account the
  // chat was marked in, not whichever one is active by then. The lease keeps
  // that database open through an account switch until it has.
  final db = _readProvider(ref, appDatabaseProvider);
  if (db == null) throw StateError('No chat database for this account.');
  // Read before the first await: the caller's ref may be disposed by then.
  final conversations = _readProvider(ref, conversationsProvider.notifier);
  final lease = _readProvider(
    ref,
    databaseManagerProvider,
  ).tryAcquireLease(db);
  try {
    final previous = await db.chatsDao.markUnread(rawId);
    // Every stored mark reaches finishUnread, or later lists stay blocked
    // from this chat's read state.
    var refused = true;
    try {
      conversations
        ..showConversationUnread(conversationId)
        ..refreshFolderConversations();
      await api.markConversationUnread(rawId);
      refused = false;
    } catch (e) {
      DebugLogger.log(
        'Error marking conversation unread: $e',
        scope: 'chat/providers',
      );
      rethrow;
    } finally {
      try {
        await db.chatsDao.finishUnread(
          rawId,
          refused: refused,
          previous: previous,
        );
        if (refused) conversations.refreshFolderConversations();
      } catch (error, stackTrace) {
        DebugLogger.error(
          'unread-finish-failed',
          scope: 'chat/providers',
          error: error,
          stackTrace: stackTrace,
          data: {'id': rawId},
        );
      }
    }
  } finally {
    await lease?.release();
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

  if (_isLibreChatSelection(conversationId, listedConversation)) {
    await _writeLibreChatEnvelope(ref, conversationId, archived: archived);
    return;
  }
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

  // The open chat stays on screen until the server takes the archive: a
  // refused one leaves it as it was, picks and all, with nothing to put back,
  // and no blank composer stands in for it meanwhile. Another chat opened or
  // started meanwhile, with picks of its own, is left alone, and so is the
  // same chat opened under another account or server.
  final ChatMutationOwnerToken? archivedOwner = leavingActiveConversation
      ? captureChatMutationOwner(ref, activeConversation)
      : null;
  bool archivedChatStillShown() =>
      archivedOwner != null && chatMutationTokenStillActive(ref, archivedOwner);

  try {
    if (api == null) throw Exception('No API service available');

    await api.archiveConversation(rawId, archived);

    // The chat is gone for good: it leaves the screen and its picks start
    // again, unless the user has moved on meanwhile.
    if (leavingActiveConversation && archivedChatStillShown()) {
      clearSelectedFiltersForConversationBoundary(ref);
      _readProvider(ref, activeConversationProvider.notifier).clear();
      _readProvider(ref, chatMessagesProvider.notifier).clearMessages();
    }

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
    rethrow;
  }
}

// Share conversation
Future<String?> shareConversation(dynamic ref, String conversationId) async {
  _requireNotLibreChat(conversationId);
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
  _requireNotLibreChat(conversationId);
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
  _requireNotLibreChat(conversationId);
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
