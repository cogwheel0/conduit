import 'dart:async';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show
        archiveConversation,
        copyLibreChatConversation,
        deleteLibreChatConversation,
        pinConversation,
        renameLibreChatConversation,
        captureChatMutationOwner,
        chatActionAvailability,
        chatMenuAvailability,
        deleteConversationShareLink,
        exportOpenWebUiChat,
        exportOpenWebUiChatTranscript,
        forkChatAtMessage,
        isReasoningEffortRejection,
        markConversationUnread,
        openWebUiChatActionAllowedProvider,
        selectChatBranch,
        shareConversationLink;
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart'
    show libreChatCapabilitiesProvider;
import 'package:conduit_core/services/connectivity_service.dart'
    show isOnlineProvider;
import 'package:conduit_core/features/chat/providers/conversation_title_generation.dart';
import 'package:conduit_core/features/chat/services/chat_branch_service.dart'
    show ChatBranchException, ChatBranchFailure;
import 'package:conduit_core/features/chat/utils/chat_share_url.dart';
import 'package:conduit_core/features/chat/utils/chat_export_file_name.dart';
import 'package:conduit_core/features/chat/utils/conversation_unread.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart'
    show directContextLengthOverridesProvider;
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart'
    show directModelAdvertisedContextLength;
import 'package:conduit_core/features/sharing/models/resource_access.dart';
import 'package:conduit_core/features/sharing/providers/resource_access_controller.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart'
    show
        WorkspaceAccessGrantInput,
        WorkspaceGrantPermission,
        WorkspacePrincipalType;
import 'package:conduit_core/models/chat_comparison.dart';
import 'package:conduit_core/models/chat_message.dart' as core;
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    as mutations;
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart'
    show currentUserProvider2;
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/folder_icons.dart';
import 'package:conduit_core/models/openwebui_chat_settings.dart'
    show kChatParamSystem;
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/host_ports.dart'
    show connectivityPortProvider;
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/conversation_parsing.dart'
    show kMessageRatingMetadataKey;
import 'package:conduit_core/sync/id_remapper.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart'
    show PrimaryAccountKind, primaryAccountKindProvider;
import 'package:conduit_core/sync/primary_sync_provider.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/features/librechat/providers/librechat_composer_providers.dart'
    show libreChatFileBaseUrlProvider;
import 'package:conduit_core/database/chat_database_repository.dart'
    show ChatStorageIdentity, ChatStorageKind;
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/utils/usage_summary.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart'
    show hermesApiServiceProvider;
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart'
    show isNativeHermesConversation;
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart'
    show kHermesTransport;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/misc.dart' show ProviderListenable;
import 'package:riverpod/riverpod.dart';

import 'chat_settings_service.dart';
import 'event_bus.dart';
import 'message_blocks.dart';
import 'queued_completions_service.dart';
import 'settled.dart';
import 'temporary_chats.dart';
import 'hermes_service.dart';

/// [conversation] as the windows list it, for the account whose signed-in
/// user is [currentUserId].
///
/// Another user's chat, reached through a folder shared with this account,
/// is read-only, as the core decides it for a phone
/// ([isReadOnlySharedConversation]): the server refuses every write to it.
///
/// [menu] is what its menus offer (the core's `chatMenuAvailability`); a
/// caller without a container leaves them all off.
ChatSummary chatSummaryOf(
  Conversation conversation, {
  required String? currentUserId,
  bool generating = false,
  ChatMenuAbilities menu = const ChatMenuAbilities(),
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
  unread: isConversationUnread(conversation, generating: generating),
  menu: menu,
);

/// [conversation]'s menus, by the core's rule for its backend
/// ([chatMenuAvailability]); all off when it cannot be read.
ChatMenuAbilities chatMenuAbilitiesOf(
  ProviderContainer container,
  Conversation conversation,
) {
  try {
    final offered = chatMenuAvailability(container, conversation);
    return ChatMenuAbilities(
      share: offered.share,
      duplicate: offered.duplicate,
      move: offered.move,
      markUnread: offered.markUnread,
      generateTitle: offered.generateTitle,
      export: offered.export,
    );
  } on Object {
    return const ChatMenuAbilities();
  }
}

/// What a chat's answers are doing, as the turns service knows it: which
/// chats are answering (no unread dot while they are), whether one is, or
/// is merging, and a way to let go of an idle chat's scope after its stored
/// copy changed under it.
abstract interface class ChatTurns {
  Iterable<String> get activeChatIds;
  bool isRunning(String chatId);
  bool mergeRunning(String chatId);
  void forgetIdle(String chatId);

  /// Waits (briefly) for [chatId]'s last answer to reach the stored copy, so
  /// nothing it pulls lands over a change made after.
  Future<void> settled(String chatId);

  /// The messages of [chatId]'s open scope, as its turns left them; null
  /// when it has none.
  List<core.ChatMessage>? openMessages(String chatId);
}

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
  // A curated icon, or any shortcode Open WebUI knows (one chosen on the
  // web, such as `fire`).
  icon: folderIconEmoji(folder.meta?['icon']?.toString()),
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
  ChatMenuAbilities Function(Conversation chat)? menu,
}) => <ChatSummary>[
  for (final chat in chats)
    chatSummaryOf(
      chat.folderId == null ? chat.copyWith(folderId: folderId) : chat,
      currentUserId: currentUserId,
      menu: menu?.call(chat) ?? const ChatMenuAbilities(),
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
    QueuedCompletionsService? queued,
  }) : _events = events,
       _hermes = hermes,
       _queued = queued,
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
  /// Answers waiting in the outbox, shown on the messages they fill.
  final QueuedCompletionsService? _queued;

  final HermesService? _hermes;

  /// The turns service, once the daemon has made it.
  ChatTurns? turns;

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
    // What each chat's menus offer reads the account's permissions and
    // LibreChat's capabilities as loaded when it is listed: list again
    // when they change (a permission that loads after the list did).
    void relist() {
      pending?.cancel();
      pending = Timer(const Duration(milliseconds: 250), () {
        _events?.emit(ConduitEventSpecs.chatsChanged, const ChatsChanged());
      });
    }

    void follow<T>(ProviderListenable<T> provider) {
      try {
        _container.listen<T>(provider, (previous, next) {
          if (previous != next) relist();
        });
      } on Object catch (error) {
        DebugLogger.error(
          'chat-menu-follow-failed',
          scope: 'daemon/chats',
          error: error,
        );
      }
    }

    follow(openWebUiChatActionAllowedProvider('export'));
    follow(libreChatCapabilitiesProvider);
    follow(chatMarkUnreadSupportedProvider);
    follow(foldersAvailableProvider);
    follow(isOnlineProvider);
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
  /// Prompts, but does not wait for it: a full pull takes seconds with a
  /// couple of hundred conversations, and the renderer lists again on every
  /// `chats.changed`, faster than a pull finishes during a conversation. The
  /// database answers at once; if the pull changes the list, the projection
  /// listener publishes another `chats.changed`.
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
      // The account that owns the chats: Open WebUI's engine, or the
      // LibreChat account's.
      await _container.read(primarySyncProvider).requestPull(reason: reason);
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
      // While its scope is open (a window follows its agent's work there,
      // or a turn just ran), the chat is what the scope holds: an answer a
      // turn, with all it showed, under the names the scope answers to.
      // Hermes's record has a row a tool step, which a turn's last row
      // only partly says.
      final open = turns?.openMessages(id);
      final messages = open != null && open.isNotEmpty
          ? open
          : await hermes.transcript(sessionId);
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
        messages: _messages(messages),
        // Its history's actions, its agent's work, and its context
        // window and usage.
        abilities: hermes.abilities(sessionId),
        hermes: hermes.chatState(sessionId),
      );
    }
    // Never in the database, so never in the list. The transcript lives
    // only in the daemon's memory. Known by membership rather than by the
    // `local:` prefix, which a direct chat awaiting its first sync to Open
    // WebUI also carries -- and that one *is* in the database.
    if (_temporary.contains(id)) {
      final messages = _temporary.transcript(id);
      final now = DateTime.now();
      final title = messages.isEmpty
          ? ''
          : messages.first.content.split('\n').first;
      final conversation = Conversation(
        id: id,
        title: title,
        createdAt: now,
        updatedAt: now,
        messages: messages,
      );
      return ChatDetail(
        summary: ChatSummary(
          id: id,
          title: title,
          updatedAtMs: now.millisecondsSinceEpoch,
        ),
        messages: _messages(messages, conversation: conversation),
        temporary: true,
        abilities: await _abilities(conversation, temporary: true),
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

    // The chat's own prompt: `params.system` when set, an empty one
    // included (it replaces every other prompt, as a turn sends it), else
    // the legacy `chat.system` (what mobile's request sends ahead of the
    // user's own).
    final saved = conversation.chatParams[kChatParamSystem];
    final prompt = saved is String
        ? saved.trim()
        : conversation.systemPrompt?.trim();
    final opened = _summarize(conversation);
    final shareId = conversation.shareId;
    final queued =
        await _queued?.forChat(id) ?? const <String, QueuedCompletionDto>{};
    return ChatDetail(
      summary: opened,
      messages: _messages(
        conversation.messages,
        conversation: conversation,
        queued: queued,
      ),
      systemPrompt: prompt == null || prompt.isEmpty ? null : prompt,
      readOnly: opened.readOnly,
      abilities: await _abilities(conversation),
      shareId: shareId == null || shareId.isEmpty ? null : shareId,
      tasks: chatTaskDtos(conversation.metadata),
    );
  }

  /// What [conversation] offers, as the core decides it for a phone; none
  /// when that cannot be read.
  Future<ChatAbilities> _abilities(
    Conversation conversation, {
    bool temporary = false,
  }) async {
    // A Hermes chat (or an Open WebUI chat a Hermes turn ran in): its
    // agent's work can be watched; a Hermes session's own context read.
    final hermes = _container.read(hermesApiServiceProvider) != null;
    final native = isNativeHermesConversation(conversation);
    final hermesWork =
        hermes &&
        (native ||
            conversation.messages.any(
              (m) => m.metadata?['transport'] == kHermesTransport,
            ));
    final hermesContext = hermes && native;
    try {
      final offered = await chatActionAvailability(
        _container,
        conversation,
        temporary: temporary,
        mergeRunning: turns?.mergeRunning(conversation.id) ?? false,
      );
      return ChatAbilities(
        fork: offered.fork,
        export: offered.export,
        merge: offered.merge,
        branch: offered.branch,
        deleteMessages: offered.deleteMessages,
        markUnread: offered.markUnread,
        generateTitle: offered.generateTitle,
        share: offered.share,
        saveTemporary: offered.saveTemporary,
        compare: offered.compare,
        hermesWork: hermesWork,
        hermesContext: hermesContext,
      );
    } on Object catch (error) {
      DebugLogger.error(
        'chat-abilities-failed',
        scope: 'daemon/chats',
        error: error,
      );
      return ChatAbilities(
        hermesWork: hermesWork,
        hermesContext: hermesContext,
      );
    }
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

    // The account in charge's: LibreChat's own database while it owns the
    // chats.
    final libreChat =
        _container.read(primaryAccountKindProvider) ==
        PrimaryAccountKind.libreChat;
    final database = libreChat
        ? _container
              .read(chatDatabaseRepositoryProvider)
              .libreChatLocation
              ?.database
        : _container.read(appDatabaseProvider);
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
      // LibreChat's list is whole once its sync has pulled it, which the
      // list answering already waited for.
      complete:
          libreChat ||
          (sync.phase == SyncPhase.idle &&
              sync.lastSuccessUpdatedAtWatermark != null),
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
      await _container.read(primarySyncProvider).pullChatNow(chatId);
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
    if (_isLibreChat(id)) {
      // Written here at once, and to the server through LibreChat's own
      // outbox, as the phone renames one.
      await renameLibreChatConversation(_container, id, trimmed);
      return _refresh();
    }
    await _api.updateConversation(id, title: trimmed);
    await _afterEnvelopeChange(id);
    return _refresh();
  }

  Future<ChatList> setPinned(String id, {required bool value}) async {
    if (_isDirectLocal(id)) {
      await mutations.pinConversation(_container, id, value);
    } else if (_isLibreChat(id)) {
      await pinConversation(_container, _libreChatScoped(id), value);
    } else {
      await _api.pinConversation(id, value);
    }
    return _refresh();
  }

  Future<ChatList> setArchived(String id, {required bool value}) async {
    await _archive(id, value);
    return _refresh();
  }

  /// Direct's local chats and LibreChat's are archived where they are kept;
  /// the rest on the server.
  Future<void> _archive(String id, bool value) {
    if (_isDirectLocal(id)) {
      return mutations.archiveConversation(_container, id, value);
    }
    if (_isLibreChat(id)) {
      return archiveConversation(_container, _libreChatScoped(id), value);
    }
    return _api.archiveConversation(id, value);
  }

  /// Whether chat [id] is one of the LibreChat account's: its changes go
  /// through the core's LibreChat mutations, which write the account's own
  /// database and queue the server write, never to Open WebUI.
  bool _isLibreChat(String id) {
    final identity = ChatStorageIdentity.parse(id);
    if (identity.storage == ChatStorageKind.libreChat) return true;
    final listed = _container
        .read(conversationsProvider)
        .value
        ?.where((conversation) => conversation.id == id)
        .firstOrNull;
    if (listed != null) return isLibreChatConversation(listed);
    // Not listed yet (a copy just made, say): a server chat is the account
    // in charge's.
    return identity.storage == null &&
        !id.startsWith('local:') &&
        _container.read(primaryAccountKindProvider) ==
            PrimaryAccountKind.libreChat;
  }

  /// [id] as the core's mutations know a LibreChat chat whether or not the
  /// list holds it yet (a copy just made): a bare server id they would
  /// otherwise take for Open WebUI's.
  static String _libreChatScoped(String id) {
    final identity = ChatStorageIdentity.parse(id);
    if (identity.storage != null) return id;
    return ChatStorageIdentity(
      rawId: identity.rawId,
      storage: ChatStorageKind.libreChat,
    ).scopedId;
  }

  Future<ChatList> delete(String id) async {
    // Never on the server: forgetting it here is the whole delete.
    if (_temporary.contains(id)) {
      _temporary.delete(id);
      _events?.emit(ConduitEventSpecs.chatsChanged, ChatsChanged(chatId: id));
      return _refresh();
    }
    if (_isDirectLocal(id)) {
      await mutations.deleteDirectLocalConversation(_container, id);
      return _refresh();
    }
    if (_isLibreChat(id)) {
      await deleteLibreChatConversation(_container, id);
      _conversations.removeConversation(id);
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
          case BulkChatAction.delete when _isLibreChat(id):
            await deleteLibreChatConversation(_container, id);
            _conversations.removeConversation(id);
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
  /// The core's own branch switch, as a phone's version pager and version
  /// list make it: the newest reply down from there becomes the chat's
  /// current message, stored and queued for the server under the chat's lock,
  /// then sent. With [ChatCurrent.alternativeTo] the message must be another
  /// answer to the same message in the same role (Continue from This
  /// Response). Refused while the chat is answering.
  Future<ChatDetail?> setCurrent(ChatCurrent request) async {
    _refuseWhileAnswering(request.chatId);
    // The last answer's own pulls first: one that read the server before
    // this change and lands after it would put the old branch back. And a
    // scope left from that answer holds the branch it showed.
    await turns?.settled(request.chatId);
    turns?.forgetIdle(request.chatId);
    final conversation = await _load(request.chatId);
    Future<String> select() async {
      try {
        return (await selectChatBranch(
          _container,
          conversation: conversation,
          messageId: request.messageId,
          alternativeTo: request.alternativeTo,
        )).leafId;
      } on ChatBranchException catch (error) {
        throw branchError(error);
      }
    }

    final leaf = await select();
    // Sent now, so the server's copy (and another device) has it before the
    // window reads the chat again.
    await _drain();
    await _confirmBranch(request.chatId, leaf, select);
    turns?.forgetIdle(request.chatId);
    _container.invalidate(loadConversationProvider(request.chatId));
    _events?.emit(
      ConduitEventSpecs.chatsChanged,
      ChatsChanged(chatId: request.chatId),
    );
    return get(request.chatId);
  }

  /// Makes sure the server kept [leaf] as [chatId]'s current message.
  ///
  /// Open WebUI finishes writing an answer a moment after its stream ends,
  /// and that write can put the branch back to the answer just written; a
  /// pull that read the server before the switch can do the same here. So
  /// the server is asked, and the switch made again from what it now has,
  /// a few times at most.
  Future<void> _confirmBranch(
    String chatId,
    String leaf,
    Future<String> Function() select,
  ) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      try {
        final raw = await _api.getChatRaw(chatId);
        final chat = raw?['chat'];
        final history = chat is Map ? chat['history'] : null;
        if (history is! Map || history['currentId'] == leaf) return;
      } on Object catch (error) {
        DebugLogger.error(
          'branch-check-failed',
          scope: 'daemon/chats',
          error: error,
        );
        return;
      }
      try {
        await _container.read(syncEngineProvider.notifier).pullChatNow(chatId);
      } on Object catch (error) {
        DebugLogger.error('pull-failed', scope: 'daemon/chats', error: error);
      }
      await select();
      await _drain();
    }
  }

  /// Sends what this account has queued for the server, for at most a few
  /// seconds; a slow server gets it with the next sync.
  Future<void> _drain() async {
    final database = _container.read(appDatabaseProvider);
    if (database == null) return;
    try {
      await _container
          .read(syncEngineProvider.notifier)
          .drainNowForDatabase(database)
          .timeout(const Duration(seconds: 5));
    } on Object catch (error) {
      DebugLogger.error('drain-failed', scope: 'daemon/chats', error: error);
    }
  }

  /// The text of answer [messageId] in [chatId] (or of the version with
  /// that id), with the model that wrote it: what Read Aloud reads. Read
  /// where `chats.get` reads it: a Hermes session's transcript is Hermes's,
  /// a temporary chat's is in this daemon's memory.
  Future<({String content, String? model})> answerFor(
    String chatId,
    String messageId,
  ) async {
    final List<core.ChatMessage> messages;
    if (hermesSessionOf(chatId) case final sessionId? when _hermes != null) {
      messages = await _hermes.transcript(sessionId);
    } else if (_temporary.contains(chatId)) {
      messages = _temporary.transcript(chatId);
    } else {
      messages = (await _load(chatId)).messages;
    }
    for (final message in messages) {
      if (message.id == messageId) {
        return (content: message.content, model: message.model);
      }
      for (final version in message.versions) {
        if (version.id == messageId) {
          return (content: version.content, model: version.model);
        }
      }
    }
    throw RpcError(
      code: ConduitErrorCodes.notFound,
      args: <String, String>{'messageId': messageId},
      debugMessage: 'no such message in that chat',
    );
  }

  /// The model [chatId] answers with.
  Future<String?> modelOf(String chatId) async => (await _load(chatId)).model;

  /// [chatId] as the core loads it, or not found.
  Future<Conversation> _load(String chatId) async {
    try {
      return await readSettled(
        _container,
        loadConversationProvider(chatId).future,
      );
    } on Object catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        args: <String, String>{'chatId': chatId},
        debugMessage: 'could not open that chat: $error',
      );
    }
  }

  void _refuseWhileAnswering(String chatId) {
    if (turns?.isRunning(chatId) ?? false) {
      throw RpcError(
        code: ConduitErrorCodes.conflict,
        args: const <String, String>{'reason': 'responseRunning'},
        debugMessage: 'that chat is still answering',
      );
    }
  }

  /// A branch operation the core refused, as the windows read it: the core's
  /// reason in `args.reason`.
  static RpcError branchError(ChatBranchException error) => RpcError(
    code: switch (error.reason) {
      ChatBranchFailure.responseRunning ||
      ChatBranchFailure.forkConflict => ConduitErrorCodes.conflict,
      ChatBranchFailure.messageNotFound ||
      ChatBranchFailure.notAnAlternative ||
      ChatBranchFailure.forkSourceMissing => ConduitErrorCodes.notFound,
      ChatBranchFailure.offline => ConduitErrorCodes.offline,
      ChatBranchFailure.ownerChanged => ConduitErrorCodes.sessionExpired,
      ChatBranchFailure.forkForbidden => ConduitErrorCodes.unauthorized,
      ChatBranchFailure.unavailable ||
      ChatBranchFailure.forkUnsupported => ConduitErrorCodes.unsupported,
      ChatBranchFailure.forkFailed => ConduitErrorCodes.serverError,
    },
    args: <String, String>{'reason': error.reason.name},
    debugMessage: 'the branch operation was refused: ${error.reason.name}',
  );

  // -----------------------------------------------------------------------
  // Fork, export, title, read state
  // -----------------------------------------------------------------------

  /// A new chat from the start of [ForkChat.chatId] to its message
  /// [ForkChat.messageId]: Open WebUI's fork, through the core, stored here
  /// as the server made it. Every window's sidebar lists it.
  Future<ChatForked> fork(ForkChat request) async {
    _refuseWhileAnswering(request.chatId);
    if (_isLibreChat(request.chatId)) {
      // LibreChat's fork: the chat up to that message, copied on its
      // server, as the phone's Branch in New Chat does.
      final copy = await copyLibreChatConversation(
        _container,
        request.chatId,
        upToMessageId: request.messageId,
      );
      _events?.emit(ConduitEventSpecs.chatsChanged, const ChatsChanged());
      return ChatForked(chatId: copy.id);
    }
    final conversation = await _load(request.chatId);
    final ({String chatId, bool opened}) outcome;
    try {
      outcome = await forkChatAtMessage(
        _container,
        conversation: conversation,
        messageId: request.messageId,
      );
    } on ChatBranchException catch (error) {
      throw branchError(error);
    }
    _events?.emit(ConduitEventSpecs.chatsChanged, const ChatsChanged());
    return ChatForked(chatId: outcome.chatId);
  }

  /// [ExportChat.chatId] as a file: the JSON backup Open WebUI imports, every
  /// branch, or the shown branch as Markdown, read from the stored copy.
  Future<ChatExportFile> export(ExportChat request) async {
    final conversation = await _load(request.chatId);
    final owner = captureChatMutationOwner(_container, conversation);
    final now = _now();
    try {
      switch (request.format) {
        case ChatExportFormat.json:
          final export = await exportOpenWebUiChat(
            _container,
            conversation: conversation,
            owner: owner,
          );
          return ChatExportFile(
            fileName: chatExportFileName(
              export.title.isEmpty ? conversation.title : export.title,
              now,
              'json',
            ),
            content: export.toJson(),
            mimeType: 'application/json',
            hasUnsyncedChanges: export.hasUnsyncedChanges,
          );
        case ChatExportFormat.markdown:
          final markdown = await exportOpenWebUiChatTranscript(
            _container,
            conversation: conversation,
            owner: owner,
          );
          return ChatExportFile(
            fileName: chatExportFileName(conversation.title, now, 'md'),
            content: markdown,
            mimeType: 'text/markdown',
          );
      }
    } on ChatBranchException catch (error) {
      throw branchError(error);
    }
  }

  final Set<String> _titlesBeingGenerated = <String>{};

  /// Asks the server's model for a title, as the phone's Generate Title
  /// does, and saves it unless the chat was renamed meanwhile.
  Future<GeneratedTitle> generateTitle(String chatId) async {
    if (!_titlesBeingGenerated.add(chatId)) {
      throw const RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: 'a title is already being made for that chat',
      );
    }
    try {
      final GeneratedConversationTitle generated;
      try {
        generated = await generateConversationTitle(_container, chatId);
      } on RpcError {
        rethrow;
      } on Object catch (error) {
        throw RpcError(
          code: ConduitErrorCodes.serverError,
          debugMessage: 'the title could not be made: $error',
        );
      }
      if (generated.outcome == ConversationTitleOutcome.saved) {
        await _afterEnvelopeChange(chatId);
      }
      return GeneratedTitle(
        outcome: switch (generated.outcome) {
          ConversationTitleOutcome.saved => GenerateTitleOutcome.saved,
          ConversationTitleOutcome.none => GenerateTitleOutcome.none,
          ConversationTitleOutcome.unchanged ||
          ConversationTitleOutcome.kept => GenerateTitleOutcome.unchanged,
        },
        title: generated.title,
      );
    } finally {
      _titlesBeingGenerated.remove(chatId);
    }
  }

  /// Marks [MarkUnread.chatId] unread, as the web sidebar's Mark as Unread
  /// does, or read, as opening it does.
  Future<ChatList> markUnread(MarkUnread request) async {
    if (request.unread) {
      try {
        await markConversationUnread(_container, request.chatId);
      } on Object catch (error) {
        throw RpcError(
          code: ConduitErrorCodes.serverError,
          debugMessage: 'the chat could not be marked unread: $error',
        );
      }
    } else {
      markConversationRead(_container, request.chatId);
    }
    _events?.emit(
      ConduitEventSpecs.chatsChanged,
      ChatsChanged(chatId: request.chatId),
    );
    return list();
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
        menu: (chat) => chatMenuAbilitiesOf(_container, chat),
      ),
    );
  }

  /// Sets or clears a conversation's own system prompt. Open
  /// WebUI merges the chat's top-level keys, so sending `system` alone
  /// leaves the transcript as it was.
  Future<ChatDetail?> setSystemPrompt(ChatSystemPrompt request) async {
    final settings = _chatSettings;
    if (settings == null) {
      // No settings service (tests): the legacy field, as before.
      await _api.updateConversation(
        request.chatId,
        systemPrompt: request.prompt.trim(),
      );
      await _afterEnvelopeChange(request.chatId);
      return get(request.chatId);
    }
    // The chat's own prompt is `params.system`, as mobile's Chat Settings
    // and Open WebUI's web client save it; the legacy `chat.system` still
    // reads back when no params prompt is set.
    if (await settings.setSystemPrompt(request.chatId, request.prompt)) {
      // The legacy prompt was cleared on the server: this device's copy
      // follows before the chat is read back.
      await _afterEnvelopeChange(request.chatId);
    }
    return get(request.chatId);
  }

  /// `chats.setSystemPrompt` writes through it once the daemon wires it.
  ChatSettingsService? _chatSettings;
  set chatSettings(ChatSettingsService? value) => _chatSettings = value;

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

  /// The chat's link: made, or updated to the chat as it is now
  /// ([ShareChat.publish]), or only read; and who may open it, set when
  /// [ShareChat.audience] says (the core's access grants for the chat).
  Future<ChatShare> share(ShareChat request) async {
    final id = request.id;
    String? shareId;
    String? url;
    if (request.publish) {
      try {
        final link = await shareConversationLink(_container, id);
        shareId = link.shareId;
        url = link.url;
      } on Object catch (error) {
        throw RpcError(
          code: ConduitErrorCodes.serverError,
          debugMessage: 'the link could not be made: $error',
        );
      }
      await _afterEnvelopeChange(id);
      await _refresh();
    } else {
      final conversation = await _load(id);
      shareId = conversation.shareId;
      if (shareId != null && shareId.isEmpty) shareId = null;
      url = shareId == null ? null : _shareUrl(shareId);
    }
    ShareAudience? audience;
    final access = ResourceAccessController.open(
      _container,
      kind: ResourceKind.chat,
      resourceId: id,
    );
    if (access != null) {
      try {
        var snapshot = await access.load();
        if (request.audience case final wanted?
            when _audienceOf(snapshot.audience) != wanted) {
          snapshot = await access.save(
            snapshot,
            _grantsFor(snapshot, wanted),
            audience: _resourceAudience(wanted),
          );
        }
        audience = _audienceOf(snapshot.audience);
      } on Object catch (error) {
        if (request.audience != null) {
          throw RpcError(
            code: ConduitErrorCodes.serverError,
            debugMessage: 'who may open the chat could not be changed: $error',
          );
        }
        DebugLogger.error(
          'share-audience-unread',
          scope: 'daemon/chats',
          error: error,
        );
      }
    }
    return ChatShare(
      chatId: id,
      shareId: shareId,
      url: url,
      audience: audience,
    );
  }

  /// The link for [shareId] on the account's server, as the core builds it.
  String? _shareUrl(String shareId) {
    // A LibreChat chat's link is under its web app, as the core builds it
    // when sharing.
    final libreChat = _container.read(libreChatFileBaseUrlProvider);
    if (libreChat != null) {
      final base = libreChat.endsWith('/')
          ? libreChat.substring(0, libreChat.length - 1)
          : libreChat;
      return '$base/share/$shareId';
    }
    final server = _container.read(apiServiceProvider)?.serverConfig.url;
    if (server == null) return null;
    try {
      return buildChatShareUrl(serverUrl: server, shareId: shareId);
    } on FormatException {
      return null;
    }
  }

  static ShareAudience _audienceOf(ResourceAudience audience) =>
      switch (audience) {
        ResourceAudience.private => ShareAudience.private,
        ResourceAudience.public => ShareAudience.public,
        ResourceAudience.open => ShareAudience.open,
      };

  static ResourceAudience _resourceAudience(ShareAudience audience) =>
      switch (audience) {
        ShareAudience.private => ResourceAudience.private,
        ShareAudience.public => ResourceAudience.public,
        ShareAudience.open => ResourceAudience.open,
      };

  /// The people and groups given access, kept, with the one wildcard read
  /// grant that makes the chat [ShareAudience.public] (Open WebUI's web
  /// editor's `setVisibility`; Open's `anyone` grant is added by the core).
  static List<WorkspaceAccessGrantInput> _grantsFor(
    ResourceAccessSnapshot snapshot,
    ShareAudience audience,
  ) => <WorkspaceAccessGrantInput>[
    for (final grant in snapshot.editableGrants)
      if (!(grant.principalType == WorkspacePrincipalType.user &&
          grant.principalId == '*'))
        grant,
    if (audience == ShareAudience.public)
      const WorkspaceAccessGrantInput(
        principalType: WorkspacePrincipalType.user,
        principalId: '*',
        permission: WorkspaceGrantPermission.read,
      ),
  ];

  Future<ChatShare> unshare(String id) async {
    try {
      await deleteConversationShareLink(_container, id);
    } on Object catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.serverError,
        debugMessage: 'the link could not be deleted: $error',
      );
    }
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
    generating: turns?.isRunning(conversation.id) ?? false,
    menu: chatMenuAbilitiesOf(_container, conversation),
  );

  /// [messages] as the windows draw them. [conversation], when given, is the
  /// chat they belong to, which decides whether a failed answer offers Retry
  /// Without Reasoning Effort. [queued] holds the answers waiting to go out,
  /// by id.
  List<ChatMessageDto> _messages(
    List<core.ChatMessage> messages, {
    Conversation? conversation,
    Map<String, QueuedCompletionDto> queued =
        const <String, QueuedCompletionDto>{},
  }) {
    final byId = <String, core.ChatMessage>{
      for (final message in messages) message.id: message,
    };
    final models = _modelsById();
    return <ChatMessageDto>[
      for (final message in messages)
        _message(
          message,
          parent: byId[message.metadata?['parentId']?.toString()],
          conversation: conversation,
          models: models,
          queued: queued[message.id],
        ),
    ];
  }

  /// The models on offer, by id, as the account last listed them.
  Map<String, Model> _modelsById() {
    try {
      final models = _container.read(modelsProvider).value ?? const <Model>[];
      return <String, Model>{for (final model in models) model.id: model};
    } on Object {
      return const <String, Model>{};
    }
  }

  /// The context window of [modelId], as the phone's usage card reads it:
  /// the one the model advertises, else the one set for a Direct model.
  int? _contextLength(String? modelId, Map<String, Model> models) {
    final model = models[modelId?.trim()];
    if (model == null) return null;
    try {
      return directModelAdvertisedContextLength(model) ??
          _container.read(directContextLengthOverridesProvider)[model.id];
    } on Object {
      return null;
    }
  }

  ChatMessageDto _message(
    core.ChatMessage message, {
    core.ChatMessage? parent,
    Conversation? conversation,
    Map<String, Model> models = const <String, Model>{},
    QueuedCompletionDto? queued,
  }) {
    final assistant = message.role == 'assistant';
    // A question more than one model answered: its answers, by column.
    final group = assistant && message.versions.isNotEmpty
        ? ChatComparisonGroup.fromMessage(message)
        : null;
    final compared = group != null && group.isComparison;
    final unfinished = <String>{
      ...?(message.metadata?[kMessageUnfinishedAnswersMetadataKey] as List?)
          ?.whereType<String>(),
    };
    final merged = message.mergedResponse?.content.trim();
    return ChatMessageDto(
      id: message.id,
      role: message.role,
      content: message.content,
      timestampMs: message.timestamp.millisecondsSinceEpoch,
      model: message.model,
      modelName: answerModelNameOf(message),
      streaming: message.isStreaming,
      errorCode: message.error == null ? null : ConduitErrorCodes.serverError,
      versions: <ChatMessageVersionDto>[
        for (final version in message.versions)
          ChatMessageVersionDto(
            id: version.id,
            content: version.content,
            timestampMs: version.timestamp.millisecondsSinceEpoch,
            model: version.model,
            modelName: _nonEmpty(version.modelName),
            sources: chatSourceDtos(version.sources),
            usage: _usage(
              version.usage,
              contextLength: _contextLength(version.model, models),
            ),
            blocks: assistant
                ? blocks.forVersion(message, version)
                : const <MessageBlockDto>[],
            slot: compared ? (version.modelIdx ?? 0) : null,
            merged: _mergedText(version.merged),
            streaming: unfinished.contains(version.id),
            errorCode: version.error == null
                ? null
                : ConduitErrorCodes.serverError,
          ),
      ],
      sources: chatSourceDtos(message.sources),
      usage: _usage(
        message.usage,
        contextLength: _contextLength(message.model, models),
      ),
      rating: switch (message.metadata?[kMessageRatingMetadataKey]) {
        final int rating => rating,
        _ => null,
      },
      files: chatFileDtos(message.files),
      blocks: blocks.forMessage(message),
      parentId: message.metadata?['parentId']?.toString(),
      slot: compared ? message.modelSlot : null,
      merged: merged == null || merged.isEmpty ? null : merged,
      retryWithoutEffort: _retryWithoutEffort(message, conversation, models),
      comparison: !compared
          ? const <ComparisonSlotDto>[]
          : <ComparisonSlotDto>[
              for (final slot in group.slots)
                ComparisonSlotDto(
                  index: slot.index,
                  answerIds: <String>[
                    for (final answer in slot.answers) answer.messageId,
                  ],
                  model: slot.current.model,
                ),
            ],
      mergeableIds: !compared
          ? const <String>[]
          : <String>[
              for (final answer in group.mergeableAnswers(shownId: message.id))
                answer.messageId,
            ],
      siblingIds: siblingIdsOf(message, parent),
      queued: assistant ? queued : null,
    );
  }

  /// A saved merge's text, from Open WebUI's `{status, content}`.
  static String? _mergedText(Map<String, dynamic>? raw) {
    final text = ChatMergedResponse.tryFrom(raw)?.content.trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// Whether [message], a failed answer of [conversation], was refused over
  /// the reasoning effort the chat or the picker sent (the core's
  /// [isReasoningEffortRejection], as a phone's footer asks it).
  bool _retryWithoutEffort(
    core.ChatMessage message,
    Conversation? conversation,
    Map<String, Model> models,
  ) {
    if (message.role != 'assistant' || conversation == null) return false;
    final error = message.error?.content;
    final content = message.content;
    final failed =
        error != null ||
        content.contains('⚠️') ||
        content.contains('Error') ||
        content.contains('timeout') ||
        content.contains('retry options');
    if (!failed) return false;
    try {
      return isReasoningEffortRejection(
        _ConversationReader(_container, conversation),
        errorText: '${error ?? ''}\n$content',
        retryModel: models[message.model],
      );
    } on Object {
      return false;
    }
  }

  /// The core's reading of whatever shape the provider reported in; null
  /// when it reported nothing usable.
  static ChatUsageDto? _usage(
    Map<String, dynamic>? usage, {
    int? contextLength,
  }) {
    if (usage == null) return null;
    final summary = UsageSummary.fromUsage(usage);
    if (summary.isEmpty) return null;
    return ChatUsageDto(
      contextLength: contextLength,
      contextTokens: summary.contextTokens,
      incomplete: summary.incomplete,
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

/// The name [message]'s model went by when it answered, as the stored
/// answer keeps it (`modelName`, or `model_name` as some servers write it);
/// null when it kept none. The phone's header falls back to it when the
/// model is not among those on offer (a Hermes answer's agent id after a
/// confirmed model switch), and a window does the same.
String? answerModelNameOf(core.ChatMessage message) => _nonEmpty(
  (message.metadata?['modelName'] ?? message.metadata?['model_name'])
      ?.toString(),
);

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// [message] and its versions, by id, in the order the server keeps them:
/// its parent's `childrenIds`, then any the parent does not list (the
/// versions, then the message, oldest first). Empty without versions.
List<String> siblingIdsOf(core.ChatMessage message, core.ChatMessage? parent) {
  if (message.versions.isEmpty) return const <String>[];
  final own = <String>[for (final version in message.versions) version.id];
  own.add(message.id);
  final wanted = own.toSet();
  final ordered = <String>[];
  final children = parent?.metadata?['childrenIds'];
  if (children is List) {
    for (final child in children) {
      final id = '$child';
      if (wanted.contains(id) && !ordered.contains(id)) ordered.add(id);
    }
  }
  for (final id in own) {
    if (!ordered.contains(id)) ordered.add(id);
  }
  return ordered;
}

/// A reader that answers [activeConversationProvider] with one chat and
/// everything else from the account's container: how the daemon asks a
/// core rule written for the open chat about any chat.
final class _ConversationReader {
  _ConversationReader(this._container, this._conversation);

  final ProviderContainer _container;
  final Conversation _conversation;

  T read<T>(ProviderListenable<T> provider) =>
      identical(provider, activeConversationProvider)
      ? _conversation as T
      : _container.read(provider);
}
