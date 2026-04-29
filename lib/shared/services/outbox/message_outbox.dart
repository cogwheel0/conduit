import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/conversation.dart';
import '../../../core/persistence/conversation_store.dart';
import '../../../core/persistence/persistence_providers.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/connectivity_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../features/chat/providers/chat_providers.dart' as chat;

/// Drives outbound text-message delivery from the SQLite outbox.
///
/// Replaces the prior Hive-backed task queue. Each message row in SQLite
/// carries its own `send_status` / `send_attempt` / `send_next_at` /
/// `send_error` columns; this provider's only job is to scan for rows that
/// are ready to send and call back into [chat.sendMessageFromService].
///
/// Scope:
///   * Only the **active conversation's** pending rows fire here. Background
///     conversations sit until the user opens them. This avoids polluting
///     the in-memory chat state of whatever conversation the user is
///     currently looking at.
///   * Same backoff schedule as the old queue: 30s / 1m / 5m / 15m / 1h cap,
///     8 attempts before transitioning to `failed` permanently. Permanent
///     failures (`PermanentTaskError`-style 4xx) are marked terminal in
///     [chat.sendMessageFromService] itself and never picked up again.
///   * On connectivity restored, all pending rows for the active conv have
///     their backoff window cleared and are kicked immediately.
final messageOutboxProvider =
    NotifierProvider<MessageOutbox, MessageOutboxState>(MessageOutbox.new);

class MessageOutboxState {
  const MessageOutboxState({this.inFlight = const <String>{}});
  final Set<String> inFlight;
  MessageOutboxState copyWith({Set<String>? inFlight}) =>
      MessageOutboxState(inFlight: inFlight ?? this.inFlight);
}

class MessageOutbox extends Notifier<MessageOutboxState> {
  Timer? _drainTimer;
  bool _disposed = false;

  static const List<Duration> _backoff = <Duration>[
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 15),
    Duration(hours: 1),
  ];

  @override
  MessageOutboxState build() {
    _drainTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      _kick();
    });
    ref.onDispose(() {
      _disposed = true;
      _drainTimer?.cancel();
      _drainTimer = null;
    });

    // Reconnect → cancel backoff windows for the active conv and kick now.
    ref.listen<ConnectivityStatus>(connectivityStatusProvider, (prev, next) {
      if (next == ConnectivityStatus.online &&
          prev != ConnectivityStatus.online) {
        unawaited(_onConnectivityRestored());
      }
    });

    // Active conv changed → kick so its pending rows resume.
    ref.listen<Conversation?>(activeConversationProvider, (prev, next) {
      if (next != null && next.id != prev?.id) {
        _kick();
      }
    });

    // Initial drain on startup.
    Future.microtask(_kick);
    return const MessageOutboxState();
  }

  /// Public hook called by the send entry, retry button, and any code path
  /// that has just put a message into the outbox.
  void kick() => _kick();

  Duration backoffFor(int attempt) {
    if (attempt <= 0) return _backoff.first;
    final clamped = attempt - 1;
    if (clamped >= _backoff.length) return _backoff.last;
    return _backoff[clamped];
  }

  Future<void> _onConnectivityRestored() async {
    final activeId = ref.read(activeConversationProvider)?.id;
    if (activeId == null) return;
    final store = ref.read(conversationStoreProvider);
    final pending = await store.pendingMessages();
    for (final p in pending) {
      if (p.conversationId != activeId) continue;
      if (p.nextAt == null) continue;
      // Wipe the backoff: user just regained connectivity, the wait reason
      // (don't hammer a flaky server) no longer applies.
      await store.scheduleRetry(
        messageId: p.messageId,
        attempt: p.attempt,
        nextAt: DateTime.now().subtract(const Duration(seconds: 1)),
        error: p.error ?? 'reconnected',
      );
    }
    _kick();
  }

  Future<void> _kick() async {
    if (_disposed) return;
    final activeId = ref.read(activeConversationProvider)?.id;
    if (activeId == null) return;

    final store = ref.read(conversationStoreProvider);
    final List<PendingMessage> all;
    try {
      all = await store.pendingMessages();
    } catch (e, st) {
      DebugLogger.error(
        'outbox-poll-failed',
        scope: 'outbox',
        error: e,
        stackTrace: st,
      );
      return;
    }

    final now = DateTime.now();
    for (final p in all) {
      if (_disposed) return;
      if (p.conversationId != activeId) continue;
      // Skip user-message rows only — assistant rows never enter the outbox.
      if (p.message.role != 'user') continue;
      if (state.inFlight.contains(p.messageId)) continue;
      // Respect scheduled backoff window.
      if (p.nextAt != null && now.isBefore(p.nextAt!)) continue;
      _spawn(p);
    }
  }

  void _spawn(PendingMessage p) {
    state = state.copyWith(inFlight: {...state.inFlight, p.messageId});
    unawaited(
      _runOne(p).whenComplete(() {
        if (_disposed) return;
        final next = {...state.inFlight}..remove(p.messageId);
        state = state.copyWith(inFlight: next);
        // Some other row might be ready now (e.g. capacity freed, server
        // burst recovered). Cheap to call.
        _kick();
      }),
    );
  }

  Future<void> _runOne(PendingMessage p) async {
    final attachmentIds = p.message.attachmentIds;
    final attachments =
        (attachmentIds == null || attachmentIds.isEmpty)
        ? null
        : List<String>.from(attachmentIds);
    final toolIds = _readToolIds(p.message.metadata);
    try {
      await chat.sendMessageFromService(
        ref,
        p.message.content,
        attachments,
        toolIds: toolIds,
        pendingMessageId: p.messageId,
      );
      // _sendMessageInternal writes markSent on success. No-op here.
    } catch (_) {
      // _sendMessageInternal writes scheduleRetry / markPermanentFailed.
      // Outbox doesn't need to do anything on the error path.
    }
  }

  List<String>? _readToolIds(Map<String, dynamic>? metadata) {
    if (metadata == null) return null;
    final raw = metadata['toolIds'];
    if (raw is! List) return null;
    final list = raw
        .map((v) => v?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    return list.isEmpty ? null : list;
  }
}
