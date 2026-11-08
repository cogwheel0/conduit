part of 'chat_providers.dart';

/// How long Stop waits for the server's aborted final frame before ending
/// the turn here, counted from the press. Tests shorten it.
final libreChatStopFallbackProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 8),
);

/// How often a start the server deferred (starting up, the previous turn
/// still being saved) is tried, with the same request id.
const int _libreChatStartAttempts = 4;

/// Marks a message the server has not confirmed yet: its id is still the one
/// minted here, so no later turn may name it as its parent. In memory only.
const String _kLibreChatPendingKey = 'libreChatPending';

/// The approval or question a LibreChat run is paused on, on its reply while
/// it waits. In memory only; the overlay that answers it reads this.
const String kLibreChatPendingActionKey = 'libreChatPendingAction';

/// The waits LibreChat turns use between start attempts and reconnects.
/// Tests replace it to run without real time.
final libreChatTurnSleepProvider = Provider<Future<void> Function(Duration)>(
  (ref) => Future<void>.delayed,
);

/// One LibreChat turn running in this app session.
final class LibreChatRun {
  LibreChatRun._({
    required this.assistantMessageId,
    required this.turn,
    this.userMessageId,
    this.accountId,
  });

  /// The LibreChat account the run writes for. Another account's chat can
  /// share the conversation's id (a copied server), so the run shows only
  /// while this account is in use.
  final String? accountId;

  /// The reply's id: minted here, then the server's once it names it.
  String assistantMessageId;

  /// The user message's id: minted here, then the server's. Null while a
  /// turn followed after reopening a chat has not reported it.
  String? userMessageId;

  /// The body the turn was sent with, which resuming after an approval must
  /// repeat.
  final Map<String, dynamic> turn;

  String? conversationId;
  int? generationCreatedAt;

  /// The messages as the run last showed them, to put back when its chat is
  /// opened again mid-run.
  ChatMessage? user;
  ChatMessage? assistant;

  /// The approval or question the run waits on.
  Map<String, dynamic>? pendingAction;

  /// The answer going out to the pause the run waits on. A second answer to
  /// the same pause (its card shown again, the chat opened again) joins it
  /// rather than send the decisions twice; a newer pause is answered anew.
  ({Map<String, dynamic> action, Future<void> request})? _answering;

  /// Ids minted here that the server has since replaced, to its ids: a copy
  /// of the chat taken before then shows the server's when it opens again.
  final Map<String, String> _renamed = <String, String>{};

  /// The saved reply a regeneration replaces: kept among the new reply's
  /// versions, so a copy of the chat taken before shows it only there.
  String? _replaces;

  bool _stopRequested = false;
  void Function()? _settleLocally;
  StreamSubscription<LibreChatTurnUpdate>? _subscription;

  /// Cancels the run's requests in flight: its start and its stream.
  final CancelToken _requests = CancelToken();
  final Completer<void> _done = Completer<void>();

  bool get isDone => _done.isCompleted;
  Future<void> get done => _done.future;
}

/// The LibreChat turns running in this app session, by reply and by
/// conversation. Separate from Hermes' registry, whose connection changes
/// cancel everything it holds.
final libreChatRunRegistryProvider = Provider<LibreChatRunRegistry>((ref) {
  final registry = LibreChatRunRegistry._(ref);
  ref.onDispose(registry._dispose);
  return registry;
});

/// Stops every LibreChat reply this session follows, in any chat, once the
/// user has agreed to leave the account anyway: the open chat's Stop does
/// not reach the others, and the server would go on writing them for the
/// account left. Each is aborted through the account it runs on, read
/// before the switch goes ahead.
final stopAllLibreChatRunsProvider = Provider<void Function()>((ref) {
  return () => ref.read(libreChatRunRegistryProvider)._stopAll();
});

final class LibreChatRunRegistry {
  LibreChatRunRegistry._(this._ref);

  final Ref _ref;
  final List<LibreChatRun> _runs = <LibreChatRun>[];

  /// The run generating in [conversationId] for the LibreChat account in
  /// use, if any. Another account's chat can share the id (a copied
  /// server): its run, still stopping after a switch, is not this chat's.
  LibreChatRun? forConversation(String? conversationId) {
    if (conversationId == null) return null;
    final accountId = _ref.read(activeLibreChatAccountProvider)?.id;
    return _runs
        .where(
          (run) =>
              run.conversationId == conversationId &&
              run.accountId == accountId &&
              !run.isDone,
        )
        .lastOrNull;
  }

  /// A run still starting a new chat from the draft that shows [shown]: the
  /// server has not named its chat, and its reply is on screen there. New
  /// Chat empties the draft, so another draft has none.
  LibreChatRun? forDraft(Iterable<ChatMessage> shown) {
    final ids = {for (final message in shown) message.id};
    return _runs
        .where(
          (run) =>
              run.conversationId == null &&
              !run.isDone &&
              ids.contains(run.assistantMessageId),
        )
        .lastOrNull;
  }

  /// The run whose reply is [messageId], if any.
  LibreChatRun? forMessage(String messageId) =>
      _runs.where((run) => run.assistantMessageId == messageId).lastOrNull;

  bool isGenerating(String conversationId) =>
      forConversation(conversationId) != null;

  void _add(LibreChatRun run) => _runs.add(run);

  void _bind(LibreChatRun run, String conversationId) {
    run.conversationId = conversationId;
    // The generations a pull holds back are the account in use's: a run of
    // one left, named late, is not among them.
    if (run.accountId != _ref.read(activeLibreChatAccountProvider)?.id) return;
    _ref.read(libreChatActiveGenerationsProvider.notifier).add(conversationId);
  }

  void _finish(LibreChatRun run) {
    _runs.remove(run);
    if (!run._done.isCompleted) run._done.complete();
    final conversationId = run.conversationId;
    if (conversationId != null && forConversation(conversationId) == null) {
      _ref
          .read(libreChatActiveGenerationsProvider.notifier)
          .remove(conversationId);
    }
  }

  /// Stops [run]: asks the server to abort, whose final aborted frame ends
  /// the run with the reply so far. When the server does not answer in
  /// time, counted from the press, the run ends here: its requests are
  /// cancelled, and nothing waits on them, an abort that stalls included.
  Future<void> stop(LibreChatRun run) async {
    if (run.isDone) return;
    run._stopRequested = true;
    final fallback = Timer(_ref.read(libreChatStopFallbackProvider), () {
      if (run.isDone) return;
      DebugLogger.warning('stop-fallback', scope: 'librechat/turn');
      // The cancelled requests fail as the stream winds down; nobody is
      // listening for that any more.
      run._subscription?.cancel().ignore();
      if (!run._requests.isCancelled) run._requests.cancel('stopped');
      run._settleLocally?.call();
    });
    final conversationId = run.conversationId;
    final streams = _ref.read(libreChatStreamClientProvider);
    if (conversationId != null && streams != null) {
      unawaited(() async {
        try {
          await streams.abort(
            conversationId,
            generationCreatedAt: run.generationCreatedAt,
          );
        } on LibreChatApiException catch (error) {
          DebugLogger.warning(
            'abort-failed',
            scope: 'librechat/turn',
            data: {'status': error.statusCode},
          );
        }
      }());
    }
    await run.done;
    fallback.cancel();
  }

  void _stopAll() {
    for (final run in List<LibreChatRun>.of(_runs)) {
      unawaited(stop(run));
    }
  }

  void _dispose() {
    for (final run in List<LibreChatRun>.of(_runs)) {
      run._subscription?.cancel().ignore();
      if (!run._requests.isCancelled) run._requests.cancel('closed');
      if (!run._done.isCompleted) run._done.complete();
    }
    _runs.clear();
  }
}

/// The chat a LibreChat turn belongs to: none yet for a new chat, which the
/// server names when it starts the turn.
final class _LibreChatConversationOwner {
  _LibreChatConversationOwner(Conversation? conversation)
    : _snapshot = conversation;

  Conversation? _snapshot;

  /// For a new chat the server has not named yet: the id of the turn's own
  /// user message, which only the draft it was sent from shows. New Chat,
  /// or another draft's send, is not this turn's draft.
  String? Function()? draftMessageId;

  String? get conversationId => _snapshot?.id;

  /// The notifier scope of the chat, for its owner checks.
  String? get notifierConversationId {
    final snapshot = _snapshot;
    return snapshot == null
        ? null
        : chatMutationOwnerScopeForConversation(snapshot);
  }

  bool isActive(dynamic ref) {
    final active = ref.read(activeConversationProvider) as Conversation?;
    final snapshot = _snapshot;
    if (snapshot == null) {
      if (active != null) return false;
      final draftId = draftMessageId?.call();
      if (draftId == null) return false;
      final shown = ref.read(chatMessagesProvider) as List<ChatMessage>;
      return shown.any((message) => message.id == draftId);
    }
    return active != null &&
        isLibreChatConversation(active) &&
        active.id == snapshot.id;
  }

  void bind(Conversation conversation) => _snapshot = conversation;
}

/// Refuses a new LibreChat chat while temporary chat is on, before anything
/// is sent: LibreChat would keep it in the history.
final class LibreChatTemporaryChatException implements Exception {
  const LibreChatTemporaryChatException();

  @override
  String toString() =>
      'LibreChatTemporaryChatException: LibreChat keeps every chat; turn '
      'off temporary chat to send';
}

/// Whether [message] is a LibreChat turn its server has not accepted: its id
/// is this device's, which the server knows nothing of (to fork from, say).
bool isUnconfirmedLibreChatMessage(ChatMessage message) =>
    message.metadata?[_kLibreChatPendingKey] == true;

/// Refuses a second turn in a LibreChat chat while its reply still runs,
/// before anything is written: it would follow the running reply, which
/// would then go on with no Stop.
final class LibreChatReplyRunningException implements Exception {
  const LibreChatReplyRunningException();

  @override
  String toString() =>
      'LibreChatReplyRunningException: a reply is still running in this chat';
}

/// Whether a LibreChat reply still runs in [active], or, with no chat open,
/// in the draft a new chat is starting from (the server has not named it
/// yet): a second turn there is refused.
bool isLibreChatReplyRunning(dynamic ref, Conversation? active) {
  final runs = ref.read(libreChatRunRegistryProvider) as LibreChatRunRegistry;
  final running = active != null
      ? runs.forConversation(active.id)
      : runs.forDraft(ref.read(chatMessagesProvider) as List<ChatMessage>);
  return running != null;
}

/// Whether a regeneration in [active] with [model] runs on LibreChat.
bool usesLibreChatTransportForRegeneration(Conversation? active, Model model) =>
    active == null ? isLibreChatModel(model) : isLibreChatConversation(active);

/// The message a new LibreChat turn answers: the latest message the server
/// has confirmed. Messages minted here and never confirmed (a turn that
/// failed to start) are passed over.
String? _libreChatParentFor(List<ChatMessage> messages) {
  for (final message in messages.reversed) {
    if (message.metadata?[_kLibreChatPendingKey] == true) continue;
    return message.id;
  }
  return null;
}

/// Takes [unsent], a user message the server never took, out of the chat
/// with everything after it (its failed reply), and out of its parent's
/// replies.
void _dropUnsentLibreChatTurn(dynamic ref, ChatMessage unsent) {
  final notifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  final messages = ref.read(chatMessagesProvider) as List<ChatMessage>;
  final index = messages.indexWhere((message) => message.id == unsent.id);
  if (index < 0) return;
  notifier.setMessages(messages.sublist(0, index));
  final parentId = unsent.metadata?['parentId'];
  if (parentId is! String) return;
  notifier.updateMessageById(parentId, (parent) {
    final children = message_tree.chatMessageChildrenIds(parent);
    if (!children.contains(unsent.id)) return parent;
    return parent.copyWith(
      metadata: <String, dynamic>{
        ...?parent.metadata,
        'childrenIds': [
          for (final id in children)
            if (id != unsent.id) id,
        ],
      },
    );
  });
}

/// A spec's preset, sent as the turn's parameters (model settings, tools).
Map<String, dynamic> _libreChatParametersFor(LibreChatTarget target) =>
    target.kind == LibreChatTargetKind.spec
    ? Map<String, dynamic>.of(target.preset)
    : const <String, dynamic>{};

/// How an uploaded file shows on the user's message until the server's copy
/// replaces it: the same descriptor the stored message maps to.
Map<String, dynamic> _libreChatFileDescriptor(Map<String, dynamic> file) {
  final type = file['type'];
  final isImage =
      (type is String && type.startsWith('image/')) || file['width'] is num;
  return <String, dynamic>{
    'type': isImage ? 'image' : 'file',
    'url': file['filepath'],
    'name': ?file['filename'],
    'size': ?file['bytes'],
    if (type is String) 'content_type': type,
    'libreChatFileId': ?file['file_id'],
  };
}

/// The ids of [message]'s LibreChat uploads, sendable again: records the
/// composer no longer holds (it forgets them once their turn goes out, and
/// a reopened chat never had them) are rebuilt from the files the message
/// shows, so an edited message goes out with its files. Null when it has
/// none.
List<String>? reattachLibreChatFiles(dynamic ref, ChatMessage message) {
  final files = message.files;
  if (files == null || files.isEmpty) return null;
  final uploads =
      ref.read(libreChatUploadedFilesProvider.notifier)
          as LibreChatUploadedFiles;
  final ids = <String>[];
  for (final file in files) {
    final id = file['libreChatFileId'];
    if (id is! String || id.isEmpty) continue;
    if (!uploads.has(id)) {
      final type = file['content_type'];
      uploads.record(<String, dynamic>{
        'file_id': id,
        'filepath': ?file['url'],
        'filename': ?file['name'],
        'bytes': ?file['size'],
        if (type is String) 'type': type,
      });
    }
    ids.add(id);
  }
  return ids.isEmpty ? null : ids;
}

String _libreChatDraftTitle(String text) {
  final line = text.trim().split('\n').first.trim();
  if (line.isEmpty) return 'New Chat';
  return line.length <= 60 ? line : '${line.substring(0, 57)}...';
}

/// Sends [message] in the active LibreChat chat, or starts one, with
/// [model] and the tools in [toolIds] (none when null, as for the other
/// backends). [replacing] is a message of this chat the server never took,
/// which this send takes the place of, with its reply.
Future<void> _sendLibreChatMessage(
  dynamic ref,
  String message,
  List<String>? attachments, {
  required Model model,
  List<String>? toolIds,
  ChatSendVoiceContext? voice,
  void Function(ChatSendPlaceholderHandle handle)?
  onAssistantPlaceholderCreated,
  ChatMessage? replacing,
}) async {
  if (voice?.reply != null) {
    throw StateError('LibreChat chats do not keep spoken answers.');
  }
  final active = ref.read(activeConversationProvider) as Conversation?;
  if (active != null && !isLibreChatConversation(active)) {
    throw StateError('A LibreChat model can only continue a LibreChat chat.');
  }
  // LibreChat keeps every chat it starts, so a new chat meant to stay out of
  // the history is not sent there.
  if (active == null && ref.read(temporaryChatEnabledProvider) == true) {
    throw const LibreChatTemporaryChatException();
  }
  // One turn at a time in a chat: a send that slipped past the composer's
  // Stop (a shortcut, the expanded editor) is refused here.
  if (isLibreChatReplyRunning(ref, active)) {
    throw const LibreChatReplyRunningException();
  }
  final target = libreChatTargetOf(model);
  final streams =
      ref.read(libreChatStreamClientProvider) as LibreChatStreamClient?;
  if (target == null || streams == null) {
    throw StateError('The selected LibreChat model is not available.');
  }
  // Files went up when they were attached; the turn names them. A file
  // whose upload this session no longer holds stops the send rather than
  // going out without it.
  final uploads =
      ref.read(libreChatUploadedFilesProvider.notifier)
          as LibreChatUploadedFiles;
  final fileIds = attachments ?? const <String>[];
  final files = uploads.recordsFor(fileIds);
  // The send's own tools: a follow-up that leaves the composer alone does
  // not take the tools picked for the unsent draft.
  final tools = libreChatModelTakesTools(model)
      ? libreChatToolSelectionFor(toolIds ?? const <String>[])
      : const LibreChatToolSelection();
  final mutationOwner = captureChatMutationOwner(ref, active);
  if (replacing != null) _dropUnsentLibreChatTurn(ref, replacing);
  final existing = ref.read(chatMessagesProvider) as List<ChatMessage>;
  final parentId = active == null ? null : _libreChatParentFor(existing);
  final userId = const Uuid().v4();
  final assistantId = const Uuid().v4();
  final now = DateTime.now();
  final user = ChatMessage(
    id: userId,
    role: 'user',
    content: message,
    timestamp: now,
    model: model.id,
    attachmentIds: fileIds.isEmpty ? null : List<String>.of(fileIds),
    files: files.isEmpty
        ? null
        : [for (final file in files) _libreChatFileDescriptor(file)],
    metadata: <String, dynamic>{
      'parentId': parentId,
      'childrenIds': <String>[assistantId],
      'models': <String>[model.id],
      _kLibreChatPendingKey: true,
    },
  );
  final placeholder = ChatMessage(
    id: assistantId,
    role: 'assistant',
    content: '',
    timestamp: now,
    model: model.id,
    isStreaming: true,
    metadata: <String, dynamic>{
      'parentId': userId,
      'childrenIds': const <String>[],
      'transport': kLibreChatTransport,
      _kLibreChatPendingKey: true,
      if (model.name.trim().isNotEmpty) 'modelName': model.name.trim(),
    },
  );
  final notifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  if (parentId != null) {
    notifier.updateMessageById(parentId, (parent) {
      final children = message_tree
          .chatMessageChildrenIds(parent)
          .toList(growable: true);
      if (children.contains(userId)) return parent;
      return parent.copyWith(
        metadata: <String, dynamic>{
          ...?parent.metadata,
          'childrenIds': [...children, userId],
        },
      );
    });
  }
  notifier.addMessages([user, placeholder]);
  final handle = ChatSendPlaceholderHandle._(
    userMessageId: userId,
    assistantMessageId: assistantId,
    mutationOwner: mutationOwner,
  );
  onAssistantPlaceholderCreated?.call(handle);

  final request = LibreChatTurnRequest(
    text: message,
    endpoint: target.endpoint,
    endpointType: target.endpointType,
    model: target.model,
    agentId: target.agentId,
    spec: target.spec,
    conversationId: active?.id,
    parentMessageId: parentId,
    clientRequestId: const Uuid().v4(),
    files: [for (final file in files) libreChatTurnFile(file)],
    ephemeralAgent: tools.toEphemeralAgent(),
    parameters: _libreChatParametersFor(target),
  );
  final registry =
      ref.read(libreChatRunRegistryProvider) as LibreChatRunRegistry;
  await _runLibreChatTurn(
    registry,
    streams: streams,
    owner: _LibreChatConversationOwner(active),
    request: request,
    user: user,
    assistant: placeholder,
    model: model,
    sendHandle: handle,
  );
  // Spent once the server has the turn. A refused one keeps them, for the
  // draft that is sent again. Read through the registry: the page that sent
  // may be gone.
  registry._ref.read(libreChatUploadedFilesProvider.notifier).forget(fileIds);
}

/// Starts [request] and follows it, trying a start the server deferred
/// again with the same request id, so the server takes it once.
Stream<LibreChatTurnUpdate> _startLibreChatTurn(
  LibreChatTurnRunner runner,
  LibreChatTurnRequest request,
  Future<void> Function(Duration) sleep,
) async* {
  for (var attempt = 1; ; attempt++) {
    // `yield*` would pass the start's error on rather than throw it here.
    var started = false;
    try {
      await for (final update in runner.run(request)) {
        started = true;
        yield update;
      }
      return;
    } on LibreChatTurnDeferredException catch (error) {
      if (started || attempt >= _libreChatStartAttempts) rethrow;
      final wait = error.retryAfter ?? Duration(seconds: 2 * attempt);
      await sleep(
        wait > const Duration(seconds: 30) ? const Duration(seconds: 30) : wait,
      );
    }
  }
}

/// Runs one LibreChat turn into the chat: a new turn from [request], or,
/// without one, the generation already running in the owner's chat.
///
/// The run lives in [libreChatRunRegistryProvider], not in the visible
/// message list: it carries on while another chat is open and is put back
/// when its own is opened again. When it ends, the conversation is fetched
/// so the stored copy holds what the server saved, and the server's rows
/// take the place of the ones shown while it ran.
///
/// Returns once the server has taken a new turn, while the reply still runs,
/// so the composer is free for the next message. Throws when the turn ended
/// before the server took it (refused, or stopped while starting): the
/// message was never sent, and its draft stays.
Future<void> _runLibreChatTurn(
  LibreChatRunRegistry registry, {
  required LibreChatStreamClient streams,
  required _LibreChatConversationOwner owner,
  LibreChatTurnRequest? request,
  int? followCreatedAt,
  ChatMessage? user,
  required ChatMessage assistant,
  Model? model,
  ChatSendPlaceholderHandle? sendHandle,
  String? replaces,
}) async {
  // The caller's ref may be a page's, gone once the page closes, or the chat
  // notifier's own; the run outlives both, so it reads through the
  // registry's.
  final runRef = registry._ref;
  final sleep = runRef.read(libreChatTurnSleepProvider);
  final following = request == null;
  final run =
      LibreChatRun._(
          assistantMessageId: assistant.id,
          userMessageId: user?.id,
          accountId: runRef.read(activeLibreChatAccountProvider)?.id,
          turn: request?.toJson() ?? <String, dynamic>{},
        )
        ..user = user
        ..assistant = assistant
        // A followed reply's generation, which Stop names so it cannot end
        // a newer one another device started.
        ..generationCreatedAt = followCreatedAt
        .._replaces = replaces;
  final runner = LibreChatTurnRunner(
    streams,
    sleep: sleep,
    cancelToken: run._requests,
  );
  registry._add(run);
  owner.draftMessageId ??= () => run.userMessageId;
  // The account the turn runs for: a chat the server names is listed in its
  // database, never in one signed in since.
  final startDatabase = runRef
      .read(chatDatabaseRepositoryProvider)
      .libreChatLocation
      ?.database;
  final startConversationId = owner.conversationId;
  if (startConversationId != null) registry._bind(run, startConversationId);
  final release = holdLocalChatGeneration(runRef);
  final projector = StructuredOutputStreamingProjector();
  var content = assistant.content;
  var materialized = !following;
  String? pendingTitle;
  // A followed generation is already the server's.
  final admitted = Completer<void>();
  if (following) admitted.complete();
  void refuseAdmission(Object error, [StackTrace? stackTrace]) {
    if (!admitted.isCompleted) admitted.completeError(error, stackTrace);
  }

  ChatMessagesNotifier notifier() => runRef.read(chatMessagesProvider.notifier);
  bool ownerActive() =>
      runRef.read(activeLibreChatAccountProvider)?.id == run.accountId &&
      owner.isActive(runRef);

  void updateAssistant(ChatMessage Function(ChatMessage message) change) {
    run.assistant = change(run.assistant!);
    if (ownerActive()) {
      notifier().updateMessageById(run.assistantMessageId, change);
    }
  }

  // A followed turn shows its messages once the stream says what they are.
  // A reply the history already shows becomes the live one in its row.
  void materialize() {
    if (materialized) return;
    materialized = true;
    if (!ownerActive()) return;
    final current = runRef.read(chatMessagesProvider);
    final runUser = run.user;
    final shown = current.any((m) => m.id == run.assistantMessageId);
    notifier().addMessages([
      if (runUser != null && !current.any((m) => m.id == runUser.id)) runUser,
      if (!shown) run.assistant!,
    ]);
    if (shown) {
      notifier().updateMessageById(
        run.assistantMessageId,
        (_) => run.assistant!,
      );
    }
  }

  void applyTitle(String title) {
    final conversationId = owner.conversationId;
    if (conversationId == null) {
      pendingTitle = title;
      return;
    }
    if (ownerActive()) {
      final active = runRef.read(activeConversationProvider);
      if (active != null && active.title != title) {
        runRef
            .read(activeConversationProvider.notifier)
            .set(active.copyWith(title: title));
      }
    }
    // A title arriving after the account was left belongs to that account,
    // not to the chat with the same id the new one lists.
    if (runRef.read(activeLibreChatAccountProvider)?.id != run.accountId) {
      return;
    }
    runRef
        .read(conversationsProvider.notifier)
        .applyLibreChatGeneratedTitle(conversationId, title);
  }

  void bindConversation(String conversationId) {
    registry._bind(run, conversationId);
    if (owner.conversationId != null) return;
    final wasActive = ownerActive();
    final now = DateTime.now();
    final visible = wasActive
        ? List<ChatMessage>.of(runRef.read(chatMessagesProvider))
        : <ChatMessage>[?run.user, ?run.assistant];
    final conversation = stampLibreChatProvenance(
      withChatStorageProvenance(
        Conversation(
          id: conversationId,
          title: pendingTitle ?? _libreChatDraftTitle(run.user?.content ?? ''),
          createdAt: now,
          updatedAt: now,
          model: model?.id,
          messages: visible,
        ),
        ChatStorageKind.libreChat,
      ),
    );
    owner.bind(conversation);
    runRef
        .read(libreChatActiveGenerationsProvider.notifier)
        .noteStarted(conversation.copyWith(messages: const <ChatMessage>[]));
    sendHandle?._bindConversation(conversation);
    if (wasActive) {
      runRef.read(activeConversationProvider.notifier).set(conversation);
    }
    // Listed at once, so the chat can be found again while its first reply
    // runs (sync skips a generating chat): its envelope only, as the server
    // named it, with nothing queued. The pull after the turn fills it in.
    unawaited(
      _listLibreChatChat(runRef, startDatabase, conversationId, conversation),
    );
    final title = pendingTitle;
    if (title != null) applyTitle(title);
  }

  void confirmUser(Map<String, dynamic> serverUser) {
    final serverId = serverUser['messageId'];
    if (serverId is! String || serverId.isEmpty) return;
    final localId = run.userMessageId;
    if (localId == null) {
      // A followed turn: the user message comes from the server.
      final text = serverUser['text'];
      final parent = serverUser['parentMessageId'];
      run.user = ChatMessage(
        id: serverId,
        role: 'user',
        content: text is String ? text : '',
        timestamp: DateTime.now(),
        metadata: <String, dynamic>{
          'parentId': parent is String && parent != kLibreChatRootParentId
              ? parent
              : null,
          'childrenIds': <String>[run.assistantMessageId],
        },
      );
      run.userMessageId = serverId;
      run.assistant = run.assistant!.copyWith(
        metadata: <String, dynamic>{
          ...?run.assistant!.metadata,
          'parentId': serverId,
        },
      );
      return;
    }
    if (ownerActive()) {
      notifier()
        ..renameMessage(localId, serverId)
        ..updateMessageById(serverId, _withoutPending);
    }
    // A stream resumed again names the same message: nothing was replaced.
    if (localId != serverId) run._renamed[localId] = serverId;
    run.userMessageId = serverId;
    run.user = _withoutPending(run.user!.copyWith(id: serverId));
    run.assistant = run.assistant!.copyWith(
      metadata: <String, dynamic>{
        ...?run.assistant!.metadata,
        'parentId': serverId,
      },
    );
  }

  void confirmAssistant(String? serverId) {
    if (serverId == null ||
        serverId.isEmpty ||
        serverId == run.assistantMessageId) {
      return;
    }
    final localId = run.assistantMessageId;
    run._renamed[localId] = serverId;
    run.assistantMessageId = serverId;
    run.assistant = _withoutPending(run.assistant!.copyWith(id: serverId));
    final runUser = run.user;
    if (runUser != null) {
      run.user = ChatMessagesNotifier._withRenamedReferences(
        runUser,
        (id) => id == localId ? serverId : id,
      );
    }
    if (!ownerActive()) return;
    final existing = runRef
        .read(chatMessagesProvider)
        .where((message) => message.id == serverId)
        .firstOrNull;
    if (existing == null) {
      notifier()
        ..renameMessage(localId, serverId)
        ..updateMessageById(serverId, _withoutPending);
      return;
    }
    // The history the chat opened with already shows the reply (one
    // followed after reopening the chat): that row becomes the live reply,
    // as far as the run has it, and the placeholder minted for it goes.
    final live = run.assistant!;
    // A pause the stream reported first (a resumed run replays it before its
    // progress) is the live reply's, which the saved row does not have:
    // without it the question or approval would have no card.
    final pause = run.pendingAction;
    run.assistant = _withoutPending(
      existing.copyWith(
        content: live.content,
        output: live.output,
        isStreaming: live.isStreaming,
        metadata: pause == null
            ? existing.metadata
            : <String, dynamic>{
                ...?existing.metadata,
                kLibreChatPendingActionKey: pause,
              },
      ),
    );
    notifier()
      ..removeMessageById(localId)
      ..updateMessageById(serverId, (_) => run.assistant!);
  }

  // The reply's parts as the stream last reported them: re-read as ended
  // once the run settles, so a tool cut short stops showing as running.
  List<Map<String, dynamic>>? lastParts;

  void progress(LibreChatTurnProgress update) {
    confirmAssistant(update.responseMessageId);
    materialize();
    lastParts = update.parts;
    final items = LibreChatMessageMapper.outputItems(
      update.parts,
      inProgress: true,
    );
    final projection = projector.project(parseOpenWebUIStructuredOutput(items));
    switch (projection) {
      case StructuredOutputStreamingAppend(content: final fragment):
        content = '$content$fragment';
        if (ownerActive()) {
          notifier().appendToMessageById(run.assistantMessageId, fragment);
        }
      case StructuredOutputStreamingReplace(content: final replacement):
        content = replacement;
        if (ownerActive()) {
          notifier().replaceMessageContentById(
            run.assistantMessageId,
            replacement,
          );
        }
      case null:
        break;
    }
    run.assistant = run.assistant!.copyWith(content: content, output: items);
  }

  var settled = false;
  void settle({String? error}) {
    if (settled) return;
    settled = true;
    final parts = lastParts;
    final endedItems = parts == null
        ? null
        : LibreChatMessageMapper.outputItems(parts);
    if (endedItems != null) {
      projector.project(parseOpenWebUIStructuredOutput(endedItems));
    }
    final last = projector.finish();
    if (last != null) content = last.content;
    run.assistant = run.assistant!.copyWith(
      content: content,
      output: endedItems ?? run.assistant!.output,
      isStreaming: false,
      error: error == null
          ? run.assistant!.error
          : ChatMessageError(content: error),
    );
    if (ownerActive()) {
      final visible = notifier();
      if (last != null) {
        visible.replaceMessageContentById(run.assistantMessageId, last.content);
      }
      if (endedItems != null) {
        visible.updateMessageById(
          run.assistantMessageId,
          (message) => message.copyWith(output: endedItems),
        );
      }
      if (error != null) {
        visible.updateMessageById(
          run.assistantMessageId,
          (message) =>
              message.copyWith(error: ChatMessageError(content: error)),
        );
      }
      visible.finishStreamingMessage(
        run.assistantMessageId,
        ownerConversationId: owner.notifierConversationId,
        requireConversationOwner: true,
        persistTurn: false,
      );
    }
    registry._finish(run);
    release();
    final conversationId = run.conversationId;
    // Through the account the run wrote for: after a switch, the engine in
    // use is another account's.
    if (conversationId != null &&
        runRef.read(activeLibreChatAccountProvider)?.id == run.accountId) {
      unawaited(_pullLibreChatConversation(runRef, conversationId));
    }
    refuseAdmission(
      LibreChatApiException(
        message: error ?? 'The LibreChat server did not take the message.',
      ),
    );
  }

  run._settleLocally = () => settle();

  final updates = following
      ? runner.follow(
          owner.conversationId!,
          generationCreatedAt: followCreatedAt,
          resume: true,
        )
      : _startLibreChatTurn(runner, request, sleep);
  run._subscription = updates.listen(
    (update) {
      switch (update) {
        case LibreChatTurnStarted(:final generation):
          run.generationCreatedAt = generation.createdAt;
          bindConversation(generation.conversationId);
          if (!admitted.isCompleted) admitted.complete();
          if (run._stopRequested) {
            unawaited(registry.stop(run));
          }
        case LibreChatTurnCreated(:final userMessage):
          confirmUser(userMessage);
          materialize();
        case LibreChatTurnProgress():
          progress(update);
        case LibreChatTurnPaused(:final action):
          materialize();
          run.pendingAction = action;
          updateAssistant(
            (message) => message.copyWith(
              metadata: <String, dynamic>{
                ...?message.metadata,
                kLibreChatPendingActionKey: action,
              },
            ),
          );
        case LibreChatTurnPauseCleared():
          // Answered elsewhere while the stream was away: its card goes,
          // and the reply carries on.
          if (run.pendingAction == null) break;
          run.pendingAction = null;
          if (run.assistant != null) updateAssistant(_withoutPendingAction);
        case LibreChatTurnTitled(:final title):
          applyTitle(title);
        case LibreChatTurnFinished(:final frame):
          final responseId = frame?.responseMessage?['messageId'];
          confirmAssistant(responseId is String ? responseId : null);
          final title = frame?.title;
          if (title != null) applyTitle(title);
          settle();
        case LibreChatTurnFailed(:final message):
          materialize();
          settle(error: message);
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      DebugLogger.error(
        'turn-failed',
        scope: 'librechat/turn',
        error: error,
        stackTrace: stackTrace,
      );
      materialize();
      refuseAdmission(error, stackTrace);
      settle(
        error: error is LibreChatApiException
            ? error.message
            : 'The LibreChat server could not answer.',
      );
    },
    onDone: () {
      // A runner ends with Finished or Failed; anything else ended it early.
      if (!settled) settle();
    },
    cancelOnError: true,
  );
  // Closing the registry ends its runs without settling them.
  unawaited(
    run.done.then(
      (_) => refuseAdmission(
        const LibreChatApiException(
          message: 'The LibreChat server did not take the message.',
        ),
      ),
    ),
  );
  await admitted.future;
}

ChatMessage _withoutPending(ChatMessage message) {
  final metadata = message.metadata;
  if (metadata == null || !metadata.containsKey(_kLibreChatPendingKey)) {
    return message;
  }
  return message.copyWith(
    metadata: Map<String, dynamic>.of(metadata)..remove(_kLibreChatPendingKey),
  );
}

/// Lists the chat the server named, [conversationId], in [database] (the
/// account the turn runs for), while that account is still the one signed
/// in: an envelope stub, as if the server had listed it.
Future<void> _listLibreChatChat(
  dynamic ref,
  AppDatabase? database,
  String conversationId,
  Conversation conversation,
) async {
  if (database == null) return;
  try {
    final current = (ref.read(chatDatabaseRepositoryProvider)
            as ChatDatabaseRepository)
        .libreChatLocation
        ?.database;
    if (!identical(current, database)) return;
    final seconds = conversation.createdAt.millisecondsSinceEpoch ~/ 1000;
    await (ref.read(libreChatChatLocksProvider) as ChatLocks).runExclusive(
      conversationId,
      () => database.chatsDao.upsertEnvelopeStub(
        id: conversationId,
        title: conversation.title,
        createdAt: seconds,
        updatedAt: seconds,
      ),
    );
  } catch (error, stackTrace) {
    DebugLogger.error(
      'list-new-chat-failed',
      scope: 'librechat/turn',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

/// Fetches [conversationId] into the LibreChat database, after a turn ended.
Future<void> _pullLibreChatConversation(
  dynamic ref,
  String conversationId,
) async {
  try {
    final engine =
        ref.read(libreChatSyncEngineProvider) as LibreChatSyncEngine?;
    await engine?.pullChat(conversationId);
  } catch (error, stackTrace) {
    DebugLogger.error(
      'pull-after-turn-failed',
      scope: 'librechat/turn',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

/// [messages] with the live LibreChat run of [conversation] put back: its
/// user message, and its reply as the run last showed it.
List<ChatMessage> _restoreLiveLibreChatRunState(
  dynamic ref,
  List<ChatMessage> messages,
  Conversation? conversation,
) {
  if (conversation == null || !isLibreChatConversation(conversation)) {
    return messages;
  }
  final LibreChatRunRegistry registry;
  try {
    registry = ref.read(libreChatRunRegistryProvider) as LibreChatRunRegistry;
  } catch (_) {
    return messages;
  }
  final run = registry.forConversation(conversation.id);
  final assistant = run?.assistant;
  if (run == null || assistant == null) return messages;
  // A run of the account just left, stopping still, is not this chat's.
  if (run.accountId != ref.read(activeLibreChatAccountProvider)?.id) {
    return messages;
  }
  // A copy of the chat taken before the server named the run's messages
  // still has the ids minted here: those go, for the run's own below.
  // The reply a regeneration replaces goes the same way, for the new one.
  final renamed = run._renamed;
  final replaced = run._replaces;
  String swap(String id) =>
      renamed[id] ?? (id == replaced ? run.assistantMessageId : id);
  final next = <ChatMessage>[
    for (final message in messages)
      if (!renamed.containsKey(message.id) && message.id != replaced)
        renamed.isEmpty && replaced == null
            ? message
            : ChatMessagesNotifier._withRenamedReferences(message, swap),
  ];
  final user = run.user;
  if (user != null && !next.any((message) => message.id == user.id)) {
    next.add(user);
  }
  final index = next.indexWhere((message) => message.id == assistant.id);
  if (index >= 0) {
    next[index] = assistant;
  } else {
    next.add(assistant);
  }
  return List<ChatMessage>.unmodifiable(next);
}

/// Follows a reply the server is still writing in [conversation], opened
/// while no run of this session follows it (after a restart, or a reply
/// started elsewhere).
Future<void> _followLibreChatGenerationOnOpen(
  dynamic ref,
  Conversation conversation,
) async {
  final LibreChatRunRegistry registry;
  final LibreChatStreamClient? streams;
  try {
    registry = ref.read(libreChatRunRegistryProvider) as LibreChatRunRegistry;
    streams = ref.read(libreChatStreamClientProvider) as LibreChatStreamClient?;
  } catch (_) {
    return;
  }
  if (streams == null || registry.forConversation(conversation.id) != null) {
    return;
  }
  final Map<String, dynamic> status;
  try {
    status = await streams.status(conversation.id);
  } catch (_) {
    return;
  }
  if (status['active'] != true) return;
  // The chat notifier calls this with its own ref, which cannot read the
  // messages it holds; the registry's can.
  final runRef = registry._ref;
  final active = runRef.read(activeConversationProvider);
  if (active == null ||
      !isLibreChatConversation(active) ||
      active.id != conversation.id ||
      registry.forConversation(conversation.id) != null) {
    return;
  }
  final messages = runRef.read(chatMessagesProvider);
  final model = runRef.read(selectedModelProvider);
  final createdAt = status['createdAt'];
  final placeholder = ChatMessage(
    id: const Uuid().v4(),
    role: 'assistant',
    content: '',
    timestamp: DateTime.now(),
    model: model?.id,
    isStreaming: true,
    metadata: <String, dynamic>{
      'parentId': messages.lastOrNull?.id,
      'childrenIds': const <String>[],
      'transport': kLibreChatTransport,
      _kLibreChatPendingKey: true,
    },
  );
  await _runLibreChatTurn(
    registry,
    streams: streams,
    owner: _LibreChatConversationOwner(active),
    followCreatedAt: createdAt is int ? createdAt : null,
    assistant: placeholder,
    model: model,
  );
}

/// Stops the LibreChat reply [message], when one of this session's runs
/// writes it. Null when none does.
Future<void>? _stopLibreChatTurn(dynamic ref, ChatMessage message) {
  final LibreChatRunRegistry registry;
  try {
    registry = ref.read(libreChatRunRegistryProvider) as LibreChatRunRegistry;
  } catch (_) {
    return null;
  }
  final run = registry.forMessage(message.id);
  if (run == null) return null;
  return registry.stop(run);
}

/// Regenerates the latest LibreChat reply with [model]: the server answers
/// the last user message again, as a sibling of the old reply, which stays
/// one of the reply's versions.
Future<void> _regenerateLibreChatMessage(
  dynamic ref, {
  required Model model,
}) async {
  final messages = ref.read(chatMessagesProvider) as List<ChatMessage>;
  final replayedIndex = messages.lastIndexWhere(
    (message) => message.role == 'user',
  );
  if (replayedIndex < 0) {
    throw StateError('There is no message to answer again.');
  }
  final replayed = messages[replayedIndex];
  // The server never took this message (its start was refused), so it has
  // nothing to answer again: the message goes out as a new turn instead.
  if (replayed.metadata?[_kLibreChatPendingKey] == true) {
    await _sendLibreChatMessage(
      ref,
      replayed.content,
      reattachLibreChatFiles(ref, replayed),
      model: model,
      toolIds: ref.read(selectedToolIdsProvider) as List<String>,
      replacing: replayed,
    );
    return;
  }
  final active = ref.read(activeConversationProvider) as Conversation?;
  // One turn at a time, as for a send: asked again here, after the checks
  // before it waited, and before the reply is replaced. Whoever changed the
  // transcript for this puts it back.
  if (isLibreChatReplyRunning(ref, active)) {
    throw const LibreChatReplyRunningException();
  }
  final target = libreChatTargetOf(model);
  final streams =
      ref.read(libreChatStreamClientProvider) as LibreChatStreamClient?;
  if (active == null || target == null || streams == null) {
    throw StateError('The selected LibreChat model is not available.');
  }
  // Answered again as it was asked: with the message's files, and the tools
  // chosen now, as a send takes them.
  final files =
      (ref.read(libreChatUploadedFilesProvider.notifier)
              as LibreChatUploadedFiles)
          .recordsFor(reattachLibreChatFiles(ref, replayed) ?? const []);
  final tools = libreChatModelTakesTools(model)
      ? libreChatToolSelectionFor(
          ref.read(selectedToolIdsProvider) as List<String>,
        )
      : const LibreChatToolSelection();
  final previous = messages.lastOrNull?.role == 'assistant'
      ? messages.last
      : null;
  final placeholder = ChatMessage(
    id: const Uuid().v4(),
    role: 'assistant',
    content: '',
    timestamp: DateTime.now(),
    model: model.id,
    isStreaming: true,
    versions: previous == null
        ? const <ChatMessageVersion>[]
        : _buildReplayVersions(previous),
    metadata: <String, dynamic>{
      'parentId': replayed.id,
      'childrenIds': const <String>[],
      'transport': kLibreChatTransport,
      _kLibreChatPendingKey: true,
      if (model.name.trim().isNotEmpty) 'modelName': model.name.trim(),
    },
  );
  final notifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  notifier.setMessages([
    ...messages.sublist(0, replayedIndex + 1),
    placeholder,
  ]);
  final parent = replayed.metadata?['parentId'];
  final request = LibreChatTurnRequest(
    text: replayed.content,
    endpoint: target.endpoint,
    endpointType: target.endpointType,
    model: target.model,
    agentId: target.agentId,
    spec: target.spec,
    conversationId: active.id,
    parentMessageId: parent is String ? parent : null,
    clientRequestId: const Uuid().v4(),
    isRegenerate: true,
    overrideParentMessageId: replayed.id,
    files: [for (final file in files) libreChatTurnFile(file)],
    ephemeralAgent: tools.toEphemeralAgent(),
    parameters: _libreChatParametersFor(target),
  );
  await _runLibreChatTurn(
    ref.read(libreChatRunRegistryProvider) as LibreChatRunRegistry,
    streams: streams,
    owner: _LibreChatConversationOwner(active),
    request: request,
    assistant: placeholder,
    model: model,
    replaces: previous?.id,
  );
}

/// The pending action of the LibreChat run writing reply [messageId], or
/// null when none waits.
LibreChatPendingAction? libreChatPendingActionFor(
  dynamic ref,
  String messageId,
) {
  final registry =
      ref.read(libreChatRunRegistryProvider) as LibreChatRunRegistry;
  final action = registry.forMessage(messageId)?.pendingAction;
  return action == null ? null : LibreChatPendingAction(action);
}

/// Answers the approval or questions the LibreChat run writing reply
/// [messageId] paused on, with [decisions] for tool calls or [answers] for
/// questions. The run carries on on the stream it was already following.
///
/// LibreChat resumes only with the settings the turn paused with, so the
/// body repeats the turn's own request; a turn followed after reopening its
/// chat never sent one here, and repeats the selected model's instead.
Future<void> resolveLibreChatPendingAction(
  dynamic ref,
  String messageId, {
  Map<String, LibreChatToolDecisionInput>? decisions,
  Map<String, String>? answers,
}) async {
  final registry =
      ref.read(libreChatRunRegistryProvider) as LibreChatRunRegistry;
  final streams =
      ref.read(libreChatStreamClientProvider) as LibreChatStreamClient?;
  final run = registry.forMessage(messageId);
  final raw = run?.pendingAction;
  if (run == null || raw == null || streams == null) {
    throw StateError('The paused LibreChat reply is no longer running.');
  }
  final answering = run._answering;
  if (answering != null && _sameLibreChatPause(answering.action, raw)) {
    return answering.request;
  }
  final action = LibreChatPendingAction(raw);
  final turn = run.turn.isNotEmpty
      ? run.turn
      : _libreChatTurnSettingsFor(
          ref.read(selectedModelProvider) as Model?,
          run.conversationId,
        );
  final body = answers != null
      ? action.resumeWithAnswers(
          answers: answers,
          turn: turn,
          generationCreatedAt: run.generationCreatedAt,
        )
      : action.resumeWithDecisions(
          decisions: decisions ?? const {},
          turn: turn,
          generationCreatedAt: run.generationCreatedAt,
        );
  final request = streams.resumeAfterAction(body);
  run._answering = (action: raw, request: request);
  try {
    await request;
  } finally {
    if (identical(run._answering?.action, raw)) run._answering = null;
  }
  if (!_sameLibreChatPause(run.pendingAction, raw)) return;
  run.pendingAction = null;
  final assistant = run.assistant;
  if (assistant != null) run.assistant = _withoutPendingAction(assistant);
  // The caller's ref may be a page's, gone if it closed during the resume;
  // the run's registry outlives it.
  registry._ref
      .read(chatMessagesProvider.notifier)
      .updateMessageById(run.assistantMessageId, _withoutPendingAction);
}

/// Whether [a] and [b] are the same pause: one map, or one `actionId` -- a
/// reconnect's snapshot reports the pause it already had as a new map.
bool _sameLibreChatPause(Map<String, dynamic>? a, Map<String, dynamic>? b) {
  if (identical(a, b)) return true;
  final id = a?['actionId'];
  return id is String && id.isNotEmpty && id == b?['actionId'];
}

ChatMessage _withoutPendingAction(ChatMessage message) {
  final metadata = message.metadata;
  if (metadata == null || !metadata.containsKey(kLibreChatPendingActionKey)) {
    return message;
  }
  return message.copyWith(
    metadata: Map<String, dynamic>.of(metadata)
      ..remove(kLibreChatPendingActionKey),
  );
}

/// The settings a turn with [model] in [conversationId] runs with, for a
/// resume whose original request is not at hand.
Map<String, dynamic> _libreChatTurnSettingsFor(
  Model? model,
  String? conversationId,
) {
  final target = model == null ? null : libreChatTargetOf(model);
  if (target == null) {
    return <String, dynamic>{'conversationId': conversationId};
  }
  return <String, dynamic>{
    ..._libreChatParametersFor(target),
    'endpoint': target.endpoint,
    'endpointType': ?target.endpointType,
    'model': ?target.model,
    'agent_id': ?target.agentId,
    'spec': ?target.spec,
    'conversationId': conversationId,
  };
}
