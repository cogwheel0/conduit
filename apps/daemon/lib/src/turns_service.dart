import 'dart:async';
import 'dart:convert';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/features/direct_connections/models/direct_completion.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_mcp_client.dart';
import 'package:conduit_core/features/direct_connections/services/direct_run_registry.dart'
    show kMaxDirectMcpApprovalArgumentCharacters;
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_adapter_helpers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_storage.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/direct_connections/services/direct_provider_adapter.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/ports/ui_request_port.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/chat_completion_transport.dart';
import 'package:conduit_core/services/message_rating.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/services/streaming_helper.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/id_remapper.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/utils/openwebui_request_variables.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/utils/message_tree_utils.dart' as message_tree;
import 'package:conduit_core/utils/system_prompt.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';

import 'event_bus.dart';
import 'files_service.dart';
import 'hermes_service.dart';
import 'language_tag.dart';
import 'settled.dart';
import 'temporary_chats.dart';
import 'ui_requests_service.dart';

part 'direct_turns.dart';
part 'hermes_turns.dart';

/// Implements `turns.*`: sending a message and streaming the answer.
///
/// Drives the core's `attachUnifiedChunkedStreaming` directly rather than
/// going through the mobile app's transport dispatch. That dispatch exists to
/// reconcile a Flutter notifier, a sidebar spinner and a background-task
/// lifecycle with the stream; none of those exist here, and reimplementing
/// them in order to reuse the wrapper would be more code than driving the
/// helper itself.
///
/// What is *not* reimplemented is anything that decides what the stream
/// means. Parsing, tool calls, reasoning splitting, socket-vs-HTTP transport,
/// the watchdog and the post-stream snapshot pull all stay where they are.
/// This class owns exactly two things the helper does not: a per-chat buffer,
/// and the coalescing that turns a token firehose into frames a renderer can
/// keep up with.
final class TurnsService {
  TurnsService(
    this._container,
    this._events, {
    FilesService? files,
    TemporaryChats? temporary,
    UiRequestPort? uiRequests,
    HermesService? hermes,
  }) : _files = files,
       _hermes = hermes,
       _uiRequests = uiRequests ?? const NullUiRequestPort(),
       temporary = temporary ?? TemporaryChats() {
    _remaps = _container
        .read(syncEngineProvider.notifier)
        .remapEvents
        .where((event) => event.entityKind == 'chat')
        .listen((event) => _followRemap(event.fromId, event.toId));
  }

  StreamSubscription<RemapEvent>? _remaps;

  /// Moves a turn to its chat's new id.
  ///
  /// A direct chat mirrored to Open WebUI is written as `local:` and the
  /// sync engine may give it the server's id while the answer is still
  /// streaming. The window follows the chat (`route.remap`) and listens on
  /// the new id from then on, so the turn has to publish there too, or the
  /// rest of the answer goes to nobody.
  void _followRemap(String fromId, String toId) {
    final turn = _active.remove(fromId);
    if (turn != null) {
      turn.chatId = toId;
      _active[toId] = turn;
    }
    if (_settling.remove(fromId) case final settling?) {
      _settling[toId] = settling;
    }
  }

  /// Conversations the server never stores. Shared with `ChatsService`,
  /// which answers `chats.get` for them from the same memory.
  final TemporaryChats temporary;

  /// Where the streaming pipeline takes a question it needs a person to
  /// answer: a tool approval, a server prompt. Declines with no UI attached.
  final UiRequestPort _uiRequests;

  final ProviderContainer _container;
  final EventBus _events;

  /// Names the attachments a turn refers to. Optional so a test that only
  /// exercises sending does not have to build one.
  final FilesService? _files;

  /// Hermes sessions' transcripts.
  final HermesService? _hermes;

  static const Uuid _uuid = Uuid();

  /// Coalescing window for `turn.delta`.
  ///
  /// A 60 Hz ceiling. A fast model emits tokens far quicker than
  /// that, and every extra frame costs a JSON encode, a socket write and a
  /// markdown parse for text the user cannot read at that rate anyway.
  static const Duration _deltaInterval = Duration(milliseconds: 16);

  final Map<String, _ActiveTurn> _active = <String, _ActiveTurn>{};

  /// MCP tools allowed "for this session": approval fingerprint to the
  /// server it was allowed on. Forgotten when the daemon exits.
  final Map<String, String> _sessionMcpApprovals = <String, String>{};

  /// Chats currently generating, for the sidebar's spinner.
  Iterable<String> get activeChatIds => _active.keys;

  /// The signed-in server, or the error that says why there is none.
  ///
  /// Both checks, and in this order. A configured-but-signed-out server
  /// still produces an `ApiService`, so a null check alone lets the request
  /// go out and come back as a transport error -- which tells the user their
  /// network is broken when in fact they are signed out.
  ApiService _requireApi() {
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

  /// The live socket's session id, connecting it first if it has dropped.
  ///
  /// Sent with a turn so the server runs it as a task that reports over the
  /// socket, the same way it runs for Open WebUI's own client and for
  /// mobile. That is what makes server-initiated prompts possible: a tool
  /// asking for approval addresses a session, and without one it has nobody
  /// to ask. Null falls back to a plain HTTP stream, which still answers.
  Future<String?> _socketSession(SendTurn request, {bool force = false}) async {
    // Only for a turn that opts into what the server does itself: tools,
    // web search, code execution, image generation. Those are the turns
    // where a tool can ask for approval or a function can ask a question,
    // and they need the socket to do it.
    //
    // Not for every turn, which is what Open WebUI's own client does. With
    // a socket session the server injects its built-in tools into the
    // request, and a model that cannot take tools (a small Ollama model,
    // for instance) then fails every turn with "does not support tools".
    // The model list does not say which models those are, and retrying
    // cannot repair it: the failed attempt is persisted against the answer
    // and read back after the retry succeeds. A plain turn therefore stays
    // on HTTP, as it always has.
    //
    // `force` is for a model from a direct connection kept in the Open
    // WebUI account: the server asks this app, over the socket, to make the
    // request, so without a session there is nobody for it to ask.
    if (!force && !_wantsServerTools(request)) return null;
    final socket = _container.read(socketServiceProvider);
    if (socket == null) return null;
    if (!socket.isConnected) {
      try {
        await socket.ensureConnected(
          timeout: const Duration(milliseconds: 1200),
        );
      } on Object catch (error) {
        DebugLogger.log('socket-connect-failed: $error', scope: 'daemon/turns');
      }
    }
    final id = socket.sessionId;
    return socket.isConnected && id != null && id.isNotEmpty ? id : null;
  }

  static bool _wantsServerTools(SendTurn request) =>
      request.toolIds.isNotEmpty ||
      request.webSearch ||
      request.codeInterpreter ||
      request.imageGeneration;

  /// Refuses a second turn in a chat that is already generating.
  ///
  /// Two answers would interleave into one placeholder, and the server would
  /// be answering a history that does not include the message it is
  /// answering.
  void _requireIdle(String chatId) {
    if (_active.containsKey(chatId)) {
      throw const RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: 'that chat is already generating',
      );
    }
  }

  Future<SendTurnAccepted> send(SendTurn request) async {
    final text = request.text.trim();
    if (text.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'turns.send needs a non-empty text',
      );
    }

    final requested = await _resolveModel(request.model);
    if (requested == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'this server offers no models',
      );
    }
    // A connection kept in the Open WebUI account: sent through the server
    // under the id it knows, and relayed back through this app.
    final relayed = await _openWebUiWireModel(requested);
    final model = relayed ?? requested;

    // Hermes Agent: the daemon runs the turn against it.
    if (relayed == null && await _isHermes(model)) {
      return _sendHermes(request, model: model, text: text);
    }

    // A model from a direct connection on this computer: the daemon is the
    // client.
    if (relayed == null) {
      if (DirectModelId.decode(model) case final route?) {
        return _sendDirect(request, model: model, text: text, route: route);
      }
    }
    final api = _requireApi();

    final chatId = request.chatId;
    if (chatId != null) _requireIdle(chatId);

    final history = chatId == null
        ? const <ChatMessage>[]
        : await _historyFor(chatId);

    final userMessageId = _uuid.v4();
    final assistantMessageId = _uuid.v4();
    final userMessage = ChatMessage(
      id: userMessageId,
      role: 'user',
      content: text,
      timestamp: DateTime.now(),
    );

    // A new chat is created on the server *before* the completion request.
    //
    // Not an optimisation -- a requirement. Open WebUI answers a completion
    // for an unknown conversation with a JSON null, and the core's recovery
    // path for that explicitly needs a persisted conversation id: "Cannot
    // recover a JSON null chat completion without a persisted conversation
    // ID". Creating first is also what the mobile app does, and it means the
    // server owns the id from the start, so there is never a local id to
    // reconcile afterwards.
    final String resolvedChatId;
    if (chatId == null && request.temporary) {
      // No server call at all. The `local:` prefix is what Open WebUI, the
      // core's persistence paths and the sync engine all read as "never
      // store this", so a temporary chat needs no flag beyond its id.
      resolvedChatId = 'local:${_uuid.v4()}';
      temporary.start(resolvedChatId);
    } else if (chatId == null) {
      final created = await api.createConversation(
        title: _titleFor(text),
        messages: <ChatMessage>[userMessage],
        model: model,
      );
      resolvedChatId = created.id;
    } else {
      resolvedChatId = chatId;
    }

    // Checked again now that a new chat has an id.
    _requireIdle(resolvedChatId);
    if (TemporaryChats.isTemporary(resolvedChatId)) {
      temporary.append(resolvedChatId, userMessage);
    }

    final payload = withSystemMessage(<Map<String, dynamic>>[
      for (final message in history)
        <String, dynamic>{'role': message.role, 'content': message.content},
      <String, dynamic>{'role': 'user', 'content': text},
    ], await _systemPromptFor(api, resolvedChatId));

    // A temporary chat is sent as a bare completion: no chat id, no parent,
    // no user-message node. Open WebUI's own temporary chats rely on a live
    // socket session, and without one a `local:` chat id is answered with a
    // JSON null the core can only recover for a *persisted* chat. The
    // server needs none of that here, because the daemon keeps the
    // transcript itself.
    final isTemporary = TemporaryChats.isTemporary(resolvedChatId);
    // Uploaded files, then knowledge bases chosen with `#` -- which Open
    // WebUI's client sends in the same list, typed `collection`.
    final descriptors = <Map<String, dynamic>>[
      ...?(request.fileIds.isEmpty
          ? null
          : _files?.attachmentsFor(request.fileIds)),
      for (final knowledge in request.knowledge)
        <String, dynamic>{
          'type': 'collection',
          'id': knowledge.id,
          'name': knowledge.name,
          'description': ?knowledge.description,
        },
    ];
    final attachments = descriptors.isEmpty ? null : descriptors;
    final variables = await _variables();
    Future<ChatCompletionSession> dispatch(
      String? sessionId,
    ) => api.sendMessageSession(
      sessionIdOverride: sessionId,
      variables: variables,
      terminalId: _terminalIdFor(model),
      messages: payload,
      model: model,
      conversationId: isTemporary ? null : resolvedChatId,
      responseMessageId: assistantMessageId,
      parentId: isTemporary || history.isEmpty ? null : history.last.id,
      // What the server records as the user's turn. Without it an existing
      // chat gains an answer with nothing to answer.
      userMessage: isTemporary
          ? null
          : <String, dynamic>{
              'id': userMessageId,
              'role': 'user',
              'content': text,
              'timestamp': userMessage.timestamp.millisecondsSinceEpoch ~/ 1000,
              'models': <String>[model],
              'childrenIds': <String>[assistantMessageId],
              if (history.isNotEmpty) 'parentId': history.last.id,
              // On the question as well as the request, as Open WebUI's
              // own client does: the request is what the model reads,
              // the stored question is what shows the attachment later.
              'files': ?attachments,
            },
      toolIds: request.toolIds.isEmpty ? null : request.toolIds,
      // Uploaded through `POST /upload`, so the daemon already knows each
      // one's name and size -- which Open WebUI wants alongside the id.
      files: attachments,
      enableWebSearch: request.webSearch,
      enableImageGeneration: request.imageGeneration,
      enableCodeInterpreter: request.codeInterpreter,
    );
    final sessionId = isTemporary
        ? null
        : await _socketSession(request, force: relayed != null);
    final completion = await dispatch(sessionId);

    _attach(
      api: api,
      chatId: resolvedChatId,
      model: model,
      completion: completion,
      overSocket: sessionId != null,
      request: request,
    );

    return SendTurnAccepted(
      chatId: resolvedChatId,
      userMessageId: userMessageId,
      assistantMessageId: completion.messageId,
    );
  }

  /// Runs a turn again, replacing one assistant answer.
  ///
  /// A branch, not an overwrite. Open WebUI records the new answer as
  /// another child of the same user message, so the previous one stays
  /// reachable -- which matters, because a user who regenerates and prefers
  /// the first answer has not lost it. That also means this does not delete
  /// anything: the server decides which child is current.
  Future<SendTurnAccepted> regenerate(RegenerateTurn request) async {
    // Both rely on the stored message tree, which a temporary chat does
    // not have.
    if (temporary.contains(request.chatId)) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'a temporary chat has no history to branch',
      );
    }
    _requireIdle(request.chatId);

    final history = await _historyFor(request.chatId);
    final index = history.indexWhere((m) => m.id == request.messageId);
    if (index < 0) {
      throw const RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'no such message in that conversation',
      );
    }
    if (history[index].role != 'assistant') {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'only an assistant message can be regenerated',
      );
    }

    // Everything before the answer, which necessarily ends at the user
    // message that prompted it. Searching backwards for the nearest user
    // message rather than assuming `index - 1`: a turn can leave tool or
    // system messages in between, and sending those as the parent would
    // branch from the wrong place.
    final prompt = history.sublist(0, index);
    final userIndex = prompt.lastIndexWhere((m) => m.role == 'user');
    if (userIndex < 0) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'that answer has no message to answer',
      );
    }
    final userMessage = prompt[userIndex];

    // Precedence matters here in a way it does not for a send. "Run this
    // again" means the same model unless the caller says otherwise, so the
    // answer's own model outranks the account's current selection -- and
    // `??` after `_resolveModel` never reached it, because that method
    // already falls back to "the first model the server offers". On a
    // server whose first model is paid-tier, every regenerate came back as
    // a refusal for a model the user had not chosen.
    final requested = await _resolveModel(
      request.model ?? history[index].model,
    );
    if (requested == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'this server offers no models',
      );
    }
    final relayed = await _openWebUiWireModel(requested);
    final model = relayed ?? requested;

    if (DirectModelId.decode(model) case final route? when relayed == null) {
      return _regenerateDirect(
        chatId: request.chatId,
        model: model,
        route: route,
        prompt: prompt.sublist(0, userIndex + 1),
        user: userMessage,
      );
    }

    final api = _requireApi();
    final systemPrompt = await _systemPromptFor(api, request.chatId);
    final variables = await _variables();
    Future<ChatCompletionSession> dispatch(
      String? sessionId,
    ) => api.sendMessageSession(
      variables: variables,
      sessionIdOverride: sessionId,
      terminalId: _terminalIdFor(model),
      messages: withSystemMessage(<Map<String, dynamic>>[
        for (final message in prompt)
          <String, dynamic>{'role': message.role, 'content': message.content},
      ], systemPrompt),
      model: model,
      conversationId: request.chatId,
      responseMessageId: _uuid.v4(),
      // Open WebUI 0.9+ reads these two fields differently from what their
      // names suggest. `parent_id` is the *user message's* parent: the
      // answer before it, or null for the first turn. `user_message` is what
      // the server links the new answer to, through its id.
      //
      // The first version of this sent `parentId: userMessage.id` and no
      // user message. The server then recorded the new answer with no
      // parent, left it out of the user message's children, and made it
      // `currentId`. The conversation's visible path lost the question, and
      // the answer being regenerated became unreachable. That is the
      // opposite of a branch.
      //
      // The user message goes back as it already is on the server. Its
      // existing children are included, so the server appends the new
      // answer to them instead of replacing them.
      parentId: message_tree.chatMessageParentId(userMessage),
      userMessage: <String, dynamic>{
        'id': userMessage.id,
        'role': 'user',
        'content': userMessage.content,
        'timestamp': userMessage.timestamp.millisecondsSinceEpoch ~/ 1000,
        'models': <String>[model],
        'parentId': message_tree.chatMessageParentId(userMessage),
        'childrenIds': message_tree.chatMessageChildrenIds(userMessage),
      },
    );
    final sessionId = relayed == null
        ? null
        : await _socketSession(const SendTurn(text: ''), force: true);
    final completion = await dispatch(sessionId);

    _attach(
      api: api,
      chatId: request.chatId,
      model: model,
      completion: completion,
      overSocket: sessionId != null,
      // The flags a regenerate cannot carry: the original request's tool
      // and web-search choices are not recorded per message, so repeating
      // the turn repeats the prompt, not the tooling.
      request: SendTurn(chatId: request.chatId, text: userMessage.content),
    );

    return SendTurnAccepted(
      chatId: request.chatId,
      userMessageId: userMessage.id,
      assistantMessageId: completion.messageId,
    );
  }

  /// Replaces one of the user's messages and answers the new text.
  ///
  /// The new question is a sibling of the old one: same parent, new id.
  /// Open WebUI links it into the parent's children and makes it current,
  /// and the old question keeps its answer and everything after it. Nothing
  /// is deleted.
  Future<SendTurnAccepted> edit(EditTurn request) async {
    // Both rely on the stored message tree, which a temporary chat does
    // not have.
    if (temporary.contains(request.chatId)) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'a temporary chat has no history to branch',
      );
    }
    _requireIdle(request.chatId);
    final text = request.text.trim();
    if (text.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'turns.edit needs a non-empty text',
      );
    }

    final history = await _historyFor(request.chatId);
    final index = history.indexWhere((m) => m.id == request.messageId);
    if (index < 0) {
      throw const RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'no such message in that conversation',
      );
    }
    final original = history[index];
    if (original.role != 'user') {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'only a user message can be edited',
      );
    }

    // Everything before the edited question, which is what the new one is
    // asked on top of. Answers after it belong to the old branch.
    final before = history.sublist(0, index);
    // The same parent the original had. That makes the two siblings, and
    // makes this a branch rather than a continuation.
    final parentId = message_tree.chatMessageParentId(original);
    // A user message carries no model. The answer that followed it does,
    // and "ask this again, differently" means the same model as before.
    final answeredWith = history
        .skip(index + 1)
        .where((m) => m.role == 'assistant')
        .firstOrNull
        ?.model;
    final requested = await _resolveModel(request.model ?? answeredWith);
    if (requested == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'this server offers no models',
      );
    }
    final relayed = await _openWebUiWireModel(requested);
    final model = relayed ?? requested;

    if (DirectModelId.decode(model) case final route? when relayed == null) {
      return _editDirect(
        chatId: request.chatId,
        model: model,
        route: route,
        before: before,
        parent: before.where((m) => m.id == parentId).lastOrNull,
        text: text,
      );
    }

    final api = _requireApi();
    final userMessageId = _uuid.v4();
    final assistantMessageId = _uuid.v4();
    final now = DateTime.now();

    final systemPrompt = await _systemPromptFor(api, request.chatId);
    final variables = await _variables();
    Future<ChatCompletionSession> dispatch(String? sessionId) =>
        api.sendMessageSession(
          variables: variables,
          sessionIdOverride: sessionId,
          terminalId: _terminalIdFor(model),
          messages: withSystemMessage(<Map<String, dynamic>>[
            for (final message in before)
              <String, dynamic>{
                'role': message.role,
                'content': message.content,
              },
            <String, dynamic>{'role': 'user', 'content': text},
          ], systemPrompt),
          model: model,
          conversationId: request.chatId,
          responseMessageId: assistantMessageId,
          // As with regenerate, `parent_id` is the *user message's* parent. The
          // server uses the user message's own `parentId` to link it into that
          // parent's children, which is what puts the new question beside the
          // old one.
          parentId: parentId,
          userMessage: <String, dynamic>{
            'id': userMessageId,
            'role': 'user',
            'content': text,
            'timestamp': now.millisecondsSinceEpoch ~/ 1000,
            'models': <String>[model],
            'childrenIds': <String>[assistantMessageId],
            'parentId': ?parentId,
          },
        );
    final sessionId = relayed == null
        ? null
        : await _socketSession(const SendTurn(text: ''), force: true);
    final completion = await dispatch(sessionId);

    _attach(
      api: api,
      chatId: request.chatId,
      model: model,
      completion: completion,
      overSocket: sessionId != null,
      request: SendTurn(chatId: request.chatId, text: text),
    );

    return SendTurnAccepted(
      chatId: request.chatId,
      userMessageId: userMessageId,
      assistantMessageId: completion.messageId,
    );
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
      await MessageRating(_requireApi()).rate(
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
    final turn = _active[chatId];
    if (turn == null) return;
    if (turn.direct) {
      turn.stopped = true;
      try {
        await turn.cancel?.call();
      } on Object catch (error) {
        DebugLogger.error(
          'turn-stop-failed',
          scope: 'daemon/turns',
          error: error,
        );
      }
      return;
    }
    try {
      await turn.stream?.controller?.cancel();
    } on Object catch (error) {
      DebugLogger.error(
        'turn-stop-failed',
        scope: 'daemon/turns',
        error: error,
      );
    }
    _finish(chatId);
  }

  /// Wires a started completion to the event bus.
  ///
  /// Shared by `send` and `regenerate` because from here on the two are the
  /// same thing: a stream of tokens for one assistant message in one chat.
  /// The renderer cannot tell them apart either, which is the point -- a
  /// regenerated answer arrives through exactly the `turn.*` events a sent
  /// one does.
  void _attach({
    required ApiService api,
    required String chatId,
    required String model,
    required ChatCompletionSession completion,
    required SendTurn request,
    bool overSocket = false,
  }) {
    final turn = _ActiveTurn(
      chatId: chatId,
      messageId: completion.messageId,
      model: model,
    )..overSocket = overSocket;
    _active[chatId] = turn;

    _events.publish(
      ConduitEvents.turnStarted,
      scope: chatId,
      payload: TurnStarted(
        chatId: chatId,
        messageId: completion.messageId,
        model: model,
      ).toJson(),
    );

    turn.stream = attachUnifiedChunkedStreaming(
      session: completion,
      webSearchEnabled: request.webSearch,
      assistantMessageId: completion.messageId,
      modelId: model,
      modelItem: const <String, dynamic>{},
      sessionId: completion.sessionId,
      activeConversationId: chatId,
      api: api,
      // Only a turn sent over the socket listens on it. An HTTP turn gets
      // everything on its own stream, and listening anyway let a *failed*
      // socket attempt's late error event, carrying the same message id,
      // land on the HTTP retry that had already answered.
      socketService: overSocket ? _container.read(socketServiceProvider) : null,
      uiRequests: _uiRequests,
      workerManager: _container.read(workerManagerProvider),
      appendToLastMessage: turn.append,
      bufferLastMessageContent: turn.buffer,
      replaceLastMessageContent: turn.replace,
      updateLastMessageWith: turn.updateLast,
      appendStatusUpdate: (_, _) {},
      upsertCodeExecution: (_, _) {},
      appendSourceReference: (_, _) {},
      // A model's terminal tool asks to show a file: the window shows it.
      onTerminalDisplayFile: (path) => _events.publish(
        ConduitEvents.terminalDisplayFile,
        scope: chatId,
        payload: TerminalDisplayFile(chatId: chatId, path: path).toJson(),
      ),
      // How a failed turn arrives. The helper does not throw for a server
      // refusal -- it sets an error on the message and finishes -- so a
      // no-op here reported "free tier users do not have access to this
      // model" to the user as a successful empty answer.
      updateMessageById: (id, update) {
        if (id != turn.messageId) return;
        final applied = update(turn.snapshot());
        // `content` is nullable, and an error with no message is still an
        // error -- reporting it as a successful empty answer is the failure
        // this whole branch exists to avoid.
        if (applied.error case final error?) {
          turn.fail(error.content ?? ConduitErrorCodes.serverError);
        }
      },
      completeStreamingUi: () {},
      finishStreaming: () => _finish(chatId),
      getMessages: () => <ChatMessage>[turn.snapshot()],
      getVisibleStreamingContent: () => turn.text,
      flushStreamingBuffer: turn.flush,
      // The same pull the mobile app uses, so both front-ends end up with
      // the server's version of the chat rather than each keeping its own
      // reconstruction of it.
      pullChatSnapshot: (id) =>
          _container.read(syncEngineProvider.notifier).pullChatNow(id),
    );

    turn.ticker = Timer.periodic(_deltaInterval, (_) => _emitDelta(turn));
  }

  Future<void> dispose() async {
    await _remaps?.cancel();
    for (final chatId in _active.keys.toList()) {
      await stop(chatId);
    }
  }

  /// The model to send with.
  ///
  /// The request wins when it names one, as the composer's picker does. Otherwise the account's current selection, and failing that the
  /// first model the server offers -- which is what a fresh install has
  /// before anything has been chosen.
  Future<String?> _resolveModel(String? requested) async {
    final trimmed = requested?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;

    final selected = _container.read(selectedModelProvider);
    if (selected != null) return selected.id;

    // Awaited, not read with `.value`. That was null until something else
    // had loaded the model list, so a turn sent before the renderer asked
    // for models failed with "this server offers no models" on a server
    // that offers a couple of dozen.
    try {
      final available = await readSettled(_container, modelsProvider.future);
      return available.isEmpty ? null : available.first.id;
    } on Object catch (error) {
      DebugLogger.error(
        'models-unavailable',
        scope: 'daemon/turns',
        error: error,
      );
      return null;
    }
  }

  /// A first title for a new chat.
  ///
  /// The server renames it from the conversation shortly afterwards; this is
  /// what the sidebar shows until then, and it beats "New Chat" for telling
  /// two fresh conversations apart.
  static String _titleFor(String text) {
    final firstLine = text.split('\n').first.trim();
    if (firstLine.length <= 48) return firstLine;
    return '${firstLine.substring(0, 47)}\u2026';
  }

  /// The system prompt a turn in [chatId] goes out with.
  ///
  /// The conversation's own, else the user's default from their Open WebUI
  /// settings -- which desktop turns used to ignore, so the same question
  /// answered differently here than on the phone or the web. Settings are
  /// kept for a minute: they change rarely, and a turn should not wait on
  /// a second request to learn nothing new.
  /// The terminal a turn may use, as mobile sends it: the one
  /// selected, unless the model has switched terminals off in its
  /// capabilities.
  String? _terminalIdFor(String modelId) {
    final selected = _container.read(selectedTerminalIdProvider)?.trim();
    if (selected == null || selected.isEmpty) return null;
    final models = _container.read(modelsProvider).value ?? const <Model>[];
    final model = models.where((m) => m.id == modelId).firstOrNull;
    final info = model?.metadata?['info'];
    final meta = info is Map ? info['meta'] : null;
    final capabilities = meta is Map ? meta['capabilities'] : null;
    if (capabilities is Map && capabilities['terminal'] == false) return null;
    return selected;
  }

  Future<String?> _systemPromptFor(ApiService api, String? chatId) async {
    String? own;
    if (chatId != null && !temporary.contains(chatId)) {
      try {
        own = (await readSettled(
          _container,
          loadConversationProvider(chatId).future,
        )).systemPrompt;
      } on Object {
        own = null;
      }
    }
    if (own != null && own.trim().isNotEmpty) return own.trim();
    final fetchedAt = _settingsFetchedAt;
    if (fetchedAt == null ||
        DateTime.now().difference(fetchedAt) > const Duration(minutes: 1)) {
      try {
        _settings = await api.getUserSettings().timeout(
          const Duration(seconds: 5),
        );
        _settingsFetchedAt = DateTime.now();
      } on Object catch (error) {
        DebugLogger.error(
          'settings-failed',
          scope: 'daemon/turns',
          error: error,
        );
      }
    }
    return effectiveSystemPrompt(conversationPrompt: own, settings: _settings);
  }

  Map<String, dynamic>? _settings;
  DateTime? _settingsFetchedAt;

  /// Open WebUI's request `variables` -- `{{USER_NAME}}`, `{{CURRENT_DATE}}`
  /// and the rest -- as its own client fills them, so a model's system
  /// prompt reads the same from here as from the browser.
  ///
  /// The location is the account's fixed one, when it has one. Looking it up
  /// live is the phone's job; Chromium's geolocation needs a Google key on
  /// Windows and Linux, and the Apple helper is not here yet.
  Future<Map<String, dynamic>> _variables() async {
    User? user;
    try {
      user = await readSettled(_container, currentUserProvider.future);
    } on Object {
      user = null;
    }
    final name = user?.name?.trim();
    final location = extractUserLocationSetting(_settings).legacyLocation;
    return buildOpenWebUiPromptVariables(
      now: DateTime.now(),
      userName: name != null && name.isNotEmpty ? name : (user?.email ?? ''),
      userEmail: user?.email ?? '',
      userLanguage: userLanguageTag(_container),
      userLocation: location,
    );
  }

  /// The conversation so far, as the server has it.
  ///
  /// `loadConversationProvider`, not `conversationsProvider`: the latter is
  /// the sidebar's list, and its rows are envelopes with no message bodies
  /// by design. Reading `.messages` off one returned an empty history for
  /// every chat not created in this session -- so every follow-up message
  /// was sent to the model with no memory of the conversation it was in,
  /// and the answer read as though the user had started over.
  Future<List<ChatMessage>> _historyFor(String chatId) async {
    // By membership, not by the `local:` prefix: a direct chat waiting to
    // reach Open WebUI has that prefix too, and its history is stored.
    if (temporary.contains(chatId)) return temporary.transcript(chatId);
    if (_settling[chatId] case final pending?) {
      await pending.timeout(_settleTimeout, onTimeout: () {});
    }
    try {
      final conversation = await _container.read(
        loadConversationProvider(chatId).future,
      );
      return conversation.messages;
    } on Object catch (error) {
      // An unloadable history is better sent empty than not sent: the user
      // gets an answer without context rather than an error.
      DebugLogger.error(
        'history-load-failed',
        scope: 'daemon/turns',
        error: error,
        data: <String, Object?>{'chatId': chatId},
      );
      return const <ChatMessage>[];
    }
  }

  /// Publishes at most one frame per tick, and only when something changed.
  ///
  /// The emptiness check is what makes a slow model cost nothing: a stream
  /// that produces a token a second would otherwise publish sixty identical
  /// frames between each one.
  void _emitDelta(_ActiveTurn turn) {
    if (!turn.dirty) return;
    turn.dirty = false;
    _events.publish(
      ConduitEvents.turnDelta,
      scope: turn.chatId,
      payload: TurnDelta(
        chatId: turn.chatId,
        messageId: turn.messageId,
        text: turn.text,
      ).toJson(),
    );
  }

  void _finish(String chatId) {
    final turn = _active.remove(chatId);
    if (turn == null) return;
    turn.ticker?.cancel();

    // A final frame regardless of the tick, so the last tokens are never
    // stranded by the coalescing window closing first.
    if (turn.failure case final failure?) {
      _events.publish(
        ConduitEvents.turnFailed,
        scope: chatId,
        payload: TurnFailed(
          chatId: chatId,
          messageId: turn.messageId,
          code: ConduitErrorCodes.serverError,
          // The server's own words. Errors cross as codes, and
          // they do -- but a refusal like "this model needs a paid plan" is
          // information only the server has, and dropping it would leave the
          // user with `server.error` and no way to act.
          args: <String, String>{'detail': failure},
          partialText: turn.text,
        ).toJson(),
      );
    } else {
      // A direct turn has added its own answer already.
      if (!turn.direct && TemporaryChats.isTemporary(chatId)) {
        temporary.append(
          chatId,
          ChatMessage(
            id: turn.messageId,
            role: 'assistant',
            content: turn.text,
            timestamp: DateTime.now(),
            model: turn.model,
          ),
        );
      }
      _events.publish(
        ConduitEvents.turnCompleted,
        scope: chatId,
        payload: TurnCompleted(
          chatId: chatId,
          messageId: turn.messageId,
          text: turn.text,
        ).toJson(),
      );
    }
    // After the pull, not now. The stream has ended, but the database, which
    // is what `chats.get` reads, only has the answer once the snapshot pull
    // lands. Publishing straight away made the renderer refetch a
    // transcript whose answer was still the empty placeholder. It then kept
    // that version, because nothing told it to look again.
    // A direct turn has already written its answer; there is nothing on a
    // server to wait for.
    final settling = turn.direct
        ? _announceStored(chatId)
        : _announceWhenSynced(
            chatId,
            answerId: turn.failure == null ? turn.messageId : null,
          );
    _settling[chatId] = settling;
    unawaited(
      settling.whenComplete(() {
        if (identical(_settling[chatId], settling)) _settling.remove(chatId);
      }),
    );
  }

  /// The post-turn sync still running for each chat.
  ///
  /// A follow-up waits for it. The next question's parent is the last
  /// message in the stored copy, and until the sync lands that copy ends a
  /// turn early -- so a question sent straight after an answer was hung off
  /// the answer *before* it, forking the conversation and dropping the
  /// latest exchange from view.
  final Map<String, Future<void>> _settling = <String, Future<void>>{};

  /// Longest a turn waits for the previous one to reach the stored copy.
  ///
  /// Past the retry schedule's total, so a sync that is merely slow is
  /// waited for. One that has failed outright is not worth holding the
  /// user's message for: it goes out with the history there is.
  static const Duration _settleTimeout = Duration(seconds: 20);

  /// How long to keep looking for a finished answer in the server's copy.
  ///
  /// Open WebUI writes the answer when its own stream handler finishes,
  /// which is not the moment ours does. A single pull straight after the
  /// stream usually wins that race, and when it lost, the renderer fetched
  /// a transcript without the answer and was never told to look again: a
  /// regenerated answer sat beside the one it replaced instead of becoming
  /// its second version.
  ///
  /// Assignable so a test can shorten it.
  static List<Duration> syncRetryDelays = const <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];

  Future<void> _announceWhenSynced(String chatId, {String? answerId}) async {
    // Nothing to pull for a chat the server never stored, and the core's
    // pull would refuse a `local:` id anyway.
    if (TemporaryChats.isTemporary(chatId)) {
      _events.publish(
        ConduitEvents.chatsChanged,
        payload: ChatsChanged(chatId: chatId).toJson(),
      );
      return;
    }
    for (final delay in <Duration>[Duration.zero, ...syncRetryDelays]) {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      await _pull(chatId);
      // A failed turn has no answer to wait for; one pull is all it gets.
      if (answerId == null || await _hasAnswer(chatId, answerId)) break;
    }
    // Unscoped, so every window's sidebar reorders, including a window
    // showing a different conversation. The payload says which chat it was
    // about, so only a window showing that chat refetches its transcript.
    _events.publish(
      ConduitEvents.chatsChanged,
      payload: ChatsChanged(chatId: chatId).toJson(),
    );
  }

  Future<void> _announceStored(String chatId) async {
    _container.invalidate(loadConversationProvider(chatId));
    _events.publish(
      ConduitEvents.chatsChanged,
      payload: ChatsChanged(chatId: chatId).toJson(),
    );
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
    // `loadConversationProvider` is a family. An entry that already loaded
    // this chat would otherwise answer from what it read before the pull.
    _container.invalidate(loadConversationProvider(chatId));
  }

  /// Whether the stored conversation has [answerId] with its text in it.
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
}

/// One in-flight answer.
class _ActiveTurn {
  _ActiveTurn({
    required this.chatId,
    required this.messageId,
    required this.model,
  });

  /// Not final: a direct chat's `local:` id can be replaced by the
  /// server's while the answer streams. See [TurnsService._followRemap].
  String chatId;
  final String messageId;
  final String model;

  /// Whether the server is running this turn as a socket task.
  bool overSocket = false;

  /// Whether the daemon itself is talking to the provider. Such a turn
  /// stores its own answer, so there is nothing to pull afterwards.
  bool direct = false;

  /// Stops a direct turn's provider request; its runner then stores what
  /// arrived and finishes the turn.
  Future<void> Function()? cancel;
  bool stopped = false;

  final StringBuffer _content = StringBuffer();
  String? _pending;
  bool dirty = false;

  Timer? ticker;
  ActiveChatStream? stream;

  /// Set when the server refused or failed the turn.
  String? failure;

  void fail(String message) => failure = message;

  String get text => _pending ?? _content.toString();

  void append(String chunk) {
    _flushPendingIntoBuffer();
    _content.write(chunk);
    dirty = true;
  }

  /// Holds a whole-content replacement without materializing it.
  ///
  /// The helper buffers rather than appends whenever it has rewritten the
  /// content (a reasoning split, a tool-call rerender). Keeping it as a
  /// pending string means the common append path never pays for a rebuild.
  void buffer(String content) {
    _pending = content;
    dirty = true;
  }

  void replace(String content) {
    _pending = null;
    _content
      ..clear()
      ..write(content);
    dirty = true;
  }

  void updateLast(ChatMessage Function(ChatMessage) update) {
    final updated = update(snapshot());
    replace(updated.content);
  }

  void flush() => _flushPendingIntoBuffer();

  void _flushPendingIntoBuffer() {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    _content
      ..clear()
      ..write(pending);
  }

  ChatMessage snapshot() => ChatMessage(
    id: messageId,
    role: 'assistant',
    content: text,
    timestamp: DateTime.now(),
    model: model,
    isStreaming: true,
  );
}
