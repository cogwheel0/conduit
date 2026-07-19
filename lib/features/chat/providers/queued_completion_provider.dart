import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/database/chat_database_repository.dart';
import '../../../core/database/app_database.dart';
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

part 'queued_completion_provider.g.dart';

enum QueuedCompletionPhase { pending, failed }

/// A pending completion is only surfaced as "queued" once it has failed at least
/// this many attempts (i.e. a retry is genuinely pending), so a single transient
/// first-attempt failure — e.g. a cold network/socket connection on the first
/// message of a session — auto-retries invisibly instead of flashing the banner.
const int _queuedCompletionStallAttempts = 2;

/// Test seam at the final account/session admission point for queue writes.
/// Production resolves an already-completed future.
final queuedCompletionMutationAdmissionProvider =
    Provider<Future<void> Function()>(
      (_) =>
          () => Future<void>.value(),
    );

final class _QueuedCompletionSessionRetired implements Exception {
  const _QueuedCompletionSessionRetired();
}

class QueuedCompletionInfo {
  const QueuedCompletionInfo({
    required Object databaseOwner,
    required this.seq,
    required this.chatId,
    required this.scopedChatId,
    required this.assistantMessageId,
    required this.phase,
    required this.isOffline,
    this.lastError,
    this.nextAttemptAt,
  }) : _databaseOwner = databaseOwner,
       _ownership = null;

  QueuedCompletionInfo._owned({
    required _QueuedCompletionOwnership ownership,
    required this.seq,
    required this.chatId,
    required this.scopedChatId,
    required this.assistantMessageId,
    required this.phase,
    required this.isOffline,
    this.lastError,
    this.nextAttemptAt,
  }) : _databaseOwner = ownership.session.database!,
       _ownership = ownership;

  final Object _databaseOwner;
  final _QueuedCompletionOwnership? _ownership;
  final int seq;
  final String chatId;
  final String scopedChatId;
  final String assistantMessageId;
  final QueuedCompletionPhase phase;
  final bool isOffline;
  final String? lastError;
  final int? nextAttemptAt;

  bool get isFailed => phase == QueuedCompletionPhase.failed;

  bool _isCurrent(dynamic ref) {
    final ownership = _ownership;
    return ownership != null && ownership.sessionIsCurrent(ref);
  }

  bool _ownsActiveConversation(dynamic ref) {
    final ownership = _ownership;
    return ownership != null && ownership.activeConversationIsCurrent(ref);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is QueuedCompletionInfo &&
          identical(_databaseOwner, other._databaseOwner) &&
          identical(_ownership, other._ownership) &&
          seq == other.seq &&
          chatId == other.chatId &&
          scopedChatId == other.scopedChatId &&
          assistantMessageId == other.assistantMessageId &&
          phase == other.phase &&
          isOffline == other.isOffline &&
          lastError == other.lastError &&
          nextAttemptAt == other.nextAttemptAt;

  @override
  int get hashCode => Object.hash(
    identityHashCode(_databaseOwner),
    identityHashCode(_ownership),
    seq,
    chatId,
    scopedChatId,
    assistantMessageId,
    phase,
    isOffline,
    lastError,
    nextAttemptAt,
  );
}

/// One synchronous snapshot of the database/account session and the active
/// OpenWebUI conversation that surfaced a queued-completion row.
final class _QueuedCompletionOwnership {
  const _QueuedCompletionOwnership({
    required this.session,
    required this.scopedChatId,
  });

  final OpenWebUiConversationReadSnapshot session;
  final String scopedChatId;

  bool sessionIsCurrent(dynamic ref) =>
      openWebUiConversationReadIsCurrent(ref, session);

  bool activeConversationIsCurrent(dynamic ref) {
    if (!sessionIsCurrent(ref)) return false;
    final active = ref.read(activeConversationProvider);
    return active != null &&
        conversationUsesOpenWebUiStorage(active) &&
        conversationMatchesScopedId(active, scopedChatId);
  }
}

/// Watches one optional input of the retry/cancel ownership fence.
///
/// Mirrors the tolerance of `_readOpenWebUiConversationContext`: a narrow test
/// or a teardown window can make one of these providers unreadable, and the
/// snapshot capture below stays fail-closed on its own guarded reads. When a
/// watched provider is in an error state the dependency is still registered,
/// so a later recovery rebuilds this stream.
void _watchOwnershipFenceInput(Ref ref, ProviderListenable<Object?> input) {
  try {
    ref.watch(input);
  } catch (_) {}
}

@riverpod
Stream<Map<String, QueuedCompletionInfo>> queuedCompletionInfoByMessage(
  Ref ref,
) {
  final activeTarget = ref.watch(
    activeConversationProvider.select(
      (conversation) => (
        chatId: conversation?.id,
        isOpenWebUi: conversationUsesOpenWebUiStorage(conversation),
      ),
    ),
  );
  final db = ref.watch(appDatabaseProvider);
  // The same database object may be reused across an account transition.
  // Rebuild the stream owner when that session epoch changes, even when the
  // active chat id and database identity happen to be unchanged.
  ref.watch(openWebUiAuthSessionEpochProvider);
  // The retry/cancel ownership fence (openWebUiConversationReadIsCurrent)
  // compares more than the database and auth epoch: it also requires the exact
  // ApiService instance plus the database access phase, certified database
  // server, and active server captured at snapshot time. Watch each of those
  // fence inputs too, so identity churn that leaves the auth epoch untouched
  // (for example `ref.invalidate(apiServiceProvider)` during an auth-state
  // rollback or a logout-fence toggle) rebuilds this stream with a fresh
  // snapshot instead of leaving the banner's Retry/Cancel actions permanently
  // fenced out against a stale one. The rebuild cost is one re-subscription of
  // the chat-scoped Drift outbox watcher, and these inputs only change on
  // auth/server/service transitions.
  _watchOwnershipFenceInput(ref, apiServiceProvider);
  _watchOwnershipFenceInput(ref, openWebUiDatabaseAccessProvider);
  _watchOwnershipFenceInput(ref, openWebUiCertifiedDatabaseServerProvider);
  _watchOwnershipFenceInput(ref, activeServerProvider);
  final isOnline = ref.watch(isOnlineProvider);
  if (db == null ||
      !activeTarget.isOpenWebUi ||
      (activeTarget.chatId?.isEmpty ?? true)) {
    return Stream<Map<String, QueuedCompletionInfo>>.value(
      const <String, QueuedCompletionInfo>{},
    );
  }
  final chatId = activeTarget.chatId!;
  final scopedChatId = ChatStorageIdentity(
    rawId: chatId,
    storage: ChatStorageKind.openWebUi,
  ).scopedId;
  final session = captureOpenWebUiConversationRead(ref, database: db);
  if (session == null) {
    return Stream<Map<String, QueuedCompletionInfo>>.value(
      const <String, QueuedCompletionInfo>{},
    );
  }
  final ownership = _QueuedCompletionOwnership(
    session: session,
    scopedChatId: scopedChatId,
  );

  return db.outboxDao.watchQueuedCompletionsForChat(chatId).map((ops) {
    final infos = <String, QueuedCompletionInfo>{};
    for (final op in ops) {
      final id = _assistantMessageIdFromPayload(op.payload);
      if (id == null || infos.containsKey(id)) {
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

      infos[id] = QueuedCompletionInfo._owned(
        ownership: ownership,
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
    return Map<String, QueuedCompletionInfo>.unmodifiable(infos);
  });
}

/// Per-row compatibility selector backed by one chat-scoped Drift watcher.
///
/// Keeping this as a StreamProvider family preserves the existing override
/// surface used by focused widget tests while avoiding one database watcher and
/// one JSON scan for every mounted assistant row in production.
@riverpod
Stream<QueuedCompletionInfo?> queuedCompletionInfoForMessage(
  Ref ref,
  String assistantMessageId,
) {
  final id = assistantMessageId.trim();
  if (id.isEmpty) {
    return Stream<QueuedCompletionInfo?>.value(null);
  }

  final selected = ref.watch(
    queuedCompletionInfoByMessageProvider.select(
      (asyncInfos) => asyncInfos.whenData((infos) => infos[id]),
    ),
  );
  return selected.when(
    data: (info) => Stream<QueuedCompletionInfo?>.value(info),
    error: (error, stackTrace) =>
        Stream<QueuedCompletionInfo?>.error(error, stackTrace),
    loading: () => const Stream<QueuedCompletionInfo?>.empty(),
  );
}

@Riverpod(keepAlive: true)
QueuedCompletionActions queuedCompletionActions(Ref ref) =>
    QueuedCompletionActions(ref);

class QueuedCompletionActions {
  QueuedCompletionActions(this._ref);

  final Ref _ref;

  Future<void> retry(QueuedCompletionInfo info) async {
    final db = _ref.read(appDatabaseProvider);
    if (db == null ||
        !identical(info._databaseOwner, db) ||
        !info._isCurrent(_ref)) {
      return;
    }

    final result = await _runSessionAtomicMutation<bool>(
      info: info,
      database: db,
      mutation: () async {
        final now = _ref.read(syncClockProvider).nowEpochSeconds();
        if (info.phase == QueuedCompletionPhase.failed) {
          await db.outboxDao.requeueParked(info.seq, nowEpochSeconds: now);
        } else {
          await db.outboxDao.retryPendingNow(info.seq, nowEpochSeconds: now);
        }
        return true;
      },
      afterCommit: () async {
        if (!info._isCurrent(_ref)) return;
        await _ref.read(syncEngineProvider.notifier).drainNowForDatabase(db);
      },
    );
    if (!result.committed) return;
  }

  Future<int> cancel(QueuedCompletionInfo info) async {
    final db = _ref.read(appDatabaseProvider);
    if (db == null ||
        !identical(info._databaseOwner, db) ||
        !info._isCurrent(_ref)) {
      return 0;
    }

    final result = await _runSessionAtomicMutation<int>(
      info: info,
      database: db,
      mutation: () => db.chatsDao.cancelQueuedCompletion(
        info.chatId,
        assistantMessageId: info.assistantMessageId,
      ),
    );
    if (!result.committed) return 0;
    final removed = result.value ?? 0;
    if (removed == 0) return 0;
    if (!info._isCurrent(_ref)) return removed;

    final active = _ref.read(activeConversationProvider);
    if (active != null && info._ownsActiveConversation(_ref)) {
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

  /// Holds a managed database lifetime lease and wraps the complete DAO write
  /// in an outer Drift transaction. The session is checked immediately before
  /// and after the mutation; a transition in any awaited admission/DAO window
  /// throws from inside that transaction and rolls every nested DAO write back.
  ///
  /// An auth transition that begins in the final SQLite commit window cannot
  /// close or expose this executor to another account: the manager must wait
  /// for this lease, then the account-isolation coordinator purges it before a
  /// different owner can be certified.
  Future<({bool committed, T? value})> _runSessionAtomicMutation<T>({
    required QueuedCompletionInfo info,
    required AppDatabase database,
    required Future<T> Function() mutation,
    Future<void> Function()? afterCommit,
  }) async {
    final manager = _ref.read(databaseManagerProvider);
    final managedServerId = manager.serverIdForDatabase(database);
    final lease = manager.tryAcquireLease(database);
    if (managedServerId != null && lease == null) {
      return (committed: false, value: null);
    }

    try {
      if (!info._isCurrent(_ref)) {
        return (committed: false, value: null);
      }
      try {
        final value = await database.transaction<T>(() async {
          if (!info._isCurrent(_ref)) {
            throw const _QueuedCompletionSessionRetired();
          }
          await _ref.read(queuedCompletionMutationAdmissionProvider)();
          if (!info._isCurrent(_ref)) {
            throw const _QueuedCompletionSessionRetired();
          }
          final value = await mutation();
          if (!info._isCurrent(_ref)) {
            throw const _QueuedCompletionSessionRetired();
          }
          return value;
        });
        if (info._isCurrent(_ref)) {
          await afterCommit?.call();
        }
        return (committed: true, value: value);
      } on _QueuedCompletionSessionRetired {
        return (committed: false, value: null);
      }
    } finally {
      await lease?.release();
    }
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
