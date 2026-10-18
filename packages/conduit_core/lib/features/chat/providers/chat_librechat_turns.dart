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
  });

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

final class LibreChatRunRegistry {
  LibreChatRunRegistry._(this._ref);

  final Ref _ref;
  final List<LibreChatRun> _runs = <LibreChatRun>[];

  /// The run generating in [conversationId], if any.
  LibreChatRun? forConversation(String? conversationId) =>
      conversationId == null
      ? null
      : _runs
            .where((run) => run.conversationId == conversationId && !run.isDone)
            .lastOrNull;

  /// The run whose reply is [messageId], if any.
  LibreChatRun? forMessage(String messageId) =>
      _runs.where((run) => run.assistantMessageId == messageId).lastOrNull;

  bool isGenerating(String conversationId) =>
      forConversation(conversationId) != null;

  void _add(LibreChatRun run) => _runs.add(run);

  void _bind(LibreChatRun run, String conversationId) {
    run.conversationId = conversationId;
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

/// A spec's preset, sent as the turn's parameters (model settings, tools).
Map<String, dynamic> _libreChatParametersFor(LibreChatTarget target) =>
    target.kind == LibreChatTargetKind.spec
    ? Map<String, dynamic>.of(target.preset)
    : const <String, dynamic>{};

String _libreChatDraftTitle(String text) {
  final line = text.trim().split('\n').first.trim();
  if (line.isEmpty) return 'New Chat';
  return line.length <= 60 ? line : '${line.substring(0, 57)}...';
}

/// Sends [message] in the active LibreChat chat, or starts one, with
/// [model].
Future<void> _sendLibreChatMessage(
  dynamic ref,
  String message,
  List<String>? attachments, {
  required Model model,
  ChatSendVoiceContext? voice,
  void Function(ChatSendPlaceholderHandle handle)?
  onAssistantPlaceholderCreated,
}) async {
  if (attachments != null && attachments.isNotEmpty) {
    throw StateError('Attachments are not available in LibreChat chats yet.');
  }
  if (voice?.reply != null) {
    throw StateError('LibreChat chats do not keep spoken answers.');
  }
  final active = ref.read(activeConversationProvider) as Conversation?;
  if (active != null && !isLibreChatConversation(active)) {
    throw StateError('A LibreChat model can only continue a LibreChat chat.');
  }
  final target = libreChatTargetOf(model);
  final streams =
      ref.read(libreChatStreamClientProvider) as LibreChatStreamClient?;
  if (target == null || streams == null) {
    throw StateError('The selected LibreChat model is not available.');
  }
  final mutationOwner = captureChatMutationOwner(ref, active);
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
    parameters: _libreChatParametersFor(target),
  );
  await _runLibreChatTurn(
    ref.read(libreChatRunRegistryProvider) as LibreChatRunRegistry,
    streams: streams,
    owner: _LibreChatConversationOwner(active),
    request: request,
    user: user,
    assistant: placeholder,
    model: model,
    sendHandle: handle,
  );
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
          turn: request?.toJson() ?? <String, dynamic>{},
        )
        ..user = user
        ..assistant = assistant;
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

  ChatMessagesNotifier notifier() => runRef.read(chatMessagesProvider.notifier);
  bool ownerActive() => owner.isActive(runRef);

  void updateAssistant(ChatMessage Function(ChatMessage message) change) {
    run.assistant = change(run.assistant!);
    if (ownerActive()) {
      notifier().updateMessageById(run.assistantMessageId, change);
    }
  }

  // A followed turn shows its messages once the stream says what they are.
  void materialize() {
    if (materialized) return;
    materialized = true;
    if (!ownerActive()) return;
    final current = runRef.read(chatMessagesProvider);
    final runUser = run.user;
    notifier().addMessages([
      if (runUser != null && !current.any((m) => m.id == runUser.id)) runUser,
      if (!current.any((m) => m.id == run.assistantMessageId)) run.assistant!,
    ]);
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
    if (ownerActive()) {
      notifier()
        ..renameMessage(localId, serverId)
        ..updateMessageById(serverId, _withoutPending);
    }
    run.assistantMessageId = serverId;
    run.assistant = _withoutPending(run.assistant!.copyWith(id: serverId));
  }

  void progress(LibreChatTurnProgress update) {
    confirmAssistant(update.responseMessageId);
    materialize();
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
    final last = projector.finish();
    if (last != null) content = last.content;
    run.assistant = run.assistant!.copyWith(
      content: content,
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
    if (conversationId != null) {
      unawaited(_pullLibreChatConversation(runRef, conversationId));
    }
  }

  run._settleLocally = () => settle();

  final updates = following
      ? runner.follow(
          owner.conversationId!,
          generationCreatedAt: followCreatedAt,
          resume: true,
        )
      : _startLibreChatTurn(runner, request, sleep);
  final finished = Completer<void>();
  run._subscription = updates.listen(
    (update) {
      switch (update) {
        case LibreChatTurnStarted(:final generation):
          run.generationCreatedAt = generation.createdAt;
          bindConversation(generation.conversationId);
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
      settle(
        error: error is LibreChatApiException
            ? error.message
            : 'The LibreChat server could not answer.',
      );
      if (!finished.isCompleted) finished.complete();
    },
    onDone: () {
      // A runner ends with Finished or Failed; anything else ended it early.
      if (!settled) settle();
      if (!finished.isCompleted) finished.complete();
    },
    cancelOnError: true,
  );
  await Future.any<void>([finished.future, run.done]);
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
  final next = List<ChatMessage>.of(messages);
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
  final active = ref.read(activeConversationProvider) as Conversation?;
  final target = libreChatTargetOf(model);
  final streams =
      ref.read(libreChatStreamClientProvider) as LibreChatStreamClient?;
  if (active == null || target == null || streams == null) {
    throw StateError('The selected LibreChat model is not available.');
  }
  final messages = ref.read(chatMessagesProvider) as List<ChatMessage>;
  final previous = messages.lastOrNull?.role == 'assistant'
      ? messages.last
      : null;
  final replayedIndex = messages.lastIndexWhere(
    (message) => message.role == 'user',
  );
  if (replayedIndex < 0) {
    throw StateError('There is no message to answer again.');
  }
  final replayed = messages[replayedIndex];
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
    parameters: _libreChatParametersFor(target),
  );
  await _runLibreChatTurn(
    ref.read(libreChatRunRegistryProvider) as LibreChatRunRegistry,
    streams: streams,
    owner: _LibreChatConversationOwner(active),
    request: request,
    assistant: placeholder,
    model: model,
  );
}
