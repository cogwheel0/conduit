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
  final Map<String, String> _aliases = <String, String>{};
  final Map<String, String> _bridgedSources = <String, String>{};

  /// Redirects future waiters for [fromId] to [toId]. If a waiter was already
  /// queued behind [fromId], it re-checks the alias after reaching the head of
  /// that queue and reroutes before running [action].
  void remapKeyInPlace({required String fromId, required String toId}) {
    final sourceKey = _canonicalKey(fromId);
    final targetKey = _canonicalKey(toId);
    if (sourceKey == targetKey) return;

    final sourceTail = _tails[sourceKey];
    final targetTail = _tails[targetKey];
    _aliases[sourceKey] = targetKey;

    if (sourceTail == null) return;
    _bridgedSources[sourceKey] = targetKey;
    final bridge = targetTail == null
        ? sourceTail
        : Future.wait<void>([targetTail, sourceTail]).then((_) {});
    _tails[targetKey] = bridge;
    unawaited(
      bridge.whenComplete(() {
        if (identical(_tails[targetKey], bridge)) {
          _tails.remove(targetKey);
        }
        if (_bridgedSources[sourceKey] == targetKey) {
          _bridgedSources.remove(sourceKey);
        }
      }),
    );
  }

  /// Runs [action] while holding the exclusive lock for [chatId].
  Future<T> runExclusive<T>(String chatId, Future<T> Function() action) {
    return _runExclusive(chatId, _canonicalKey(chatId), action);
  }

  Future<T> _runExclusive<T>(
    String requestedId,
    String lockId,
    Future<T> Function() action,
  ) {
    final previous = _tails[lockId];
    if (previous != null) {
      DebugLogger.log(
        'contended',
        scope: 'sync/locks',
        data: {'chatId': lockId},
      );
    }
    final release = Completer<void>();
    final tail = release.future;
    _tails[lockId] = tail;

    void finish() {
      if (!release.isCompleted) {
        release.complete();
      }
      if (identical(_tails[lockId], tail)) {
        _tails.remove(lockId);
      }
    }

    Future<T> run() async {
      if (previous != null) {
        await previous;
      }
      final latestLockId = _canonicalKey(requestedId);
      if (latestLockId != lockId && _bridgedSources[lockId] != latestLockId) {
        finish();
        return _runExclusive(requestedId, latestLockId, action);
      }
      try {
        return await action();
      } finally {
        // Errors propagate through the returned future only; the tail
        // completes normally so queued waiters never see them.
        finish();
      }
    }

    return run();
  }

  String _canonicalKey(String id) {
    var current = id;
    final seen = <String>{};
    while (seen.add(current)) {
      final next = _aliases[current];
      if (next == null || next == current) return current;
      current = next;
    }
    return current;
  }

  /// Whether no lock is currently held or queued (for tests).
  bool get isIdle => _tails.isEmpty;
}

/// Lock domain for chat/conversation rows.
///
/// Kept as a distinct type from [FolderLocks] and [NoteLocks] so constructor
/// injection catches accidental cross-domain wiring at compile time.
class ConversationLocks extends ChatLocks {}

/// Lock domain for folder rows.
class FolderLocks extends ChatLocks {}

/// Lock domain for note rows.
class NoteLocks extends ChatLocks {}

/// Fresh instance per database identity so locks never leak across servers.
@Riverpod(keepAlive: true)
ConversationLocks chatLocks(Ref ref) {
  ref.watch(appDatabaseProvider);
  return ConversationLocks();
}

/// Folder ops own a SEPARATE lock domain from chats (`OutboxDao.isFolderKind`):
/// [PushSync]/[OutboxDrainer] take this as their `folderLocks`. A distinct
/// instance from [chatLocksProvider] so a folder op never contends a chat op
/// (and vice versa). Also recreated per database identity.
@Riverpod(keepAlive: true)
FolderLocks folderLocks(Ref ref) {
  ref.watch(appDatabaseProvider);
  return FolderLocks();
}

/// Note ops own a SEPARATE lock domain from chats and folders
/// (`OutboxDao.isNoteKind`): the Phase 5 notes write path + push take this as
/// their `noteLocks`. A distinct [ChatLocks] instance so a note op never
/// contends a chat/folder op (and vice versa). Recreated per database identity
/// so locks never leak across servers. The per-key id is the NOTE id.
@Riverpod(keepAlive: true)
NoteLocks noteLocks(Ref ref) {
  ref.watch(appDatabaseProvider);
  return NoteLocks();
}
