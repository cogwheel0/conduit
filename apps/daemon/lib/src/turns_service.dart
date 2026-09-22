import 'dart:async';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/services/streaming_helper.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';

import 'event_bus.dart';

/// Implements `turns.*`: sending a message and streaming the answer (M3).
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
  TurnsService(this._container, this._events);

  final ProviderContainer _container;
  final EventBus _events;

  static const Uuid _uuid = Uuid();

  /// Coalescing window for `turn.delta`.
  ///
  /// The plan's 60 Hz ceiling. A fast model emits tokens far quicker than
  /// that, and every extra frame costs a JSON encode, a socket write and a
  /// markdown parse for text the user cannot read at that rate anyway.
  static const Duration _deltaInterval = Duration(milliseconds: 16);

  final Map<String, _ActiveTurn> _active = <String, _ActiveTurn>{};

  /// Chats currently generating, for the sidebar's spinner.
  Iterable<String> get activeChatIds => _active.keys;

  Future<SendTurnAccepted> send(SendTurn request) async {
    final api = _container.read(apiServiceProvider);
    // Both checks, and in this order. A configured-but-signed-out server
    // still produces an `ApiService`, so a null check alone lets the request
    // go out and come back as a transport error -- which tells the user
    // their network is broken when in fact they are signed out.
    final session = _container.read(authStateManagerProvider).value;
    if (api == null || session == null || !session.isAuthenticated) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'sign in before sending a turn',
      );
    }
    final text = request.text.trim();
    if (text.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'turns.send needs a non-empty text',
      );
    }

    final model = _resolveModel(request.model);
    if (model == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'this server offers no models',
      );
    }

    final chatId = request.chatId;
    // One turn per chat. A second send while the first is streaming would
    // interleave two answers into one placeholder, and the server would be
    // answering a history that does not include the message it is answering.
    if (chatId != null && _active.containsKey(chatId)) {
      throw const RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: 'that chat is already generating',
      );
    }

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
    if (chatId == null) {
      final created = await api.createConversation(
        title: _titleFor(text),
        messages: <ChatMessage>[userMessage],
        model: model,
      );
      resolvedChatId = created.id;
    } else {
      resolvedChatId = chatId;
    }

    // One turn per chat, checked again now that a new chat has an id.
    if (_active.containsKey(resolvedChatId)) {
      throw const RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: 'that chat is already generating',
      );
    }

    final payload = <Map<String, dynamic>>[
      for (final message in history)
        <String, dynamic>{'role': message.role, 'content': message.content},
      <String, dynamic>{'role': 'user', 'content': text},
    ];

    final completion = await api.sendMessageSession(
      messages: payload,
      model: model,
      conversationId: resolvedChatId,
      responseMessageId: assistantMessageId,
      parentId: history.isEmpty ? null : history.last.id,
      // What the server records as the user's turn. Without it an existing
      // chat gains an answer with nothing to answer.
      userMessage: <String, dynamic>{
        'id': userMessageId,
        'role': 'user',
        'content': text,
        'timestamp': userMessage.timestamp.millisecondsSinceEpoch ~/ 1000,
        'models': <String>[model],
        'childrenIds': <String>[assistantMessageId],
        if (history.isNotEmpty) 'parentId': history.last.id,
      },
      toolIds: request.toolIds.isEmpty ? null : request.toolIds,
      enableWebSearch: request.webSearch,
      enableImageGeneration: request.imageGeneration,
      enableCodeInterpreter: request.codeInterpreter,
    );

    final turn = _ActiveTurn(
      chatId: resolvedChatId,
      messageId: completion.messageId,
      model: model,
    );
    _active[resolvedChatId] = turn;

    _events.publish(
      ConduitEvents.turnStarted,
      scope: resolvedChatId,
      payload: TurnStarted(
        chatId: resolvedChatId,
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
      activeConversationId: resolvedChatId,
      api: api,
      socketService: _container.read(socketServiceProvider),
      workerManager: _container.read(workerManagerProvider),
      appendToLastMessage: turn.append,
      bufferLastMessageContent: turn.buffer,
      replaceLastMessageContent: turn.replace,
      updateLastMessageWith: turn.updateLast,
      appendStatusUpdate: (_, _) {},
      upsertCodeExecution: (_, _) {},
      appendSourceReference: (_, _) {},
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
      finishStreaming: () => _finish(resolvedChatId),
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

    return SendTurnAccepted(
      chatId: resolvedChatId,
      userMessageId: userMessageId,
      assistantMessageId: completion.messageId,
    );
  }

  /// Stops generation, keeping what has arrived.
  ///
  /// Not an error when nothing is running: a stop button pressed as the last
  /// token lands is the common case, not a mistake.
  Future<void> stop(String chatId) async {
    final turn = _active[chatId];
    if (turn == null) return;
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

  Future<void> dispose() async {
    for (final chatId in _active.keys.toList()) {
      await stop(chatId);
    }
  }

  /// The model to send with.
  ///
  /// The request wins when it names one, so WP-3.4's picker will simply pass
  /// a value. Otherwise the account's current selection, and failing that the
  /// first model the server offers -- which is what a fresh install has
  /// before anything has been chosen.
  String? _resolveModel(String? requested) {
    final trimmed = requested?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;

    final selected = _container.read(selectedModelProvider);
    if (selected != null) return selected.id;

    final available = _container.read(modelsProvider).value;
    return (available == null || available.isEmpty) ? null : available.first.id;
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

  Future<List<ChatMessage>> _historyFor(String chatId) async {
    final conversations = await _container.read(conversationsProvider.future);
    return conversations
            .where((conversation) => conversation.id == chatId)
            .firstOrNull
            ?.messages ??
        const <ChatMessage>[];
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
          // The server's own words. Section 4 says errors cross as codes, and
          // they do -- but a refusal like "this model needs a paid plan" is
          // information only the server has, and dropping it would leave the
          // user with `server.error` and no way to act.
          args: <String, String>{'detail': failure},
          partialText: turn.text,
        ).toJson(),
      );
    } else {
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
    _events.publish(ConduitEvents.chatsChanged, scope: chatId);
  }
}

/// One in-flight answer.
class _ActiveTurn {
  _ActiveTurn({
    required this.chatId,
    required this.messageId,
    required this.model,
  });

  final String chatId;
  final String messageId;
  final String model;

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
