import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/chat_database_repository.dart';
import '../../../core/database/daos/outbox_dao.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/connectivity_service.dart';
import '../../../core/sync/clock.dart';
import '../../../core/sync/sync_engine.dart';
import '../../../core/utils/debug_logger.dart';
import '../../hermes/services/hermes_session_provenance.dart';
import 'chat_providers.dart'
    show chatMessagesProvider, conversationUsesOpenWebUiStorage;

enum QueuedCompletionPhase { pending, failed }

/// A pending completion is only surfaced as "queued" once it has failed at least
/// this many attempts (i.e. a retry is genuinely pending), so a single transient
/// first-attempt failure — e.g. a cold network/socket connection on the first
/// message of a session — auto-retries invisibly instead of flashing the banner.
const int _queuedCompletionStallAttempts = 2;

class QueuedCompletionInfo {
  const QueuedCompletionInfo({
    required this.seq,
    required this.chatId,
    required this.scopedChatId,
    required this.assistantMessageId,
    required this.phase,
    required this.isOffline,
    this.lastError,
    this.nextAttemptAt,
  });

  final int seq;
  final String chatId;
  final String scopedChatId;
  final String assistantMessageId;
  final QueuedCompletionPhase phase;
  final bool isOffline;
  final String? lastError;
  final int? nextAttemptAt;

  bool get isFailed => phase == QueuedCompletionPhase.failed;
}

final queuedCompletionInfoForMessageProvider = StreamProvider.autoDispose
    .family<QueuedCompletionInfo?, String>((ref, assistantMessageId) {
      final id = assistantMessageId.trim();
      if (id.isEmpty) {
        return Stream<QueuedCompletionInfo?>.value(null);
      }

      final activeTarget = ref.watch(
        activeConversationProvider.select(
          (conversation) => (
            chatId: conversation?.id,
            isOpenWebUi: conversationUsesOpenWebUiStorage(conversation),
          ),
        ),
      );
      final db = ref.watch(appDatabaseProvider);
      final isOnline = ref.watch(isOnlineProvider);
      if (db == null ||
          !activeTarget.isOpenWebUi ||
          (activeTarget.chatId?.isEmpty ?? true)) {
        return Stream<QueuedCompletionInfo?>.value(null);
      }
      final chatId = activeTarget.chatId!;
      final scopedChatId = ChatStorageIdentity(
        rawId: chatId,
        storage: ChatStorageKind.openWebUi,
      ).scopedId;

      return db.outboxDao.watchQueuedCompletionsForChat(chatId).map((ops) {
        for (final op in ops) {
          if (_assistantMessageIdFromPayload(op.payload) != id) {
            continue;
          }

          final phase = op.status == OutboxStatus.failed
              ? QueuedCompletionPhase.failed
              : QueuedCompletionPhase.pending;
          final offline = op.lastError == 'offline' || !isOnline;

          // Only surface a PENDING completion when it genuinely needs the user's
          // attention — never for a transient auto-retry. A normal send (and
          // especially the FIRST send of a session, which can race a cold
          // network/socket connection) often fails once and is retried with a
          // ~1s backoff; showing the retry/cancel banner for that single attempt
          // makes it flash on screen. Surface a pending op only when:
          //   • it is offline-deferred (queued until connectivity returns), or
          //   • it has stalled across multiple attempts (the drainer has retried
          //     it `>= _queuedCompletionStallAttempts` times without success).
          // A `failed` (parked) op always surfaces for manual retry. This is
          // independent of `isOnline`, which can be transiently not-online while
          // connectivity is still resolving at startup.
          if (phase == QueuedCompletionPhase.pending) {
            final offlineDeferred = op.lastError == 'offline';
            final stalled = op.attempts >= _queuedCompletionStallAttempts;
            if (!offlineDeferred && !stalled) {
              continue;
            }
          }

          return QueuedCompletionInfo(
            seq: op.seq,
            chatId: chatId,
            scopedChatId: scopedChatId,
            assistantMessageId: id,
            phase: phase,
            isOffline: offline,
            lastError: op.lastError,
            nextAttemptAt: op.nextAttemptAt,
          );
        }
        return null;
      });
    });

final queuedCompletionActionsProvider = Provider<QueuedCompletionActions>(
  QueuedCompletionActions.new,
);

class QueuedCompletionActions {
  QueuedCompletionActions(this._ref);

  final Ref _ref;

  Future<void> retry(QueuedCompletionInfo info) async {
    final db = _ref.read(appDatabaseProvider);
    if (db == null) return;

    final now = _ref.read(syncClockProvider).nowEpochSeconds();
    if (info.phase == QueuedCompletionPhase.failed) {
      await db.outboxDao.requeueParked(info.seq, nowEpochSeconds: now);
    } else {
      await db.outboxDao.retryPendingNow(info.seq, nowEpochSeconds: now);
    }
    await _ref.read(syncEngineProvider.notifier).drainNow();
  }

  Future<int> cancel(QueuedCompletionInfo info) async {
    final db = _ref.read(appDatabaseProvider);
    if (db == null) return 0;

    final removed = await db.chatsDao.cancelQueuedCompletion(
      info.chatId,
      assistantMessageId: info.assistantMessageId,
    );
    if (removed == 0) return 0;

    final active = _ref.read(activeConversationProvider);
    if (active != null &&
        conversationUsesOpenWebUiStorage(active) &&
        conversationMatchesScopedId(active, info.scopedChatId)) {
      final messages = _ref.read(chatMessagesProvider);
      final updatedMessages = messages
          .where((message) => message.id != info.assistantMessageId)
          .toList(growable: false);
      if (updatedMessages.length != messages.length) {
        _ref.read(chatMessagesProvider.notifier).setMessages(updatedMessages);
      }

      final updatedActive = inheritNativeHermesConversationProvenance(
        active,
        active.copyWith(messages: updatedMessages, updatedAt: DateTime.now()),
      );
      _ref.read(activeConversationProvider.notifier).set(updatedActive);
      _ref
          .read(conversationsProvider.notifier)
          .updateConversation(info.scopedChatId, (_) => updatedActive);
    }

    DebugLogger.log(
      'cancelled',
      scope: 'chat/queued-completion',
      data: {
        'chatId': info.chatId,
        'assistantMessageId': info.assistantMessageId,
      },
    );
    return removed;
  }
}

String? _assistantMessageIdFromPayload(String rawPayload) {
  try {
    final decoded = jsonDecode(rawPayload);
    if (decoded is Map && decoded['assistantMessageId'] is String) {
      final id = decoded['assistantMessageId'] as String;
      return id.isEmpty ? null : id;
    }
  } catch (_) {}
  return null;
}
