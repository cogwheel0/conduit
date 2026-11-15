import 'dart:async';

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
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart'
    show HermesSteerUncertain;
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart'
    show kHermesTransport;
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart'
    show TerminalFileRequest, terminalDisplayFileProvider;
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
import 'package:conduit_core/persistence/account_scoped_preferences.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/message_rating.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';

import 'chat_prompts_service.dart';
import 'chats_service.dart' show ChatTurns;
import 'composer_wire.dart';
import 'event_bus.dart';
import 'files_service.dart';
import 'hermes_service.dart';
import 'message_blocks.dart';
import 'models_service.dart';
import 'queued_completions_service.dart';
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
final class TurnsService implements ChatTurns {
  TurnsService(
    this._container,
    this._events, {
    TemporaryChats? temporary,
    UiRequestsService? uiRequests,
    HermesService? hermes,
    FilesService? files,
    ChatPromptsService? chatPrompts,
    QueuedCompletionsService? queued,
  }) : temporary = temporary ?? TemporaryChats(),
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
    ];
    _remaps = _container
        .read(syncEngineProvider.notifier)
        .remapEvents
        .where((event) => event.entityKind == 'chat')
        .listen((event) => _followRemap(event.fromId, event.toId));
  }

  final ProviderContainer _container;
  final EventBus _events;

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

  /// Whether [chatId] is answering, or about to.
  @override
  bool isRunning(String chatId) {
    final session = _sessionOf(chatId);
    if (session == null) return false;
    final turn = session.turn;
    final pending = session.pending;
    return (turn != null && !turn.finished) ||
        (pending != null && !pending.started.isCompleted);
  }

  /// Whether [chatId] has a scope here: a turn, a merge or a queue in it,
  /// or one just finished.
  bool hasScope(String chatId) => _sessionOf(chatId) != null;

  @override
  Future<void> settled(String chatId) async {
    final settling = _sessionOf(chatId)?.settling;
    if (settling == null) return;
    await settling.timeout(_settleTimeout, onTimeout: () {});
  }

  /// Whether a merge (Merge Responses) is writing in [chatId].
  @override
  bool mergeRunning(String chatId) => _sessionOf(chatId)?.merge != null;

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
    final paramsOwner = request.chatId == null
        ? await _requireChatParamsAccess(model, request)
        : null;
    await _requireBackendFor(model);
    final session = await _sessionFor(request.chatId);
    try {
      await _requireIdle(session);
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
        if (paramsOwner != null && !_stillOwner(paramsOwner)) {
          throw _accountChanged;
        }
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
        return await _compare(session, request, text, knowledge);
      }
      return await _run(
        session,
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
      _release(session);
    }
  }

  /// A new Open WebUI chat's settings ([SendTurn.chatParams]) are saved as
  /// it is made: held to the rule `chatSettings.save` keeps, the system
  /// prompt by the account's prompt right and the rest by its parameters
  /// right. A Direct or Hermes chat keeps no Open WebUI settings.
  ///
  /// Returns the account the rights were read for, to check again as the
  /// settings are stored; null when nothing needs them.
  Future<_ParamsOwner?> _requireChatParamsAccess(
    Model model,
    SendTurn request,
  ) async {
    final params = request.chatParams;
    if (params == null || params.isEmpty) return null;
    // Only a chat this device runs keeps no Open WebUI settings: Hermes, or
    // a Direct connection of its own. A server's own connection is still
    // the server's chat, held to its rights.
    if (isHermesModel(model) ||
        _container.read(directModelRegistryProvider).resolve(model)?.source ==
            DirectModelSource.device) {
      return null;
    }
    // The rights are the asking account's: another one signed in or made
    // active while they load gets nothing stored or sent.
    final owner = (
      session: _container.read(openWebUiAuthSessionEpochProvider),
      accountId: currentPreferenceAccountId(),
    );
    OpenWebUiChatSettingsAccess access;
    try {
      access = await readSettled(
        _container,
        openWebUiChatSettingsAccessProvider.future,
      );
    } on Object {
      access = OpenWebUiChatSettingsAccess.denied;
    }
    if (!_stillOwner(owner)) throw _accountChanged;
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
    return owner;
  }

  /// The session (the signed-in user's, by its epoch) and account the rights
  /// were read for, still the current ones.
  bool _stillOwner(_ParamsOwner owner) =>
      identical(
        owner.session,
        _container.read(openWebUiAuthSessionEpochProvider),
      ) &&
      owner.accountId == currentPreferenceAccountId();

  static const _accountChanged = RpcError(
    code: ConduitErrorCodes.sessionExpired,
    debugMessage: 'the account changed after its chat rights were read',
  );

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
        modelId: models.first.id,
        userMessageId: null,
        compare: true,
        start: (onPlaceholder) {
          // The core reads the knowledge and context from the scope's tray,
          // which choosing the model emptied: both answers get them, as a
          // normal send does.
          final tray = scope.read(contextAttachmentsProvider.notifier)
            ..clear();
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
    _refuseTemporary(request.chatId);
    final session = await _sessionFor(request.chatId);
    try {
      await _requireIdle(session);
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
        request.model ?? target.assistantMessage.model,
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
        modelId: model.id,
        userMessageId: target.userMessage.id,
        start: (_) => regenerateHistoricalMessageById(
          session.scope.container,
          request.messageId,
        ),
      );
    } finally {
      _release(session);
    }
  }

  /// Replaces one of the user's messages and answers the new text.
  ///
  /// The new question is a sibling of the old one, so the old question keeps
  /// its answer and everything after it.
  Future<SendTurnAccepted> edit(EditTurn request) async {
    _refuseTemporary(request.chatId);
    final text = request.text.trim();
    if (text.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'turns.edit needs a non-empty text',
      );
    }
    final session = await _sessionFor(request.chatId);
    try {
      await _requireIdle(session);
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
      final model = await _resolveModel(request.model ?? answeredWith);
      await _requireBackendFor(model);
      _choose(session.scope.container, model);
      return await _run(
        session,
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
  Future<int> deleteMessages(DeleteMessages request) async {
    final session = await _sessionFor(request.chatId);
    var reserved = false;
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
      await _requireIdle(session, deleting: true);
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
      _release(session);
    }
  }

  /// Merge Responses: [MergeTurn.sourceIds] (by default, the answers a
  /// merge may read) merged into one response and saved on
  /// [MergeTurn.targetId], through the core's merge, in the chat's scope.
  /// The text goes out as `messages.merge`, at most one frame per tick, and
  /// once more as it ends. [MergeTurn.stop] stops the running merge.
  Future<MergeStarted> merge(MergeTurn request) async {
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
    final session = await _sessionFor(request.chatId);
    var started = false;
    // Reserved before the first await, so a second merge, or a send, edit
    // or regenerate ([_requireIdle]), is refused while this one is admitted.
    _Merge? run;
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
      await _requireIdle(session, admitting: run);
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
            responses: <String>[for (final answer in sources) answer.sourceText],
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
    if (!temporary.contains(chatId)) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'only a temporary chat can be saved',
      );
    }
    final session = await _sessionFor(chatId);
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
    try {
      await _requireIdle(session, saving: true);
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
    final session = _sessionOf(chatId);
    final turn = session?.turn;
    if (session == null || turn == null || turn.finished) return;
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
    unawaited(
      _run(
        session,
        modelId: model.id,
        userMessageId: null,
        start: (onPlaceholder) async {
          // As before any turn ([_requireIdle]): the last turn's stored copy
          // first, then a quiet transcript. A turn started while a pull
          // adopts the stored rows is dropped by the server's copy, and the
          // queue's batch follows an answer that has only just ended.
          final settling = session.settling;
          if (settling != null) {
            await settling.timeout(_settleTimeout, onTimeout: () {});
          }
          await _settleBeforeTurn(session);
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
            onAdmissionCommitted: onAdmissionCommitted,
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
      ).then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          if (!sent.isCompleted) sent.completeError(error, stackTrace);
        },
      ),
    );
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
    final session = await _sessionFor(request.chatId);
    try {
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
  Future<SendTurnAccepted> _run(
    _ChatSession session, {
    required String modelId,
    required String? userMessageId,
    bool compare = false,
    String? assistantMessageId,
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
        final turn = session.turn;
        if (turn != null && !turn.finished) {
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
    if (turn == null || turn.finished) return;
    final answer = messages.where((m) => m.id == turn.messageId).lastOrNull;
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
      answer = messages.where((m) => m.id == expected).lastOrNull;
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
    final transport = answer.metadata?['transport'];
    final clientOwned =
        transport == kHermesTransport || transport == kDirectTransport;
    // The id the windows address the chat by. A direct or Hermes chat has
    // it as soon as the core has made the chat; an Open WebUI turn returns
    // once its send has, by which time a new chat has the server's id.
    final chatId = session.scope.conversation?.id;
    if (chatId == null || (!clientOwned && !pending.sendSettled)) return;
    final index = messages.indexOf(answer);
    final question =
        pending.userMessageId ??
        messages
            .take(index < 0 ? 0 : index)
            .lastWhere((m) => m.role == 'user', orElse: () => answer!)
            .id;
    final turn = _Turn(
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
    turn.ticker?.cancel();
    session.ended = null;
    // The turn is over here, its send settled or not: the scope may close
    // once nothing else holds it.
    if (pending != null && identical(pending, turn.pending)) {
      session.pending = null;
    }
    _scheduleLinger(session);
    _events.emit(
      ConduitEventSpecs.turnFinished,
      TurnFinished(chatId: chatId, messageId: turn.messageId, ok: true),
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
    final session = await _sessionFor(ref.chatId);
    try {
      final info = await _queuedInfo(session, ref.messageId);
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
    final session = await _sessionFor(ref.chatId);
    try {
      final info = await _queuedInfo(session, ref.messageId);
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
        .contentForStreamingMessage(turn.messageId);
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
              // paid plan" is information only the server has.
              args: <String, String>{'detail': ?error},
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
    // Unscoped: every window hears it, whichever chat it shows.
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
      _hermes?.forget(sessionId);
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
      unawaited(_answerHermesApproval(session, hermes));
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
    final session = await _sessionFor(chatId);
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
      await _requireIdle(session);
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
      _release(session);
    }
  }

  void _showTerminalFile(_ChatSession session, TerminalFileRequest? request) {
    final chatId = session.chatId;
    final path = request?.path.trim() ?? '';
    if (chatId == null || path.isEmpty) return;
    _events.emit(
      ConduitEventSpecs.terminalDisplayFile,
      TerminalDisplayFile(chatId: chatId, path: path),
      scope: chatId,
    );
  }

  Future<void> _answerHermesApproval(
    _ChatSession session,
    HermesPendingApproval approval,
  ) async {
    final ask = _uiRequests;
    final choices = approval.choices.isEmpty
        ? const <String>['once', 'deny']
        : approval.choices;
    final choice = ask == null
        ? 'deny'
        : await ask.askHermesApproval(
            summary: approval.summary ?? '',
            choices: choices,
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

  Future<_ChatSession> _sessionFor(String? chatId) async {
    if (_disposed) {
      throw const RpcError(
        code: ConduitErrorCodes.shuttingDown,
        debugMessage: 'the daemon is stopping',
      );
    }
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
    final account = _container.read(openWebUiAuthSessionEpochProvider);
    final conversation = chatId == null ? null : await _conversation(chatId);
    if (!identical(
      account,
      _container.read(openWebUiAuthSessionEpochProvider),
    )) {
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        debugMessage: 'the account changed while the chat loaded',
      );
    }
    late final _ChatSession session;
    final scope = ChatSessionScope.open(
      _container,
      overrides: <Override>[
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
      ],
    );
    session = _ChatSession(scope, requestedChatId: chatId)..holds = 1;
    _sessions.add(session);
    session.subscriptions.addAll(<ProviderSubscription<Object?>>[
      scope.container.listen<List<ChatMessage>>(
        chatMessagesProvider,
        (_, _) => _project(session),
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
        turn.ticker?.cancel();
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
  Future<void> _requireIdle(
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
    final turn = session.turn;
    if ((turn != null && !turn.finished) ||
        (session.pending != null && !session.pending!.started.isCompleted) ||
        merging()) {
      refuse();
    }
    // The last turn's stored copy first: until it has the answer, the
    // pulls that bring it keep replacing the transcript a new turn reads.
    final settling = session.settling;
    if (settling != null) {
      await settling.timeout(_settleTimeout, onTimeout: () {});
    }
    if (session.requestedChatId != null || session.scope.conversation != null) {
      await _settleBeforeTurn(session);
    }
    refuseWhileReserved();
    if ((!session.scope.isDisposed && session.scope.isStreaming) ||
        merging()) {
      refuse();
    }
  }

  static const Duration _settleBudget = Duration(seconds: 6);

  /// Longest a turn waits for the previous one to reach the stored copy:
  /// past [syncRetryDelays]' total, so a sync that is merely slow is waited
  /// for, and one that has failed outright does not hold the turn.
  static const Duration _settleTimeout = Duration(seconds: 20);
  static const Duration _settleQuiet = Duration(milliseconds: 500);

  Future<void> _settleBeforeTurn(_ChatSession session) async {
    if (session.scope.isDisposed) return;
    var lastChange = DateTime.now();
    final watch = session.scope.container.listen<List<ChatMessage>>(
      chatMessagesProvider,
      (_, _) => lastChange = DateTime.now(),
    );
    try {
      final deadline = DateTime.now().add(_settleBudget);
      while (DateTime.now().isBefore(deadline) && !session.scope.isDisposed) {
        final quiet = DateTime.now().difference(lastChange) >= _settleQuiet;
        if (quiet && !session.scope.isStreaming) return;
        await Future<void>.delayed(const Duration(milliseconds: 50));
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
    return session.scope.messages
        .where((m) => m.id == turn.messageId)
        .lastOrNull;
  }

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

  String? get chatId {
    if (!scope.isDisposed) {
      final id = scope.conversation?.id;
      if (id != null) return id;
    }
    return turn?.chatId ?? requestedChatId;
  }
}

/// A turn asked for whose answer has not appeared yet.
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
typedef _ParamsOwner = ({Object session, String? accountId});
