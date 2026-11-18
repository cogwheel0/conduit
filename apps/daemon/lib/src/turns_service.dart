import 'dart:async';
import 'dart:collection';

import 'package:collection/collection.dart';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/database/chat_database_repository.dart'
    show ChatStorageKind;
import 'package:conduit_core/features/chat/models/chat_context_attachment.dart';
import 'package:conduit_core/features/chat/providers/attached_files_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/providers/context_attachments_provider.dart';
import 'package:conduit_core/features/chat/providers/openwebui_chat_prompt_provider.dart';
import 'package:conduit_core/features/chat/providers/openwebui_prompt_resolution.dart';
import 'package:conduit_core/features/chat/providers/queued_completion_provider.dart';
import 'package:conduit_core/features/chat/services/chat_draft_queue.dart';
import 'package:conduit_core/features/chat/services/chat_message_actions.dart';
import 'package:conduit_core/features/chat/services/historical_message_regeneration.dart';
import 'package:conduit_core/features/chat/utils/message_targeting.dart';
import 'package:conduit_core/features/chat/utils/openwebui_tasks.dart';
import 'package:conduit_core/features/chat/views/assistant_message_blocks.dart';
import 'package:conduit_core/features/chat/voice_mode/chat_voice_send.dart';
import 'package:conduit_core/features/direct_connections/models/direct_completion.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart'
    show
        DirectChatInputException,
        kDirectMcpApprovalMetadataKey,
        kDirectTransport;
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/hermes/controllers/hermes_busy_turn_controller.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/models/hermes_approval_cost.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart'
    show HermesSteerUncertain;
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart'
    show kHermesApprovalMeta, kHermesTransport;
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart'
    show TerminalFileRequest, terminalDisplayFileProvider;
import 'package:conduit_core/features/terminal/models/terminal_agent_model.dart'
    show
        isTerminalAgentModelId,
        terminalAgentDisplayName,
        terminalAgentTerminalId;
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/features/chat/providers/temporary_chat_save.dart';
import 'package:conduit_core/models/chat_comparison.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/file_info.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/openwebui_chat_prompt.dart';
import 'package:conduit_core/models/openwebui_chat_settings.dart'
    show OpenWebUiChatSettingsAccess, kChatParamSystem;
import 'package:conduit_core/ports/ui_request_port.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/primary_account_providers.dart'
    show PrimaryAccountRef, primaryAccountProvider;
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/message_rating.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/features/librechat/models/librechat_tools.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart'
    show isLibreChatModel;
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart'
    show libreChatSessionHandleProvider;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';

import 'apple_models_service.dart' show appleErrorType;
import 'chat_prompts_service.dart';
import 'chats_service.dart' show ChatTurns;
import 'composer_wire.dart';
import 'account_scope.dart';
import 'event_bus.dart';
import 'files_service.dart';
import 'hermes_cards_service.dart';
import 'hermes_service.dart';
import 'librechat_pauses.dart';
import 'message_blocks.dart';
import 'models_service.dart';
import 'queued_completions_service.dart';
import 'servers_service.dart' show AddressReplies;
import 'settled.dart';
import 'temporary_chats.dart';
import 'ui_requests_service.dart';

/// Implements `turns.*` by driving the core's chat library, the one mobile
/// streams through.
///
/// Each chat with a turn in it gets a [ChatSessionScope]: the chat library's
/// per-conversation state (the open chat, its transcript, the composer's
/// model and toggles) in a child container of its own. A turn is started
/// through the same entry points the phone's composer uses -- [durableSend],
/// [regenerateHistoricalMessageById], [resendEditedUserMessage] and the stop
/// provider -- with the scope as `ref`, and streams into that scope's own
/// transcript. So a user can start a turn, open another chat and start
/// another, and both answer at once, through one pipeline for Open WebUI,
/// direct connections and Hermes alike.
///
/// What this class adds is what the phone's screen does around the
/// pipeline:
///
/// * it projects the scope's transcript onto the `turn.*` events, coalesced
///   to 60 Hz -- the text as `turn.delta`, the parsed answer as
///   `turn.blocks` -- and answers a window that subscribes mid-turn with the
///   answer so far ([progress]); every window, whichever chat it shows,
///   hears `turn.finished`;
/// * it asks the user, through `ui.request`, for the approvals the pipeline
///   leaves for the screen to show: a direct connection's MCP tool, a Hermes
///   agent wanting to act. Open WebUI's own prompts reach the user through
///   the core's [UiRequestPort], which the daemon binds;
/// * it tells the windows when the stored copy has the answer
///   (`chats.changed`), and when the server renamed or tagged the chat.
///
/// A scope lives while its turn runs and for [lingerAfterTurn] afterwards,
/// for the title, tags and follow-ups the server sends once the answer is
/// done. It is disposed sooner when the account changes or the user signs
/// out: its chat belongs to the account it was opened under.
final class TurnsService implements ChatTurns, AddressReplies {
  TurnsService(
    this._container,
    this._events, {
    TemporaryChats? temporary,
    UiRequestsService? uiRequests,
    HermesService? hermes,
    FilesService? files,
    ChatPromptsService? chatPrompts,
    QueuedCompletionsService? queued,
    DateTime Function()? now,
    Future<void> Function(Duration)? pause,
  }) : temporary = temporary ?? TemporaryChats(),
       _now = now ?? DateTime.now,
       _pause = pause ?? Future<void>.delayed,
       _ownClock = pause != null,
       _uiRequests = uiRequests,
       _hermes = hermes,
       _files = files,
       _chatPrompts = chatPrompts,
       _queuedCompletions = queued {
    // A chat keeps its scope while it has answers waiting to go out, so one
    // that goes out streams there; once none wait it may go.
    queued?.onChanged = (chatId) {
      for (final session in _sessions) {
        if (session.chatId != chatId) continue;
        _handOffQueued(session);
        _scheduleLinger(session);
      }
    };
    // Open WebUI's questions and approvals in a chat: the ones saved in a
    // stored answer are found, and answered, in that chat's scope.
    chatPrompts
      ?..storedPrompt = storedPrompt
      ..resolveStored = resolveStoredPrompt;
    // A chat belongs to the account it was opened under. On another
    // account, or none, every scope goes, and a running turn with it.
    _accountWatches = <ProviderSubscription<Object?>>[
      _container.listen<Object?>(openWebUiAuthSessionEpochProvider, (
        previous,
        next,
      ) {
        _closeAll(reason: 'account-changed');
        this.temporary.clear();
      }),
      _container.listen<Object?>(apiServiceProvider, (previous, next) {
        if (!identical(previous, next)) _closeAll(reason: 'session-changed');
      }),
      // The account in charge of the chats: one LibreChat account after
      // another changes neither Open WebUI's session nor its client.
      _container.listen<PrimaryAccountRef>(primaryAccountProvider, (
        previous,
        next,
      ) {
        if (previous == null || previous == next) return;
        _closeAll(reason: 'account-changed');
        this.temporary.clear();
      }),
      // The terminal the account selects (`terminal.select`) is every open
      // chat's from then on: whichever way its next turn goes out (typed,
      // a queued batch, words in a call), its tools run there.
      _container.listen<String?>(selectedTerminalIdProvider, (previous, next) {
        for (final session in _sessions) {
          if (!session.scope.isDisposed) {
            _followAccountTerminal(session.scope.container);
          }
        }
      }),
    ];
    _remaps = _container
        .read(syncEngineProvider.notifier)
        .remapEvents
        .where((event) => event.entityKind == 'chat')
        .listen((event) => _followRemap(event.fromId, event.toId));
  }

  final ProviderContainer _container;
  final EventBus _events;

  /// The clock and the pause the waits before a turn ([_untilQuiet],
  /// [_settleBeforeTurn]) measure and wait with; a test passes its own.
  final DateTime Function() _now;
  final Future<void> Function(Duration) _pause;
  final bool _ownClock;

  /// Conversations the server never stores. Shared with `ChatsService`,
  /// which answers `chats.get` for them from the same memory.
  final TemporaryChats temporary;

  /// Where the approvals this class hosts are asked. Without one they are
  /// denied, as the pipeline's own questions are with no window attached.
  final UiRequestsService? _uiRequests;

  /// Hermes sessions' transcripts, for opening a Hermes chat in a scope and
  /// refreshing what `chats.get` shows after a turn.
  final HermesService? _hermes;

  /// What this daemon uploaded, to name a queued message's files.
  final FilesService? _files;

  /// Where Open WebUI's prompts in a chat wait for an answer.
  final ChatPromptsService? _chatPrompts;

  /// Answers waiting in the outbox (sent while offline, or failed).
  final QueuedCompletionsService? _queuedCompletions;

  late final List<ProviderSubscription<Object?>> _accountWatches;
  StreamSubscription<Object?>? _remaps;
  final List<_ChatSession> _sessions = <_ChatSession>[];

  /// The answers this daemon announced (`turn.started` or `turn.finished`),
  /// newest last: the windows notify for those themselves, so the server's
  /// own word of them (its socket's `chat:completion`) is not another.
  final LinkedHashSet<String> _announced = LinkedHashSet<String>();

  void _remember(String messageId) {
    if (messageId.isEmpty) return;
    _announced
      ..remove(messageId)
      ..add(messageId);
    if (_announced.length > 512) _announced.remove(_announced.first);
  }

  /// Whether this daemon announced the answer [messageId] (it ran it, or
  /// followed it in a chat it holds), so its windows notify for it.
  bool announced(String messageId) => _announced.contains(messageId);
  bool _disposed = false;

  /// Coalescing window for `turn.delta`: a 60 Hz ceiling. A fast model emits
  /// tokens far quicker than that, and every extra frame costs a JSON
  /// encode, a socket write and a markdown parse for text nobody can read at
  /// that rate.
  static const Duration _deltaInterval = Duration(milliseconds: 16);

  /// How long a chat's scope outlives its turn. The server sends a new
  /// chat's title, its tags and the follow-up suggestions after the answer,
  /// over the chat's socket subscription, which lives in the scope.
  /// Assignable so a test can shorten it.
  static Duration lingerAfterTurn = const Duration(seconds: 30);

  /// How long to keep looking for a finished answer in the server's copy
  /// before telling the windows it changed. Open WebUI writes the answer
  /// when its own stream handler finishes, which is not the moment ours
  /// does. Assignable so a test can shorten it.
  static List<Duration> syncRetryDelays = const <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];

  /// Chats currently generating, for the sidebar's spinner.
  @override
  Iterable<String> get activeChatIds => <String>[
    for (final session in _sessions)
      if (session.turn case final turn? when !turn.finished) turn.chatId,
  ];

  /// Whether an Open WebUI answer is being written: one that arrives
  /// through the active account's address, unlike a direct or Hermes one,
  /// which this process talks to the provider for itself.
  @override
  bool get addressAnswering => _sessions.any(
    (session) => switch (session.turn) {
      final turn? => !turn.finished && !turn.clientOwned,
      null => false,
    },
  );

  /// Stops the answers [addressAnswering] counts.
  @override
  Future<void> stopAddressAnswers() async {
    final chats = [
      for (final session in _sessions)
        if (session.turn case final turn?
            when !turn.finished && !turn.clientOwned)
          turn.chatId,
    ];
    for (final chatId in chats) {
      await stop(chatId);
    }
  }

  /// Whether [chatId] is answering, or about to.
  @override
  bool isRunning(String chatId) {
    final session = _sessionOf(chatId);
    return session != null && _busy(session);
  }

  /// Whether [chatId] has a scope here: a turn, a merge or a queue in it,
  /// or one just finished.
  bool hasScope(String chatId) => _sessionOf(chatId) != null;

  /// The chat whose send holds Hermes session [sessionId], so a question
  /// about that send is the chat's alone: the one chat with a running send
  /// that holds the session (its `local:hermes_` chat, a chat that names the
  /// session, or an Open WebUI chat with a Hermes answer of that session).
  /// Null, so the question is not asked, when no running send holds it or
  /// several do: an old answer of the session in another chat never takes
  /// it.
  String? hermesChatOf(String sessionId) {
    if (sessionId.isEmpty) return null;
    bool holds(_ChatSession session) {
      final chatId = session.chatId;
      if (chatId == '$kHermesSessionConversationIdPrefix$sessionId') {
        return true;
      }
      final conversation = session.scope.conversation;
      if (conversation?.metadata['hermesSessionId']?.toString() == sessionId) {
        return true;
      }
      return session.scope.messages.any(
        (m) => m.metadata?['hermesSessionId']?.toString() == sessionId,
      );
    }

    bool sending(_ChatSession session) {
      final turn = session.turn;
      return session.pending != null || (turn != null && !turn.finished);
    }

    final live = <_ChatSession>[
      for (final session in _sessions)
        if (!session.scope.isDisposed && (session.chatId ?? '').isNotEmpty)
          session,
    ];
    final holding = <_ChatSession>[
      for (final session in live)
        if (sending(session) && holds(session)) session,
    ];
    return holding.length == 1 ? holding.single.chatId : null;
  }

  @override
  Future<void> settled(String chatId) async {
    final settling = _sessionOf(chatId)?.settling;
    if (settling == null) return;
    await settling.timeout(_settleTimeout, onTimeout: () {});
  }

  /// Whether a merge (Merge Responses) is writing in [chatId].
  @override
  bool mergeRunning(String chatId) => _sessionOf(chatId)?.merge != null;

  @override
  List<ChatMessage>? openMessages(String chatId) {
    final session = _sessionOf(chatId);
    if (session == null || session.scope.isDisposed) return null;
    return List<ChatMessage>.of(session.scope.messages);
  }

  /// Lets go of [chatId]'s scope when nothing runs in it: its transcript was
  /// read before the stored copy changed (another branch, say), and the next
  /// turn must start from the stored one.
  @override
  void forgetIdle(String chatId) {
    final session = _sessionOf(chatId);
    final pending = session?.pending;
    if (session == null ||
        session.holds > 0 ||
        // A send still on its way owns the scope; one that has gone out and
        // whose answer finished only waits for the stored copy, which the
        // settle reads from the account's container.
        (pending != null &&
            (!pending.sendSettled || !pending.started.isCompleted)) ||
        session.merge != null ||
        isRunning(chatId) ||
        _queued(session)) {
      return;
    }
    _close(session);
  }

  /// [chatId]'s running turn as a window that subscribes now needs it: the
  /// whole answer so far, or null when nothing is running there.
  ///
  /// A new chat's id reaches the window with the reply to `turns.send`, and
  /// `turn.started` has gone out by then to no one subscribed to it -- so
  /// without this the composer offered Send in a busy chat until the first
  /// token.
  TurnDelta? progress(String chatId) {
    final session = _sessionOf(chatId);
    final turn = session?.turn;
    if (session == null || turn == null || turn.finished || !turn.announced) {
      return null;
    }
    _refreshText(session, turn);
    return TurnDelta(
      chatId: turn.chatId,
      messageId: turn.messageId,
      text: turn.text,
    );
  }

  /// [chatId]'s running answer, parsed, as a window that subscribes now
  /// needs it; null when nothing is running there.
  TurnBlocks? progressBlocks(String chatId) {
    final session = _sessionOf(chatId);
    final turn = session?.turn;
    if (session == null || turn == null || turn.finished || !turn.announced) {
      return null;
    }
    _refreshText(session, turn);
    return _blocks(session, turn);
  }

  /// Sends [sessionId] what it missed in the chats [subscription] names.
  ///
  /// For a chat answering now, the answer so far as a `turn.delta` and a
  /// `turn.blocks`, whether or not the window was listening before (a
  /// snapshot is harmless), after its `turn.started` for a chat the window
  /// only now adds (it names a comparison's other answers). For a chat it has only now added, whose answer
  /// finished since the window could last have seen it -- a fast model can
  /// finish before `turns.send` returns the new chat's id -- that turn's
  /// final `turn.blocks` and its `turn.completed` or `turn.failed`, for as
  /// long as its scope lingers.
  void catchUp(
    String sessionId,
    EventSubscription subscription, {
    Set<String> alreadySubscribed = const <String>{},
  }) {
    bool wants(String event) =>
        subscription.events.isEmpty || subscription.events.contains(event);
    for (final chatId in subscription.scopes) {
      final running = progress(chatId);
      if (running != null) {
        // Which answers the turn writes: a new chat's window subscribes after
        // `turn.started` went out, and a comparison's columns are named only
        // there.
        final turn = _sessionOf(chatId)?.turn;
        if (turn != null &&
            !alreadySubscribed.contains(chatId) &&
            wants(ConduitEvents.turnStarted)) {
          _events.emitTo(
            sessionId,
            ConduitEventSpecs.turnStarted,
            TurnStarted(
              chatId: turn.chatId,
              messageId: turn.messageId,
              model: turn.model,
              companionIds: turn.companions.keys.toList(growable: false),
            ),
            scope: chatId,
          );
        }
        if (wants(ConduitEvents.turnDelta)) {
          _events.emitTo(
            sessionId,
            ConduitEventSpecs.turnDelta,
            running,
            scope: chatId,
          );
        }
        final blocks = progressBlocks(chatId);
        if (blocks != null && wants(ConduitEvents.turnBlocks)) {
          _events.emitTo(
            sessionId,
            ConduitEventSpecs.turnBlocks,
            blocks,
            scope: chatId,
          );
        }
        // A comparison's other answers, as far as they have got.
        final session = _sessionOf(chatId);
        if (session != null && turn != null) {
          for (final entry in turn.companions.entries) {
            final companion = entry.value;
            if (wants(ConduitEvents.turnDelta) && !companion.finished) {
              _events.emitTo(
                sessionId,
                ConduitEventSpecs.turnDelta,
                TurnDelta(
                  chatId: turn.chatId,
                  messageId: entry.key,
                  text: companion.text,
                ),
                scope: chatId,
              );
            }
            if (wants(ConduitEvents.turnBlocks)) {
              _events.emitTo(
                sessionId,
                ConduitEventSpecs.turnBlocks,
                _companionBlocks(
                  session,
                  turn,
                  entry.key,
                  finished: companion.finished,
                ),
                scope: chatId,
              );
            }
            // One already over says so: the window that just met it would
            // otherwise keep it streaming until the whole turn ends.
            if (companion.completed case final completed?
                when wants(ConduitEvents.turnCompleted)) {
              _events.emitTo(
                sessionId,
                ConduitEventSpecs.turnCompleted,
                completed,
                scope: chatId,
              );
            } else if (companion.failed case final failed?
                when wants(ConduitEvents.turnFailed)) {
              _events.emitTo(
                sessionId,
                ConduitEventSpecs.turnFailed,
                failed,
                scope: chatId,
              );
            }
          }
        }
        continue;
      }
      if (alreadySubscribed.contains(chatId)) continue;
      final ended = _sessionOf(chatId)?.ended;
      if (ended == null) continue;
      if (wants(ConduitEvents.turnBlocks)) {
        _events.emitTo(
          sessionId,
          ConduitEventSpecs.turnBlocks,
          ended.blocks,
          scope: chatId,
        );
      }
      if (ended.completed case final completed?
          when wants(ConduitEvents.turnCompleted)) {
        _events.emitTo(
          sessionId,
          ConduitEventSpecs.turnCompleted,
          completed,
          scope: chatId,
        );
      }
      if (ended.failed case final failed?
          when wants(ConduitEvents.turnFailed)) {
        _events.emitTo(
          sessionId,
          ConduitEventSpecs.turnFailed,
          failed,
          scope: chatId,
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // turns.*
  // ---------------------------------------------------------------------------

  Future<SendTurnAccepted> send(SendTurn request) async {
    // The account the words are for: every wait below (the model, the
    // rights, the chat) is followed by its check, last as the turn starts.
    final account = AccountScope.capture(_container);
    _refuseDeleted(request.chatId);
    // `@` users and channels and `$` skills, in Open WebUI's wire format.
    final text = composerWireText(request.text, request.mentions).trim();
    if (text.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'turns.send needs a non-empty text',
      );
    }
    // A comparison runs on its own models: the first is the one chosen.
    final model = await _resolveModel(
      request.compareModels.isNotEmpty
          ? request.compareModels.first
          : request.model,
    );
    account.require('the model was read');
    if (request.chatId == null) {
      await _requireChatParamsAccess(model, request, account);
    }
    await _requireBackendFor(model);
    account.require('the backend was ready');
    final session = await _sessionFor(request.chatId, account: account);
    _Claim? claim;
    try {
      claim = await _requireIdle(session);
      final scope = session.scope.container;
      _choose(
        scope,
        model,
        webSearch: request.webSearch,
        imageGeneration: request.imageGeneration,
        codeInterpreter: request.codeInterpreter,
        toolIds: request.toolIds,
        filterIds: request.filterIds,
        temporary: request.chatId == null
            ? request.temporary
            : temporary.contains(request.chatId!),
      );
      if (request.chatId == null) {
        // A new chat: made in its folder ("New Chat in Folder"), so the
        // folder's prompt and knowledge apply from the first answer, and
        // with the settings its window kept for it (`chatSettings.*`).
        // Checked again here, as they are stored: the rights were the
        // asking account's, and the waits since could have let another in.
        account.require('the chat settings were stored');
        final folderId = request.folderId;
        if (folderId != null && folderId.isNotEmpty) {
          scope.read(pendingFolderIdProvider.notifier).set(folderId);
        }
        final params = request.chatParams;
        if (params != null && params.isNotEmpty) {
          scope
              .read(pendingOpenWebUiChatSettingsProvider.notifier)
              .replace(params);
        }
      }
      // Knowledge bases chosen with `#`: the composer's context attachments,
      // which the core sends as Open WebUI's own client does.
      final knowledge = <ChatContextAttachment>[
        for (final base in request.knowledge)
          ChatContextAttachment.knowledgeBase(
            id: base.id,
            name: base.name,
            description: base.description,
          ),
        // Web pages, transcripts, notes and knowledge files.
        for (final context in request.context) contextFromDto(context),
      ];
      if (request.compareModels.isNotEmpty) {
        return await _compare(session, request, text, knowledge, account);
      }
      return await _run(
        session,
        account: account,
        refuseIfBusy: true,
        modelId: model.id,
        userMessageId: null,
        start: (onPlaceholder) => durableSend(
          scope,
          text,
          request.fileIds.isEmpty ? null : request.fileIds,
          toolIds: request.toolIds.isEmpty ? null : request.toolIds,
          contextAttachments: knowledge,
          onAssistantPlaceholderCreated: onPlaceholder,
        ),
      );
    } finally {
      claim?.end();
      _release(session);
    }
  }

  /// A new Open WebUI chat's settings ([SendTurn.chatParams]) are saved as
  /// it is made: held to the rule `chatSettings.save` keeps, the system
  /// prompt by the account's prompt right and the rest by its parameters
  /// right. A Direct or Hermes chat keeps no Open WebUI settings.
  ///
  /// The rights are [account]'s: another account in charge once they are
  /// read gets nothing stored or sent.
  Future<void> _requireChatParamsAccess(
    Model model,
    SendTurn request,
    AccountScope account,
  ) async {
    final params = request.chatParams;
    if (params == null || params.isEmpty) return;
    // Only a chat this device runs keeps no Open WebUI settings: Hermes, or
    // a Direct connection of its own. A server's own connection is still
    // the server's chat, held to its rights.
    if (isHermesModel(model) ||
        _container.read(directModelRegistryProvider).resolve(model)?.source ==
            DirectModelSource.device) {
      return;
    }
    OpenWebUiChatSettingsAccess access;
    try {
      access = await readSettled(
        _container,
        openWebUiChatSettingsAccessProvider.future,
      );
    } on Object {
      access = OpenWebUiChatSettingsAccess.denied;
    }
    account.require('its chat rights were read');
    for (final key in params.keys) {
      final allowed = key == kChatParamSystem
          ? access.canEditSystemPrompt
          : access.canEditParameters;
      if (!allowed) {
        throw RpcError(
          code: ConduitErrorCodes.unauthorized,
          args: const <String, String>{'reason': 'permissionDenied'},
          debugMessage: 'this account may not set "$key" on a chat',
        );
      }
    }
  }

  /// Compare Models: one message to two models, as one durable Open WebUI
  /// turn (the core's [durableCompareSend]); the server answers each under
  /// its own message id.
  ///
  /// The windows follow the first model's answer as the turn, and the
  /// others as its companions (`turn.started` names them): each streams
  /// under its own id and ends with its own `turn.completed` or
  /// `turn.failed`; the turn ends once every answer has.
  Future<SendTurnAccepted> _compare(
    _ChatSession session,
    SendTurn request,
    String text,
    List<ChatContextAttachment> context,
    AccountScope account,
  ) async {
    final scope = session.scope.container;
    if (!scope.read(comparisonRuntimeAvailableProvider)) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'comparing models needs a stored Open WebUI chat',
      );
    }
    final models = <Model>[
      for (final id in request.compareModels) await _resolveModel(id),
    ];
    var first = true;
    try {
      return await _run(
        session,
        account: account,
        refuseIfBusy: true,
        modelId: models.first.id,
        userMessageId: null,
        compare: true,
        start: (onPlaceholder) {
          // The core reads the knowledge and context from the scope's tray,
          // which choosing the model emptied: both answers get them, as a
          // normal send does.
          final tray = scope.read(contextAttachmentsProvider.notifier)..clear();
          for (final attachment in context) {
            tray.add(attachment);
          }
          return durableCompareSend(
            scope,
            text,
            request.fileIds.isEmpty ? null : request.fileIds,
            models: models,
            toolIds: request.toolIds.isEmpty ? null : request.toolIds,
            onAssistantPlaceholderCreated: (handle) {
              // The first slot is the turn the windows follow.
              if (first) onPlaceholder(handle);
              first = false;
            },
          ).then((_) {});
        },
      );
    } on ComparisonAdmissionException catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{
          'reason': error.reason.name,
          if (error.modelIds.isNotEmpty) 'models': error.modelIds.join(','),
        },
        debugMessage: 'the comparison was refused: ${error.reason.name}',
      );
    }
  }

  /// Runs a turn again, replacing one assistant answer.
  ///
  /// A branch, not an overwrite: the new answer is another child of the same
  /// question, so the previous one stays reachable as a version.
  Future<SendTurnAccepted> regenerate(RegenerateTurn request) async {
    final account = AccountScope.capture(_container);
    _refuseTemporary(request.chatId);
    final session = await _sessionFor(request.chatId, account: account);
    _Claim? claim;
    try {
      claim = await _requireIdle(session);
      final target = resolveAssistantRegenerationTarget(
        session.scope.messages,
        request.messageId,
      );
      if (target == null) {
        final known = session.scope.messages.any(
          (message) => message.id == request.messageId,
        );
        throw RpcError(
          code: known
              ? ConduitErrorCodes.invalidParams
              : ConduitErrorCodes.notFound,
          debugMessage: known
              ? 'only an answer to a question can be regenerated'
              : 'no such message in that conversation',
        );
      }
      // "Run this again" means the same model unless the caller says
      // otherwise.
      final model = await _resolveModel(
        request.model ??
            _libreChatModelOf(session) ??
            target.assistantMessage.model,
      );
      await _requireBackendFor(model);
      _choose(session.scope.container, model);
      if (request.withoutReasoningEffort) {
        // "Automatic" clears the local pick and, for a model that was sent
        // it, the chat's saved override; the retry goes only once both are
        // confirmed, or it would resend the rejected value.
        final cleared = await clearReasoningEffortForRetry(
          session.scope.container,
          model,
        );
        if (!cleared) {
          throw const RpcError(
            code: ConduitErrorCodes.serverError,
            args: <String, String>{'reason': 'effortNotCleared'},
            debugMessage: 'the reasoning effort could not be cleared',
          );
        }
      }
      return await _run(
        session,
        account: account,
        refuseIfBusy: true,
        modelId: model.id,
        userMessageId: target.userMessage.id,
        start: (_) => regenerateHistoricalMessageById(
          session.scope.container,
          request.messageId,
        ),
      );
    } finally {
      claim?.end();
      _release(session);
    }
  }

  /// Replaces one of the user's messages and answers the new text.
  ///
  /// The new question is a sibling of the old one, so the old question keeps
  /// its answer and everything after it.
  Future<SendTurnAccepted> edit(EditTurn request) async {
    final account = AccountScope.capture(_container);
    _refuseTemporary(request.chatId);
    final text = request.text.trim();
    if (text.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'turns.edit needs a non-empty text',
      );
    }
    final session = await _sessionFor(request.chatId, account: account);
    _Claim? claim;
    try {
      claim = await _requireIdle(session);
      final messages = session.scope.messages;
      final index = messages.indexWhere((m) => m.id == request.messageId);
      if (index < 0) {
        throw const RpcError(
          code: ConduitErrorCodes.notFound,
          debugMessage: 'no such message in that conversation',
        );
      }
      if (messages[index].role != 'user') {
        throw const RpcError(
          code: ConduitErrorCodes.invalidParams,
          debugMessage: 'only a user message can be edited',
        );
      }
      if (messages[index].content.trim() == text) {
        throw const RpcError(
          code: ConduitErrorCodes.invalidParams,
          debugMessage: 'the edited text is the same as the original',
        );
      }
      // A question carries no model; the answer that followed it does, and
      // "ask this again, differently" means the same model as before.
      final answeredWith = messages
          .skip(index + 1)
          .where((m) => m.role == 'assistant')
          .firstOrNull
          ?.model;
      final model = await _resolveModel(
        request.model ?? _libreChatModelOf(session) ?? answeredWith,
      );
      await _requireBackendFor(model);
      _choose(session.scope.container, model);
      return await _run(
        session,
        account: account,
        refuseIfBusy: true,
        modelId: model.id,
        userMessageId: null,
        start: (_) async {
          final sent = await resendEditedUserMessage(
            session.scope.container,
            messageId: request.messageId,
            newText: text,
          );
          if (!sent) {
            throw const RpcError(
              code: ConduitErrorCodes.notFound,
              debugMessage: 'that message is no longer in the conversation',
            );
          }
        },
      );
    } finally {
      claim?.end();
      _release(session);
    }
  }

  // ---------------------------------------------------------------------------
  // messages.delete, turns.merge, chats.saveTemporary
  // ---------------------------------------------------------------------------

  /// Deletes [DeleteMessages.messageIds] (each with the answers to it) from
  /// the chat, as a phone's Delete does (the core's
  /// [deleteChatMessageGroup], in the chat's scope); or, for a dry run,
  /// counts what would go. Answers with how many messages that is. Refused
  /// while the chat is answering.
  /// Branch from Here on reply [request.messageId] of Hermes chat
  /// [request.chatId]: a new session with the chat up to the end of that
  /// reply's turn (the phone's `branchHermesChatFromMessage`), told to the
  /// windows and answered with, to open.
  Future<HermesSessionDto> branchHermes(HermesBranch request) async {
    final account = AccountScope.capture(_container);
    final hermes = _hermes;
    final sessionId = hermesSessionOf(request.chatId);
    if (hermes == null || sessionId == null) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'chatId': request.chatId},
        debugMessage: 'not a Hermes chat',
      );
    }
    final session = await _sessionFor(request.chatId, account: account);
    _Claim? claim;
    try {
      _refuseReadOnlyHermes(hermes, sessionId);
      // Never from a reply still being written.
      claim = await _requireIdle(session);
      account.require('the branch was made');
      final scope = session.scope.container;
      final messages = session.scope.messages;
      final index = messages.indexWhere((m) => m.id == request.messageId);
      if (index < 0) {
        throw const RpcError(
          code: ConduitErrorCodes.notFound,
          debugMessage: 'no such reply in that chat',
        );
      }
      final title = session.scope.conversation?.title ?? '';
      final branch = await scope
          .read(hermesSessionsProvider.notifier)
          .branchFromMessage(
            sessionId: sessionId,
            title: title,
            messages: messages,
            index: index,
          );
      if (branch == null) {
        throw const RpcError(
          code: ConduitErrorCodes.conflict,
          retryable: true,
          debugMessage: 'a branch is already being made, or Hermes changed',
        );
      }
      return await hermes.adopt(branch.session, transcript: branch.transcript);
    } on StateError catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.conflict,
        retryable: true,
        debugMessage: error.message,
      );
    } finally {
      claim?.end();
      _release(session);
    }
  }

  /// Undo Last Turn of Hermes chat [request.id] (a Desktop Gateway's): its
  /// last question and everything after go, in the gateway's transcript
  /// and in the chat. `ok` is false when there was nothing to undo.
  /// Another Hermes app's session (read-only here): its history is not
  /// this app's to branch or undo, whoever asks. Read after the session's
  /// scope opened, which is when its owner is known.
  static void _refuseReadOnlyHermes(HermesService hermes, String sessionId) {
    if (hermes.chatState(sessionId).readOnly) {
      throw RpcError(
        code: ConduitErrorCodes.unsupported,
        args: <String, String>{'sessionId': sessionId},
        debugMessage: 'that Hermes session is read-only',
      );
    }
  }

  Future<OkResult> undoHermes(ChatRef request) async {
    final account = AccountScope.capture(_container);
    final sessionId = hermesSessionOf(request.id);
    if (_hermes == null || sessionId == null) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'chatId': request.id},
        debugMessage: 'not a Hermes chat',
      );
    }
    final session = await _sessionFor(request.id, account: account);
    _Claim? claim;
    try {
      _refuseReadOnlyHermes(_hermes, sessionId);
      claim = await _requireIdle(session);
      account.require('the last turn was undone');
      final undone = await undoLastHermesTurn(session.scope.container);
      if (undone) {
        // The undone answer must not come back as the turn a window that
        // subscribes is caught up on.
        session.ended = null;
        _hermes.forget(sessionId, latest: session.scope.messages);
        _hermes.announceSessions();
        _announce(request.id);
      }
      return OkResult(ok: undone);
    } on StateError catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.conflict,
        retryable: true,
        debugMessage: error.message,
      );
    } finally {
      claim?.end();
      _release(session);
    }
  }

  Future<int> deleteMessages(DeleteMessages request) async {
    final account = AccountScope.capture(_container);
    final session = await _sessionFor(request.chatId, account: account);
    var reserved = false;
    _Claim? claim;
    try {
      if (isRunning(request.chatId) ||
          session.merge != null ||
          session.deleting) {
        throw const RpcError(
          code: ConduitErrorCodes.conflict,
          debugMessage: 'that chat is still answering',
        );
      }
      // Reserved before the first await: the core writes the shorter
      // transcript before the server answers, and puts the old one back if
      // it refuses, so a turn or merge started meanwhile would be lost.
      session.deleting = reserved = true;
      claim = await _requireIdle(session, deleting: true);
      // Counted or deleted for the account that asked, or not at all.
      account.require('the messages were deleted');
      final scope = session.scope.container;
      final count = chatMessageIdsRemovedByDelete(
        session.scope.messages,
        request.messageIds,
      ).length;
      if (count == 0) {
        throw const RpcError(
          code: ConduitErrorCodes.notFound,
          debugMessage: 'no such message in that conversation',
        );
      }
      if (request.dryRun) return count;
      final outcome = await deleteChatMessageGroup(scope, request.messageIds);
      switch (outcome) {
        case ChatMessageDeleteOutcome.nothingToDelete:
          throw const RpcError(
            code: ConduitErrorCodes.notFound,
            debugMessage: 'no such message in that conversation',
          );
        case ChatMessageDeleteOutcome.persistFailed:
          throw const RpcError(
            code: ConduitErrorCodes.serverError,
            debugMessage: 'the server kept the message',
          );
        case ChatMessageDeleteOutcome.deleted:
          break;
      }
      // The turn that ended here last is replayed to a window that opens
      // the chat now ([catchUp]); an answer that is gone must not come back.
      final ended = session.ended;
      if (ended != null &&
          !session.scope.messages.any((m) => m.id == ended.blocks.messageId)) {
        session.ended = null;
      }
      final chatId = session.chatId ?? request.chatId;
      if (temporary.contains(chatId)) {
        temporary.replace(chatId, session.scope.messages);
        _announce(chatId);
      } else {
        await _pull(chatId);
        _announce(chatId);
      }
      return count;
    } finally {
      if (reserved) session.deleting = false;
      claim?.end();
      _release(session);
    }
  }

  /// Merge Responses: [MergeTurn.sourceIds] (by default, the answers a
  /// merge may read) merged into one response and saved on
  /// [MergeTurn.targetId], through the core's merge, in the chat's scope.
  /// The text goes out as `messages.merge`, at most one frame per tick, and
  /// once more as it ends. [MergeTurn.stop] stops the running merge.
  Future<MergeStarted> merge(MergeTurn request) async {
    final account = AccountScope.capture(_container);
    if (request.stop) {
      final session = _sessionOf(request.chatId);
      final running = session?.merge;
      if (session != null && running != null && !session.scope.isDisposed) {
        await session.scope.container
            .read(comparisonMergeProvider.notifier)
            .cancel();
      }
      return MergeStarted(targetId: running?.targetId ?? request.targetId);
    }
    // An answer named twice would be weighed twice.
    if (request.sourceIds.toSet().length != request.sourceIds.length) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'reason': 'notMergeable'},
        debugMessage: 'an answer is named more than once',
      );
    }
    _refuseTemporary(request.chatId);
    final session = await _sessionFor(request.chatId, account: account);
    var started = false;
    // Reserved before the first await, so a second merge, or a send, edit
    // or regenerate ([_requireIdle]), is refused while this one is admitted.
    _Merge? run;
    _Claim? claim;
    try {
      if (isRunning(request.chatId) || session.merge != null) {
        throw const RpcError(
          code: ConduitErrorCodes.conflict,
          args: <String, String>{'reason': 'busy'},
          debugMessage: 'that chat is answering or merging already',
        );
      }
      run = _Merge(
        chatId: request.chatId,
        messageId: request.messageId,
        targetId: request.targetId,
      );
      session.merge = run;
      claim = await _requireIdle(session, admitting: run);
      final displayed = session.scope.messages
          .where((m) => m.id == request.messageId && m.role == 'assistant')
          .lastOrNull;
      if (displayed == null) {
        throw const RpcError(
          code: ConduitErrorCodes.notFound,
          debugMessage: 'no such answer in that conversation',
        );
      }
      final group = ChatComparisonGroup.fromMessage(displayed);
      final answers = <String, ChatComparisonAnswer>{
        for (final slot in group.slots)
          for (final answer in slot.answers) answer.messageId: answer,
      };
      final target = answers[request.targetId];
      final sources = request.sourceIds.isEmpty
          ? group.mergeableAnswers(shownId: request.targetId)
          : <ChatComparisonAnswer>[
              for (final id in request.sourceIds) ?answers[id],
            ];
      final parentId = group.parentId;
      if (!group.isComparison ||
          target == null ||
          parentId == null ||
          sources.length < 2 ||
          // Every answer named must be one of this question's.
          (request.sourceIds.isNotEmpty &&
              sources.length != request.sourceIds.length) ||
          !target.isMergeable ||
          sources.any((answer) => !answer.isMergeable)) {
        throw const RpcError(
          code: ConduitErrorCodes.invalidParams,
          args: <String, String>{'reason': 'notMergeable'},
          debugMessage: 'those answers cannot be merged',
        );
      }
      final scope = session.scope.container;
      final model = target.model ?? displayed.model ?? '';
      account.require('the merge started');
      // The hold [_sessionFor] took is the merge's now; [_endMerge] lets it
      // go.
      final admitted = run;
      started = true;
      run.ticker = Timer.periodic(
        _deltaInterval,
        (_) => _emitMerge(session, admitted),
      );
      final merging = scope
          .read(comparisonMergeProvider.notifier)
          .merge(
            targetMessageId: target.messageId,
            displayedMessageId: displayed.id,
            parentMessageId: parentId,
            model: model,
            responses: <String>[
              for (final answer in sources) answer.sourceText,
            ],
          );
      unawaited(
        merging.then<void>(
          (_) => _endMerge(session, admitted),
          onError: (Object error) => _endMerge(
            session,
            admitted,
            error: error is ComparisonMergeException
                ? error.reason.name
                : ComparisonMergeFailure.failed.name,
          ),
        ),
      );
      return MergeStarted(targetId: target.messageId);
    } finally {
      claim?.end();
      if (!started) {
        if (run != null && identical(session.merge, run)) session.merge = null;
        _release(session);
      }
    }
  }

  /// The merged text [run] writes, as the scope's transcript has it now.
  String _mergeText(_ChatSession session, _Merge run) {
    if (session.scope.isDisposed) return run.text;
    final message = session.scope.messages
        .where((m) => m.id == run.messageId)
        .lastOrNull;
    if (message == null) return run.text;
    Object? raw;
    if (message.id == run.targetId) {
      raw = message.metadata?[kMessageMergedMetadataKey];
    } else {
      for (final version in message.versions) {
        if (version.id == run.targetId) raw = version.merged;
      }
    }
    return ChatMergedResponse.tryFrom(raw)?.content ?? run.text;
  }

  void _emitMerge(_ChatSession session, _Merge run) {
    final text = _mergeText(session, run);
    if (text == run.text && run.published) return;
    run.text = text;
    run.published = true;
    _events.emit(
      ConduitEventSpecs.messagesMerge,
      MergeProgress(
        chatId: run.chatId,
        messageId: run.messageId,
        targetId: run.targetId,
        text: text,
      ),
      scope: run.chatId,
    );
  }

  void _endMerge(_ChatSession session, _Merge run, {String? error}) {
    run.ticker?.cancel();
    run.text = _mergeText(session, run);
    if (identical(session.merge, run)) session.merge = null;
    _events.emit(
      ConduitEventSpecs.messagesMerge,
      MergeProgress(
        chatId: run.chatId,
        messageId: run.messageId,
        targetId: run.targetId,
        text: run.text,
        running: false,
        error: error,
      ),
      scope: run.chatId,
    );
    _release(session);
    // The merge's stored copy, as a turn's: a turn started before its pull
    // lands would have the transcript it reads replaced.
    final synced = _announceWhenSynced(run.chatId);
    session.settling = synced;
    unawaited(
      synced.whenComplete(() {
        if (identical(session.settling, synced)) session.settling = null;
      }),
    );
  }

  /// Save Chat: the temporary chat [chatId] becomes a stored one (the core's
  /// [saveTemporaryChat], in its scope). Windows showing it follow it to its
  /// new id (`route.remap`), which this answers with.
  Future<ChatForked> saveTemporary(String chatId) async {
    final account = AccountScope.capture(_container);
    if (!temporary.contains(chatId)) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'only a temporary chat can be saved',
      );
    }
    final session = await _sessionFor(chatId, account: account);
    // One save at a time: a second would make a second server chat.
    if (session.saving) {
      _release(session);
      throw const RpcError(
        code: ConduitErrorCodes.conflict,
        args: <String, String>{'reason': 'saving'},
        debugMessage: 'that chat is being saved already',
      );
    }
    session.saving = true;
    var closing = false;
    _Claim? claim;
    try {
      claim = await _requireIdle(session, saving: true);
      account.require('the temporary chat was read');
      final messages = session.scope.messages;
      if (messages.isEmpty) {
        throw const RpcError(
          code: ConduitErrorCodes.invalidParams,
          debugMessage: 'an empty chat has nothing to save',
        );
      }
      // The model the chat is saved with: its last answer's.
      final answeredWith = messages
          .where((m) => m.role == 'assistant')
          .lastOrNull
          ?.model;
      final model = await _resolveModel(answeredWith);
      // Saved into the account that asked, or not at all.
      account.require('the temporary chat was saved');
      _requireOpenWebUi();
      final scope = session.scope.container;
      _choose(scope, model, temporary: true);
      final outcome = await saveTemporaryChat(scope);
      final saved = session.scope.conversation;
      if (outcome != TemporaryChatSaveOutcome.saved ||
          saved == null ||
          saved.id == chatId) {
        throw RpcError(
          code: ConduitErrorCodes.serverError,
          args: <String, String>{'reason': outcome.name},
          debugMessage: 'the chat could not be saved (${outcome.name})',
        );
      }
      temporary.forget(chatId);
      _events.emit(
        ConduitEventSpecs.routeRemap,
        RouteRemap(fromId: chatId, toId: saved.id),
      );
      _announce(saved.id);
      closing = true;
      return ChatForked(chatId: saved.id);
    } finally {
      session.saving = false;
      claim?.end();
      _release(session);
      // Its scope holds the chat under the old id's turn state; the saved
      // chat opens fresh.
      if (closing && !session.scope.isDisposed && session.holds == 0) {
        _close(session);
      }
    }
  }

  /// Rates an answer up or down.
  ///
  /// The core's `MessageRating` does what Open WebUI's client does; this
  /// only refuses what cannot be rated and tells the windows afterwards, so
  /// the thumb comes back from the stored copy like everything else does.
  Future<void> rate(RateTurn request) async {
    if (request.rating != 1 && request.rating != -1) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a rating is 1 or -1',
      );
    }
    if (TemporaryChats.isTemporary(request.chatId)) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a temporary chat is not stored, so it cannot be rated',
      );
    }
    try {
      await MessageRating(_requireOpenWebUi()).rate(
        chatId: request.chatId,
        messageId: request.messageId,
        rating: request.rating,
      );
    } on StateError catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: error.message,
      );
    } finally {
      unawaited(_announceWhenSynced(request.chatId));
    }
  }

  /// Stops generation, keeping what has arrived.
  ///
  /// Not an error when nothing is running: a stop button pressed as the last
  /// token lands is the common case, not a mistake.
  Future<void> stop(String chatId) async {
    // The account the Stop was asked under: a stranded answer is read before
    // it is stopped, and nothing is stopped once another account is in charge.
    final account = AccountScope.capture(_container);
    final session = _sessionOf(chatId);
    final turn = session?.turn;
    if (session == null || turn == null || turn.finished) {
      await _stopStranded(chatId, session, account);
      return;
    }
    await _stopTurn(session, turn);
  }

  /// Stops [turn]'s answer as Stop does: its generation ends in the core,
  /// then the turn is finished.
  Future<void> _stopTurn(_ChatSession session, _Turn turn) async {
    turn.stopped = true;
    try {
      await session.scope.container.read(stopGenerationSettledProvider)();
    } on Object catch (error, stackTrace) {
      DebugLogger.error(
        'turn-stop-failed',
        scope: 'daemon/turns',
        error: error,
        stackTrace: stackTrace,
      );
    }
    // Stopped is finished, whatever the transport did with its message.
    if (!session.scope.isDisposed) _project(session);
    if (!turn.finished) _finish(session, turn, _answerOf(session, turn));
  }

  /// Stop on an answer the core still shows as generating with no turn of
  /// this daemon's behind it: one whose request never went out, which an
  /// earlier build could leave stored that way (the same-second stale pull).
  /// It refuses every later send ("already generating"), and the window
  /// shows Stop for it as the phone does; the core's own stop settles it,
  /// as the phone's Stop does (the answer marked done, the server's task
  /// told to stop, a request that never started dropped). Nothing happens
  /// for a chat that is quiet, or while a send is on its way (the window
  /// stops that one once it is answered).
  ///
  /// [account]: the account the Stop was asked under. Once another is in
  /// charge, nothing is stopped (logged, not an error, as a Stop with
  /// nothing running is not).
  Future<void> _stopStranded(
    String chatId,
    _ChatSession? open,
    AccountScope account,
  ) async {
    if (_disposed || open?.pending != null) return;
    final _ChatSession session;
    try {
      // The stored copy says so too: a chat with no scope open is opened.
      session = await _sessionFor(chatId, account: account);
    } on Object catch (error) {
      // Not a chat this daemon can open: nothing of its to stop.
      DebugLogger.warning(
        'turn-stop-stranded-unopened',
        scope: 'daemon/turns',
        data: {'error': error.toString()},
      );
      return;
    }
    try {
      if (session.scope.isDisposed || !session.scope.isStreaming) return;
      if (!account.isCurrent) {
        DebugLogger.info(
          'turn-stop-stranded-stale',
          scope: 'daemon/turns',
          data: {'chatId': chatId},
        );
        return;
      }
      DebugLogger.info(
        'turn-stop-stranded',
        scope: 'daemon/turns',
        data: {'chatId': chatId},
      );
      await session.scope.container.read(stopGenerationSettledProvider)();
      if (!session.scope.isDisposed) _project(session);
      _announce(chatId);
    } on Object catch (error, stackTrace) {
      DebugLogger.error(
        'turn-stop-stranded-failed',
        scope: 'daemon/turns',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _release(session);
    }
  }

  // ---------------------------------------------------------------------------
  // queue.* -- messages queued behind a running Open WebUI answer
  // ---------------------------------------------------------------------------

  /// [chatId]'s queue: the core's [ChatDraftQueueController] in the chat's
  /// scope. A chat with no scope has no answer running and nothing queued.
  QueueState queueGet(String chatId) {
    final session = _sessionOf(chatId);
    if (session == null || session.scope.isDisposed) {
      return QueueState(chatId: chatId);
    }
    return _queueState(session);
  }

  /// Queues what the composer holds behind [QueueAdd.chatId]'s running
  /// answer, as mobile's Queue does: its files and context go with it.
  QueueState queueAdd(QueueAdd request) {
    final session = _queueSession(request.chatId);
    final scope = session.scope.container;
    if (!scope.read(chatDraftQueueOfferProvider)) {
      throw const RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: 'that chat takes no queued message now',
      );
    }
    // The scope's tray is the draft's: the core captures it for the queue.
    final tray = scope.read(attachedFilesProvider.notifier)..clearAll();
    for (final id in request.fileIds) {
      tray.addRemoteFile(_uploaded(id));
    }
    final context = scope.read(contextAttachmentsProvider.notifier)..clear();
    for (final attachment in request.context) {
      context.add(contextFromDto(attachment));
    }
    final draft = scope
        .read(chatDraftQueueProvider.notifier)
        .enqueue(composerWireText(request.text, request.mentions));
    if (draft == null) {
      tray.clearAll();
      context.clear();
      throw const RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: 'the answer ended before the message was queued',
      );
    }
    return _publishQueue(session, force: true);
  }

  QueueState queueEdit(QueueEdit request) {
    final session = _queueSession(request.chatId);
    final edited = session.scope.container
        .read(chatDraftQueueProvider.notifier)
        .editDraft(request.draftId, request.text);
    if (!edited) _refuseQueueChange();
    return _publishQueue(session, force: true);
  }

  QueueState queueRemove(QueueDraftRef request) {
    final session = _queueSession(request.chatId);
    final removed = session.scope.container
        .read(chatDraftQueueProvider.notifier)
        .removeDraft(request.draftId);
    if (!removed) _refuseQueueChange();
    return _publishQueue(session, force: true);
  }

  /// Stops the running answer and sends one queued message now; the others
  /// wait for that turn, as on mobile.
  Future<QueueSendNowResult> queueSendNow(QueueDraftRef request) async {
    final session = _queueSession(request.chatId);
    final outcome = await session.scope.container
        .read(chatDraftQueueProvider.notifier)
        .sendNow(request.draftId);
    return QueueSendNowResult(
      outcome: outcome.name,
      queue: session.scope.isDisposed
          ? QueueState(chatId: request.chatId)
          : _publishQueue(session, force: true),
    );
  }

  QueueState queueRetry(String chatId) {
    final session = _queueSession(chatId);
    session.scope.container
        .read(chatDraftQueueProvider.notifier)
        .retryAdmission();
    return _publishQueue(session, force: true);
  }

  _ChatSession _queueSession(String chatId) {
    final session = _sessionOf(chatId);
    if (session == null || session.scope.isDisposed) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        args: <String, String>{'chatId': chatId},
        debugMessage: 'nothing is queued in that chat',
      );
    }
    return session;
  }

  Never _refuseQueueChange() => throw const RpcError(
    code: ConduitErrorCodes.conflict,
    debugMessage: 'that message is being sent, or is gone',
  );

  /// A file this daemon uploaded (or one picked from the server), as the
  /// server describes a file the tray takes as already uploaded.
  FileInfo _uploaded(String id) {
    final known = _files?.describe(id);
    final now = DateTime.now();
    return FileInfo(
      id: id,
      filename: known?.name ?? 'file',
      originalFilename: known?.name ?? 'file',
      size: known?.size ?? 0,
      mimeType: known?.contentType ?? '',
      createdAt: now,
      updatedAt: now,
    );
  }

  bool _queued(_ChatSession session) =>
      !session.scope.isDisposed &&
      (session.scope.container
              .read(activeChatDraftQueueProvider)
              ?.drafts
              .isNotEmpty ??
          false);

  QueueState _queueState(_ChatSession session) {
    final scope = session.scope.container;
    final chatId = session.chatId ?? '';
    final queue = scope.read(activeChatDraftQueueProvider);
    final offer = scope.read(chatDraftQueueOfferProvider);
    if (queue == null) return QueueState(chatId: chatId, offer: offer);
    final held = scope.read(queuedDraftAttachmentsProvider);
    return QueueState(
      chatId: chatId,
      drafts: <QueuedDraftDto>[
        for (final draft in queue.drafts)
          QueuedDraftDto(
            id: draft.id,
            text: draft.text,
            files: <ChatFileDto>[
              for (final file in chatDraftFiles(queue, draft, held))
                if (file != null)
                  ChatFileDto(
                    id: file.upload.fileId,
                    name: file.upload.fileName,
                    image: file.upload.isImage ?? false,
                  ),
            ],
            context: <ContextAttachmentDto>[
              for (final context in draft.contextAttachments)
                contextToDto(context),
            ],
            frozen: queue.isFrozen(draft.id),
          ),
      ],
      phase: switch (queue.phase) {
        ChatDraftQueuePhase.idle => QueuePhase.idle,
        ChatDraftQueuePhase.stopping => QueuePhase.stopping,
        ChatDraftQueuePhase.admitting => QueuePhase.admitting,
      },
      admissionFailed: queue.admissionFailed,
      offer: offer,
    );
  }

  /// Hands [insertion] (Hermes' prefill) to the windows showing
  /// [session]'s chat, then takes it back, as a phone's composer clears what
  /// it took.
  void _insertText(_ChatSession session, ComposerTextInsertion? insertion) {
    if (insertion == null ||
        insertion.text.isEmpty ||
        insertion.targetId != chatComposerTextInsertionTargetId) {
      return;
    }
    // Words given back after a declined model switch (`onlyIntoEmpty`) stay
    // in the chat, with its note and Copy: a window's message box is never
    // written into on its own. They are taken all the same.
    if (!insertion.onlyIntoEmpty) {
      final chatId = session.chatId;
      if (chatId != null && chatId.isNotEmpty) {
        _events.emit(
          ConduitEventSpecs.composerInsertText,
          ComposerInsertText(chatId: chatId, text: insertion.text),
          scope: chatId,
        );
      } else {
        DebugLogger.warning(
          'composer-insert-without-chat',
          scope: 'daemon/turns',
        );
      }
    }
    // Not from inside the provider's own notification.
    scheduleMicrotask(() {
      if (session.scope.isDisposed) return;
      session.scope.container
          .read(composerTextInsertionProvider.notifier)
          .clear(insertion.id);
    });
  }

  /// Tells the windows showing [session]'s chat that its queue changed
  /// (`queue.changed`), once per change, and keeps the scope while anything
  /// is queued.
  QueueState _publishQueue(_ChatSession session, {bool force = false}) {
    if (session.scope.isDisposed) {
      return QueueState(chatId: session.chatId ?? '');
    }
    final state = _queueState(session);
    if (state.drafts.isNotEmpty) {
      session.linger?.cancel();
    } else if (session.lastQueue?.drafts.isNotEmpty ?? false) {
      final turn = session.turn;
      if ((turn == null || turn.finished) &&
          session.pending == null &&
          session.holds == 0) {
        _scheduleLinger(session);
      }
    }
    if (force || state != session.lastQueue) {
      session.lastQueue = state;
      if (state.chatId.isNotEmpty) {
        _events.emit(
          ConduitEventSpecs.queueChanged,
          state,
          scope: state.chatId,
        );
      }
    }
    return state;
  }

  /// The core queue's send for [session]: the batch as one turn, through
  /// [_run] like any other, so its answer reaches the windows. Completes when
  /// the core's send does, as [durableSend] would.
  ///
  /// The batch waits for the chat to be quiet ([_untilQuiet]) without holding
  /// its admission, takes admission only then, and asks [_quietNow] again
  /// once it has it: anything that came in between (an answer, a delete,
  /// a stored copy) sends it back to wait, admission let go. So it claims
  /// the chat in the same moment its placeholder appears. Its turn starts
  /// once the core has committed it ([_PendingTurn.committed]).
  Future<void> _queuedSend(
    _ChatSession session,
    String text,
    List<String>? fileIds, {
    List<String>? toolIds,
    List<ChatContextAttachment>? contextAttachments,
    void Function(ChatSendPlaceholderHandle handle)?
    onAssistantPlaceholderCreated,
    void Function(ChatSendAdmissionReceipt receipt)? onAdmissionCommitted,
  }) {
    final account = AccountScope.capture(_container);
    final scope = session.scope.container;
    final model = scope.read(selectedModelProvider);
    if (model == null) {
      return Future<void>.error(
        const RpcError(
          code: ConduitErrorCodes.serverError,
          debugMessage: 'the chat has no model to send the queue with',
        ),
      );
    }
    final sent = Completer<void>();
    unawaited(() async {
      try {
        // Stored copies already given their time, for every retry below.
        final waitedOut = <Future<void>>{};
        while (true) {
          // The core sent the batch once it found no answer on screen, but
          // a turn asked for before it (words in a call) may start one, a
          // delete may begin, a stored copy may still be pulled: the batch
          // waits for all of it, without holding admission, so words said
          // meanwhile can still talk over that answer.
          await _untilQuiet(session, waitedOut: waitedOut);
          try {
            await _run(
              session,
              account: account,
              modelId: model.id,
              userMessageId: null,
              onAdmitted: () async {
                if (!_quietNow(session, waitedOut: waitedOut)) {
                  throw const _NotQuietYet();
                }
              },
              start: (onPlaceholder) => _sendBatch(
                session,
                scope,
                text,
                fileIds,
                toolIds: toolIds,
                contextAttachments: contextAttachments,
                onPlaceholder: onPlaceholder,
                onAssistantPlaceholderCreated: onAssistantPlaceholderCreated,
                onAdmissionCommitted: onAdmissionCommitted,
                sent: sent,
              ),
            );
            return;
          } on _NotQuietYet {
            // Admission let go: wait again.
          }
        }
      } on Object catch (error, stackTrace) {
        if (!sent.isCompleted) sent.completeError(error, stackTrace);
      }
    }());
    return sent.future;
  }

  /// The batch's send, once admitted while the chat is quiet.
  Future<void> _sendBatch(
    _ChatSession session,
    ProviderContainer scope,
    String text,
    List<String>? fileIds, {
    List<String>? toolIds,
    List<ChatContextAttachment>? contextAttachments,
    required void Function(ChatSendPlaceholderHandle handle) onPlaceholder,
    void Function(ChatSendPlaceholderHandle handle)?
    onAssistantPlaceholderCreated,
    void Function(ChatSendAdmissionReceipt receipt)? onAdmissionCommitted,
    required Completer<void> sent,
  }) async {
    final pending = session.pending;
    final sending = durableSend(
      scope,
      text,
      fileIds,
      toolIds: toolIds,
      contextAttachments: contextAttachments,
      onAssistantPlaceholderCreated: (handle) {
        onPlaceholder(handle);
        onAssistantPlaceholderCreated?.call(handle);
      },
      // Only with the core's own receipt (an Open WebUI chat's
      // durable send): a send without one takes none.
      onAdmissionCommitted: onAdmissionCommitted == null
          ? null
          : (receipt) {
              // Started before the batch leaves the queue, so the
              // windows never see an empty queue with nothing
              // answering.
              if (pending != null && identical(session.pending, pending)) {
                pending.committed = true;
                _project(session);
              }
              onAdmissionCommitted(receipt);
            },
    );
    sending.then(
      (_) {
        if (!sent.isCompleted) sent.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!sent.isCompleted) sent.completeError(error, stackTrace);
      },
    );
    await sending;
  }

  // ---------------------------------------------------------------------------
  // Voice calls
  // ---------------------------------------------------------------------------

  /// The scope a voice call runs in: [chatId]'s, or a new chat's (with
  /// [folderId], temporary when [temporary]), with [model] chosen. Held, so
  /// it outlives any turn, until the hold's `release`.
  Future<CallScopeHold> holdForCall({
    String? chatId,
    String? model,
    String? folderId,
    bool temporary = false,
  }) async {
    final account = AccountScope.capture(_container);
    final chosen = await _resolveModel(model);
    account.require('the call\'s model was read');
    await _requireBackendFor(chosen);
    final session = await _sessionFor(chatId, account: account);
    try {
      account.require('the call took the chat');
      final scope = session.scope.container;
      final running = session.turn != null && !session.turn!.finished;
      if (!running) {
        _choose(
          scope,
          chosen,
          temporary: chatId == null
              ? temporary
              : this.temporary.contains(chatId),
        );
      }
      if (chatId == null && folderId != null && folderId.isNotEmpty) {
        scope.read(pendingFolderIdProvider.notifier).set(folderId);
      }
      // A new chat: the call's start makes the scope a new chat again (the
      // app's own temporary default, no folder), so its first turn is made
      // with what the window chose ([_voiceSend]).
      if (chatId == null) {
        session.callNewChat = (
          temporary: temporary,
          folderId: (folderId?.isNotEmpty ?? false) ? folderId : null,
        );
      }
    } on Object {
      _release(session);
      rethrow;
    }
    session.linger?.cancel();
    var released = false;
    return CallScopeHold._(
      session.scope,
      chatId: () => session.chatId,
      release: () {
        if (released) return;
        released = true;
        session.callNewChat = null;
        _release(session);
      },
    );
  }

  /// One turn of a voice call ([chatVoiceSendProvider]): the user's words,
  /// a request the realtime voice handed over, or what was said with the
  /// voice's own reply. Through [_run], as a typed message goes.
  Future<void> _voiceSend(
    _ChatSession session,
    String text, {
    List<String>? toolIds,
    List<ChatContextAttachment>? contextAttachments,
    bool isVoiceMode = false,
    ChatSendVoiceContext? voice,
    void Function(ChatSendPlaceholderHandle handle)?
    onAssistantPlaceholderCreated,
  }) async {
    final account = AccountScope.capture(_container);
    final scope = session.scope.container;
    // The call's choice for a new chat, as these words began: a call that
    // ends while they wait below still makes the chat as it chose.
    final choice = session.callNewChat;
    final model = scope.read(selectedModelProvider);
    final sent = Completer<void>();
    session.holds++;
    try {
      await _run(
        session,
        account: account,
        modelId: model?.id ?? '',
        userMessageId: null,
        // The user talked over the answer (barge-in): it stops as Stop
        // stops it, generation and all, before these words go (once words
        // said before them have started their turn).
        onAdmitted: () async {
          final running = session.turn;
          if (running != null && !running.finished) {
            await _stopTurn(session, running);
          }
        },
        start: (onPlaceholder) async {
          // A reply the user talked over has only just ended: quiet first,
          // as every turn the core sends waits ([_untilQuiet]); this turn is
          // admitted already, so a window's request waits for it, not it
          // for the request.
          await _untilQuiet(session, ownPending: true);
          // The call's first turn makes its chat: temporary or not, and in
          // the folder, as the window chose, whatever the call's start reset.
          if (choice != null && !session.scope.isDisposed) {
            if (scope.read(activeConversationProvider) == null) {
              scope
                  .read(temporaryChatEnabledProvider.notifier)
                  .set(choice.temporary);
              final folderId = choice.folderId;
              if (folderId != null) {
                scope.read(pendingFolderIdProvider.notifier).set(folderId);
              }
            } else {
              session.callNewChat = null;
            }
          }
          final sending = durableSend(
            scope,
            text,
            null,
            toolIds: toolIds,
            contextAttachments: contextAttachments,
            isVoiceMode: isVoiceMode,
            voice: voice,
            onAssistantPlaceholderCreated: (handle) {
              onPlaceholder(handle);
              onAssistantPlaceholderCreated?.call(handle);
            },
          );
          sending.then(
            (_) {
              if (!sent.isCompleted) sent.complete();
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!sent.isCompleted) sent.completeError(error, stackTrace);
            },
          );
          await sending;
        },
      );
    } on Object catch (error, stackTrace) {
      if (!sent.isCompleted) sent.completeError(error, stackTrace);
    } finally {
      _release(session);
    }
    // A Standard call's words are sent once their turn has started: a
    // direct or Hermes send runs to the end of its answer, and the call
    // must be free to hear the user talk over it. A later failure shows on
    // the answer, which the call follows.
    if (isVoiceMode && voice == null && !sent.isCompleted) {
      unawaited(sent.future.then((_) {}, onError: (Object _) {}));
      return;
    }
    return sent.future;
  }

  // ---------------------------------------------------------------------------
  // turns.steer -- a message typed while Hermes works
  // ---------------------------------------------------------------------------

  /// Hands [SteerTurn.text] to the Hermes turn running in its chat: to steer
  /// it, or as the next message. The core's busy-turn controller, in the
  /// chat's scope.
  Future<SteerResult> steer(SteerTurn request) async {
    final text = composerWireText(request.text, request.mentions).trim();
    if (text.isEmpty) return const SteerResult(accepted: false);
    final account = AccountScope.capture(_container);
    final session = await _sessionFor(request.chatId, account: account);
    try {
      account.require('the words were handed to the running answer');
      final accepted = await session.scope.container
          .read(hermesBusyTurnControllerProvider)
          .submit(
            action: request.steer
                ? HermesBusyTurnAction.steer
                : HermesBusyTurnAction.sendNext,
            text: text,
            localStreaming: session.scope.isStreaming,
          );
      return SteerResult(accepted: accepted);
    } on HermesSteerUncertain {
      return const SteerResult(accepted: false, uncertain: true);
    } finally {
      _release(session);
    }
  }

  /// Stops every running answer, as leaving the account they belong to does
  /// once the user has agreed to.
  Future<void> stopAll() async {
    for (final chatId in activeChatIds.toList()) {
      await stop(chatId);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _remaps?.cancel();
    for (final watch in _accountWatches) {
      watch.close();
    }
    for (final session in List<_ChatSession>.of(_sessions)) {
      if (session.turn case final turn? when !turn.finished) {
        await stop(turn.chatId);
      }
      _close(session);
    }
  }

  // ---------------------------------------------------------------------------
  // Running a turn
  // ---------------------------------------------------------------------------

  /// Starts [start] in [session]'s scope and returns once its answer has
  /// started: the placeholder is in the transcript, and the chat has the id
  /// the windows should address it by.
  ///
  /// The core's send does not return at the same moment for every backend.
  /// An Open WebUI turn returns once the server has the request and the
  /// stream is attached; a direct or Hermes turn returns when the answer is
  /// finished. So the send runs on its own and this waits for the answer to
  /// appear in the scope.
  ///
  /// One send at a time takes the chat's pending turn: a send that comes
  /// while an earlier one has not started its turn yet (words in a call or a
  /// queue's batch, waiting for the last answer to settle) goes after it, in
  /// order, so each turn has its own answer and every send's turn starts.
  /// [onAdmitted] runs once it is this send's turn, before it is pending.
  /// A window's own turn ([refuseIfBusy], after [_requireIdle]) is refused
  /// if an answer has started meanwhile: two answers would interleave.
  /// [account]: the account the turn was asked for, captured at its
  /// request's entry; checked once the turn is admitted, as it starts.
  Future<SendTurnAccepted> _run(
    _ChatSession session, {
    required AccountScope account,
    required String modelId,
    required String? userMessageId,
    bool compare = false,
    String? assistantMessageId,
    bool refuseIfBusy = false,
    Future<void> Function()? onAdmitted,
    required Future<void> Function(
      void Function(ChatSendPlaceholderHandle handle) onPlaceholder,
    )
    start,
  }) async {
    final earlier = session.admitting;
    final admitted = Completer<void>();
    session.admitting = admitted.future;
    try {
      if (earlier != null) await earlier;
      if (session.scope.isDisposed) {
        throw const RpcError(
          code: ConduitErrorCodes.sessionExpired,
          debugMessage: 'the chat closed before this turn could start',
        );
      }
      final running = session.turn;
      if (refuseIfBusy && running != null && !running.finished) {
        throw const RpcError(
          code: ConduitErrorCodes.conflict,
          debugMessage: 'that chat is already generating',
        );
      }
      await onAdmitted?.call();
      if (session.scope.isDisposed) {
        throw const RpcError(
          code: ConduitErrorCodes.sessionExpired,
          debugMessage: 'the chat closed before this turn could start',
        );
      }
      account.require('the turn started');
      return await _runAdmitted(
        session,
        modelId: modelId,
        userMessageId: userMessageId,
        compare: compare,
        assistantMessageId: assistantMessageId,
        start: start,
      );
    } finally {
      // Started (or refused): the next send may take its turn.
      admitted.complete();
      if (identical(session.admitting, admitted.future)) {
        session.admitting = null;
      }
    }
  }

  Future<SendTurnAccepted> _runAdmitted(
    _ChatSession session, {
    required String modelId,
    required String? userMessageId,
    required bool compare,
    required String? assistantMessageId,
    required Future<void> Function(
      void Function(ChatSendPlaceholderHandle handle) onPlaceholder,
    )
    start,
  }) async {
    session.linger?.cancel();
    session.ended = null;
    final pending = _PendingTurn(
      model: modelId,
      userMessageId: userMessageId,
      compare: compare,
      baseline: <String, ChatMessage>{
        for (final message in session.scope.messages)
          if (message.role == 'assistant') message.id: message,
      },
    );
    // An answer that goes on where it stopped (a prompt answered) is
    // known by its id from the start.
    pending.assistantMessageId = assistantMessageId;
    session.pending = pending;

    Future<void> sending;
    try {
      sending = start((handle) {
        pending.assistantMessageId = handle.assistantMessageId;
        pending.userMessageId ??= handle.userMessageId;
        _project(session);
      });
    } on Object catch (error, stackTrace) {
      sending = Future<void>.error(error, stackTrace);
    }
    pending.sending = sending.then<void>(
      (_) {
        pending.sendSettled = true;
        if (!session.scope.isDisposed) _project(session);
      },
      onError: (Object error, StackTrace stackTrace) {
        pending.sendSettled = true;
        pending.sendError = error;
        DebugLogger.error(
          'turn-send-failed',
          scope: 'daemon/turns',
          error: error,
          stackTrace: stackTrace,
        );
        // Only the turn this send started: one handed off to the outbox
        // has ended already, and the chat's turn may be a later one now.
        final turn = session.turn;
        if (turn != null &&
            !turn.finished &&
            identical(turn.pending, pending)) {
          _finish(
            session,
            turn,
            _answerOf(session, turn),
            failure: _describe(error),
          );
        }
        if (!pending.started.isCompleted) {
          pending.started.completeError(_rpcErrorFor(error));
        }
      },
    );
    _project(session);

    final _Turn turn;
    try {
      turn = await pending.started.future;
    } on Object {
      if (identical(session.pending, pending)) session.pending = null;
      _scheduleLinger(session);
      rethrow;
    }
    return SendTurnAccepted(
      chatId: turn.chatId,
      userMessageId: turn.userMessageId ?? '',
      assistantMessageId: turn.messageId,
    );
  }

  /// Brings [session]'s turn up to date with its scope's transcript: starts
  /// it once its answer has appeared, marks new text for the next frame,
  /// asks the approvals waiting in it, and finishes it when the answer has.
  void _project(_ChatSession session) {
    if (session.scope.isDisposed) return;
    final messages = session.scope.messages;
    final pending = session.pending;
    if (pending != null && !pending.started.isCompleted) {
      _maybeStart(session, pending, messages);
    }
    var current = session.turn;
    if ((current == null || current.finished) &&
        (pending == null || pending.started.isCompleted)) {
      current = _followQueued(session, messages) ?? current;
    }
    _handOffQueued(session);
    final turn = current;
    if (turn == null || turn.finished) {
      // Between turns (a chat reopened while Hermes still waits on a
      // question): the latest answer's question, if any.
      final chatId = session.chatId;
      final conversation = session.scope.conversation;
      final latest = messages.lastWhereOrNull((m) => m.role == 'assistant');
      if (chatId != null && conversation != null && latest != null) {
        hermesCards?.project(
          chatId,
          session.scope.container,
          conversation.id,
          latest,
        );
      }
      return;
    }
    final answer = _find(session, messages, turn.messageId);
    if (answer == null) return;
    if (answer.isStreaming) {
      _refreshText(session, turn);
    } else if (answer.content != turn.text) {
      turn.text = answer.content;
      turn.dirty = true;
    }
    // A status, a code execution, the sources: the blocks change without
    // the text.
    final inputs = messageBlockInputsHash(answer);
    if (inputs != turn.blockInputs) {
      turn.blockInputs = inputs;
      turn.blocksDirty = true;
    }
    _hostApprovals(session, answer);
    // An Open WebUI answer is finished once the send that started it has
    // settled too; before that its placeholder can still be swapped for
    // the stored row while the request goes out.
    final settled = turn.clientOwned || (turn.pending?.sendSettled ?? true);
    // A comparison's other answers, each ending on its own.
    for (final entry in turn.companions.entries) {
      final companion = entry.value;
      if (companion.finished) continue;
      final other = messages.where((m) => m.id == entry.key).lastOrNull;
      if (other == null) continue;
      if (other.isStreaming) {
        final live = session.scope.container
            .read(chatMessagesProvider.notifier)
            .contentForStreamingMessage(entry.key);
        if (live != null && live != companion.text) {
          companion.text = live;
          companion.dirty = true;
        }
      } else if (other.content != companion.text) {
        companion.text = other.content;
        companion.dirty = true;
      }
      final inputs = messageBlockInputsHash(other);
      if (inputs != companion.blockInputs) {
        companion.blockInputs = inputs;
        companion.blocksDirty = true;
      }
      if (!other.isStreaming && settled) {
        _finishCompanion(session, turn, entry.key, other);
      }
    }
    final companionsDone = turn.companions.values.every((c) => c.finished);
    if (!answer.isStreaming && settled && companionsDone) {
      _finish(session, turn, answer);
    }
  }

  /// [turn]'s companion [id] (another column of a comparison), parsed: as it
  /// streams, or whole once it has finished.
  TurnBlocks _companionBlocks(
    _ChatSession session,
    _Turn turn,
    String id, {
    bool finished = false,
  }) {
    final companion = turn.companions[id]!;
    final answer = session.scope.isDisposed
        ? null
        : session.scope.messages.where((m) => m.id == id).lastOrNull;
    if (answer != null) {
      companion.lastBlocks = MessageBlocks.toDtos(
        assistantMessageBlocks(
          answer,
          content: companion.text,
          streaming: finished ? false : null,
          live: finished ? null : companion.live,
        ),
      );
    }
    return TurnBlocks(
      chatId: turn.chatId,
      messageId: id,
      blocks: companion.lastBlocks,
    );
  }

  /// Ends companion [id] of [turn]: its whole answer, then its own
  /// `turn.completed`, or `turn.failed` with [failure] or its error.
  void _finishCompanion(
    _ChatSession session,
    _Turn turn,
    String id,
    ChatMessage? answer, {
    String? failure,
  }) {
    final companion = turn.companions[id];
    if (companion == null || companion.finished) return;
    if (answer != null) companion.text = answer.content;
    final blocks = _companionBlocks(session, turn, id, finished: true);
    companion.finished = true;
    _events.emit(ConduitEventSpecs.turnBlocks, blocks, scope: turn.chatId);
    final error = failure ?? answer?.error?.content;
    if (error != null || answer?.error != null) {
      final failed = companion.failed = TurnFailed(
        chatId: turn.chatId,
        messageId: id,
        code: ConduitErrorCodes.serverError,
        args: <String, String>{'detail': ?error},
        partialText: companion.text,
      );
      _events.emit(ConduitEventSpecs.turnFailed, failed, scope: turn.chatId);
    } else {
      final completed = companion.completed = TurnCompleted(
        chatId: turn.chatId,
        messageId: id,
        text: companion.text,
        usage: _usageOf(answer?.usage),
      );
      _events.emit(
        ConduitEventSpecs.turnCompleted,
        completed,
        scope: turn.chatId,
      );
    }
  }

  void _maybeStart(
    _ChatSession session,
    _PendingTurn pending,
    List<ChatMessage> messages,
  ) {
    ChatMessage? answer;
    final expected = pending.assistantMessageId;
    if (expected != null) {
      answer = _find(session, messages, expected);
    } else {
      // The answer now streaming at the end of the transcript. A regenerate
      // may stream into the answer it replaces, keeping its id and moving
      // the old text into its versions, as the core does for a direct chat.
      final tail = messages.where((m) => m.role == 'assistant').lastOrNull;
      if (tail != null &&
          tail.isStreaming &&
          !(pending.baseline[tail.id]?.isStreaming ?? false)) {
        answer = tail;
      } else if (tail != null &&
          pending.sendSettled &&
          _changed(pending.baseline[tail.id], tail)) {
        // Over before it was seen streaming: a quick provider.
        answer = tail;
      }
    }
    if (answer == null) {
      if (pending.sendSettled && pending.sendError == null) {
        pending.started.completeError(
          const RpcError(
            code: ConduitErrorCodes.serverError,
            debugMessage: 'the core started no answer',
          ),
        );
      }
      return;
    }
    // A LibreChat answer streams under an id minted here until the server
    // names it (and its question): the windows are told the server's ids,
    // which the stored chat keeps, so the turn starts once they are named,
    // or once it ends unnamed.
    if (answer.isStreaming && isUnconfirmedLibreChatMessage(answer)) {
      return;
    }
    final transport = answer.metadata?['transport'];
    final clientOwned =
        transport == kHermesTransport || transport == kDirectTransport;
    // The id the windows address the chat by. A direct or Hermes chat has
    // it as soon as the core has made the chat; an Open WebUI turn returns
    // once its send has, by which time a new chat has the server's id.
    final chatId = session.scope.conversation?.id;
    if (chatId == null ||
        (!clientOwned && !pending.sendSettled && !pending.committed)) {
      return;
    }
    final index = messages.indexOf(answer);
    final asked = pending.userMessageId;
    final question =
        (asked == null ? null : _currentId(session, asked)) ??
        messages
            .take(index < 0 ? 0 : index)
            .lastWhere((m) => m.role == 'user', orElse: () => answer!)
            .id;
    final turn =
        _Turn(
            chatId: chatId,
            messageId: answer.id,
            model: answer.model ?? pending.model,
            userMessageId: question == answer.id ? null : question,
            clientOwned: clientOwned,
          )
          ..text = answer.content
          ..pending = pending;
    if (pending.compare) {
      // The other columns' answers: the same question's other placeholders.
      for (final other in messages) {
        if (other.role == 'assistant' &&
            other.id != answer.id &&
            other.metadata?['parentId']?.toString() == question &&
            other.metadata?[kMessageModelIdxMetadataKey] is int) {
          turn.companions[other.id] = _Companion()..text = other.content;
        }
      }
    }
    session.turn = turn;
    turn.announced = true;
    _remember(turn.messageId);
    _events.emit(
      ConduitEventSpecs.turnStarted,
      TurnStarted(
        chatId: chatId,
        messageId: turn.messageId,
        model: turn.model,
        companionIds: turn.companions.keys.toList(growable: false),
      ),
      scope: chatId,
    );
    // A Hermes session's row shows it working.
    if (hermesSessionOf(chatId) case final sessionId?) {
      _hermes?.setRunning(sessionId, true);
    }
    turn.ticker = Timer.periodic(
      _deltaInterval,
      (_) => _emitDelta(session, turn),
    );
    pending.started.complete(turn);
  }

  /// A queued answer (sent while offline, or failed and retried) that has
  /// gone out and streams into [session]'s scope, followed as a turn of its
  /// own so the windows see it stream; null when there is none.
  _Turn? _followQueued(_ChatSession session, List<ChatMessage> messages) {
    final queued = _queuedCompletions;
    final chatId = session.chatId;
    if (queued == null || chatId == null) return null;
    final answer = messages
        .where(
          (m) =>
              m.role == 'assistant' &&
              m.isStreaming &&
              queued.wasQueued(chatId, m.id) &&
              !queued.isQueued(chatId, m.id),
        )
        .lastOrNull;
    if (answer == null) return null;
    queued.followed(chatId, answer.id);
    final index = messages.indexOf(answer);
    final question = messages
        .take(index < 0 ? 0 : index)
        .where((m) => m.role == 'user')
        .lastOrNull;
    final turn = _Turn(
      chatId: chatId,
      messageId: answer.id,
      model: answer.model ?? '',
      userMessageId: question?.id,
      clientOwned: false,
    )..text = answer.content;
    session.linger?.cancel();
    session.ended = null;
    session.turn = turn;
    turn.announced = true;
    _remember(turn.messageId);
    _events.emit(
      ConduitEventSpecs.turnStarted,
      TurnStarted(chatId: chatId, messageId: turn.messageId, model: turn.model),
      scope: chatId,
    );
    turn.ticker = Timer.periodic(
      _deltaInterval,
      (_) => _emitDelta(session, turn),
    );
    return turn;
  }

  /// [session]'s answer is queued by the core: its request waits in the
  /// outbox (the server is out of reach, or the request keeps failing). The
  /// turn ends here, with neither an answer nor a failure: `turns.send`
  /// answers now if it has not yet, and the windows fetch the chat, where
  /// the answer shows as queued, with Retry and Remove. Once the request
  /// goes out the answer streams, and is followed as a turn of its own
  /// ([_followQueued]).
  void _handOffQueued(_ChatSession session) {
    final queued = _queuedCompletions;
    final chatId = session.chatId;
    if (queued == null || chatId == null || session.scope.isDisposed) return;
    final pending = session.pending;
    if (pending != null && !pending.started.isCompleted) {
      final answerId = pending.assistantMessageId;
      if (answerId == null || !queued.isQueued(chatId, answerId)) return;
      _endQueuedBeforeStart(session, pending, answerId);
      _announce(chatId);
      return;
    }
    final turn = session.turn;
    if (turn == null ||
        turn.finished ||
        turn.clientOwned ||
        !queued.isQueued(chatId, turn.messageId)) {
      return;
    }
    turn.finished = true;
    if (!turn.ended.isCompleted) turn.ended.complete();
    turn.ticker?.cancel();
    session.ended = null;
    // The turn is over here, its send settled or not: the scope may close
    // once nothing else holds it.
    if (pending != null && identical(pending, turn.pending)) {
      session.pending = null;
    }
    _scheduleLinger(session);
    // Not an answer yet: the windows end the turn and show the stored row
    // queued, and no "answer ready" goes out for it.
    _remember(turn.messageId);
    _events.emit(
      ConduitEventSpecs.turnFinished,
      TurnFinished(
        chatId: chatId,
        messageId: turn.messageId,
        ok: true,
        queued: true,
      ),
    );
    _announce(chatId);
  }

  /// Ends [pending], whose answer [answerId] the core queued (or removed)
  /// before it ever started: `turns.send` answers with it, and the chat no
  /// longer counts as answering, so its scope can linger and close.
  void _endQueuedBeforeStart(
    _ChatSession session,
    _PendingTurn pending,
    String answerId,
  ) {
    final chatId = session.chatId;
    if (chatId == null) return;
    if (!pending.started.isCompleted) {
      pending.started.complete(
        _Turn(
          chatId: chatId,
          messageId: answerId,
          model: pending.model,
          userMessageId: pending.userMessageId,
          clientOwned: false,
        )..finished = true,
      );
    }
    if (identical(session.pending, pending)) session.pending = null;
    _scheduleLinger(session);
  }

  /// `turns.retryQueued`: sends a queued answer's request again now.
  Future<OkResult> retryQueued(QueuedTurnRef ref) async {
    final account = AccountScope.capture(_container);
    final session = await _sessionFor(ref.chatId, account: account);
    try {
      final info = await _queuedInfo(session, ref.messageId);
      account.require('the queued answer was sent again');
      final actions = session.scope.container.read(
        queuedCompletionActionsProvider,
      );
      if (ref.withoutReasoningEffort) {
        await actions.retryWithoutReasoningEffort(info);
      } else {
        await actions.retry(info);
      }
      _announce(ref.chatId);
      return const OkResult(ok: true);
    } finally {
      _release(session);
    }
  }

  /// `turns.removeQueued`: removes a queued answer before it goes out.
  Future<OkResult> removeQueued(QueuedTurnRef ref) async {
    final account = AccountScope.capture(_container);
    final session = await _sessionFor(ref.chatId, account: account);
    try {
      final info = await _queuedInfo(session, ref.messageId);
      account.require('the queued answer was removed');
      final removed = await session.scope.container
          .read(queuedCompletionActionsProvider)
          .cancel(info);
      _queuedCompletions?.followed(ref.chatId, ref.messageId);
      // Removed before its hand-off was seen: the send waiting for it ends.
      final pending = session.pending;
      if (pending != null &&
          !pending.started.isCompleted &&
          pending.assistantMessageId == ref.messageId) {
        _endQueuedBeforeStart(session, pending, ref.messageId);
      }
      _announce(ref.chatId);
      return OkResult(ok: removed > 0);
    } finally {
      _release(session);
    }
  }

  Future<QueuedCompletionInfo> _queuedInfo(
    _ChatSession session,
    String messageId,
  ) async {
    final infos = await readSettled(
      session.scope.container,
      queuedCompletionInfoByMessageProvider.future,
    );
    final info = infos[messageId];
    if (info == null) {
      throw const RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'that answer is not waiting to go out',
      );
    }
    return info;
  }

  /// Reads the answer as the scope's transcript has it right now, including
  /// what the core has buffered since it last published the text: the core
  /// paints a phone's screen at its own cadence, and the windows get frames
  /// at [_deltaInterval].
  void _refreshText(_ChatSession session, _Turn turn) {
    if (session.scope.isDisposed || turn.finished) return;
    final live = session.scope.container
        .read(chatMessagesProvider.notifier)
        .contentForStreamingMessage(_currentId(session, turn.messageId));
    if (live != null && live != turn.text) {
      turn.text = live;
      turn.dirty = true;
    }
  }

  /// Publishes at most one frame per tick, and only when something changed:
  /// the text as `turn.delta`, and the parsed answer as `turn.blocks` when
  /// the text or anything else it is made from moved.
  void _emitDelta(_ChatSession session, _Turn turn) {
    _refreshText(session, turn);
    if (!turn.finished) _emitCompanionDeltas(session, turn);
    if (turn.finished || !(turn.dirty || turn.blocksDirty)) return;
    if (turn.dirty) {
      _events.emit(
        ConduitEventSpecs.turnDelta,
        TurnDelta(
          chatId: turn.chatId,
          messageId: turn.messageId,
          text: turn.text,
        ),
        scope: turn.chatId,
      );
    }
    turn.dirty = false;
    turn.blocksDirty = false;
    _events.emit(
      ConduitEventSpecs.turnBlocks,
      _blocks(session, turn),
      scope: turn.chatId,
    );
  }

  /// A frame for each companion still answering whose text or blocks moved.
  void _emitCompanionDeltas(_ChatSession session, _Turn turn) {
    if (turn.companions.isEmpty || session.scope.isDisposed) return;
    final notifier = session.scope.container.read(
      chatMessagesProvider.notifier,
    );
    for (final entry in turn.companions.entries) {
      final companion = entry.value;
      if (companion.finished) continue;
      final live = notifier.contentForStreamingMessage(entry.key);
      if (live != null && live != companion.text) {
        companion.text = live;
        companion.dirty = true;
      }
      if (!(companion.dirty || companion.blocksDirty)) continue;
      if (companion.dirty) {
        _events.emit(
          ConduitEventSpecs.turnDelta,
          TurnDelta(
            chatId: turn.chatId,
            messageId: entry.key,
            text: companion.text,
          ),
          scope: turn.chatId,
        );
      }
      companion.dirty = false;
      companion.blocksDirty = false;
      _events.emit(
        ConduitEventSpecs.turnBlocks,
        _companionBlocks(session, turn, entry.key),
        scope: turn.chatId,
      );
    }
  }

  /// [turn]'s answer, parsed: frame by frame while it streams, and whole
  /// once [finished], the snapshot a window settles on.
  TurnBlocks _blocks(
    _ChatSession session,
    _Turn turn, {
    bool finished = false,
  }) {
    final answer = _answerOf(session, turn);
    if (answer != null) {
      turn.lastBlocks = MessageBlocks.toDtos(
        assistantMessageBlocks(
          answer,
          content: turn.text,
          streaming: finished ? false : null,
          live: finished ? null : turn.live,
        ),
      );
    }
    final metadata = session.scope.isDisposed
        ? null
        : session.scope.conversation?.metadata;
    return TurnBlocks(
      chatId: turn.chatId,
      messageId: turn.messageId,
      blocks: turn.lastBlocks,
      // The checklist as the turn left it, once it has one.
      tasks: metadata?.containsKey(kOpenWebUiTasksMetadataKey) ?? false
          ? chatTaskDtos(metadata)
          : null,
    );
  }

  void _finish(
    _ChatSession session,
    _Turn turn,
    ChatMessage? answer, {
    String? failure,
  }) {
    if (turn.finished) return;
    // A comparison's answers that had not ended end with the turn.
    for (final id in turn.companions.keys.toList()) {
      if (turn.companions[id]!.finished) continue;
      final other = session.scope.isDisposed
          ? null
          : session.scope.messages.where((m) => m.id == id).lastOrNull;
      _finishCompanion(
        session,
        turn,
        id,
        other,
        failure: failure ?? (other?.isStreaming ?? true ? 'stopped' : null),
      );
    }
    if (answer != null) turn.text = answer.content;
    // The whole answer, parsed whole: what the windows settle on.
    final blocks = _blocks(session, turn, finished: true);
    turn.finished = true;
    if (!turn.ended.isCompleted) turn.ended.complete();
    turn.ticker?.cancel();
    final error = failure ?? answer?.error?.content;
    final failed = error != null || answer?.error != null;
    final ended = failed
        ? _Ended(
            blocks: blocks,
            failed: TurnFailed(
              chatId: turn.chatId,
              messageId: turn.messageId,
              code: ConduitErrorCodes.serverError,
              // The server's own words: a refusal like "this model needs a
              // paid plan" is information only the server has. Apple's
              // engine's own texts carry their code too, as the stored
              // error block does.
              args: <String, String>{
                'detail': ?error,
                'type': ?appleErrorType(error),
              },
              partialText: turn.text,
            ),
          )
        : _Ended(
            blocks: blocks,
            completed: TurnCompleted(
              chatId: turn.chatId,
              messageId: turn.messageId,
              text: turn.text,
              usage: _usageOf(answer?.usage),
            ),
          );
    session.ended = ended;
    _events.emit(ConduitEventSpecs.turnBlocks, blocks, scope: turn.chatId);
    if (ended.failed case final payload?) {
      _events.emit(ConduitEventSpecs.turnFailed, payload, scope: turn.chatId);
    }
    if (ended.completed case final payload?) {
      _events.emit(
        ConduitEventSpecs.turnCompleted,
        payload,
        scope: turn.chatId,
      );
    }
    if (hermesSessionOf(turn.chatId) case final sessionId?) {
      _hermes?.setRunning(sessionId, false);
    }
    // Unscoped: every window hears it, whichever chat it shows.
    _remember(turn.messageId);
    _events.emit(
      ConduitEventSpecs.turnFinished,
      TurnFinished(
        chatId: turn.chatId,
        messageId: turn.messageId,
        ok: !failed,
        code: failed ? ConduitErrorCodes.serverError : null,
      ),
    );
    final settling = _settle(session, turn, failed: failed);
    session.settling = settling;
    unawaited(
      settling.whenComplete(() {
        if (identical(session.settling, settling)) session.settling = null;
      }),
    );
  }

  /// After the turn: makes sure the stored copy has the answer, then tells
  /// every window, and lets the scope go once nothing needs it.
  Future<void> _settle(
    _ChatSession session,
    _Turn turn, {
    required bool failed,
  }) async {
    // A direct or Hermes send settles once its answer is stored. This
    // turn's own send: a queued message may already have put its own in
    // [session.pending], and it waits for this settle to start.
    try {
      await turn.pending?.sending;
    } on Object {
      // Reported with the turn.
    }
    final chatId = session.scope.isDisposed
        ? turn.chatId
        : (session.scope.conversation?.id ?? turn.chatId);
    if (temporary.contains(chatId) ||
        (TemporaryChats.isTemporary(chatId) &&
            hermesSessionOf(chatId) == null &&
            !session.scope.isDisposed &&
            _isTemporaryConversation(session.scope.conversation))) {
      if (!session.scope.isDisposed) {
        temporary.replace(chatId, session.scope.messages);
      }
      _announce(chatId);
    } else if (hermesSessionOf(chatId) case final sessionId?) {
      _hermes?.forget(
        sessionId,
        latest: session.scope.isDisposed ? null : session.scope.messages,
      );
      _hermes?.announceSessions();
      _announce(chatId);
    } else if (_storedLocally(session, chatId)) {
      _container.invalidate(loadConversationProvider(chatId));
      _announce(chatId);
    } else {
      await _announceWhenSynced(
        chatId,
        answerId: failed ? null : turn.messageId,
      );
    }
    // Only this turn's: a queued send installed meanwhile keeps its own,
    // so it is still announced, streams and can be stopped.
    if (turn.pending != null && identical(session.pending, turn.pending)) {
      session.pending = null;
    }
    _scheduleLinger(session);
  }

  bool _storedLocally(_ChatSession session, String chatId) {
    if (chatId.startsWith('direct-local:')) return true;
    final conversation = session.scope.isDisposed
        ? null
        : session.scope.conversation;
    return chatStorageKindOf(conversation) == ChatStorageKind.directLocal;
  }

  static bool _isTemporaryConversation(Conversation? conversation) =>
      conversation != null &&
      isTemporaryChat(conversation.id) &&
      chatStorageKindOf(conversation) != ChatStorageKind.openWebUi &&
      !isNativeHermesConversation(conversation);

  void _scheduleLinger(_ChatSession session) {
    session.linger?.cancel();
    if (session.scope.isDisposed) return;
    session.linger = Timer(lingerAfterTurn, () {
      if (session.holds > 0) return;
      final turn = session.turn;
      if (turn != null && !turn.finished) return;
      if (session.pending != null) return;
      // Queued messages live in the scope until they have gone out.
      if (_queued(session)) return;
      // So do answers waiting in the outbox: once one goes out, it streams
      // here and the windows follow it.
      final chatId = session.chatId;
      if (chatId != null && (_queuedCompletions?.hasQueued(chatId) ?? false)) {
        return;
      }
      _close(session);
    });
  }

  // ---------------------------------------------------------------------------
  // Approvals the screen would show
  // ---------------------------------------------------------------------------

  void _hostApprovals(_ChatSession session, ChatMessage answer) {
    final mcp = answer.metadata?[kDirectMcpApprovalMetadataKey];
    if (mcp is Map && mcp['state'] == 'pending') {
      final id = mcp['id']?.toString() ?? '';
      if (id.isNotEmpty &&
          _container.read(directRunRegistryProvider).hasLiveMcpApproval(id) &&
          session.asked.add(id)) {
        unawaited(
          _answerMcpApproval(
            id: id,
            serverName: mcp['serverName']?.toString() ?? '',
            toolName: mcp['toolName']?.toString() ?? '',
            argumentsJson: mcp['arguments']?.toString() ?? '{}',
          ),
        );
      }
    }
    final toolPrompt = findPendingOpenWebUiToolPrompt(<ChatMessage>[answer]);
    final promptChat = session.chatId;
    if (toolPrompt != null &&
        promptChat != null &&
        session.asked.add('openwebui:${toolPrompt.callId}')) {
      // Docked above the chat's composer until answered there (or on
      // another device).
      _chatPrompts?.offerStored(promptChat, toolPrompt);
    }
    final hermes = pendingHermesApprovalOf(session.scope.container, answer);
    if (hermes != null &&
        session.scope.conversation != null &&
        session.asked.add('hermes:${hermes.approvalId}')) {
      final approval = answer.metadata?[kHermesApprovalMeta];
      unawaited(
        _answerHermesApproval(
          session,
          hermes,
          storedCost: approval is Map ? approval['cost'] : null,
        ),
      );
    }
    // A clarify form, a sudo password, a secret or an MCP set-up the agent
    // waits on, docked above the composer until answered (or gone).
    final conversation = session.scope.conversation;
    final cards = hermesCards;
    if (cards != null && conversation != null && promptChat != null) {
      cards.project(
        promptChat,
        session.scope.container,
        conversation.id,
        answer,
      );
    }
    final libreChat = session.scope.isDisposed
        ? null
        : libreChatPendingActionFor(session.scope.container, answer.id);
    final actionId = libreChat?.actionId;
    if (libreChat != null &&
        actionId != null &&
        session.asked.add('librechat:$actionId')) {
      unawaited(_answerLibreChatAction(session, answer.id, libreChat));
    }
  }

  /// Puts what a LibreChat run paused on to the windows and resumes it
  /// ([answerLibreChatPause]), for the turn writing [messageId].
  Future<void> _answerLibreChatAction(
    _ChatSession session,
    String messageId,
    LibreChatPendingAction action,
  ) async {
    final scope = session.scope;
    final turn = session.turn;
    if (turn == null) return;
    // The turn that asked still runs, and still waits on this pause: a card
    // answered or dismissed later touches no newer reply in the chat.
    bool asking() =>
        !turn.finished &&
        identical(session.turn, turn) &&
        !scope.isDisposed &&
        libreChatPendingActionFor(scope.container, messageId)?.actionId ==
            action.actionId;
    final outcome = await answerLibreChatPause(
      action,
      windows: _uiRequests,
      chatId: session.chatId ?? turn.chatId,
      asking: asking,
      until: turn.ended.future,
      resume: ({decisions, answers}) => resolveLibreChatPendingAction(
        scope.container,
        messageId,
        decisions: decisions,
        answers: answers,
      ),
      stop: () => stop(session.chatId ?? turn.chatId),
    );
    // Not sent, and nobody to ask (the pause waited for a window while its
    // turn ran): not left marked as asked, so the answer's next projection
    // offers it again.
    if (outcome == LibreChatPauseOutcome.failed) {
      session.asked.remove('librechat:${action.actionId}');
    }
  }

  Future<void> _answerMcpApproval({
    required String id,
    required String serverName,
    required String toolName,
    required String argumentsJson,
  }) async {
    final registry = _container.read(directRunRegistryProvider);
    final ask = _uiRequests;
    final choice = ask == null
        ? 'deny'
        : await ask.askMcpApproval(
            serverName: serverName,
            toolName: toolName,
            argumentsJson: argumentsJson,
            timeout: kDirectToolApprovalTimeout,
          );
    try {
      switch (choice) {
        case 'allow':
          registry.resolveMcpApprovalById(
            id,
            DirectToolApprovalDecision.allowOnce,
          );
        case 'allowSession':
          registry.resolveMcpApprovalById(
            id,
            DirectToolApprovalDecision.allowSession,
          );
        case 'allowAlways':
          final servers = _container.read(directMcpServersProvider.notifier);
          await registry.resolveMcpApprovalAlwaysById(
            id,
            servers.rememberApproval,
            servers.revokeRememberedApproval,
          );
        default:
          registry.resolveMcpApprovalById(id, DirectToolApprovalDecision.deny);
      }
    } on Object catch (error, stackTrace) {
      DebugLogger.error(
        'mcp-approval-failed',
        scope: 'daemon/turns',
        error: error,
        stackTrace: stackTrace,
      );
      registry.resolveMcpApprovalById(id, DirectToolApprovalDecision.deny);
    }
  }

  /// Puts a prompt Open WebUI raised over the socket, and the core holds
  /// for the chat, to the windows: a confirmation, or questions for the
  /// user. Its card goes once the core lets go of it (answered here,
  /// timed out, or cancelled by the server).
  void _hostLivePrompt(
    _ChatSession session,
    OpenWebUiLivePromptState? previous,
    OpenWebUiLivePromptState? next,
  ) {
    final prompts = _chatPrompts;
    if (prompts == null) return;
    if (previous != null &&
        (next == null || next.prompt.identity != previous.prompt.identity)) {
      prompts.withdraw(
        session.chatId ?? previous.conversationId,
        previous.prompt.identity,
      );
    }
    if (next == null || session.scope.isDisposed) return;
    final identity = next.prompt.identity;
    final kind = next.prompt.kind;
    final scope = session.scope;
    OpenWebUiLivePromptNotifier? notifier() => scope.isDisposed
        ? null
        : scope.container.read(openWebUiLivePromptProvider.notifier);
    prompts.offerLive(
      session.chatId ?? next.conversationId,
      next.prompt,
      onAnswer: (answers) => notifier()?.answer(identity, answers),
      onDecide: (approved) {
        final live = notifier();
        if (live == null) return;
        if (kind == OpenWebUiComposerPromptKind.confirmation) {
          live.decide(identity, approved);
        } else {
          // Questions declined.
          live.cancel();
        }
      },
    );
  }

  /// The prompt Open WebUI saved in [chatId]'s stored answer (a tool
  /// approval, `ask_user` in a saved chat, a coding agent's request), as a
  /// chat opened later finds it: from its open scope, else its stored
  /// transcript. None for a chat this server does not store.
  Future<OpenWebUiPendingToolPrompt?> storedPrompt(String chatId) async {
    if (temporary.contains(chatId) || hermesSessionOf(chatId) != null) {
      return null;
    }
    final open = _sessions
        .where((s) => !s.scope.isDisposed && s.chatId == chatId)
        .firstOrNull;
    final Conversation? conversation;
    final List<ChatMessage> messages;
    if (open != null) {
      conversation = open.scope.conversation;
      messages = open.scope.messages;
    } else {
      try {
        conversation = await readSettled(
          _container,
          loadConversationProvider(chatId).future,
        );
      } on Object {
        return null;
      }
      messages = conversation?.messages ?? const <ChatMessage>[];
    }
    if (conversation == null ||
        !conversationUsesOpenWebUiStorage(conversation) ||
        isTemporaryChat(conversation.id)) {
      return null;
    }
    return findPendingOpenWebUiToolPrompt(messages);
  }

  /// Answers [pending], a prompt saved in [chatId]'s answer: the server
  /// resolves the tool call, and the answer goes on where it stopped, as a
  /// turn of its own (the windows see it stream again).
  Future<void> resolveStoredPrompt(
    String chatId,
    OpenWebUiPendingToolPrompt pending,
    OpenWebUiToolCallAction action,
    Map<String, dynamic>? answers,
  ) async {
    final account = AccountScope.capture(_container);
    final session = await _sessionFor(chatId, account: account);
    _Claim? claim;
    try {
      final running = session.turn;
      if (running != null &&
          !running.finished &&
          running.messageId == pending.messageId) {
        // A coding agent waits on its card inside the turn still running:
        // the server hands that turn the answer and it goes on, so nothing
        // new is started and the busy check does not apply.
        await resolvePersistedOpenWebUiPrompt(
          session.scope.container,
          ownerConversationId: chatId,
          pending: pending,
          action: action,
          answers: answers,
          isMounted: () => !session.scope.isDisposed,
        );
        return;
      }
      claim = await _requireIdle(session);
      final answer = session.scope.messages
          .where((m) => m.id == pending.messageId)
          .lastOrNull;
      if (answer == null) {
        throw const RpcError(
          code: ConduitErrorCodes.notFound,
          debugMessage: 'the answer that asked is no longer in that chat',
        );
      }
      await _run(
        session,
        account: account,
        refuseIfBusy: true,
        modelId: answer.model ?? '',
        userMessageId: null,
        assistantMessageId: pending.messageId,
        start: (_) => resolvePersistedOpenWebUiPrompt(
          session.scope.container,
          ownerConversationId: chatId,
          pending: pending,
          action: action,
          answers: answers,
          isMounted: () => !session.scope.isDisposed,
        ),
      );
    } finally {
      claim?.end();
      _release(session);
    }
  }

  void _showTerminalFile(_ChatSession session, TerminalFileRequest? request) {
    final chatId = session.chatId;
    final path = request?.path.trim() ?? '';
    if (chatId == null || path.isEmpty) return;
    _events.emit(
      ConduitEventSpecs.terminalDisplayFile,
      // The page a model named for a PDF: the window opens it there.
      TerminalDisplayFile(chatId: chatId, path: path, page: request?.page),
      scope: chatId,
    );
  }

  Future<void> _answerHermesApproval(
    _ChatSession session,
    HermesPendingApproval approval, {
    Object? storedCost,
  }) async {
    final ask = _uiRequests;
    final choices = approval.choices.isEmpty
        ? const <String>['once', 'deny']
        : approval.choices;
    // A paid tool's price comes out of the text and shows as chips, as on
    // mobile's approval card.
    final shown = hermesApprovalPresentation(approval.summary, storedCost);
    final cost = shown.cost;
    final choice = ask == null
        ? 'deny'
        : await ask.askHermesApproval(
            summary: shown.summary ?? '',
            choices: choices,
            cost: cost == null
                ? null
                : <String, dynamic>{
                    'price': ?cost.cost,
                    'approximate': cost.approximate,
                    'note': ?cost.note,
                    'spent': ?cost.spent,
                    'limit': ?cost.limit,
                    'server': ?cost.server,
                    'overLimit': cost.overLimit,
                  },
          );
    if (session.scope.isDisposed) return;
    final answered = await resolveHermesApproval(
      session.scope.container,
      approval,
      choice: choice,
    );
    if (!answered) {
      DebugLogger.warning('hermes-approval-not-taken', scope: 'daemon/turns');
    }
  }

  // ---------------------------------------------------------------------------
  // Scopes
  // ---------------------------------------------------------------------------

  _ChatSession? _sessionOf(String chatId) {
    for (final session in _sessions) {
      if (session.chatId == chatId) return session;
    }
    return null;
  }

  /// [chatId]'s scope, opened with the chat in it; a new one for a new chat.
  /// A temporary chat the user deleted is answered no more.
  void _refuseDeleted(String? chatId) {
    if (chatId != null && temporary.isDeleted(chatId)) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'chat $chatId was deleted',
      );
    }
  }

  /// [account]: the account the request began under, captured at its entry
  /// (now, when not given).
  Future<_ChatSession> _sessionFor(
    String? chatId, {
    AccountScope? account,
  }) async {
    account ??= AccountScope.capture(_container);
    if (_disposed) {
      throw const RpcError(
        code: ConduitErrorCodes.shuttingDown,
        debugMessage: 'the daemon is stopping',
      );
    }
    // Whatever the caller waited for before this (a model, the backend),
    // an open chat too is handed only to the account that asked.
    account.require('the chat was asked for');
    _refuseDeleted(chatId);
    if (chatId != null) {
      final existing = _sessionOf(chatId);
      if (existing != null) {
        // Held by this request until it has started its turn or failed.
        existing.linger?.cancel();
        existing.holds++;
        return existing;
      }
    }
    // Loaded under one account, a chat is not opened under the next: an
    // account change while it loads closes only the sessions already open.
    final conversation = chatId == null ? null : await _conversation(chatId);
    account.require('the chat opened');
    late final _ChatSession session;
    final scope = ChatSessionScope.open(
      _container,
      overrides: <Override>[
        // What is said in a voice call goes out through [_run] too, so the
        // windows see it stream into the chat like a typed message.
        chatVoiceSendProvider.overrideWithValue(
          (
            ref,
            text, {
            toolIds,
            contextAttachments,
            isVoiceMode = false,
            voice,
            onAssistantPlaceholderCreated,
          }) => _voiceSend(
            session,
            text,
            toolIds: toolIds,
            contextAttachments: contextAttachments,
            isVoiceMode: isVoiceMode,
            voice: voice,
            onAssistantPlaceholderCreated: onAssistantPlaceholderCreated,
          ),
        ),
        // A batch of queued messages goes out through [_run], so it is
        // followed and published like a turn a window started.
        chatDraftQueueSendProvider.overrideWithValue(
          (
            ref,
            text,
            fileIds, {
            toolIds,
            contextAttachments,
            onAssistantPlaceholderCreated,
            onAdmissionCommitted,
          }) => _queuedSend(
            session,
            text,
            fileIds,
            toolIds: toolIds,
            contextAttachments: contextAttachments,
            onAssistantPlaceholderCreated: onAssistantPlaceholderCreated,
            onAdmissionCommitted: onAdmissionCommitted,
          ),
        ),
        // ...once the chat has settled after the answer before it, with the
        // composer free meanwhile. The core waits for nothing here (the
        // phone's batch goes as its answer ends); this chat settles in order:
        // first the last turn's stored copy, then a quiet transcript that is
        // not streaming ([_beforeQueuedBatch]).
        chatDraftQueueAdmissionWaitProvider.overrideWithValue(
          () => _beforeQueuedBatch(session),
        ),
        // Words the core gives this chat's composer (Hermes' prefill)
        // belong to this chat, not to whichever one a phone would show:
        // each scope has its own, sent to the chat's windows
        // (`composer.insertText`).
        composerTextInsertionProvider.overrideWith(
          ComposerTextInsertionNotifier.new,
        ),
      ],
    );
    session = _ChatSession(scope, requestedChatId: chatId)..holds = 1;
    _followAccountTerminal(scope.container);
    _sessions.add(session);
    session.subscriptions.addAll(<ProviderSubscription<Object?>>[
      scope.container.listen<List<ChatMessage>>(
        chatMessagesProvider,
        (_, _) => _project(session),
      ),
      scope.container.listen<ComposerTextInsertion?>(
        composerTextInsertionProvider,
        (_, next) => _insertText(session, next),
      ),
      // The messages queued behind the answer, and whether one may be.
      scope.container.listen<List<ChatDraftQueue>>(
        chatDraftQueueProvider,
        (_, _) => _publishQueue(session),
      ),
      scope.container.listen<bool>(
        chatDraftQueueOfferProvider,
        (_, _) => _publishQueue(session),
      ),
      scope.container.listen<List<QueuedDraftAttachment>>(
        queuedDraftAttachmentsProvider,
        (_, _) => _publishQueue(session),
      ),
      scope.container.listen<Conversation?>(activeConversationProvider, (
        previous,
        next,
      ) {
        _onConversation(session, previous, next);
        // A new chat's id can arrive after its answer has started.
        _project(session);
      }),
      // A question or confirmation Open WebUI raised mid-turn.
      scope.container.listen<OpenWebUiLivePromptState?>(
        openWebUiLivePromptProvider,
        (previous, next) => _hostLivePrompt(session, previous, next),
      ),
      // A file the model's terminal tool asked to show.
      scope.container.listen<TerminalFileRequest?>(
        terminalDisplayFileProvider,
        (_, next) => _showTerminalFile(session, next),
      ),
    ]);
    if (conversation != null) {
      if (hermesSessionOf(conversation.id) case final sessionId?) {
        scope.container
            .read(hermesActiveSessionProvider.notifier)
            .set(sessionId);
      }
      scope.container
          .read(activeConversationProvider.notifier)
          .set(conversation);
    }
    return session;
  }

  /// The conversation [chatId] names, as a scope opens it.
  Future<Conversation> _conversation(String chatId) async {
    if (temporary.contains(chatId)) {
      final messages = temporary.transcript(chatId);
      final now = DateTime.now();
      return Conversation(
        id: chatId,
        title: messages.isEmpty ? '' : messages.first.content.split('\n').first,
        createdAt: now,
        updatedAt: now,
        messages: messages,
      );
    }
    if (hermesSessionOf(chatId) case final sessionId?) {
      final hermes = _hermes;
      if (hermes == null) {
        throw const RpcError(
          code: ConduitErrorCodes.daemonUnavailable,
          debugMessage: 'the core is not up yet',
        );
      }
      final messages = await hermes.transcript(sessionId, reload: true);
      final now = DateTime.now();
      return markNativeHermesConversation(
        Conversation(
          id: chatId,
          title: await hermes.titleOf(sessionId) ?? '',
          createdAt: now,
          updatedAt: now,
          messages: messages,
          metadata: <String, dynamic>{
            'backend': 'hermes',
            'hermesSessionId': sessionId,
            // A Bot Chat runs as its bot, as the phone opens it.
            ...hermes.chatMetadata(sessionId),
          },
        ),
      );
    }
    try {
      return await readSettled(
        _container,
        loadConversationProvider(chatId).future,
      );
    } on RpcError {
      rethrow;
    } on Object catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        args: <String, String>{'chatId': chatId},
        debugMessage: 'could not open that chat: $error',
      );
    }
  }

  void _onConversation(
    _ChatSession session,
    Conversation? previous,
    Conversation? next,
  ) {
    final turn = session.turn;
    if (next != null && turn != null && !turn.finished) {
      // A chat's id can change under a running turn: a `local:` id replaced
      // by the server's. The windows follow the chat (`route.remap`), so
      // the turn publishes under the new id from then on.
      turn.chatId = next.id;
    }
    // The server titles a new chat, or tags it, after the answer.
    if (previous != null &&
        next != null &&
        previous.id == next.id &&
        (previous.title != next.title ||
            !_sameTags(previous.tags, next.tags))) {
      _announce(next.id);
    }
    // A tool updated the chat's task checklist: the running turn's next
    // frame carries it, or the windows fetch the chat again.
    if (previous != null &&
        next != null &&
        previous.id == next.id &&
        !_deepEquality.equals(
          previous.metadata[kOpenWebUiTasksMetadataKey],
          next.metadata[kOpenWebUiTasksMetadataKey],
        )) {
      if (turn != null && !turn.finished) {
        turn.blocksDirty = true;
      } else {
        _announce(next.id);
      }
    }
  }

  static const DeepCollectionEquality _deepEquality = DeepCollectionEquality();

  static bool _sameTags(List<String> a, List<String> b) =>
      a.length == b.length && a.toSet().containsAll(b);

  void _followRemap(String fromId, String toId) {
    _chatPrompts?.remap(fromId, toId);
    for (final session in _sessions) {
      if (session.turn case final turn? when turn.chatId == fromId) {
        turn.chatId = toId;
      }
      if (session.requestedChatId == fromId) session.requestedChatId = toId;
    }
  }

  /// Lets go of [session] for a request that has started its turn, or failed
  /// to; it lingers from then on as any finished chat does.
  void _release(_ChatSession session) {
    if (session.holds > 0) session.holds--;
    if (session.holds > 0 || session.scope.isDisposed) return;
    final turn = session.turn;
    final running = turn != null && !turn.finished;
    if (!running && session.pending == null) _scheduleLinger(session);
  }

  void _close(_ChatSession session) {
    session.linger?.cancel();
    session.turn?.ticker?.cancel();
    for (final subscription in session.subscriptions) {
      subscription.close();
    }
    session.subscriptions.clear();
    // A temporary chat's transcript lived in the scope; keep it for the next
    // turn and for `chats.get`.
    if (!session.scope.isDisposed) {
      final conversation = session.scope.conversation;
      if (conversation != null && _isTemporaryConversation(conversation)) {
        temporary.replace(conversation.id, session.scope.messages);
      }
    }
    session.scope.dispose();
    _sessions.remove(session);
  }

  void _closeAll({required String reason}) {
    // Another account's prompts are not this one's to answer.
    _chatPrompts?.clear();
    if (_sessions.isEmpty) return;
    DebugLogger.log(
      'chat-scopes-closed',
      scope: 'daemon/turns',
      data: <String, Object?>{'reason': reason, 'count': _sessions.length},
    );
    for (final session in List<_ChatSession>.of(_sessions)) {
      final turn = session.turn;
      if (turn != null && !turn.finished) {
        turn.finished = true;
        if (!turn.ended.isCompleted) turn.ended.complete();
        turn.ticker?.cancel();
        if (hermesSessionOf(turn.chatId) case final sessionId?) {
          _hermes?.setRunning(sessionId, false);
        }
        _remember(turn.messageId);
        _events
          ..emit(
            ConduitEventSpecs.turnFailed,
            TurnFailed(
              chatId: turn.chatId,
              messageId: turn.messageId,
              code: ConduitErrorCodes.sessionExpired,
              partialText: turn.text,
            ),
            scope: turn.chatId,
          )
          ..emit(
            ConduitEventSpecs.turnFinished,
            TurnFinished(
              chatId: turn.chatId,
              messageId: turn.messageId,
              ok: false,
              code: ConduitErrorCodes.sessionExpired,
            ),
          );
      }
      final pending = session.pending;
      if (pending != null && !pending.started.isCompleted) {
        pending.started.completeError(
          const RpcError(
            code: ConduitErrorCodes.sessionExpired,
            debugMessage: 'the account changed before the answer started',
          ),
        );
      }
      _close(session);
    }
  }

  // ---------------------------------------------------------------------------
  // The composer, as the request describes it
  // ---------------------------------------------------------------------------

  /// Sets [scope]'s composer to what this turn asks for. Chosen by hand, so
  /// the core's default-model restore leaves it alone.
  void _choose(
    ProviderContainer scope,
    Model model, {
    bool webSearch = false,
    bool imageGeneration = false,
    bool codeInterpreter = false,
    List<String> toolIds = const <String>[],
    List<String>? filterIds,
    bool? temporary,
  }) {
    scope.read(isManualModelSelectionProvider.notifier).set(true);
    scope.read(selectedModelProvider.notifier).set(model, allowHidden: true);
    scope.read(webSearchEnabledProvider.notifier).set(webSearch);
    scope.read(imageGenerationEnabledProvider.notifier).set(imageGeneration);
    scope.read(codeInterpreterEnabledProvider.notifier).set(codeInterpreter);
    scope.read(selectedToolIdsProvider.notifier).set(toolIds);
    // Chosen in the window, from the model's own defaults; a request that
    // names none (regenerate, edit) keeps the scope's.
    if (filterIds != null) {
      scope.read(selectedFilterIdsProvider.notifier).set(filterIds);
    }
    scope.read(contextAttachmentsProvider.notifier).clear();
    if (temporary != null) {
      scope.read(temporaryChatEnabledProvider.notifier).set(temporary);
    }
    // Hermes' Fast tier, as the window's picker last set it
    // (`models.setFastTier`): the scope's own resets with its model.
    scope
        .read(hermesFastTierSelectionProvider.notifier)
        .set(_container.read(hermesFastTierSelectionProvider));
    _followAccountTerminal(scope);
  }

  /// Gives [scope] the terminal chats use: the account's (`terminal.select`,
  /// the composer's Terminal section), as on mobile, or a coding agent's own
  /// when the scope's model is one (it runs nowhere else). The one place a
  /// scope's terminal is set: when the scope opens, when a turn chooses its
  /// composer, and whenever the account selects another, so every send
  /// reads the selection current when it goes out.
  void _followAccountTerminal(ProviderContainer scope) {
    final agent = terminalAgentTerminalId(scope.read(selectedModelProvider));
    final terminal = agent ?? _container.read(selectedTerminalIdProvider);
    if (scope.read(selectedTerminalIdProvider) != terminal) {
      scope.read(selectedTerminalIdProvider.notifier).set(terminal);
    }
  }

  /// The Hermes agent cards (`hermes.*` work and decisions), told about
  /// every answer a scope projects.
  HermesCardsService? hermesCards;

  /// Opens [chatId]'s live scope, or joins the one open, and keeps it open
  /// until [releaseScope]: a window showing a Hermes chat follows its
  /// agent's work there between turns.
  Future<ProviderContainer> holdScope(String chatId) async {
    final session = await _sessionFor(chatId);
    // Held: a turn's own hold comes and goes beside this one.
    session.linger?.cancel();
    return session.scope.container;
  }

  /// Lets go of a [holdScope]; the scope lingers then, as a finished
  /// chat's does.
  void releaseScope(String chatId) {
    final session = _sessionOf(chatId);
    if (session != null) _release(session);
  }

  /// The container [chatId]'s live scope runs in, or null when the chat has
  /// none open: `chatSettings.*` saves there, so the open chat follows.
  ProviderContainer? scopeOf(String chatId) {
    final session = _sessionOf(chatId);
    return session == null || session.scope.isDisposed
        ? null
        : session.scope.container;
  }

  /// The model a turn runs with.
  ///
  /// The request wins when it names one, as the composer's picker does.
  /// Otherwise the account's selection or default ([currentModel]), and
  /// failing that the first model offered.
  /// The model a LibreChat chat runs on, as the picker knows it. Its
  /// stored answers name the server's raw model (`harbour-small`), which is
  /// no model here; the chat names the picker's (a spec, an agent, or an
  /// endpoint's model). Null for any other chat.
  static String? _libreChatModelOf(_ChatSession session) {
    if (session.scope.isDisposed) return null;
    final conversation = session.scope.conversation;
    if (conversation == null || !isLibreChatConversation(conversation)) {
      return null;
    }
    final id = conversation.model;
    return id == null || id.isEmpty ? null : id;
  }

  Future<Model> _resolveModel(String? requested) async {
    List<Model> models;
    try {
      // Awaited, not read: a turn sent before anything loaded the list
      // would otherwise find none.
      models = await readSettled(_container, modelsProvider.future);
    } on Object catch (error) {
      DebugLogger.error(
        'models-unavailable',
        scope: 'daemon/turns',
        error: error,
      );
      models = const <Model>[];
    }
    final id = requested?.trim();
    if (id != null && id.isNotEmpty) {
      final known = models.where((m) => m.id == id).firstOrNull;
      if (known != null) return known;
      // A direct model is the core's own object, bound in its registry; only
      // discovery hands it out, and a connection saved a moment ago may
      // still be being discovered.
      if (DirectModelId.decode(id) != null) {
        final discovered = await _discoveredDirectModel(id);
        if (discovered != null) return discovered;
      }
      // A coding agent is listed by its terminal, never with the models:
      // the one selected carries its controls; any other goes by its id,
      // which names its terminal.
      if (isTerminalAgentModelId(id)) {
        final selected = _container.read(selectedModelProvider);
        if (selected?.id == id) return selected!;
        return Model(id: id, name: terminalAgentDisplayName(id) ?? id);
      }
      // A bare id shaped like a direct or Hermes model is not that model.
      if (DirectModelId.decode(id) != null || id.startsWith('hermes:')) {
        throw RpcError(
          code: ConduitErrorCodes.notFound,
          args: <String, String>{'model': id},
          debugMessage: 'that model is not available',
        );
      }
      return Model(id: id, name: id);
    }
    final current = await currentModel(_container);
    if (current != null) return current;
    if (models.isNotEmpty) return models.first;
    throw const RpcError(
      code: ConduitErrorCodes.unsupported,
      debugMessage: 'this server offers no models',
    );
  }

  Future<Model?> _discoveredDirectModel(String id) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      try {
        final state = await readSettled(
          _container,
          directModelDiscoveryProvider.future,
        );
        final model = state.models.where((m) => m.id == id).firstOrNull;
        if (model != null) return model;
      } on Object catch (error) {
        DebugLogger.error(
          'direct-discovery-failed',
          scope: 'daemon/turns',
          error: error,
        );
      }
      if (DateTime.now().isAfter(deadline)) return null;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// Refuses a turn its backend cannot take, saying why, before the core
  /// starts one: signed out of Open WebUI, Hermes not set up or waiting for
  /// its sign-in. The core would stop quietly or fail further in, and the
  /// window could only call that a connection problem.
  Future<void> _requireBackendFor(Model model) async {
    if (isHermesModel(model)) {
      final config = _container.read(hermesConfigProvider.notifier);
      // Before anything reads the connection: on a cold start the saved
      // tokens are still loading, and loading them rebuilds the service.
      await config.waitForSecretsHydration();
      if (_container.read(hermesConfigProvider).mode ==
          HermesBackendMode.responsesApi) {
        // The long-term memory key, made before the first turn as mobile
        // does; made later it would rebuild the service underneath.
        await config.ensureSessionKey();
      }
      if (_container.read(hermesApiServiceProvider) == null) {
        throw const RpcError(
          code: ConduitErrorCodes.unauthenticated,
          args: <String, String>{'backend': 'hermes'},
          debugMessage: 'Hermes is not configured',
        );
      }
      if (hermesAwaitsSignIn(_container.read(hermesConfigProvider))) {
        throw const RpcError(
          code: ConduitErrorCodes.unauthenticated,
          args: <String, String>{'backend': 'hermes'},
          debugMessage: 'sign in to Hermes first',
        );
      }
      return;
    }
    if (isLibreChatModel(model)) {
      // A LibreChat model sends through the LibreChat account's session,
      // whose renewals the core runs; none signed in means a sign-in first.
      if (_container.read(libreChatSessionHandleProvider) == null) {
        throw const RpcError(
          code: ConduitErrorCodes.unauthenticated,
          args: <String, String>{'backend': 'libreChat'},
          debugMessage: 'sign in to LibreChat first',
        );
      }
      return;
    }
    final binding = _container.read(directModelRegistryProvider).resolve(model);
    if (binding?.source == DirectModelSource.device) return;
    _requireOpenWebUi();
  }

  /// The signed-in server, or the error that says why there is none.
  ///
  /// Both checks, in this order: a configured-but-signed-out server still
  /// produces a client, so a null check alone lets the request go out and
  /// come back as a transport error.
  ApiService _requireOpenWebUi() {
    final api = _container.read(apiServiceProvider);
    final session = _container.read(authStateManagerProvider).value;
    if (api == null || session == null || !session.isAuthenticated) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'sign in before sending a turn',
      );
    }
    return api;
  }

  /// Refuses a second turn in a chat that is already generating: two
  /// answers would interleave into one transcript.
  ///
  /// A chat this daemon is not answering in is first let settle. Opening an
  /// Open WebUI chat starts the core's reconciliation with the stored and the
  /// server's copies, which can briefly put a finished answer back to
  /// streaming while it checks whether that answer is still running; a
  /// regenerate or an edit started meanwhile loses its claim on the
  /// transcript and the core quietly drops it. On a phone the user's tap
  /// comes after that settles; here the call can come first. So the turn
  /// waits for the transcript to be quiet and not streaming, for at most
  /// [_settleBudget], and only a chat still generating after that is
  /// refused.
  ///
  /// The request has the chat from then until it ends ([_Claim.end], in its
  /// `finally`): a queued batch waiting to go ([_beforeQueuedBatch]) lets it
  /// go first, as the phone's composer does while its queue waits.
  Future<_Claim> _requireIdle(
    _ChatSession session, {
    _Merge? admitting,
    bool saving = false,
    bool deleting = false,
  }) async {
    void refuse() => throw const RpcError(
      code: ConduitErrorCodes.conflict,
      debugMessage: 'that chat is already generating',
    );
    // A temporary chat being saved takes nothing else meanwhile: the saved
    // chat would miss it, and the temporary one goes once it is saved.
    void refuseWhileReserved() {
      if (session.saving && !saving) {
        throw const RpcError(
          code: ConduitErrorCodes.conflict,
          args: <String, String>{'reason': 'saving'},
          debugMessage: 'that chat is being saved',
        );
      }
      if (session.deleting && !deleting) {
        throw const RpcError(
          code: ConduitErrorCodes.conflict,
          debugMessage: 'messages in that chat are being deleted',
        );
      }
    }

    refuseWhileReserved();
    // A merge writes into the transcript too: nothing else starts meanwhile.
    bool merging() =>
        session.merge != null && !identical(session.merge, admitting);
    if (_busy(session) || merging()) refuse();
    final claim = _Claim(session);
    try {
      // The last turn's stored copy first: until it has the answer, the
      // pulls that bring it keep replacing the transcript a new turn reads.
      final settling = session.settling;
      if (settling != null) await _atMost(settling, _settleTimeout);
      if (session.requestedChatId != null ||
          session.scope.conversation != null) {
        await _settleBeforeTurn(session);
      }
      refuseWhileReserved();
      if ((!session.scope.isDisposed && session.scope.isStreaming) ||
          merging()) {
        refuse();
      }
    } on Object {
      claim.end();
      rethrow;
    }
    return claim;
  }

  /// A turn runs in [session], or one is on its way to its answer.
  static bool _busy(_ChatSession session) {
    final turn = session.turn;
    final pending = session.pending;
    return (turn != null && !turn.finished) ||
        (pending != null && !pending.started.isCompleted);
  }

  /// The one rule for every wait before a turn the core sends on its own
  /// (a queued batch, a voice call's words): [_quietNow] holding, with
  /// nothing new installed while it was waited for. Each part is waited
  /// out in turn, then the whole is asked again:
  ///
  /// * an answer running, or about to start (unless it is the caller's own,
  ///   [ownPending]): until it ends, however long;
  /// * the stored copy a turn or merge started: a pull that lands after a
  ///   turn started replaces the transcript it reads, so the turn would be
  ///   dropped by the server's copy (at most [_settleTimeout] each);
  /// * a merge, a delete or a Save Chat: for as long as it runs (a delete
  ///   the server refuses puts back the transcript it found, without the
  ///   turn);
  /// * a window's request on its way ([_ChatSession.claims]): a message
  ///   sent now goes first. Not for a turn already admitted
  ///   ([ownPending]): that request waits for this turn's admission;
  /// * a quiet transcript, not streaming (at most [_settleBudget]).
  ///
  /// Nothing here holds the chat's admission ([_run]): a queued batch waits
  /// for this, then takes admission and asks [_quietNow] again
  /// ([_queuedSend]), so words said meanwhile can still talk over an answer.
  ///
  /// [waitedOut] holds the stored copies already given their
  /// [_settleTimeout]: one set for a whole queued send, so a retry after a
  /// refused admission does not wait for the same one again.
  Future<void> _untilQuiet(
    _ChatSession session, {
    bool ownPending = false,
    Set<Future<void>>? waitedOut,
  }) async {
    waitedOut ??= <Future<void>>{};
    while (!session.scope.isDisposed) {
      final pending = session.pending;
      if (!ownPending && pending != null && !pending.started.isCompleted) {
        await pending.started.future.then((_) {}, onError: (Object _) {});
        continue;
      }
      final turn = session.turn;
      if (turn != null && !turn.finished) {
        await turn.ended.future;
        continue;
      }
      final settling = session.settling;
      if (settling != null && !waitedOut.contains(settling)) {
        waitedOut.add(settling);
        await _atMost(settling, _settleTimeout);
        continue;
      }
      if (_held(session, ownPending: ownPending)) {
        await _pause(const Duration(milliseconds: 50));
        continue;
      }
      await _settleBeforeTurn(session);
      if (_quietNow(session, ownPending: ownPending, waitedOut: waitedOut)) {
        return;
      }
    }
  }

  /// Whether [session] is quiet for a turn the core sends ([_untilQuiet]):
  /// no answer running or about to start (but the caller's own,
  /// [ownPending]), no stored copy settling (but those already waited out,
  /// [waitedOut]), and nothing else holding it ([_held]).
  bool _quietNow(
    _ChatSession session, {
    bool ownPending = false,
    Set<Future<void>> waitedOut = const <Future<void>>{},
  }) {
    if (session.scope.isDisposed) return true;
    final pending = session.pending;
    final turn = session.turn;
    final settling = session.settling;
    return !(turn != null && !turn.finished) &&
        !(!ownPending && pending != null && !pending.started.isCompleted) &&
        (settling == null || waitedOut.contains(settling)) &&
        !_held(session, ownPending: ownPending);
  }

  /// A merge, a delete or a Save Chat out in [session], or (unless the
  /// turn is already admitted, [ownPending]) a window's request on its way.
  static bool _held(_ChatSession session, {bool ownPending = false}) =>
      session.merge != null ||
      session.deleting ||
      session.saving ||
      (!ownPending && session.claims > 0);

  /// What a batch of queued messages waits for before the core admits it
  /// (its [chatDraftQueueAdmissionWaitProvider]): [_untilQuiet]. The core
  /// then sends it, and [_queuedSend] asks the same again before the batch
  /// takes the chat.
  ///
  /// The chat is not busy meanwhile, and the composer offers Send, as the
  /// phone's does while its queue waits on the server. A message sent now
  /// goes first, and the batch after its answer and that answer's stored
  /// copy.
  Future<void> _beforeQueuedBatch(_ChatSession session) => _untilQuiet(session);

  static const Duration _settleBudget = Duration(seconds: 6);

  /// Longest a turn waits for the previous one to reach the stored copy:
  /// past [syncRetryDelays]' total, so a sync that is merely slow is waited
  /// for, and one that has failed outright does not hold the turn.
  static const Duration _settleTimeout = Duration(seconds: 20);
  static const Duration _settleQuiet = Duration(milliseconds: 500);

  /// [future], or [limit] on this service's clock, whichever comes first.
  Future<void> _atMost(Future<void> future, Duration limit) {
    final ended = future.then((_) {}, onError: (Object _) {});
    if (!_ownClock) return ended.timeout(limit, onTimeout: () {});
    return Future.any(<Future<void>>[ended, _pause(limit)]);
  }

  /// Waits for [session]'s transcript to be quiet and not streaming, for at
  /// most [_settleBudget].
  Future<void> _settleBeforeTurn(_ChatSession session) async {
    if (session.scope.isDisposed) return;
    var lastChange = _now();
    final watch = session.scope.container.listen<List<ChatMessage>>(
      chatMessagesProvider,
      (_, _) => lastChange = _now(),
    );
    try {
      final deadline = _now().add(_settleBudget);
      while (!session.scope.isDisposed) {
        final quiet = _now().difference(lastChange) >= _settleQuiet;
        if (quiet && !session.scope.isStreaming) return;
        if (!_now().isBefore(deadline)) return;
        await _pause(const Duration(milliseconds: 50));
      }
    } finally {
      watch.close();
    }
  }

  void _refuseTemporary(String chatId) {
    if (temporary.contains(chatId)) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'a temporary chat has no history to branch',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Telling the windows
  // ---------------------------------------------------------------------------

  void _announce(String chatId) {
    // Unscoped, so every window's sidebar reorders; the payload names the
    // chat, so only a window showing it refetches its transcript.
    _events.emit(ConduitEventSpecs.chatsChanged, ChatsChanged(chatId: chatId));
  }

  Future<void> _announceWhenSynced(String chatId, {String? answerId}) async {
    // Nothing to pull for a chat the server never stored.
    if (TemporaryChats.isTemporary(chatId)) {
      _announce(chatId);
      return;
    }
    for (final delay in <Duration>[Duration.zero, ...syncRetryDelays]) {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (_disposed) return;
      await _pull(chatId);
      // A failed turn has no answer to wait for; one pull is all it gets.
      if (answerId == null || await _hasAnswer(chatId, answerId)) break;
    }
    if (!_disposed) _announce(chatId);
  }

  Future<void> _pull(String chatId) async {
    try {
      await _container.read(syncEngineProvider.notifier).pullChatNow(chatId);
    } on Object catch (error) {
      DebugLogger.error(
        'post-turn-pull-failed',
        scope: 'daemon/turns',
        error: error,
      );
    }
    _container.invalidate(loadConversationProvider(chatId));
  }

  Future<bool> _hasAnswer(String chatId, String answerId) async {
    try {
      final conversation = await readSettled(
        _container,
        loadConversationProvider(chatId).future,
      );
      return conversation.messages.any(
        (message) => message.id == answerId && message.content.isNotEmpty,
      );
    } on Object {
      // Unreadable is not the same as missing, and retrying would not make
      // it readable. Announce what there is.
      return true;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static ChatMessage? _answerOf(_ChatSession session, _Turn turn) {
    if (session.scope.isDisposed) return null;
    return _find(session, session.scope.messages, turn.messageId);
  }

  /// The message the windows know as [id] in [messages]. A LibreChat turn's
  /// messages start with ids minted here and take the server's once it
  /// names them; the windows keep the id the turn was announced with, and
  /// the transcript is searched under the server's.
  static ChatMessage? _find(
    _ChatSession session,
    List<ChatMessage> messages,
    String id,
  ) {
    final found = messages.where((m) => m.id == id).lastOrNull;
    if (found != null) return found;
    final current = _currentId(session, id);
    if (current == id) return null;
    return messages.where((m) => m.id == current).lastOrNull;
  }

  static String _currentId(_ChatSession session, String id) =>
      session.scope.isDisposed
      ? id
      : session.scope.container
            .read(libreChatRunRegistryProvider)
            .currentMessageId(id);

  static bool _changed(ChatMessage? before, ChatMessage after) =>
      before == null ||
      before.content != after.content ||
      before.versions.length != after.versions.length ||
      before.timestamp != after.timestamp;

  static Map<String, int>? _usageOf(Map<String, dynamic>? usage) {
    if (usage == null || usage.isEmpty) return null;
    final counts = <String, int>{
      for (final entry in usage.entries)
        if (entry.value is num) entry.key: (entry.value as num).toInt(),
    };
    return counts.isEmpty ? null : counts;
  }

  static String _describe(Object error) => switch (error) {
    RpcError(:final debugMessage?) => debugMessage,
    StateError(:final message) => message,
    _ => '$error',
  };

  static RpcError _rpcErrorFor(Object error) {
    if (error is RpcError) return error;
    if (error is DirectChatInputException) {
      return RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'detail': error.message},
        debugMessage: error.message,
      );
    }
    // LibreChat keeps every chat: a temporary one is refused before anything
    // is sent, as on the phone.
    if (error is LibreChatTemporaryChatException) {
      return const RpcError(
        code: ConduitErrorCodes.unsupported,
        args: <String, String>{'reason': 'libreChatTemporaryChat'},
        debugMessage: 'LibreChat keeps every chat; temporary chat is on',
      );
    }
    final detail = _describe(error);
    return RpcError(
      code: ConduitErrorCodes.serverError,
      args: <String, String>{'detail': detail},
      debugMessage: detail,
    );
  }
}

/// One chat's scope and the turn running in it.
final class _ChatSession {
  _ChatSession(this.scope, {required this.requestedChatId});

  final ChatSessionScope scope;

  /// The id the scope was opened for; null for a new chat.
  String? requestedChatId;

  _PendingTurn? pending;
  _Turn? turn;
  Timer? linger;

  /// Save Chat is making this temporary chat a stored one.
  bool saving = false;

  /// Messages in this chat are being deleted.
  bool deleting = false;

  /// Requests preparing a turn in this chat; it is not let go meanwhile.
  int holds = 0;

  /// Requests a window made that [TurnsService._requireIdle] let through and
  /// that have not yet started their turn or ended: a queued batch waits for
  /// them ([TurnsService._beforeQueuedBatch]).
  int claims = 0;

  /// The last turn's post-turn sync, while it runs.
  Future<void>? settling;

  /// The last turn's final blocks and terminal event, for a window that adds
  /// this chat after they went out.
  _Ended? ended;
  final List<ProviderSubscription<Object?>> subscriptions =
      <ProviderSubscription<Object?>>[];

  /// Approvals already put to the user, so each is asked once.
  final Set<String> asked = <String>{};

  /// The queue as `queue.changed` last published it.
  QueueState? lastQueue;

  /// A merge (Merge Responses) writing in this chat.
  _Merge? merge;

  /// A call in a new chat: the window's temporary and folder choices, for
  /// the turn that makes the chat.
  ({bool temporary, String? folderId})? callNewChat;

  /// The last send asked for, until its turn has started (or it failed): a
  /// send that comes meanwhile waits for it ([TurnsService._run]).
  Future<void>? admitting;

  String? get chatId {
    if (!scope.isDisposed) {
      final id = scope.conversation?.id;
      if (id != null) return id;
    }
    return turn?.chatId ?? requestedChatId;
  }
}

/// A window's request that [TurnsService._requireIdle] let through: it has
/// [session] until [end], which its `finally` calls once.
final class _Claim {
  _Claim(this.session) {
    session.claims++;
  }

  final _ChatSession session;
  bool _ended = false;

  void end() {
    if (_ended) return;
    _ended = true;
    session.claims--;
  }
}

/// A turn asked for whose answer has not appeared yet.
/// A queued batch admitted while the chat had stopped being quiet: it lets
/// admission go and waits again ([TurnsService._queuedSend]).
final class _NotQuietYet implements Exception {
  const _NotQuietYet();
}

final class _PendingTurn {
  _PendingTurn({
    required this.model,
    required this.userMessageId,
    required this.baseline,
    this.compare = false,
  });

  final String model;
  String? userMessageId;

  /// The answer's id, once the core's send has made its placeholder.
  String? assistantMessageId;

  /// The answers in the transcript before this turn, as they were; the turn
  /// is the answer that starts streaming, or that changed, since.
  final Map<String, ChatMessage> baseline;

  Future<void>? sending;
  bool sendSettled = false;
  Object? sendError;
  final Completer<_Turn> started = Completer<_Turn>();

  /// A batch of queued messages the core has committed: the outbox owns
  /// its turn, which starts now rather than once the request has gone out.
  /// No window is waiting on it, and its chat has its server id; the
  /// windows show the chat answering from here on, as the phone does once
  /// the batch's answer appears, instead of offering Send.
  bool committed = false;

  /// A Compare Models turn: its other answers are the turn's companions.
  final bool compare;
}

/// Another column's answer of a Compare Models turn, streamed beside the
/// turn's own.
final class _Companion {
  String text = '';
  bool dirty = false;
  final StreamingContentBlocks live = StreamingContentBlocks();
  int? blockInputs;
  bool blocksDirty = false;
  List<MessageBlockDto> lastBlocks = const <MessageBlockDto>[];
  bool finished = false;

  /// How it ended, for a window that subscribes while the turn's own
  /// answer still streams: one of these once [finished].
  TurnCompleted? completed;
  TurnFailed? failed;
}

/// One answer being streamed.
final class _Turn {
  _Turn({
    required this.chatId,
    required this.messageId,
    required this.model,
    required this.userMessageId,
    required this.clientOwned,
  });

  /// Not final: a chat's `local:` id can be replaced by the server's while
  /// the answer streams.
  String chatId;
  final String messageId;
  final String model;
  final String? userMessageId;

  /// Whether this process talks to the provider itself (direct, Hermes), so
  /// the send that started the turn lasts as long as the answer.
  final bool clientOwned;

  /// The send that started this turn; null for one followed from the
  /// queued-answer outbox. [session.pending] may already be the next send.
  _PendingTurn? pending;

  /// Completes once the turn has finished (stopped, failed or done): what
  /// it put to the windows goes with it.
  final Completer<void> ended = Completer<void>();

  String text = '';
  bool dirty = false;

  /// Parses the answer frame by frame without re-reading what is closed.
  final StreamingContentBlocks live = StreamingContentBlocks();

  /// [messageBlockInputsHash] of the answer as last seen.
  int? blockInputs;

  /// The blocks need publishing though the text may not have changed.
  bool blocksDirty = false;

  /// The blocks last built, for a frame where the answer is gone from the
  /// transcript.
  List<MessageBlockDto> lastBlocks = const <MessageBlockDto>[];
  bool announced = false;
  bool finished = false;
  bool stopped = false;
  Timer? ticker;

  /// A comparison's other answers, by id.
  final Map<String, _Companion> companions = <String, _Companion>{};
}

/// A merge (Merge Responses) running in a chat.
final class _Merge {
  _Merge({
    required this.chatId,
    required this.messageId,
    required this.targetId,
  });

  final String chatId;
  final String messageId;
  final String targetId;
  String text = '';
  bool published = false;
  Timer? ticker;
}

/// How a turn ended, kept for a window that subscribes afterwards.
final class _Ended {
  _Ended({required this.blocks, this.completed, this.failed});

  final TurnBlocks blocks;
  final TurnCompleted? completed;
  final TurnFailed? failed;
}

/// Who a new chat's settings were checked for.
/// A chat scope a voice call holds ([TurnsService.holdForCall]).
final class CallScopeHold {
  CallScopeHold._(
    this.scope, {
    required String? Function() chatId,
    required void Function() release,
  }) : _chatId = chatId,
       _release = release;

  final ChatSessionScope scope;
  final String? Function() _chatId;
  final void Function() _release;

  /// The chat's id now: null for a new chat until its first turn made it.
  String? get chatId => _chatId();

  /// Lets the scope go; it lingers as any finished chat's does.
  void release() => _release();
}
