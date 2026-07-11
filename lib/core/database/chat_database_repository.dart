import 'dart:async';

import '../models/conversation.dart';
import 'app_database.dart';
import 'daos/chats_dao.dart';
import 'daos/search_dao.dart';
import 'mappers/chat_blob_mapper.dart';
import 'mappers/conversation_assembler.dart';

/// The database that owns a chat.
///
/// Keeping provenance beside list/search results is important because a
/// direct-local chat id can legally collide with an Open WebUI chat id.
enum ChatStorageKind { openWebUi, directLocal }

/// A conversation selection that retains both its externally meaningful raw
/// id and, when known, the database that owns it.
///
/// [scopedId] is deliberately an app-internal transport value. It is safe to
/// use as a Riverpod family argument or widget key, but callers must use
/// [rawId] for database and network operations.
class ChatStorageIdentity {
  const ChatStorageIdentity({required this.rawId, this.storage});

  final String rawId;
  final ChatStorageKind? storage;

  static const String _prefix = 'conduit-chat://';

  factory ChatStorageIdentity.parse(String value) {
    if (!value.startsWith(_prefix)) {
      return ChatStorageIdentity(rawId: value);
    }

    final remainder = value.substring(_prefix.length);
    final separator = remainder.indexOf('/');
    if (separator <= 0 || separator == remainder.length - 1) {
      return ChatStorageIdentity(rawId: value);
    }
    final storageName = remainder.substring(0, separator);
    ChatStorageKind? storage;
    for (final candidate in ChatStorageKind.values) {
      if (candidate.name == storageName) {
        storage = candidate;
        break;
      }
    }
    if (storage == null) {
      return ChatStorageIdentity(rawId: value);
    }

    try {
      return ChatStorageIdentity(
        rawId: Uri.decodeComponent(remainder.substring(separator + 1)),
        storage: storage,
      );
    } on FormatException {
      return ChatStorageIdentity(rawId: value);
    }
  }

  String get scopedId {
    final owner = storage;
    if (owner == null) return rawId;
    return '$_prefix${owner.name}/${Uri.encodeComponent(rawId)}';
  }
}

/// Reserved [Conversation.metadata] key carrying storage provenance through
/// existing providers and widgets that traffic only in Conversation.
const String kChatStorageKindMetadataKey = 'conduit.chatStorageKind';

/// Returns a copy annotated with its owning chat store. Existing metadata is
/// preserved verbatim.
Conversation annotateConversationStorage(
  Conversation conversation,
  ChatStorageKind storage,
) {
  return conversation.copyWith(
    metadata: <String, dynamic>{
      ...conversation.metadata,
      kChatStorageKindMetadataKey: storage.name,
    },
  );
}

/// Reads storage provenance previously written by
/// [annotateConversationStorage]. Unknown values remain unclaimed so a caller
/// can safely fall back to [ChatDatabaseRepository.resolveChat].
ChatStorageKind? chatStorageFromConversation(Conversation conversation) {
  final value = conversation.metadata[kChatStorageKindMetadataKey];
  for (final storage in ChatStorageKind.values) {
    if (value == storage.name) return storage;
  }
  return null;
}

/// Where a newly-created direct-provider chat should be persisted.
enum DirectChatSyncPreference {
  /// The chat never enters the Open WebUI outbox.
  localOnly,

  /// Use the active Open WebUI database when one exists, otherwise fall back
  /// to the always-available direct-local database.
  syncWithOpenWebUiWhenAvailable,
}

/// A database together with the provenance callers must retain for later
/// reads and writes.
class ChatDatabaseLocation {
  const ChatDatabaseLocation({required this.storage, required this.database});

  final ChatStorageKind storage;
  final AppDatabase database;

  bool get isLocalOnly => storage == ChatStorageKind.directLocal;
}

/// A narrow conversation-list row annotated with its owning database.
class LocatedChatListEntry {
  const LocatedChatListEntry({required this.storage, required this.entry});

  final ChatStorageKind storage;
  final ChatListEntry entry;

  /// Collision-free identity for UI keys and selections.
  String get scopedId =>
      ChatStorageIdentity(rawId: entry.id, storage: storage).scopedId;

  /// Maps the narrow row into the existing Conversation summary shape while
  /// retaining database provenance in metadata.
  Conversation toConversation() =>
      annotateConversationStorage(conversationFromListEntry(entry), storage);
}

/// A full conversation annotated with its owning database.
class LocatedConversation {
  const LocatedConversation({
    required this.location,
    required this.conversation,
  });

  final ChatDatabaseLocation location;
  final Conversation conversation;

  /// Ensures provenance is present even for wrappers constructed outside the
  /// repository.
  Conversation get withStorageMetadata =>
      annotateConversationStorage(conversation, location.storage);
}

/// A full-text-search hit annotated with its owning database.
class LocatedSearchHit {
  const LocatedSearchHit({required this.storage, required this.hit});

  final ChatStorageKind storage;
  final SearchHit hit;

  String get scopedId =>
      ChatStorageIdentity(rawId: hit.chatId, storage: storage).scopedId;

  Conversation toConversation() =>
      annotateConversationStorage(conversationFromSearchHit(hit), storage);
}

/// Raised when an unscoped chat id exists in both databases.
///
/// Callers navigating from [LocatedChatListEntry] should always pass its
/// [LocatedChatListEntry.storage], which makes resolution deterministic.
class AmbiguousChatStorageException implements Exception {
  const AmbiguousChatStorageException(this.chatId);

  final String chatId;

  @override
  String toString() =>
      'AmbiguousChatStorageException: "$chatId" exists in both chat stores';
}

/// Resolves, loads, searches, and writes chats across the active Open WebUI
/// database and the permanent direct-local database.
///
/// This repository deliberately does not own either database lifecycle. The
/// Riverpod providers in `database_provider.dart` supply the currently active
/// Open WebUI database (which may be absent) and the independently-lived local
/// direct database.
class ChatDatabaseRepository {
  ChatDatabaseRepository({
    required AppDatabase? openWebUiDatabase,
    required AppDatabase directLocalDatabase,
  }) : _openWebUiDatabase = openWebUiDatabase,
       _directLocalDatabase = directLocalDatabase;

  final AppDatabase? _openWebUiDatabase;
  final AppDatabase _directLocalDatabase;

  bool get hasOpenWebUiDatabase => _openWebUiDatabase != null;

  ChatDatabaseLocation get directLocalLocation => ChatDatabaseLocation(
    storage: ChatStorageKind.directLocal,
    database: _directLocalDatabase,
  );

  ChatDatabaseLocation? get openWebUiLocation {
    final database = _openWebUiDatabase;
    if (database == null) return null;
    return ChatDatabaseLocation(
      storage: ChatStorageKind.openWebUi,
      database: database,
    );
  }

  /// Returns the requested store, throwing only when Open WebUI storage was
  /// explicitly requested while no Open WebUI server is active.
  ChatDatabaseLocation locationFor(ChatStorageKind storage) {
    switch (storage) {
      case ChatStorageKind.directLocal:
        return directLocalLocation;
      case ChatStorageKind.openWebUi:
        return openWebUiLocation ??
            (throw StateError('No active Open WebUI chat database'));
    }
  }

  /// Chooses storage for a new direct-provider chat. A missing backend never
  /// prevents chat creation: the sync preference degrades to local storage.
  ChatDatabaseLocation chooseForNewDirectChat(
    DirectChatSyncPreference preference,
  ) {
    return switch (preference) {
      DirectChatSyncPreference.localOnly => directLocalLocation,
      DirectChatSyncPreference.syncWithOpenWebUiWhenAvailable =>
        openWebUiLocation ?? directLocalLocation,
    };
  }

  /// Resolves a chat id to its owner. Supply [preferred] whenever provenance
  /// came from a list/search result. Without it, both stores are probed and a
  /// collision is reported rather than silently opening the wrong chat.
  Future<ChatDatabaseLocation?> resolveChat(
    String chatId, {
    ChatStorageKind? preferred,
  }) async {
    if (preferred != null) {
      final location = _locationForOrNull(preferred);
      if (location == null) return null;
      final row = await location.database.chatsDao.getChat(chatId);
      return row == null ? null : location;
    }

    final server = _openWebUiDatabase;
    final localFuture = _directLocalDatabase.chatsDao.getChat(chatId);
    if (server == null) {
      final local = await localFuture;
      return local == null ? null : directLocalLocation;
    }

    final rows = await Future.wait([
      server.chatsDao.getChat(chatId),
      localFuture,
    ]);
    final hasServer = rows[0] != null;
    final hasLocal = rows[1] != null;
    if (hasServer && hasLocal) {
      throw AmbiguousChatStorageException(chatId);
    }
    if (hasServer) return openWebUiLocation;
    if (hasLocal) return directLocalLocation;
    return null;
  }

  /// Loads and assembles a full local conversation from the correct store.
  /// Returns null for a missing row or a server envelope whose body has not
  /// been materialized yet, allowing the caller to use its network fallback.
  Future<LocatedConversation?> loadConversation(
    String chatId, {
    ChatStorageKind? preferred,
    ConversationParseOffload? offload,
  }) async {
    final location = await resolveChat(chatId, preferred: preferred);
    if (location == null) return null;

    final chat = await location.database.chatsDao.getChat(chatId);
    if (chat == null || !chat.bodySynced) return null;
    final messages = await location.database.messagesDao.getForChat(chatId);
    final conversation = await assembleConversationGuarded(
      chat,
      messages,
      offload: offload,
    );
    return LocatedConversation(
      location: location,
      conversation: annotateConversationStorage(conversation, location.storage),
    );
  }

  /// Watches both narrow chat-list projections and emits one globally sorted
  /// list. No message body is selected by this path.
  Stream<List<LocatedChatListEntry>> watchMergedChatList() {
    final local = _directLocalDatabase.chatsDao.watchChatList();
    final server = _openWebUiDatabase;
    if (server == null) {
      return local.map(
        (entries) => List.unmodifiable(
          _locatedList(ChatStorageKind.directLocal, entries),
        ),
      );
    }

    return _combineChatLists(server.chatsDao.watchChatList(), local);
  }

  /// Searches both stores, merges by FTS relevance, then applies one global
  /// offset/limit. The local FTS index is built lazily because this database
  /// has no server-sync cycle to trigger the normal post-first-sync gate.
  Future<List<LocatedSearchHit>> searchMergedChats(
    String raw, {
    int limit = 50,
    int offset = 0,
  }) async {
    if (limit <= 0) return const [];
    final normalizedOffset = offset < 0 ? 0 : offset;
    final sourceLimit = normalizedOffset + limit;

    await _directLocalDatabase.buildFtsIfNeeded();
    final server = _openWebUiDatabase;
    final searches = <Future<List<SearchHit>>>[
      if (server != null)
        server.searchDao.search(raw, limit: sourceLimit, offset: 0),
      _directLocalDatabase.searchDao.search(raw, limit: sourceLimit, offset: 0),
    ];
    final results = await Future.wait(searches);
    final merged = <LocatedSearchHit>[];
    var resultIndex = 0;
    if (server != null) {
      merged.addAll(
        results[resultIndex++].map(
          (hit) =>
              LocatedSearchHit(storage: ChatStorageKind.openWebUi, hit: hit),
        ),
      );
    }
    merged.addAll(
      results[resultIndex].map(
        (hit) =>
            LocatedSearchHit(storage: ChatStorageKind.directLocal, hit: hit),
      ),
    );
    merged.sort(_compareSearchHits);
    return merged.skip(normalizedOffset).take(limit).toList(growable: false);
  }

  /// Searches one explicitly selected store. Online search uses this for the
  /// direct-local store because Open WebUI already supplies its own ranked
  /// server results; applying a merged local top-N first could otherwise let
  /// cached server rows consume the entire budget before any on-device hit is
  /// considered.
  Future<List<LocatedSearchHit>> searchChatsInStorage(
    String raw, {
    required ChatStorageKind storage,
    int limit = 50,
    int offset = 0,
  }) async {
    if (limit <= 0) return const [];
    final normalizedOffset = offset < 0 ? 0 : offset;
    final location = _locationForOrNull(storage);
    if (location == null) return const [];
    if (storage == ChatStorageKind.directLocal) {
      await _directLocalDatabase.buildFtsIfNeeded();
    }
    final hits = await location.database.searchDao.search(
      raw,
      limit: limit,
      offset: normalizedOffset,
    );
    return hits
        .map((hit) => LocatedSearchHit(storage: storage, hit: hit))
        .toList(growable: false);
  }

  /// Persists a newly-created direct-provider chat. Local-only storage stays
  /// clean and enqueue-free. Open WebUI storage queues only a `createChat`
  /// sync operation; it never queues `requestCompletion`, because the direct
  /// provider already performed the completion.
  Future<void> persistNewDirectChat(
    ChatDatabaseLocation location,
    ChatRows rows, {
    String? openWebUiContentHash,
  }) {
    switch (location.storage) {
      case ChatStorageKind.directLocal:
        return location.database.chatsDao.upsertLocalOnlyChat(rows: rows);
      case ChatStorageKind.openWebUi:
        if (openWebUiContentHash == null || openWebUiContentHash.isEmpty) {
          throw ArgumentError.value(
            openWebUiContentHash,
            'openWebUiContentHash',
            'is required when a new direct chat will sync to Open WebUI',
          );
        }
        return location.database.chatsDao.insertLocalChatWithCreateOp(
          chat: rows.chat,
          messages: rows.messages,
          blobRows: rows,
          contentHash: openWebUiContentHash,
        );
    }
  }

  /// Persists messages produced by a direct-provider request. The Open WebUI
  /// path queues an ordinary chat update but explicitly never queues a
  /// completion request; the local path creates no outbox work at all.
  Future<void> persistDirectMessages(
    ChatDatabaseLocation location, {
    required String chatId,
    required List<MessageRowData> messages,
    String? currentMessageId,
    int? updatedAt,
  }) {
    switch (location.storage) {
      case ChatStorageKind.directLocal:
        return location.database.chatsDao.appendLocalOnlyMessages(
          chatId: chatId,
          messages: messages,
          currentMessageId: currentMessageId,
          updatedAt: updatedAt,
        );
      case ChatStorageKind.openWebUi:
        return location.database.chatsDao.appendMessagesWithUpdateOp(
          chatId: chatId,
          messages: messages,
          currentMessageId: currentMessageId,
          updatedAt: updatedAt,
          enqueueUpdate: true,
          enqueueCompletion: false,
        );
    }
  }

  /// Resolves the current owner of a direct assistant placeholder after a
  /// possible Open WebUI `local:` -> server-id remap. This durable lookup closes
  /// the event-subscription race: the message row is rewritten atomically with
  /// its chat even if the in-memory remap event was emitted before a listener
  /// attached.
  Future<String?> resolveCurrentChatIdForMessage(
    ChatDatabaseLocation location, {
    required String recordedChatId,
    required String messageId,
  }) async {
    final recorded = await location.database.messagesDao.getMessage(
      recordedChatId,
      messageId,
    );
    if (recorded != null) return recordedChatId;

    final candidates = await location.database.messagesDao.getChatIdsForMessage(
      messageId,
    );
    return candidates.length == 1 ? candidates.single : null;
  }

  ChatDatabaseLocation? _locationForOrNull(ChatStorageKind storage) {
    return switch (storage) {
      ChatStorageKind.openWebUi => openWebUiLocation,
      ChatStorageKind.directLocal => directLocalLocation,
    };
  }
}

List<LocatedChatListEntry> _locatedList(
  ChatStorageKind storage,
  List<ChatListEntry> entries,
) {
  return [
    for (final entry in entries)
      LocatedChatListEntry(storage: storage, entry: entry),
  ];
}

Stream<List<LocatedChatListEntry>> _combineChatLists(
  Stream<List<ChatListEntry>> serverStream,
  Stream<List<ChatListEntry>> localStream,
) {
  late StreamController<List<LocatedChatListEntry>> controller;
  StreamSubscription<List<ChatListEntry>>? serverSubscription;
  StreamSubscription<List<ChatListEntry>>? localSubscription;
  List<ChatListEntry>? serverEntries;
  List<ChatListEntry>? localEntries;

  void emitIfReady() {
    final currentServer = serverEntries;
    final currentLocal = localEntries;
    if (currentServer == null || currentLocal == null || controller.isClosed) {
      return;
    }
    final merged = <LocatedChatListEntry>[
      ..._locatedList(ChatStorageKind.openWebUi, currentServer),
      ..._locatedList(ChatStorageKind.directLocal, currentLocal),
    ]..sort(_compareListEntries);
    controller.add(List.unmodifiable(merged));
  }

  controller = StreamController<List<LocatedChatListEntry>>(
    onListen: () {
      serverSubscription = serverStream.listen((entries) {
        serverEntries = entries;
        emitIfReady();
      }, onError: controller.addError);
      localSubscription = localStream.listen((entries) {
        localEntries = entries;
        emitIfReady();
      }, onError: controller.addError);
    },
    onCancel: () async {
      await serverSubscription?.cancel();
      await localSubscription?.cancel();
    },
  );
  return controller.stream;
}

int _compareListEntries(LocatedChatListEntry a, LocatedChatListEntry b) {
  final updated = b.entry.updatedAt.compareTo(a.entry.updatedAt);
  if (updated != 0) return updated;
  final id = a.entry.id.compareTo(b.entry.id);
  if (id != 0) return id;
  return a.storage.index.compareTo(b.storage.index);
}

int _compareSearchHits(LocatedSearchHit a, LocatedSearchHit b) {
  final rank = a.hit.rank.compareTo(b.hit.rank);
  if (rank != 0) return rank;
  final updated = b.hit.updatedAt.compareTo(a.hit.updatedAt);
  if (updated != 0) return updated;
  final id = a.hit.chatId.compareTo(b.hit.chatId);
  if (id != 0) return id;
  return a.storage.index.compareTo(b.storage.index);
}
