import 'dart:async';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/chat/providers/queued_completion_provider.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';

/// Answers whose request is waiting in the outbox: sent while offline, or
/// retried after failing (the core's queued completions, as the mobile app
/// shows them on the answer with Retry and Cancel).
///
/// * [forChat] says what each answer of a chat shows, for `chats.get`.
/// * Every queued completion of the account's database is watched: when a
///   chat's change (one goes out, fails, is removed) or the connection
///   comes or goes, `chats.changed` names the chat, so a window showing it
///   fetches it again, and [onChanged] tells the turns service, which keeps
///   a chat's scope open while it has answers waiting.
final class QueuedCompletionsService {
  QueuedCompletionsService(this._container, this._events) {
    _database = _container.listen<AppDatabase?>(
      appDatabaseProvider,
      (_, next) => _watch(next),
      fireImmediately: true,
    );
    // Each queued answer says whether it waits for the connection, and a
    // request that failed before the connection went is queued only while
    // it stays down (`queuedCompletionDisplaysOf`).
    _online = _container.listen<bool>(isOnlineProvider, (previous, next) {
      if (previous != next) _show(connectionChanged: true);
    });
  }

  final ProviderContainer _container;
  final EventBus _events;

  late final ProviderSubscription<AppDatabase?> _database;
  late final ProviderSubscription<bool> _online;
  StreamSubscription<List<OutboxOp>>? _ops;

  /// The ops [_show] last showed: the live ops of every chat with a queued
  /// completion.
  List<OutboxOp> _lastOps = const <OutboxOp>[];

  /// Each chat's queued ops, as a signature of what they show.
  Map<String, String> _byChat = <String, String>{};

  /// The answers of each chat shown queued now.
  Map<String, Set<String>> _queued = <String, Set<String>>{};

  /// Answers seen queued in each chat, kept until their answer streams: a
  /// queued answer that goes out streams into the chat's open scope, and
  /// the turns service follows it as a turn of its own.
  final Map<String, Set<String>> _seen = <String, Set<String>>{};

  /// A chat's queued answers changed.
  void Function(String chatId)? onChanged;

  /// Whether [chatId] has answers waiting to go out.
  bool hasQueued(String chatId) => _byChat.containsKey(chatId);

  /// Whether [messageId]'s answer in [chatId] shows as queued now: its
  /// request waits in the outbox, and is not going out at this moment.
  bool isQueued(String chatId, String messageId) =>
      _queued[chatId]?.contains(messageId) ?? false;

  /// Whether [messageId] in [chatId] was waiting to go out, and has not
  /// been followed since ([followed]).
  bool wasQueued(String chatId, String messageId) =>
      _seen[chatId]?.contains(messageId) ?? false;

  /// [messageId]'s answer is streaming and followed as a turn.
  void followed(String chatId, String messageId) {
    final seen = _seen[chatId];
    seen?.remove(messageId);
    if (seen != null && seen.isEmpty) _seen.remove(chatId);
  }

  /// What each queued answer of [chatId] shows, by its message id.
  Future<Map<String, QueuedCompletionDto>> forChat(String chatId) async {
    final db = _container.read(appDatabaseProvider);
    if (db == null) return const <String, QueuedCompletionDto>{};
    final List<OutboxOp> ops;
    try {
      ops = await db.outboxDao
          .watchChatQueuesWithCompletions(chatId: chatId)
          .first;
    } on Object catch (error, stackTrace) {
      DebugLogger.error(
        'queued-completions-read-failed',
        scope: 'daemon/queued',
        error: error,
        stackTrace: stackTrace,
      );
      return const <String, QueuedCompletionDto>{};
    }
    final online = _container.read(isOnlineProvider);
    return <String, QueuedCompletionDto>{
      for (final MapEntry(:key, :value) in queuedCompletionDisplaysOf(
        ops,
        isOnline: online,
      ).entries)
        key: queuedCompletionDto(value),
    };
  }

  void _watch(AppDatabase? db) {
    unawaited(_ops?.cancel());
    _ops = null;
    final before = _byChat.keys.toList();
    _byChat = <String, String>{};
    _queued = <String, Set<String>>{};
    _lastOps = const <OutboxOp>[];
    _seen.clear();
    for (final chatId in before) {
      _announce(chatId);
    }
    if (db == null) return;
    _ops = db.outboxDao.watchChatQueuesWithCompletions().listen(
      (ops) {
        _lastOps = ops;
        _show();
      },
      onError: (Object error, StackTrace stackTrace) => DebugLogger.error(
        'queued-completions-watch-failed',
        scope: 'daemon/queued',
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }

  /// Works out which answers show queued now, and names every chat whose
  /// queued answers changed (all of them when the connection did).
  void _show({bool connectionChanged = false}) {
    final online = _container.read(isOnlineProvider);
    final next = <String, StringBuffer>{};
    final byChat = <String, List<OutboxOp>>{};
    for (final op in _lastOps) {
      final chatId = op.chatId;
      if (chatId == null || chatId.isEmpty) continue;
      next
          .putIfAbsent(chatId, StringBuffer.new)
          .write(
            '${op.seq}:${op.kind}:${op.status}:${op.attempts}:${op.lastError};',
          );
      (byChat[chatId] ??= <OutboxOp>[]).add(op);
    }
    final queued = <String, Set<String>>{};
    for (final MapEntry(key: chatId, value: chatOps) in byChat.entries) {
      final shown = queuedCompletionDisplaysOf(chatOps, isOnline: online).keys;
      if (shown.isEmpty) continue;
      queued[chatId] = shown.toSet();
      (_seen[chatId] ??= <String>{}).addAll(shown);
    }
    _queued = queued;
    final signatures = <String, String>{
      for (final entry in next.entries) entry.key: entry.value.toString(),
    };
    final changed = <String>{
      for (final chatId in {..._byChat.keys, ...signatures.keys})
        if (connectionChanged || _byChat[chatId] != signatures[chatId]) chatId,
    };
    _byChat = signatures;
    for (final chatId in changed) {
      _announce(chatId);
      onChanged?.call(chatId);
    }
  }

  void _announce(String chatId) => _events.emit(
    ConduitEventSpecs.chatsChanged,
    ChatsChanged(chatId: chatId),
  );

  void dispose() {
    _database.close();
    _online.close();
    unawaited(_ops?.cancel());
  }
}

final RegExp _reasoningEffortRejection = RegExp(
  r'reasoning[_\s-]*effort',
  caseSensitive: false,
);

/// [display] as the wire carries it.
QueuedCompletionDto queuedCompletionDto(QueuedCompletionDisplay display) {
  final error = display.lastError?.trim();
  return QueuedCompletionDto(
    failed: display.isFailed,
    offline: display.isOffline,
    error: error == null || error.isEmpty || error == 'offline' ? null : error,
    // The provider refused the reasoning effort the request was frozen
    // with: Retry Without Reasoning Effort sends it again without one.
    reasoningEffortRejected:
        display.isFailed &&
        display.frozenReasoningEffort != null &&
        _reasoningEffortRejection.hasMatch(error ?? ''),
  );
}
