import 'dart:async';

import 'package:conduit_core/models/chat_message.dart' as core;
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    as mutations;
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart'
    show currentUserProvider2;
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/host_ports.dart'
    show connectivityPortProvider;
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/conversation_parsing.dart'
    show kMessageRatingMetadataKey;
import 'package:conduit_core/sync/id_remapper.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/utils/usage_summary.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';
import 'message_blocks.dart';
import 'settled.dart';
import 'temporary_chats.dart';
import 'hermes_service.dart';

/// [conversation] as the windows list it, for the account whose signed-in
/// user is [currentUserId].
///
/// Another user's chat, reached through a folder shared with this account,
/// is read-only, as the core decides it for a phone
/// ([isReadOnlySharedConversation]): the server refuses every write to it.
ChatSummary chatSummaryOf(
  Conversation conversation, {
  required String? currentUserId,
}) => ChatSummary(
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
  readOnly: isReadOnlySharedConversation(conversation, currentUserId),
);

/// [folder] as the sidebar shows it, with whose it is when it is another
/// user's folder shared with this account (issue #710), and whether chats
/// may be put in it ([Folder.canWrite]).
FolderSummary folderSummaryOf(Folder folder) => FolderSummary(
  id: folder.id,
  name: folder.name,
  parentId: folder.parentId,
  expanded: folder.isExpanded,
  shared: folder.shared,
  ownerName: folder.shared ? folder.ownerName : null,
  canWrite: folder.canWrite,
);

/// [rootId] and every folder under it, at any depth: what deleting it
/// deletes on the server. A parent cycle, which a half-applied sync can
/// briefly produce, ends the walk rather than looping.
Set<String> folderSubtree(List<FolderSummary> folders, String rootId) {
  final subtree = <String>{rootId};
  var grew = true;
  while (grew) {
    grew = false;
    for (final folder in folders) {
      final parent = folder.parentId;
      if (parent != null &&
          subtree.contains(parent) &&
          subtree.add(folder.id)) {
        grew = true;
      }
    }
  }
  return subtree;
}

/// [chats] as `chats.folder` lists the folder [folderId]: each in it (the
/// server's shared-chats route does not always name the folder) and, when
/// it is another user's, read-only.
List<ChatSummary> folderChatSummaries(
  Iterable<Conversation> chats, {
  required String folderId,
  required String? currentUserId,
}) => <ChatSummary>[
  for (final chat in chats)
    chatSummaryOf(
      chat.folderId == null ? chat.copyWith(folderId: folderId) : chat,
      currentUserId: currentUserId,
    ),
];

/// Implements `chats.*` over the core's conversation providers.
///
/// Reads `conversationsProvider` rather than the DAO directly. That provider
/// is what merges the Open WebUI chats with the direct-local ones, applies
/// the archived/pinned ordering and owns the paging cursor -- reimplementing
/// any of that here would give the desktop a list that disagrees with the
/// mobile app's for the same account.
final class ChatsService {
  ChatsService(
    this._container, {
    EventBus? events,
    DateTime Function()? now,
    TemporaryChats? temporary,
    HermesService? hermes,
    MessageBlocks? blocks,
  }) : _events = events,
       _hermes = hermes,
       blocks = blocks ?? MessageBlocks(),
       _now = now ?? DateTime.now,
       _temporary = temporary ?? TemporaryChats() {
    if (events != null) {
      _announceListChanges();
      _announceSync();
      _announceConnectivity();
      _announceRemaps();
    }
  }

  /// Hermes sessions, which open as chats.
  final HermesService? _hermes;

  /// Each assistant message's display blocks, kept between `chats.get`s.
  final MessageBlocks blocks;

  /// Whether this computer has a network at all, as the port last said.
  bool _online = true;

  /// The sync engine's state, as the protocol carries it.
  SyncState syncState() => _describe(_container.read(syncEngineProvider));

  SyncState _describe(SyncStatus status) => SyncState(
    running: status.phase == SyncPhase.running,
    progress: status.progress,
    everCompleted: status.lastSuccessUpdatedAtWatermark != null,
    lastError: status.lastError,
    online: _online,
  );

  /// Republishes `sync.status` when the network comes or goes, so
  /// a window can say it is offline rather than letting a send fail.
  void _announceConnectivity() {
    final port = _container.read(connectivityPortProvider);
    void apply(bool online) {
      if (online == _online) return;
      _online = online;
      _events?.emit(ConduitEventSpecs.syncStatus, syncState());
    }

    unawaited(port.hasNetworkInterface().then(apply, onError: (Object _) {}));
    _connectivity = port.onChanged.listen(apply);
  }

  StreamSubscription<bool>? _connectivity;

  /// Stops listening to the network port.
  void dispose() {
    unawaited(_connectivity?.cancel());
    unawaited(_remaps?.cancel());
  }

  StreamSubscription<RemapEvent>? _remaps;

  /// Publishes `route.remap` when a chat made here gets its server id,
  /// so a window showing the `local:` chat follows it instead of losing it.
  void _announceRemaps() {
    _remaps = _container
        .read(syncEngineProvider.notifier)
        .remapEvents
        .where((event) => event.entityKind == 'chat')
        .listen((event) {
          _events?.emit(
            ConduitEventSpecs.routeRemap,
            RouteRemap(fromId: event.fromId, toId: event.toId),
          );
        });
  }

  /// Publishes `sync.status` when a cycle starts or ends, and on progress
  /// in steps a person would notice.
  ///
  /// Declared in the protocol from the start and long never sent. It matters
  /// because a list answered from the database can be ahead of the search
  /// index: a sync that writes message bodies changes the index without
  /// changing the list, so nothing told a search typed during the first sync
  /// to look again. It sat on "Still syncing" with no results indefinitely.
  void _announceSync() {
    var last = syncState();
    _container.listen<SyncStatus>(syncEngineProvider, (_, next) {
      final now = _describe(next);
      final progressed =
          ((now.progress ?? 0) - (last.progress ?? 0)).abs() >= 0.05;
      if (now.running == last.running &&
          now.everCompleted == last.everCompleted &&
          now.lastError == last.lastError &&
          !progressed) {
        return;
      }
      last = now;
      _events?.emit(ConduitEventSpecs.syncStatus, now);
    });
  }

  /// Publishes `chats.changed` whenever the list itself changes.
  ///
  /// Keyed on the projection rather than on whatever caused the change.
  /// Rows arrive from the post-sign-in sync, a list-prompted pull, a turn's
  /// snapshot pull, or another device, and announcing only the pulls this
  /// class started is what left a fresh install on "No conversations yet":
  /// the sync that followed sign-in filled the database and nothing said
  /// so. `conversationsProvider` already drops emissions identical to the
  /// last one, so a change here is a real change.
  ///
  /// Debounced. An initial sync writes rows in batches, and one refetch per
  /// batch would have every window list two hundred conversations a dozen
  /// times in a row.
  void _announceListChanges() {
    Timer? pending;
    _container.listen<AsyncValue<List<Conversation>>>(conversationsProvider, (
      previous,
      next,
    ) {
      if (!next.hasValue || identical(previous?.value, next.value)) return;
      pending?.cancel();
      pending = Timer(const Duration(milliseconds: 250), () {
        _events?.emit(ConduitEventSpecs.chatsChanged, const ChatsChanged());
      });
    });
  }

  final ProviderContainer _container;

  /// Where a background refresh announces that it landed. Optional so a test
  /// that only reads the list does not have to build one.
  final EventBus? _events;
  final DateTime Function() _now;

  /// The same memory `TurnsService` writes temporary conversations to.
  final TemporaryChats _temporary;

  Conversations get _conversations =>
      _container.read(conversationsProvider.notifier);

  /// The conversation list, as the local database has it right now.
  ///
  /// `conversationsProvider` projects the *local database*, which only holds
  /// what the sync engine has pulled. On mobile the pull is driven by
  /// `syncTriggers`. The sidecar has no equivalent, so a list call is what
  /// prompts one.
  ///
  /// Prompts, but does not wait for it. This used to await a full pull on
  /// every call, which takes seconds with a couple of hundred conversations.
  /// The renderer refetches on every `chats.changed`, and each refetch
  /// discarded the one still in flight. During an active conversation the
  /// events arrived faster than a pull finished, so the sidebar could go a
  /// whole session without updating: the chat you were in was never at the
  /// top and never highlighted. Now the database answers at once. If the pull
  /// changes the list, the projection listener publishes another
  /// `chats.changed`.
  Future<ChatList> list() async {
    _refreshInBackground();
    final conversations = await readSettled(
      _container,
      conversationsProvider.future,
    );
    return _project(conversations, await _folders());
  }

  /// How long a list-prompted pull suppresses the next.
  ///
  /// This is what stops a loop. The pull ends by announcing `chats.changed`,
  /// the renderer answers that by listing again, and without a floor that
  /// list would pull again, forever.
  static const Duration _refreshFloor = Duration(seconds: 30);

  DateTime? _lastRefresh;
  bool _refreshing = false;

  void _refreshInBackground() {
    final now = _now();
    if (_refreshing) return;
    if (_lastRefresh case final last?
        when now.difference(last) < _refreshFloor) {
      return;
    }
    _refreshing = true;
    _lastRefresh = now;
    // No announcement of its own. If the pull changes the list, the
    // projection listener above says so, and if it changes nothing there is
    // nothing to say.
    unawaited(_pullForList());
  }

  Future<void> _pullForList() async {
    try {
      await _pull('chats.list');
      // A pull that failed, with the server out of reach, does not hold
      // back the next one. The daemon has no trigger of its own for "the
      // server is back", so the window's next list after that is what
      // catches up. Without the floor it had to wait 30 s after the failed
      // pull at launch. A failed pull changes nothing and announces nothing,
      // so this cannot loop.
      if (_lastPullFailed()) _lastRefresh = null;
    } finally {
      _refreshing = false;
    }
  }

  bool _lastPullFailed() {
    try {
      return _container.read(syncEngineProvider).lastError != null;
    } on Object {
      return false;
    }
  }

  /// The account's folders, or none.
  ///
  /// Empty rather than an error when they will not load: a server without
  /// the folders feature, or a sync that has not landed yet, should leave
  /// the sidebar a flat list, not a broken one.
  Future<List<FolderSummary>> _folders() async {
    try {
      final folders = await readSettled(_container, foldersProvider.future);
      return <FolderSummary>[
        for (final folder in folders) folderSummaryOf(folder),
      ];
    } on Object catch (error) {
      DebugLogger.error('folders-failed', scope: 'daemon/chats', error: error);
      return const <FolderSummary>[];
    }
  }

  /// Pages archived chats into the list, or out of it.
  Future<ChatList> setArchivedVisible({required bool visible}) async {
    await _conversations.setArchivedChatsVisible(visible);
    return list();
  }

  /// Asks the sync engine to catch up, and tolerates it declining.
  ///
  /// `requestPull` returns null when the engine is inert -- no database, no
  /// server, reviewer mode -- and that is a legitimate state, not an error:
  /// the local list is then simply what there is.
  Future<void> _pull(String reason) async {
    try {
      await _container
          .read(syncEngineProvider.notifier)
          .requestPull(reason: reason);
    } on Object catch (error) {
      DebugLogger.error('pull-failed', scope: 'daemon/chats', error: error);
    }
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
    // A Hermes session: its transcript is Hermes's, not the database's.
    if (hermesSessionOf(id) case final sessionId? when _hermes != null) {
      final hermes = _hermes;
      final messages = await hermes.transcript(sessionId);
      return ChatDetail(
        summary: ChatSummary(
          id: id,
          title:
              await hermes.titleOf(sessionId) ??
              (messages.isEmpty
                  ? ''
                  : messages.first.content.split('\n').first),
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
        messages: messages.map(_message).toList(growable: false),
      );
    }
    // Never in the database, so never in the list. The transcript lives
    // only in the daemon's memory. Known by membership rather than by the
    // `local:` prefix, which a direct chat awaiting its first sync to Open
    // WebUI also carries -- and that one *is* in the database.
    if (_temporary.contains(id)) {
      final messages = _temporary.transcript(id);
      return ChatDetail(
        summary: ChatSummary(
          id: id,
          title: messages.isEmpty
              ? ''
              : messages.first.content.split('\n').first,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
        messages: messages.map(_message).toList(growable: false),
      );
    }
    final conversations = await readSettled(
      _container,
      conversationsProvider.future,
    );
    // Only the pages the sidebar has loaded. A conversation further back --
    // a search hit, a `conduit://` link, a notification -- is still one to
    // open, so its absence here only means loading it without an envelope.
    final summary = conversations
        .where((candidate) => candidate.id == id)
        .firstOrNull;

    // The list carries envelopes only -- `conversationFromListEntry` builds
    // a summary with no message bodies, deliberately, because the sidebar
    // does not need them and loading 200 transcripts to draw a list would
    // be absurd. Reading `summary.messages` here therefore returned an
    // empty transcript for every conversation that was not created in this
    // session: the app could list two hundred chats and open none of them.
    //
    // `loadConversationProvider` is the loader that assembles a full
    // conversation from the database, with the network as a fallback.
    Conversation? full;
    try {
      full = await readSettled(_container, loadConversationProvider(id).future);
    } on Object catch (error, stackTrace) {
      // A transcript that will not load is worth showing the envelope for
      // rather than pretending the conversation does not exist.
      DebugLogger.error(
        'chat-load-failed',
        scope: 'daemon/chats',
        error: error,
        stackTrace: stackTrace,
        data: <String, Object?>{'id': id},
      );
    }
    final conversation = full ?? summary;
    if (conversation == null) return null;

    final prompt = conversation.systemPrompt?.trim();
    final opened = _summarize(conversation);
    return ChatDetail(
      summary: opened,
      messages: conversation.messages.map(_message).toList(growable: false),
      systemPrompt: prompt == null || prompt.isEmpty ? null : prompt,
      readOnly: opened.readOnly,
    );
  }

  /// Full-text search over titles and message bodies.
  ///
  /// Uses the database's FTS index rather than filtering the loaded page in
  /// memory: the sidebar holds one page, and a search that only looked at
  /// what is already on screen would silently miss everything older -- which
  /// is worse than no search, because it looks like it worked.
  Future<ChatSearchResults> search(ChatSearchQuery query) async {
    final trimmed = query.query.trim();
    // An empty query is not a search for everything. Returning the whole
    // history here would look like a working search and be one of the
    // slowest things the app can do.
    if (trimmed.isEmpty) return const ChatSearchResults();

    // `tag:name` is a filter, not a phrase: Open WebUI's own search box
    // reads it the same way. The server answers it, because the local list
    // deliberately does not carry each chat's tags.
    if (trimmed.toLowerCase().startsWith('tag:')) {
      return _searchByTag(trimmed.substring(4).trim(), limit: query.limit);
    }

    final database = _container.read(appDatabaseProvider);
    if (database == null) {
      // No local database yet -- the account has not been certified. Falling
      // back to a title scan of the loaded page would be worse than saying
      // nothing, because a few results look like all of them.
      return const ChatSearchResults(complete: false);
    }

    final hits = await database.searchDao.search(trimmed, limit: query.limit);
    final sync = _container.read(syncEngineProvider);
    return ChatSearchResults(
      // Incomplete until a full sync has succeeded at least once, and while
      // one is running. The watermark is only set by a successful cycle, so
      // its absence means the index has never been known complete.
      complete:
          sync.phase == SyncPhase.idle &&
          sync.lastSuccessUpdatedAtWatermark != null,
      hits: hits
          .map(
            (hit) => ChatSearchHit(
              chatId: hit.chatId,
              title: hit.title,
              // As the index produced it. Re-deriving a snippet in the UI
              // would mean reimplementing the tokenizer to agree with it.
              snippet: hit.snippet,
              // `SearchHit.updatedAt` is epoch *seconds* -- the chat rows
              // store Open WebUI's own units -- while the wire carries
              // milliseconds. Passing it through unscaled dates every result
              // to 1970.
              updatedAtMs: hit.updatedAt * 1000,
            ),
          )
          .toList(growable: false),
    );
  }

  Future<ChatSearchResults> _searchByTag(
    String name, {
    required int limit,
  }) async {
    if (name.isEmpty) return const ChatSearchResults();
    final rows = await _api.getChatsByTag(name, limit: limit);
    return ChatSearchResults(
      hits: <ChatSearchHit>[
        for (final row in rows)
          ChatSearchHit(
            chatId: '${row['id']}',
            title: '${row['title'] ?? ''}',
            // Epoch seconds from the server, like the local rows.
            updatedAtMs: ((row['updated_at'] as num?) ?? 0).toInt() * 1000,
          ),
      ],
    );
  }

  // -----------------------------------------------------------------------
  // Tags
  // -----------------------------------------------------------------------

  Future<TagList> allTags() async =>
      TagList(tags: _tagsFrom(await _api.getAllChatTags()));

  Future<TagList> addTag(ChatTagEdit edit) async {
    final name = edit.name.trim();
    // Open WebUI refuses "none" too: it is what its filter UI means by
    // "untagged".
    if (name.isEmpty || name.toLowerCase() == 'none') {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a tag needs a name, and not "none"',
      );
    }
    final tags = await _api.addChatTag(edit.chatId, name);
    await _afterEnvelopeChange(edit.chatId);
    return TagList(tags: _tagsFrom(tags));
  }

  Future<TagList> removeTag(ChatTagEdit edit) async {
    final tags = await _api.removeChatTag(edit.chatId, edit.name.trim());
    await _afterEnvelopeChange(edit.chatId);
    return TagList(tags: _tagsFrom(tags));
  }

  /// Pulls one chat after a change Open WebUI makes without moving its
  /// `updated_at` -- a tag, a share link, and (as of 0.13) a new title or
  /// folder. The incremental pull only fetches
  /// chats whose timestamp moved, so it would never look at this one; and
  /// the windows are told only afterwards, or they would refetch the old
  /// copy.
  Future<void> _afterEnvelopeChange(String chatId) async {
    try {
      await _container.read(syncEngineProvider.notifier).pullChatNow(chatId);
    } on Object catch (error) {
      DebugLogger.error(
        'envelope-pull-failed',
        scope: 'daemon/chats',
        error: error,
      );
    }
    _container.invalidate(loadConversationProvider(chatId));
    _events?.emit(ConduitEventSpecs.chatsChanged, ChatsChanged(chatId: chatId));
  }

  static List<TagDto> _tagsFrom(List<Map<String, dynamic>> rows) => <TagDto>[
    for (final row in rows)
      if (row['id'] != null)
        TagDto(id: '${row['id']}', name: '${row['name'] ?? row['id']}'),
  ];

  // -----------------------------------------------------------------------
  // Mutations
  // -----------------------------------------------------------------------
  //
  // Each writes to the server and then republishes the conversation list,
  // because `conversationsProvider` is a projection of the local database
  // and the server write does not touch it. Without the refresh the sidebar
  // keeps showing the old title until something else happens to invalidate
  // it, which reads as the rename having failed.

  //
  // A direct chat kept on this computer (`direct-local:`) is not on the
  // server: it changes in the core's direct-local database, as mobile's
  // does, and needs no Open WebUI account.

  static bool _isDirectLocal(String id) => id.startsWith('direct-local:');

  Future<ChatList> rename(String id, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a chat title must not be empty',
      );
    }
    if (_isDirectLocal(id)) {
      await mutations.renameDirectLocalConversation(_container, id, trimmed);
      return _refresh();
    }
    await _api.updateConversation(id, title: trimmed);
    await _afterEnvelopeChange(id);
    return _refresh();
  }

  Future<ChatList> setPinned(String id, {required bool value}) async {
    if (_isDirectLocal(id)) {
      await mutations.pinConversation(_container, id, value);
    } else {
      await _api.pinConversation(id, value);
    }
    return _refresh();
  }

  Future<ChatList> setArchived(String id, {required bool value}) async {
    await _archive(id, value);
    return _refresh();
  }

  Future<void> _archive(String id, bool value) => _isDirectLocal(id)
      ? mutations.archiveConversation(_container, id, value)
      : _api.archiveConversation(id, value);

  Future<ChatList> delete(String id) async {
    // Never on the server: forgetting it here is the whole delete.
    if (_temporary.contains(id)) {
      _temporary.forget(id);
      _events?.emit(ConduitEventSpecs.chatsChanged, ChatsChanged(chatId: id));
      return _refresh();
    }
    if (_isDirectLocal(id)) {
      await mutations.deleteDirectLocalConversation(_container, id);
      return _refresh();
    }
    await _api.deleteConversation(id);
    // The local row too. A pull reconciles additions and edits, but a row the
    // server no longer has is not something the next pull will mention -- so
    // without this the conversation stays in the sidebar until something
    // else happens to evict it, which reads as the delete having failed.
    _conversations.removeConversation(id);
    return _refresh();
  }

  /// Many conversations at once, one server call each -- Open
  /// WebUI has no bulk endpoints -- and one refresh at the end rather than
  /// a pull per conversation.
  ///
  /// Carries on past a failure and reports it: a conversation already
  /// deleted elsewhere is no reason to leave the other nineteen alone.
  Future<BulkChatsResult> bulk(BulkChats request) async {
    final failed = <String>[];
    for (final id in request.chatIds.toSet()) {
      try {
        switch (request.action) {
          case BulkChatAction.archive:
            await _archive(id, true);
          case BulkChatAction.unarchive:
            await _archive(id, false);
          case BulkChatAction.delete when _isDirectLocal(id):
            await mutations.deleteDirectLocalConversation(_container, id);
          case BulkChatAction.delete:
            await _api.deleteConversation(id);
            _conversations.removeConversation(id);
          case BulkChatAction.move:
            await _api.moveConversationToFolder(id, request.folderId);
            await _afterEnvelopeChange(id);
        }
      } on Object catch (error) {
        DebugLogger.error(
          'bulk-item-failed',
          scope: 'daemon/chats',
          error: error,
          data: <String, Object?>{'id': id, 'action': request.action.name},
        );
        failed.add(id);
      }
    }
    return BulkChatsResult(list: await _refresh(), failed: failed);
  }

  /// Every message on every branch, for the overview, from the
  /// local copy -- which keeps the whole tree, not just the path shown.
  Future<ChatTree> tree(String chatId) async {
    final database = _isDirectLocal(chatId)
        ? _container.read(directLocalDatabaseProvider)
        : _container.read(appDatabaseProvider);
    if (database == null) return ChatTree(chatId: chatId);
    final chat = await database.chatsDao.getChat(chatId);
    final rows = await database.messagesDao.getForChat(chatId);
    return ChatTree(
      chatId: chatId,
      currentId: chat?.currentMessageId,
      nodes: <ChatTreeNode>[
        for (final row in rows)
          ChatTreeNode(
            id: row.id,
            parentId: row.parentId,
            role: row.role,
            preview: _preview(row.content),
            // Stored as Open WebUI sends it, in seconds.
            timestampMs: row.createdAt * 1000,
            model: row.model,
          ),
      ],
    );
  }

  /// Shows the branch through [ChatCurrent.messageId].
  ///
  /// Follows the newest reply down from there to the end of the branch --
  /// choosing an old question should show where that line of conversation
  /// ended up, not stop halfway -- and makes that the chat's current
  /// message on the server, as Open WebUI's own client does. The flat
  /// message list older clients read is rewritten to match.
  Future<ChatDetail?> setCurrent(ChatCurrent request) async {
    final raw = await _api.getChatRaw(request.chatId);
    final chat = raw?['chat'];
    final history = chat is Map ? chat['history'] : null;
    final messages = history is Map ? history['messages'] : null;
    if (chat is! Map || history is! Map || messages is! Map) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'no chat ${request.chatId}',
      );
    }
    if (messages[request.messageId] is! Map) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'no message ${request.messageId}',
      );
    }

    var leaf = request.messageId;
    final seen = <String>{};
    while (seen.add(leaf)) {
      final children = (messages[leaf] as Map)['childrenIds'];
      final next = children is List
          ? children.map((id) => '$id').where(messages.containsKey).lastOrNull
          : null;
      if (next == null) break;
      leaf = next;
    }

    final path = <Object?>[];
    String? id = leaf;
    final walked = <String>{};
    while (id != null && walked.add(id) && messages[id] is Map) {
      final message = messages[id] as Map;
      path.insert(0, message);
      id = message['parentId']?.toString();
    }

    final updated = Map<String, dynamic>.from(chat)
      ..['history'] = (Map<String, dynamic>.from(history)..['currentId'] = leaf)
      ..['messages'] = path;
    await _api.updateChatRaw(request.chatId, updated);
    await _afterEnvelopeChange(request.chatId);
    return get(request.chatId);
  }

  /// A message on one line, without its reasoning and tool-call markup,
  /// short enough to read at a glance.
  static String _preview(String content) {
    final text = content
        .replaceAll(RegExp(r'<details[\s\S]*?</details>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return text.length <= 80 ? text : '${text.substring(0, 79)}…';
  }

  /// Every conversation in a folder, for its page and the sidebar's open
  /// folder, as a phone's drawer lists it ([folderConversationSummariesProvider]):
  /// the account's own from the database, so older ones the sidebar has not
  /// paged in are there too, and other users' from the server, which keeps
  /// them out of the account's own list. A folder shared with the account
  /// holds only those.
  Future<FolderContents> folder(String folderId) async {
    final folder = (await _folders())
        .where((candidate) => candidate.id == folderId)
        .firstOrNull;
    if (folder == null) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'no folder $folderId',
      );
    }
    // Asked afresh each time it is opened: other users' chats reach this
    // account through no pull.
    _container.invalidate(folderConversationSummariesProvider(folderId));
    final chats = await readSettled(
      _container,
      folderConversationSummariesProvider(folderId).future,
    );
    return FolderContents(
      folder: folder,
      chats: folderChatSummaries(
        chats,
        folderId: folderId,
        currentUserId: _container.read(currentUserProvider2)?.id,
      ),
    );
  }

  /// Sets or clears a conversation's own system prompt. Open
  /// WebUI merges the chat's top-level keys, so sending `system` alone
  /// leaves the transcript as it was.
  Future<ChatDetail?> setSystemPrompt(ChatSystemPrompt request) async {
    await _api.updateConversation(
      request.chatId,
      systemPrompt: request.prompt.trim(),
    );
    await _afterEnvelopeChange(request.chatId);
    return get(request.chatId);
  }

  // -----------------------------------------------------------------------
  // Folders
  // -----------------------------------------------------------------------
  //
  // As a phone's drawer edits them: the write goes to the server through the
  // core's ApiService, the core's folders provider takes the confirmed
  // folder (memory and database together, so the list answers with it at
  // once), and `refreshConversationsCache` pulls whatever else moved. Every
  // window hears `chats.changed`.

  /// Makes a folder named [CreateFolder.name], at the top level or in
  /// [CreateFolder.parentId].
  Future<FolderCreated> createFolder(CreateFolder request) async {
    final name = _folderName(request.name);
    if (!_container.read(foldersAvailableProvider)) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'folders are off for this account or server',
      );
    }
    final folders = await _folders();
    final parentId = request.parentId;
    if (parentId != null) {
      final parent = folders.where((f) => f.id == parentId).firstOrNull;
      if (parent == null) {
        throw RpcError(
          code: ConduitErrorCodes.notFound,
          debugMessage: 'no folder $parentId',
        );
      }
      // Another user's folder takes one only with a write grant.
      if (!parent.canWrite) {
        throw const RpcError(
          code: ConduitErrorCodes.unsupported,
          debugMessage: 'this shared folder is read-only',
        );
      }
    }
    _refuseTakenName(folders, name: name, parentId: parentId);
    final created = await _api.createFolder(name: name, parentId: parentId);
    final folder = Folder.fromJson(Map<String, dynamic>.from(created));
    _container.read(foldersProvider.notifier).upsertFolderFromRemote(folder);
    _afterFolderChange();
    return FolderCreated(folder: folderSummaryOf(folder), list: await list());
  }

  /// Renames a folder the account owns.
  Future<ChatList> renameFolder(RenameFolder request) async {
    final name = _folderName(request.name);
    final folders = await _folders();
    final folder = _ownFolder(folders, request.id);
    if (folder.name == name) return list();
    _refuseTakenName(
      folders,
      name: name,
      parentId: folder.parentId,
      except: folder.id,
    );
    await _api.updateFolder(folder.id, name: name);
    _container
        .read(foldersProvider.notifier)
        .updateFolderFromRemote(
          folder.id,
          (current) => current.copyWith(name: name, updatedAt: _now()),
        );
    _afterFolderChange();
    return list();
  }

  /// Deletes a folder the account owns, and its subfolders with it.
  ///
  /// Their chats are kept, out of any folder: the sync engine's own folder
  /// delete asks the server for exactly that (`delete_contents=false`), and
  /// a folder is a way of filing chats, not a reason to lose them. Open
  /// WebUI moves them without touching their `updated_at`, so no pull would
  /// notice; the loaded ones are moved here too.
  Future<ChatList> deleteFolder(String folderId) async {
    final folders = await _folders();
    final folder = _ownFolder(folders, folderId);
    final subtree = folderSubtree(folders, folder.id);
    final conversations = await readSettled(
      _container,
      conversationsProvider.future,
    );
    final kept = <String>[
      for (final chat in conversations)
        if (subtree.contains(chat.folderId)) chat.id,
    ];
    await _api.deleteFolderRaw(folder.id, deleteContents: false);
    final notifier = _container.read(foldersProvider.notifier);
    for (final id in subtree) {
      notifier.removeFolderFromRemote(id);
    }
    for (final id in kept) {
      _conversations.updateConversationFromRemote(
        id,
        (chat) => chat.copyWith(folderId: null),
      );
    }
    _afterFolderChange();
    return list();
  }

  /// [name] trimmed, or refused when that leaves nothing.
  static String _folderName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a folder name must not be empty',
      );
    }
    return trimmed;
  }

  /// The account's own folder [id]: another user's, shared with it, takes
  /// no rename or delete from anyone but its owner.
  static FolderSummary _ownFolder(List<FolderSummary> folders, String id) {
    final folder = folders.where((f) => f.id == id).firstOrNull;
    if (folder == null) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'no folder $id',
      );
    }
    if (folder.shared) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: "only a folder's owner may rename or delete it",
      );
    }
    return folder;
  }

  /// Open WebUI keeps one folder of a name (in any case) per parent, and
  /// answers a second with a bare 400; this says which.
  static void _refuseTakenName(
    List<FolderSummary> folders, {
    required String name,
    required String? parentId,
    String? except,
  }) {
    final lower = name.toLowerCase();
    final taken = folders.any(
      (f) =>
          f.id != except &&
          !f.shared &&
          f.parentId == parentId &&
          f.name.toLowerCase() == lower,
    );
    if (taken) {
      throw RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: 'a folder named "$name" is already there',
      );
    }
  }

  /// After a folder write: the core refreshes what it caches (a pull, and
  /// each open folder's chats), and every window lists again.
  void _afterFolderChange() {
    refreshConversationsCache(_container, includeFolders: true);
    _events?.emit(ConduitEventSpecs.chatsChanged, const ChatsChanged());
  }

  Future<ChatList> move(MoveChat request) async {
    await _api.moveConversationToFolder(request.chatId, request.folderId);
    await _afterEnvelopeChange(request.chatId);
    return _refresh();
  }

  Future<ChatShare> share(String id) async {
    final shareId = await _api.shareConversation(id);
    await _afterEnvelopeChange(id);
    await _refresh();
    return ChatShare(chatId: id, shareId: shareId);
  }

  Future<ChatShare> unshare(String id) async {
    await _api.deleteSharedConversation(id);
    await _afterEnvelopeChange(id);
    await _refresh();
    return ChatShare(chatId: id);
  }

  ApiService get _api {
    final api = _container.read(apiServiceProvider);
    if (api == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'sign in before changing a conversation',
      );
    }
    return api;
  }

  /// Re-reads the list after a server write.
  ///
  /// Pulls first: the write went to the server, and the list is a projection
  /// of the local database, so invalidating alone would re-read the same
  /// stale rows and report the rename as having done nothing.
  Future<ChatList> _refresh() async {
    await _pull('chats.mutation');
    _container.invalidate(conversationsProvider);
    return list();
  }

  ChatList _project(
    List<Conversation> conversations,
    List<FolderSummary> folders,
  ) => ChatList(
    chats: conversations.map(_summarize).toList(growable: false),
    hasMore: _conversations.hasMoreRegularChats(),
    archivedCount: _conversations.archivedChatCount(),
    archivedVisible: _conversations.archivedChatsVisible(),
    folders: folders,
    foldersEnabled: _foldersAvailable(),
  );

  /// The core's own answer (an Open WebUI account, with the feature on);
  /// a container that cannot say leaves the sidebar offering folders.
  bool _foldersAvailable() {
    try {
      return _container.read(foldersAvailableProvider);
    } on Object {
      return true;
    }
  }

  ChatSummary _summarize(Conversation conversation) => chatSummaryOf(
    conversation,
    currentUserId: _container.read(currentUserProvider2)?.id,
  );

  ChatMessageDto _message(core.ChatMessage message) => ChatMessageDto(
    id: message.id,
    role: message.role,
    content: message.content,
    timestampMs: message.timestamp.millisecondsSinceEpoch,
    model: message.model,
    streaming: message.isStreaming,
    errorCode: message.error == null ? null : ConduitErrorCodes.serverError,
    versions: <ChatMessageVersionDto>[
      for (final version in message.versions)
        ChatMessageVersionDto(
          id: version.id,
          content: version.content,
          timestampMs: version.timestamp.millisecondsSinceEpoch,
          model: version.model,
          sources: chatSourceDtos(version.sources),
          usage: _usage(version.usage),
          blocks: message.role == 'assistant'
              ? blocks.forVersion(message, version)
              : const <MessageBlockDto>[],
        ),
    ],
    sources: chatSourceDtos(message.sources),
    usage: _usage(message.usage),
    rating: switch (message.metadata?[kMessageRatingMetadataKey]) {
      final int rating => rating,
      _ => null,
    },
    files: chatFileDtos(message.files),
    blocks: blocks.forMessage(message),
  );

  /// The core's reading of whatever shape the provider reported in; null
  /// when it reported nothing usable.
  static ChatUsageDto? _usage(Map<String, dynamic>? usage) {
    if (usage == null) return null;
    final summary = UsageSummary.fromUsage(usage);
    if (summary.isEmpty) return null;
    return ChatUsageDto(
      generationPerSecond: summary.generationPerSecond,
      generationTokens: summary.generationTokens,
      promptPerSecond: summary.promptPerSecond,
      promptTokens: summary.promptTokens,
      reasoningTokens: summary.reasoningTokens,
      totalTokens: summary.totalTokens,
      totalSeconds: summary.totalSeconds,
      queueSeconds: summary.queueSeconds,
      loadSeconds: summary.loadSeconds,
    );
  }
}
