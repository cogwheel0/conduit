import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import 'rpc_client.dart';
import 'rpc_providers.dart';
import 'session_providers.dart';

/// The sidebar's conversation list.
final chatListProvider = FutureProvider<ChatList>((ref) async {
  ref.watch(coreConnectionProvider);
  // Depends on the session, and says so. Fetched before sign-in completes it
  // would return an empty list and cache it -- and then the sidebar stays
  // empty after signing in, because nothing remembered to invalidate it.
  // Declaring the dependency makes the refetch automatic.
  ref.watch(authStatusProvider);
  // Refetched whenever the daemon says the set changed, rather than polled.
  // The daemon is the only thing that knows when a sync landed.
  ref.watch(_chatsChangedProvider);
  return ref
      .read(rpcClientProvider)
      .call(ConduitMethods.chatsList, decode: ChatList.fromJson);
});

/// Ticks whenever the daemon publishes `chats.changed`, with the chat it
/// was about, if it named one.
///
/// A tick as well as the id, because the same chat changing twice would
/// otherwise be an equal value, and an equal value notifies nobody.
final _chatsChangedProvider = StreamProvider<({int tick, String? chatId})>((
  ref,
) {
  var tick = 0;
  return ref
      .watch(rpcClientProvider)
      .events
      .where((envelope) => envelope.event == ConduitEvents.chatsChanged)
      .map(
        (envelope) => (
          tick: ++tick,
          chatId: ChatsChanged.fromJson(envelope.payload).chatId,
        ),
      );
});

/// The models the active server offers, and which is selected.
final modelListProvider = FutureProvider<ModelList>((ref) async {
  ref.watch(coreConnectionProvider);
  // Same reason as the chat list: an unauthenticated server offers none, and
  // the composer would show no picker forever.
  ref.watch(authStatusProvider);
  return ref
      .watch(rpcClientProvider)
      .call(ConduitMethods.modelsList, decode: ModelList.fromJson);
});

/// The sidebar's search text. Empty means "show the list".
final searchQueryProvider = NotifierProvider<SearchQuery, String>(
  SearchQuery.new,
);

class SearchQuery extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
}

/// Results for the current query, or null when there is no query.
///
/// Debounced rather than fired per keystroke: each search is a round trip
/// and an FTS query, and a user typing "outbox" would otherwise run six.
final searchResultsProvider = FutureProvider<ChatSearchResults?>((ref) async {
  final query = ref.watch(searchQueryProvider).trim();
  if (query.isEmpty) return null;
  // Re-run as the list changes and as the sync moves. The index fills during
  // the first sync, and a sync that writes message bodies changes the index
  // without changing the list. A search typed in that window should pick up
  // results as they land, not keep the empty answer it got first.
  ref.watch(_chatsChangedProvider);
  ref.watch(syncStateProvider);

  // Cancelled by the next keystroke, because watching the query rebuilds
  // this provider and disposes the previous body.
  var cancelled = false;
  ref.onDispose(() => cancelled = true);
  await Future<void>.delayed(const Duration(milliseconds: 200));
  if (cancelled) return null;

  return ref
      .read(rpcClientProvider)
      .call(
        ConduitMethods.chatsSearch,
        params: ChatSearchQuery(query: query).toJson(),
        decode: ChatSearchResults.fromJson,
      );
});

/// Which conversation the transcript is showing. Null is the empty state.
final selectedChatIdProvider = NotifierProvider<SelectedChatId, String?>(
  SelectedChatId.new,
);

class SelectedChatId extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? chatId) => state = chatId;
}

/// The selected conversation's transcript, as the daemon has it stored.
///
/// Deliberately separate from [liveTranscriptProvider]: this is what was
/// persisted, and it is replaced wholesale when the selection changes. The
/// live overlay is what moves while a turn streams.
final chatDetailProvider = FutureProvider<ChatDetail?>((ref) async {
  final chatId = ref.watch(selectedChatIdProvider);
  if (chatId == null) return null;
  ref.watch(coreConnectionProvider);
  // Refetched when the daemon says this chat changed, or that something
  // may have. An earlier comment here promised this and the code did not do
  // it: after a turn, the transcript kept the empty placeholder fetched at
  // send time, and a Regenerate, which only a persisted answer offers,
  // never appeared.
  //
  // `listen` and not `watch`, because the event is unscoped. Every window
  // hears every chat change so that every sidebar can reorder, but a
  // transcript has no reason to refetch because some other chat changed.
  ref.listen(_chatsChangedProvider, (_, next) {
    final changed = next.value;
    if (changed == null) return;
    if (changed.chatId == null || changed.chatId == chatId) {
      ref.invalidateSelf();
    }
  });

  final raw = await ref
      .read(rpcClientProvider)
      .call(
        ConduitMethods.chatsGet,
        params: ChatRef(id: chatId).toJson(),
        decode: (json) => json,
      );
  final chat = raw['chat'];
  return chat == null
      ? null
      : ChatDetail.fromJson(chat as Map<String, dynamic>);
});

/// Keeps the daemon's event filter in step with what this window watches.
///
/// `turn.*` events are scoped to a chat id, and the bus only delivers a
/// scoped event to a client that listed that scope -- so without this the
/// renderer receives nothing at all while a turn streams. Scoping is right:
/// two windows on different conversations should not paint each other's
/// tokens.
final _eventSubscriptionProvider = Provider<void>((ref) {
  final chatId = ref.watch(selectedChatIdProvider);
  final client = ref.watch(rpcClientProvider);
  unawaited(
    client.subscribe(
      EventSubscription(
        // Empty `events` means every event; the scope is what narrows it.
        scopes: <String>[?chatId],
      ),
    ),
  );
});

/// The turn currently streaming, if any.
class LiveTurn {
  const LiveTurn({
    required this.chatId,
    required this.messageId,
    required this.text,
    this.failedCode,
    this.failedDetail,
    this.settled = false,
  });

  final String chatId;
  final String messageId;
  final String text;
  final String? failedCode;

  /// The server's own explanation, when it gave one.
  ///
  /// A refusal like "your plan does not include this model" is information
  /// only the server has, and a red border around an empty bubble tells the
  /// user nothing they can act on.
  final String? failedDetail;

  /// The turn has finished, but the persisted transcript may not have caught
  /// up. Kept on screen until it does.
  final bool settled;

  bool get failed => failedCode != null;
}

/// Applies `turn.*` events to a single in-flight answer.
///
/// Holds only the active turn, not the transcript. When the turn completes
/// the daemon publishes `chats.changed`, [chatDetailProvider] refetches, and
/// the finished message arrives through the same path as every other
/// persisted message -- so there is exactly one place that decides what the
/// transcript is.
final liveTurnProvider = StreamProvider<LiveTurn?>((ref) {
  ref.watch(_eventSubscriptionProvider);
  final client = ref.watch(rpcClientProvider);
  final controller = StreamController<LiveTurn?>();
  LiveTurn? current;

  final subscription = client.events.listen((envelope) {
    switch (envelope.event) {
      case ConduitEvents.turnStarted:
        final started = TurnStarted.fromJson(envelope.payload);
        current = LiveTurn(
          chatId: started.chatId,
          messageId: started.messageId,
          text: '',
        );
      case ConduitEvents.turnDelta:
        // Creates the turn as readily as it updates one: a window that
        // subscribed after `turn.started` fired still shows the answer,
        // because a delta carries everything rather than an increment.
        final delta = TurnDelta.fromJson(envelope.payload);
        current = LiveTurn(
          chatId: delta.chatId,
          messageId: delta.messageId,
          text: delta.text,
        );
      case ConduitEvents.turnCompleted:
        // Kept, not cleared. The answer has finished, but it reaches the
        // transcript through a refetch of the *synced* conversation, and
        // that lands later -- so clearing here made a completed answer
        // vanish for as long as the sync took, or forever if the server had
        // not recorded it yet. The transcript drops this overlay once the
        // persisted copy shows up, exactly as it does for the sent message.
        final completed = TurnCompleted.fromJson(envelope.payload);
        current = LiveTurn(
          chatId: completed.chatId,
          messageId: completed.messageId,
          text: completed.text,
          settled: true,
        );
      case ConduitEvents.turnFailed:
        final failed = TurnFailed.fromJson(envelope.payload);
        current = LiveTurn(
          chatId: failed.chatId,
          messageId: failed.messageId,
          text: failed.partialText,
          failedCode: failed.code,
          failedDetail: failed.args['detail'],
          settled: true,
        );
      default:
        return;
    }
    controller.add(current);
  });

  ref.onDispose(() {
    subscription.cancel();
    controller.close();
  });
  return controller.stream;
});

/// The message this window just sent, until the server's copy arrives.
///
/// A sent message is not in the transcript yet: it exists on the server, but
/// `chats.get` reads the synced conversation, and the sync lands after the
/// answer. Without this the user's own words vanish the moment they press
/// send and reappear a turn later, which reads as the app having lost them.
class PendingUserMessage {
  const PendingUserMessage({
    required this.chatId,
    required this.messageId,
    required this.text,
    this.replaces,
  });

  final String chatId;
  final String messageId;
  final String text;

  /// The question this one was edited from, if it was.
  ///
  /// Until the sync lands, the transcript still holds the old branch. Hiding
  /// the replaced question and everything after it is what makes the edit
  /// look immediate rather than stacked underneath the original.
  final String? replaces;
}

final pendingUserMessageProvider =
    NotifierProvider<PendingUserMessageNotifier, PendingUserMessage?>(
      PendingUserMessageNotifier.new,
    );

class PendingUserMessageNotifier extends Notifier<PendingUserMessage?> {
  @override
  PendingUserMessage? build() => null;

  void set(PendingUserMessage message) => state = message;

  /// Drops it once [messages] contains it, so the persisted copy takes over
  /// rather than the two being rendered side by side.
  void reconcile(Iterable<ChatMessageDto> messages) {
    final pending = state;
    if (pending == null) return;
    if (messages.any((m) => m.id == pending.messageId)) state = null;
  }

  void clear() => state = null;
}

/// The most recent assistant text, live turn included.
///
/// Derived here rather than assembled where it is needed, for two reasons.
/// A cold `read` of an async provider nothing is watching answers `loading`,
/// so a copy shortcut pressed from a route with no transcript on screen
/// copied nothing the first time and worked the second; keeping this one
/// alive keeps both of its sources resolved. And the alternative -- having
/// the keyboard *component* watch them -- coupled that component's rebuilds
/// to `liveTurnProvider` being torn down and rebuilt on every chat switch,
/// which left its element permanently dirty: `setState` scheduled a build
/// that never ran, and the shortcut overlay simply never opened.
///
/// The streaming answer wins over the persisted one. It is the one on
/// screen, and waiting for it to sync would silently copy the *previous*
/// reply instead.
final lastReplyProvider = Provider<String?>((ref) {
  final chatId = ref.watch(selectedChatIdProvider);
  final live = ref.watch(liveTurnProvider).value;
  if (live != null && live.chatId == chatId && live.text.isNotEmpty) {
    return live.text;
  }
  final messages =
      ref.watch(chatDetailProvider).value?.messages ?? const <ChatMessageDto>[];
  for (final message in messages.reversed) {
    if (message.role == 'assistant' && message.content.isNotEmpty) {
      return message.content;
    }
  }
  return null;
});

final chatActionsProvider = Provider<ChatActions>((ref) => ChatActions(ref));

class ChatActions {
  ChatActions(this._ref);

  final Ref _ref;

  RpcClient get _client => _ref.read(rpcClientProvider);

  /// Sends [text], letting the daemon pick the model.
  ///
  /// WP-3.4's picker will pass one explicitly. Until then the daemon resolves
  /// it from the account's selection, which is better than the renderer
  /// fetching a model list purely so it can name what the daemon already
  /// knows.
  Future<SendTurnAccepted> send({
    required String text,
    String? model,
    List<String> fileIds = const <String>[],
  }) async {
    final sentText = text;
    final accepted = await _client.call(
      ConduitMethods.turnsSend,
      params: SendTurn(
        chatId: _ref.read(selectedChatIdProvider),
        model: model,
        text: text,
        fileIds: fileIds,
      ).toJson(),
      decode: SendTurnAccepted.fromJson,
    );
    // A new conversation gets its id from the server, so select it here --
    // otherwise the first answer streams into a transcript the user is not
    // looking at.
    // Selecting the chat also re-subscribes to its scope, which is how this
    // window starts receiving the turn's events at all. Deltas that landed
    // in the gap are not lost: each one carries the whole content so far, so
    // the first one received is complete.
    _ref.read(selectedChatIdProvider.notifier).select(accepted.chatId);
    _ref
        .read(pendingUserMessageProvider.notifier)
        .set(
          PendingUserMessage(
            chatId: accepted.chatId,
            messageId: accepted.userMessageId,
            text: sentText,
          ),
        );
    _ref.invalidate(chatDetailProvider);
    return accepted;
  }

  /// Runs an assistant answer again.
  ///
  /// Selects nothing and clears nothing: the conversation is already on
  /// screen, and the new answer arrives through the same `turn.*` events a
  /// send produces.
  Future<SendTurnAccepted> regenerate({
    required String chatId,
    required String messageId,
    String? model,
  }) => _client.call(
    ConduitMethods.turnsRegenerate,
    params: RegenerateTurn(
      chatId: chatId,
      messageId: messageId,
      model: model,
    ).toJson(),
    decode: SendTurnAccepted.fromJson,
  );

  /// Replaces one of the user's messages and answers it, as a new branch.
  Future<SendTurnAccepted> edit({
    required String chatId,
    required String messageId,
    required String text,
  }) async {
    final accepted = await _client.call(
      ConduitMethods.turnsEdit,
      params: EditTurn(
        chatId: chatId,
        messageId: messageId,
        text: text,
      ).toJson(),
      decode: SendTurnAccepted.fromJson,
    );
    // The edited question shows at once, rather than the old one sitting
    // there until the sync lands.
    _ref
        .read(pendingUserMessageProvider.notifier)
        .set(
          PendingUserMessage(
            chatId: accepted.chatId,
            messageId: accepted.userMessageId,
            text: text,
            replaces: messageId,
          ),
        );
    return accepted;
  }

  Future<void> stop(String chatId) => _client.call(
    ConduitMethods.turnsStop,
    params: StopTurn(chatId: chatId).toJson(),
    decode: (json) => json,
  );

  /// Widens the page of chats the daemon lists.
  ///
  /// Invalidates rather than returning the list, for the same reason every
  /// mutation does: the sidebar has one source, and a second path into it
  /// is how two windows start disagreeing about what is there.
  Future<void> loadMore() async {
    await _client.call(ConduitMethods.chatsLoadMore, decode: (json) => json);
    _ref.invalidate(chatListProvider);
  }

  /// Pages archived chats into the list, or back out of it.
  Future<void> setArchivedVisible({required bool visible}) async {
    await _client.call(
      ConduitMethods.chatsSetArchivedVisible,
      params: ArchivedVisibility(visible: visible).toJson(),
      decode: (json) => json,
    );
    _ref.invalidate(chatListProvider);
  }

  Future<void> rename(String id, String title) =>
      _mutate(ConduitMethods.chatsRename, RenameChat(id: id, title: title));

  Future<void> setPinned(String id, {required bool value}) =>
      _mutate(ConduitMethods.chatsSetPinned, SetChatFlag(id: id, value: value));

  Future<void> setArchived(String id, {required bool value}) => _mutate(
    ConduitMethods.chatsSetArchived,
    SetChatFlag(id: id, value: value),
  );

  Future<void> delete(String id) async {
    await _mutate(ConduitMethods.chatsDelete, ChatRef(id: id));
    // Deleting the open conversation would otherwise leave the transcript
    // showing something that no longer exists.
    if (_ref.read(selectedChatIdProvider) == id) select(null);
  }

  /// Runs a mutation, then refreshes the list from the daemon.
  ///
  /// The daemon returns the new list, but the provider is invalidated rather
  /// than seeded with it: the sidebar has one source, and a second path into
  /// it is how two windows start disagreeing about the order.
  Future<void> _mutate(String method, Object params) async {
    await _client.call(
      method,
      params: (params as dynamic).toJson() as Map<String, dynamic>,
      decode: (json) => json,
    );
    _ref.invalidate(chatListProvider);
  }

  void select(String? chatId) {
    // A pending message belongs to the chat it was sent in.
    _ref.read(pendingUserMessageProvider.notifier).clear();
    _ref.read(selectedChatIdProvider.notifier).select(chatId);
  }

  /// Chooses the model new turns use.
  ///
  /// Persisted daemon-side with the account rather than held in the window,
  /// so a second window and the next launch agree with this one.
  Future<void> selectModel(String id) async {
    await _client.call(
      ConduitMethods.modelsSelect,
      params: SelectModel(id: id).toJson(),
      decode: ModelList.fromJson,
    );
    _ref.invalidate(modelListProvider);
  }
}

/// Which folders the sidebar has open (WP-3.1).
///
/// Null until the first list arrives, and then seeded from each folder's
/// own `expanded` flag -- the state the account last left it in, so a new
/// window opens the way the old one closed. From then on it is this
/// window's: toggling a folder here does not fold it in another window.
final expandedFoldersProvider = NotifierProvider<ExpandedFolders, Set<String>?>(
  ExpandedFolders.new,
);

class ExpandedFolders extends Notifier<Set<String>?> {
  @override
  Set<String>? build() => null;

  /// Seeds from [folders] the first time, and never again.
  void seed(Iterable<FolderSummary> folders) {
    if (state != null) return;
    state = <String>{
      for (final folder in folders)
        if (folder.expanded) folder.id,
    };
  }

  void toggle(String id) {
    final current = state ?? const <String>{};
    state = current.contains(id)
        ? (Set<String>.of(current)..remove(id))
        : <String>{...current, id};
  }
}

/// Which alternative answer each message is showing (WP-3.8).
///
/// Keyed by message id and held per window. It changes what is on screen,
/// not what the server considers current. That matches the mobile app, and
/// it means flicking between answers to compare them never rewrites the
/// conversation's history.
///
/// A missing entry means the newest answer, which is what the server
/// returns as the message's own content.
final answerVersionProvider =
    NotifierProvider<AnswerVersions, Map<String, int>>(AnswerVersions.new);

class AnswerVersions extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() => const <String, int>{};

  void show(String messageId, int index) =>
      state = <String, int>{...state, messageId: index};
}

/// Which of the user's messages is being edited in place, if any.
final editingMessageProvider = NotifierProvider<EditingMessage, String?>(
  EditingMessage.new,
);

class EditingMessage extends Notifier<String?> {
  @override
  String? build() => null;

  void start(String messageId) => state = messageId;
  void stop() => state = null;
}

/// The sync engine's state (WP-3.1): asked for once, then followed.
///
/// Subscribed to events before asking, so a change that lands between the
/// answer and the subscription is not lost. The later of the two wins,
/// which is the one that is true.
final syncStateProvider = StreamProvider<SyncState>((ref) {
  ref.watch(authStatusProvider);
  final client = ref.watch(rpcClientProvider);
  final controller = StreamController<SyncState>();
  var sawEvent = false;
  final subscription = client.events
      .where((envelope) => envelope.event == ConduitEvents.syncStatus)
      .listen((envelope) {
        sawEvent = true;
        controller.add(SyncState.fromJson(envelope.payload));
      });
  unawaited(
    client
        .call(ConduitMethods.syncGet, decode: SyncState.fromJson)
        .then((state) {
          if (!sawEvent && !controller.isClosed) controller.add(state);
        })
        .catchError((Object _) {}),
  );
  ref.onDispose(() {
    unawaited(subscription.cancel());
    unawaited(controller.close());
  });
  return controller.stream;
});
