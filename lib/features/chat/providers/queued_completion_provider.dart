import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/daos/outbox_dao.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/connectivity_service.dart';
import '../../../core/sync/clock.dart';
import '../../../core/sync/sync_engine.dart';
import '../../../core/utils/debug_logger.dart';
import 'chat_providers.dart' show chatMessagesProvider;

enum QueuedCompletionPhase { pending, failed }

class QueuedCompletionInfo {
  const QueuedCompletionInfo({
    required this.seq,
    required this.chatId,
    required this.assistantMessageId,
    required this.phase,
    required this.isOffline,
    this.lastError,
    this.nextAttemptAt,
  });

  final int seq;
  final String chatId;
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

      final chatId = ref.watch(
        activeConversationProvider.select((conversation) => conversation?.id),
      );
      final db = ref.watch(appDatabaseProvider);
      final isOnline = ref.watch(isOnlineProvider);
      if (db == null || chatId == null || chatId.isEmpty) {
        return Stream<QueuedCompletionInfo?>.value(null);
      }

      return db.outboxDao.watchQueuedCompletionsForChat(chatId).map((ops) {
        for (final op in ops) {
          if (_assistantMessageIdFromPayload(op.payload) != id) {
            continue;
          }

          final phase = op.status == OutboxStatus.failed
              ? QueuedCompletionPhase.failed
              : QueuedCompletionPhase.pending;
          final offline = op.lastError == 'offline' || !isOnline;

          // A fresh, never-attempted op is "sending", not "queued" — hide its
          // transient state so the retry/cancel banner doesn't flash on a normal
          // (especially first) send before the drainer claims it. This must NOT
          // depend on `isOnline`: at app/first-send time connectivity may still
          // be resolving (reported as not-online), which previously surfaced the
          // banner on the first prompt of a new chat. Once the op is genuinely
          // offline-deferred (`lastError == 'offline'`), backoff-scheduled
          // (`nextAttemptAt`), or failed, it falls through and the banner shows.
          if (phase == QueuedCompletionPhase.pending &&
              op.lastError == null &&
              op.nextAttemptAt == null) {
            continue;
          }

          return QueuedCompletionInfo(
            seq: op.seq,
            chatId: chatId,
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
    if (active?.id == info.chatId) {
      final messages = _ref.read(chatMessagesProvider);
      final updatedMessages = messages
          .where((message) => message.id != info.assistantMessageId)
          .toList(growable: false);
      if (updatedMessages.length != messages.length) {
        _ref.read(chatMessagesProvider.notifier).setMessages(updatedMessages);
      }

      final updatedActive = active!.copyWith(
        messages: updatedMessages,
        updatedAt: DateTime.now(),
      );
      _ref.read(activeConversationProvider.notifier).set(updatedActive);
      _ref
          .read(conversationsProvider.notifier)
          .updateConversation(info.chatId, (_) => updatedActive);
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
