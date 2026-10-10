import 'dart:async';

import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/message_voice.dart';
import 'package:conduit_core/models/openwebui_chat_prompt.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/clock.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/voice/voice_session.dart';

import 'bridge_call_host.dart';

/// The chat a bridge call talks in: the one open when the call started.
///
/// A delegated request is sent like a typed message, through the chat's own
/// send, so it uses the selected model, its tools and history, and the
/// chat's storage. A reply the voice gives itself is stored the same way,
/// already answered.
final class ChatBridgeCallHost implements BridgeCallHost {
  ChatBridgeCallHost(
    this._ref, {
    required void Function(ChatVoiceModeNotice) onNotice,
  }) : _onNotice = onNotice;

  final Ref _ref;
  final void Function(ChatVoiceModeNotice) _onNotice;

  @override
  List<Map<String, String>> chatSnapshot() =>
      realtimeChatSnapshot(_ref.read(chatMessagesProvider));

  @override
  Future<void> recordExchange(RealtimeVoiceExchange exchange) => durableSend(
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
  );

  @override
  Future<DelegatedTurn> delegate(
    String text, {
    required Map<String, Object?> userVoice,
  }) async {
    // A turn the call did not start is still answering; this one waits.
    if (_ref.read(isChatStreamingProvider)) return const _DeferredTurn();
    final placed = Completer<String>();
    final sending = durableSend(
      _ref,
      text,
      null,
      toolIds: _ref.read(selectedToolIdsProvider),
      contextAttachments: const [],
      voice: ChatSendVoiceContext.delegated(userVoice: userVoice),
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
          if (!placed.isCompleted) placed.completeError(error, stackTrace);
        },
      ),
    );
    final assistantMessageId = await placed.future;
    return _ChatTurn(_ref, assistantMessageId);
  }

  @override
  Future<void> mergeSpeech(
    String assistantMessageId,
    Map<String, Object?> voice,
  ) async {
    final messages = _ref.read(chatMessagesProvider.notifier);
    messages.updateMessageById(
      assistantMessageId,
      (message) => message.copyWith(
        metadata: {...?message.metadata, kMessageVoiceMetadataKey: voice},
      ),
    );
    final active = _ref.read(activeConversationProvider);
    if (active == null) return;
    final ChatDatabaseRepository repository = _ref.read(
      chatDatabaseRepositoryProvider,
    );
    final location = await repository.resolveChat(
      active.id,
      preferred: chatStorageKindOf(active),
    );
    if (location == null) return;
    final syncs = location.storage == ChatStorageKind.openWebUi;
    var written = false;
    await _ref.read(chatLocksProvider).runExclusive(active.id, () async {
      written = await location.database.chatsDao.patchMessageVoice(
        active.id,
        assistantMessageId,
        voice: voice,
        updatedAt: _ref.read(syncClockProvider).nowEpochSeconds(),
        enqueueUpdate: syncs,
      );
    });
    if (!written || !syncs) return;
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
  if (findPendingOpenWebUiToolPrompt([message]) != null) {
    return DelegatedTurnState.approval;
  }
  return assistantMessageResponseCompleted(message)
      ? DelegatedTurnState.completed
      : DelegatedTurnState.working;
}

/// The answer as the voice should read it: the reply without its reasoning
/// and tool blocks.
String _answerText(ChatMessage message) =>
    ConduitMarkdownPreprocessor.removeAllDetails(message.content).trim();

/// A delegated turn running in the chat, followed through its answer.
final class _ChatTurn implements DelegatedTurn {
  _ChatTurn(this._ref, this.assistantMessageId) {
    _subscription = _ref.listen<List<ChatMessage>>(
      chatMessagesProvider,
      (_, messages) => _follow(messages),
    );
    _follow(_ref.read(chatMessagesProvider));
  }

  final Ref _ref;
  late final ProviderSubscription<List<ChatMessage>> _subscription;
  final _changes = StreamController<DelegatedTurnState>.broadcast();
  var _cancelled = false;

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
    final next = _cancelled
        ? DelegatedTurnState.cancelled
        : message == null
        ? DelegatedTurnState.working
        : _answerState(message);
    if (next == DelegatedTurnState.completed && message != null) {
      answer = _answerText(message);
    }
    if (next == state) return;
    state = next;
    _changes.add(next);
    if (next == DelegatedTurnState.completed ||
        next == DelegatedTurnState.failed ||
        next == DelegatedTurnState.cancelled) {
      _subscription.close();
      unawaited(_changes.close());
    }
  }

  @override
  Stream<DelegatedTurnState> get changes => _changes.stream;

  @override
  Future<void> cancel() async {
    if (_changes.isClosed) return;
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
