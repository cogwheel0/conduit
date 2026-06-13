import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../database/database_provider.dart';
import '../utils/debug_logger.dart';

part 'chat_locks.g.dart';

/// Per-key async mutex (CDT-RFC-001 §10 REQ 3).
///
/// Every write touching one chat's rows — pull merge (`upsertServerChat`),
/// stream-completion echo, pause checkpoint, future push — must go through
/// [runExclusive] for that chat id. DAO methods assert nothing; the
/// discipline lives at call sites.
///
/// Implementation: `Map<String, Future<void>>` tail chaining — [runExclusive]
/// awaits the current tail, runs the action, replaces the tail; the map entry
/// is removed when the completed future is still the tail, so the map never
/// grows unbounded.
///
/// NOT reentrant: re-acquiring the same key inside `action` deadlocks.
/// Errors from `action` propagate to the caller but never poison the chain
/// (the internal tail always completes successfully).
class ChatLocks {
  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  /// Runs [action] while holding the exclusive lock for [chatId].
  Future<T> runExclusive<T>(String chatId, Future<T> Function() action) {
    final previous = _tails[chatId];
    if (previous != null) {
      DebugLogger.log(
        'contended',
        scope: 'sync/locks',
        data: {'chatId': chatId},
      );
    }
    final release = Completer<void>();
    final tail = release.future;
    _tails[chatId] = tail;

    Future<T> run() async {
      if (previous != null) {
        await previous;
      }
      try {
        return await action();
      } finally {
        // Errors propagate through the returned future only; the tail
        // completes normally so queued waiters never see them.
        release.complete();
        if (identical(_tails[chatId], tail)) {
          _tails.remove(chatId);
        }
      }
    }

    return run();
  }

  /// Whether no lock is currently held or queued (for tests).
  bool get isIdle => _tails.isEmpty;
}

/// Fresh instance per database identity so locks never leak across servers.
@Riverpod(keepAlive: true)
ChatLocks chatLocks(Ref ref) {
  ref.watch(appDatabaseProvider);
  return ChatLocks();
}

/// Folder ops own a SEPARATE lock domain from chats (`OutboxDao.isFolderKind`):
/// [PushSync]/[OutboxDrainer] take this as their `folderLocks`. A distinct
/// instance from [chatLocksProvider] so a folder op never contends a chat op
/// (and vice versa). Also recreated per database identity.
@Riverpod(keepAlive: true)
ChatLocks folderLocks(Ref ref) {
  ref.watch(appDatabaseProvider);
  return ChatLocks();
}
