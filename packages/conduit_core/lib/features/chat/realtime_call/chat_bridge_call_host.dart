import 'dart:async';

import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart'
    show kHermesApprovalMeta, kHermesDecisionMeta, kHermesTransport;
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/message_voice.dart';
import 'package:conduit_core/models/openwebui_chat_prompt.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/clock.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/voice/voice_session.dart';

import 'bridge_call_host.dart';

/// The chat a bridge call talks in: the one open when the call started, or
/// the one its first send creates.
///
/// A delegated request is sent like a typed message, through the chat's own
/// send, so it uses the selected model, its tools and history, and the
/// chat's storage. A reply the voice gives itself is stored the same way,
/// already answered. Nothing the call says is written to another chat.
final class ChatBridgeCallHost implements BridgeCallHost {
  ChatBridgeCallHost(
    this._ref, {
    required void Function(ChatVoiceModeNotice) onNotice,
  }) : _onNotice = onNotice,
       _chat = _ref.read(activeConversationProvider);

  final Ref _ref;
  final void Function(ChatVoiceModeNotice) _onNotice;
  Conversation? _chat;
  var _creatingChat = 0;
  final _turns = <_ChatTurn>{};

  /// The call's chat by its latest id, or null before its first send.
  String? get chatId => _chat?.id;

  /// Whether a send of the call's is creating the call's chat right now.
  bool get creatingChat => _creatingChat > 0;

  /// Follows the call's chat to [chat]: the one its send created, or the
  /// same chat under its server id.
  void followChat(Conversation? chat) => _chat = chat;

  /// Stops following the delegated turns still running; the chat goes on
  /// answering them.
  void close() {
    for (final turn in List.of(_turns)) {
      turn.close();
    }
  }

  /// Whether a send reaches the call's chat: the chat send writes to the
  /// open one.
  bool get _inCallChat =>
      _ref.mounted && _ref.read(activeConversationProvider)?.id == _chat?.id;

  /// Runs [send], marking it as the one creating the call's chat when the
  /// call has none yet.
  Future<T> _send<T>(Future<T> Function() send) async {
    final creates = _chat == null;
    if (creates) _creatingChat++;
    try {
      return await send();
    } finally {
      if (creates) _creatingChat--;
    }
  }

  @override
  List<Map<String, String>> chatSnapshot() =>
      realtimeChatSnapshot(_ref.read(chatMessagesProvider));

  @override
  Future<void> recordExchange(RealtimeVoiceExchange exchange) async {
    if (!_inCallChat) throw StateError("The call's chat is not open.");
    await _send(
      () => durableSend(
        _ref,
        exchange.userText,
        null,
        contextAttachments: const [],
        voice: ChatSendVoiceContext.answered(
          userVoice: exchange.userVoice,
          reply: ChatVoiceReply(
            text: exchange.replyText,
            model: exchange.voiceModel,
            voice: exchange.replyVoice,
          ),
        ),
      ),
    );
  }

  @override
  Future<DelegatedTurn> delegate(
    String text, {
    required Map<String, Object?> userVoice,
    String? spokenContext,
  }) async {
    if (!_inCallChat) throw StateError("The call's chat is not open.");
    // A turn the call did not start is still answering; this one waits.
    if (_ref.read(isChatStreamingProvider)) return const _DeferredTurn();
    final placed = Completer<String>();
    _ChatTurn? turn;
    var sendFailed = false;
    final sending = durableSend(
      _ref,
      text,
      null,
      toolIds: _ref.read(selectedToolIdsProvider),
      contextAttachments: const [],
      voice: ChatSendVoiceContext.delegated(
        userVoice: userVoice,
        spokenContext: spokenContext,
      ),
      onAssistantPlaceholderCreated: (handle) {
        if (!placed.isCompleted) placed.complete(handle.assistantMessageId);
      },
    );
    unawaited(
      sending.then(
        (_) {
          if (!placed.isCompleted) {
            placed.completeError(StateError('The chat took no turn.'));
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!placed.isCompleted) {
            return placed.completeError(error, stackTrace);
          }
          // The answer was placed but its send failed: it will not finish.
          sendFailed = true;
          turn?.sendFailed();
        },
      ),
    );
    final assistantMessageId = await _send(() => placed.future);
    final chatTurn = turn = _ChatTurn(
      _ref,
      assistantMessageId,
      onClosed: _turns.remove,
    );
    _turns.add(chatTurn);
    if (sendFailed) chatTurn.sendFailed();
    return chatTurn;
  }

  @override
  Future<void> mergeSpeech(
    String assistantMessageId,
    Map<String, Object?> voice,
  ) async {
    // The answer is in the call's chat, open or not.
    final chat = _chat;
    if (chat == null || !_ref.mounted) return;
    if (_ref.read(activeConversationProvider)?.id == chat.id) {
      _ref
          .read(chatMessagesProvider.notifier)
          .updateMessageById(
            assistantMessageId,
            (message) => message.copyWith(
              metadata: {...?message.metadata, kMessageVoiceMetadataKey: voice},
            ),
          );
    }
    final ChatDatabaseRepository repository = _ref.read(
      chatDatabaseRepositoryProvider,
    );
    final location = await repository.resolveChat(
      chat.id,
      preferred: chatStorageKindOf(chat),
    );
    if (location == null || !_ref.mounted) return;
    final syncs = location.storage == ChatStorageKind.openWebUi;
    var written = false;
    await _ref.read(chatLocksProvider).runExclusive(chat.id, () async {
      written = await location.database.chatsDao.patchMessageVoice(
        chat.id,
        assistantMessageId,
        voice: voice,
        updatedAt: _ref.read(syncClockProvider).nowEpochSeconds(),
        enqueueUpdate: syncs,
      );
    });
    if (!written || !syncs || !_ref.mounted) return;
    try {
      await _ref
          .read(syncEngineProvider.notifier)
          .drainNowForDatabase(location.database);
    } catch (error) {
      // The update is queued; a later drain pushes it.
      DebugLogger.warning(
        'voice-merge-drain-failed',
        scope: 'realtime/host',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }

  @override
  void notice(ChatVoiceModeNotice notice) => _onNotice(notice);
}

/// The chat as a realtime voice reads it: the user's words, and each answer
/// labeled with its state, so the voice can tell finished work from work it
/// only said was coming. What was spoken is marked as past speech.
List<Map<String, String>> realtimeChatSnapshot(List<ChatMessage> messages) {
  final snapshot = <Map<String, String>>[];
  for (final message in messages) {
    if (message.metadata?['archivedVariant'] == true) continue;
    if (message.role == 'user') {
      if (message.content.trim().isNotEmpty) {
        snapshot.add({'role': 'user', 'content': message.content});
      }
      continue;
    }
    if (message.role != 'assistant') continue;
    final replay = voiceReplayFor(message);
    if (replay.spokenOnly) {
      if (replay.speech.isNotEmpty) {
        snapshot.add({
          'role': 'assistant',
          'content': replay.speech.join('\n'),
        });
      }
      continue;
    }
    final state = _answerState(message);
    final answer = state == DelegatedTurnState.completed
        ? _answerText(message)
        : '';
    snapshot.add({
      'role': 'assistant',
      'content': [
        '[Chat model answer; message ${message.id}; ${state.name}]',
        if (answer.isNotEmpty) answer,
        ...replay.speech,
      ].join('\n'),
    });
  }
  return snapshot;
}

DelegatedTurnState _answerState(ChatMessage message) {
  if (message.error != null) return DelegatedTurnState.failed;
  if (findPendingOpenWebUiToolPrompt([message]) != null ||
      _hermesAwaitsUser(message)) {
    return DelegatedTurnState.approval;
  }
  return assistantMessageResponseCompleted(message)
      ? DelegatedTurnState.completed
      : DelegatedTurnState.working;
}

/// Whether a Hermes answer waits for the user: an approval, or a question it
/// asked, both answered in the chat.
bool _hermesAwaitsUser(ChatMessage message) {
  final metadata = message.metadata;
  if (metadata?['transport'] != kHermesTransport) return false;
  final approval = metadata?[kHermesApprovalMeta];
  if (approval is Map &&
      (approval['state'] == null ||
          approval['state'] == 'pending' ||
          approval['state'] == 'resolving')) {
    return true;
  }
  final decision = metadata?[kHermesDecisionMeta];
  return decision is Map && decision['state'] == 'pending';
}

/// The chat as a GPT-Live voice starts with: the newest messages as plain
/// text, within the bounds Hermes's own client keeps (24 messages, 1200
/// characters each, 6000 in all).
List<Map<String, Object?>> gptLiveHistory(List<ChatMessage> messages) {
  const maxMessages = 24;
  const maxMessageCharacters = 1200;
  var budget = 6000;
  final history = <Map<String, Object?>>[];
  for (final message in messages.reversed) {
    if (history.length >= maxMessages || budget <= 0) break;
    if (message.metadata?['archivedVariant'] == true) continue;
    final user = message.role == 'user';
    if (!user && message.role != 'assistant') continue;
    if (!user && !assistantMessageResponseCompleted(message)) continue;
    var text = user ? message.content.trim() : _answerText(message);
    if (text.isEmpty) continue;
    final limit = budget < maxMessageCharacters ? budget : maxMessageCharacters;
    if (text.length > limit) text = text.substring(0, limit);
    budget -= text.length;
    history.insert(0, {
      'type': 'message',
      'role': message.role,
      'content': [
        {'type': user ? 'input_text' : 'output_text', 'text': text},
      ],
    });
  }
  return history;
}

/// The answer as the voice should read it: the reply without its reasoning
/// and tool blocks.
String _answerText(ChatMessage message) =>
    ConduitMarkdownPreprocessor.removeAllDetails(message.content).trim();

/// A delegated turn running in the chat, followed through its answer.
final class _ChatTurn implements DelegatedTurn {
  _ChatTurn(
    this._ref,
    this.assistantMessageId, {
    required void Function(_ChatTurn) onClosed,
  }) : _onClosed = onClosed {
    _subscription = _ref.listen<List<ChatMessage>>(
      chatMessagesProvider,
      (_, messages) => _follow(messages),
    );
    _follow(_ref.read(chatMessagesProvider));
  }

  final Ref _ref;
  final void Function(_ChatTurn) _onClosed;
  late final ProviderSubscription<List<ChatMessage>> _subscription;
  final _changes = StreamController<DelegatedTurnState>.broadcast();
  var _cancelled = false;
  var _sendFailed = false;

  @override
  final String assistantMessageId;

  @override
  var state = DelegatedTurnState.working;

  @override
  var answer = '';

  void _follow(List<ChatMessage> messages) {
    if (_changes.isClosed) return;
    final message = messages
        .where((message) => message.id == assistantMessageId)
        .firstOrNull;
    var next = _cancelled
        ? DelegatedTurnState.cancelled
        : message == null
        ? DelegatedTurnState.working
        : _answerState(message);
    if (_sendFailed &&
        (next == DelegatedTurnState.working ||
            next == DelegatedTurnState.approval)) {
      next = DelegatedTurnState.failed;
    }
    if (next == DelegatedTurnState.completed && message != null) {
      answer = _answerText(message);
    }
    if (next == state) return;
    state = next;
    _changes.add(next);
    if (next == DelegatedTurnState.completed ||
        next == DelegatedTurnState.failed ||
        next == DelegatedTurnState.cancelled) {
      close();
    }
  }

  /// The send behind this answer failed after placing it.
  void sendFailed() {
    if (_changes.isClosed) return;
    _sendFailed = true;
    _follow(_ref.read(chatMessagesProvider));
  }

  /// Stops following the answer; the chat goes on with it.
  void close() {
    if (_changes.isClosed) return;
    _subscription.close();
    unawaited(_changes.close());
    _onClosed(this);
  }

  @override
  Stream<DelegatedTurnState> get changes => _changes.stream;

  @override
  Future<void> cancel() async {
    if (_changes.isClosed || !_ref.mounted) return;
    _cancelled = true;
    // The answer is the chat's last; stopping the chat stops it.
    _ref.read(stopGenerationProvider)();
    _follow(_ref.read(chatMessagesProvider));
  }
}

/// A request the chat could not take now; nothing was sent.
final class _DeferredTurn implements DelegatedTurn {
  const _DeferredTurn();

  @override
  String? get assistantMessageId => null;

  @override
  DelegatedTurnState get state => DelegatedTurnState.deferred;

  @override
  Stream<DelegatedTurnState> get changes => const Stream.empty();

  @override
  String get answer => '';

  @override
  Future<void> cancel() async {}
}
