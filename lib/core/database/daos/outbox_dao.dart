import 'dart:convert';

import 'package:drift/drift.dart';

import '../../utils/debug_logger.dart';
import '../../sync/id_remapper.dart' show createChatContentHash;
import '../app_database.dart';
import '../mappers/conversation_assembler.dart';
import '../mappers/note_mapper.dart';
import '../tables/outbox.dart';

part 'outbox_dao.g.dart';

/// Outbox op kinds (CDT-RFC-001 §7.2, A1). Persisted as the enum NAME string
/// in `OutboxOps.kind`.
enum OutboxKind {
  createChat,
  updateChat,
  deleteChat,
  requestCompletion,
  folderUpsert,
  folderDelete,
  // ---- Phase 5 notes (CDT-RFC-001 D-11) ----
  noteCreate,
  noteUpdate,
  noteDelete,
  notePin;

  /// Parses a persisted kind name; null for an unknown/legacy string so the
  /// drainer can skip it without crashing (A1).
  static OutboxKind? fromName(String name) {
    for (final kind in OutboxKind.values) {
      if (kind.name == name) return kind;
    }
    return null;
  }

  /// Folder ops live in their own coalescing/lock domain (A1, A3).
  bool get isFolderKind =>
      this == OutboxKind.folderUpsert || this == OutboxKind.folderDelete;

  /// Note ops live in their own lock domain (Phase 5) for adapter ownership
  /// routing — parallels [isFolderKind].
  bool get isNoteKind =>
      this == OutboxKind.noteCreate ||
      this == OutboxKind.noteUpdate ||
      this == OutboxKind.noteDelete ||
      this == OutboxKind.notePin;
}

/// Typed payload for a `requestCompletion` outbox op (W1/W3/W4).
///
/// Serializes to exactly the map shape the drainer/[RequestCompletionRunner]
/// expects (`assistantMessageId`, `model`, `toolIds`, and the optional
/// streaming-session knobs). The completion never snapshots the request
/// messages — only the routing/model knobs that cannot be re-derived from rows
/// live here; the runner rebuilds the message list from DB rows at drain time
/// (§3.iii).
class RequestCompletionPayload {
  const RequestCompletionPayload({
    required this.assistantMessageId,
    required this.model,
    this.toolIds = const <String>[],
    this.filterIds = const <String>[],
    this.terminalId,
    this.enableWebSearch = false,
    this.enableImageGeneration = false,
    this.enableCodeInterpreter = false,
    this.sessionIdOverride,
  });

  /// The placeholder assistant message id — the SAME id used for the in-memory
  /// optimistic bubble AND the DB placeholder row (R8 anti-desync invariant).
  final String assistantMessageId;

  /// Model id resolved at enqueue time (or `''` to let the runner fall back to
  /// the default-model provider at drain time, per the task-queue migration).
  final String model;
  final List<String> toolIds;
  final List<String> filterIds;
  final String? terminalId;
  final bool enableWebSearch;
  final bool enableImageGeneration;
  final bool enableCodeInterpreter;
  final String? sessionIdOverride;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'assistantMessageId': assistantMessageId,
    'model': model,
    'toolIds': toolIds,
    'filterIds': filterIds,
    if (terminalId != null) 'terminalId': terminalId,
    'enableWebSearch': enableWebSearch,
    'enableImageGeneration': enableImageGeneration,
    'enableCodeInterpreter': enableCodeInterpreter,
    if (sessionIdOverride != null) 'sessionIdOverride': sessionIdOverride,
  };

  static RequestCompletionPayload fromJson(Map<String, dynamic> json) {
    return RequestCompletionPayload(
      assistantMessageId: json['assistantMessageId'] as String,
      model: json['model'] is String ? json['model'] as String : '',
      toolIds: _stringList(json['toolIds']),
      filterIds: _stringList(json['filterIds']),
      terminalId: json['terminalId'] is String
          ? json['terminalId'] as String
          : null,
      enableWebSearch: json['enableWebSearch'] == true,
      enableImageGeneration: json['enableImageGeneration'] == true,
      enableCodeInterpreter: json['enableCodeInterpreter'] == true,
      sessionIdOverride: json['sessionIdOverride'] is String
          ? json['sessionIdOverride'] as String
          : null,
    );
  }

  static List<String> _stringList(Object? value) {
    if (value is List) {
      return [
        for (final e in value)
          if (e is String) e,
      ];
    }
    return const <String>[];
  }
}

/// Outbox op statuses (A2).
class OutboxStatus {
  OutboxStatus._();

  static const String pending = 'pending';
  static const String inFlight = 'inFlight';
  static const String failed = 'failed';
}

/// Transactional op queue accessor (CDT-RFC-001 §7.2, §7.3, §10).
///
/// Enqueue methods carry NO internal `transaction(() ...)` — they are plain
/// INSERT/coalesce statements meant to run INSIDE the caller's already-open
/// transaction (the extended `ChatsDao`/`FoldersDao` mutation methods), so an
/// op can never exist without its rows (REQ §7.2.1). Drift nesting makes the
/// `transaction()`-wrapped claim/mark helpers safe to call standalone too.
@DriftAccessor(tables: [OutboxOps])
class OutboxDao extends DatabaseAccessor<AppDatabase> with _$OutboxDaoMixin {
  OutboxDao(super.db);

  /// Bounds each claim query so a large offline outbox is scanned in chunks
  /// rather than materialized into one Dart list.
  static const int _claimCandidateBatchSize = 128;

  /// Coalesces against existing PENDING ops for [chatId] per A3, then inserts
  /// a fresh `pending` op (attempts=0, nextAttemptAt=null) UNLESS coalescing
  /// determined the new op is a no-op. Returns the surviving seq: the new
  /// row's seq when inserted, or the seq of the pending op that already
  /// covers this effect (the newest such op) when collapsed, or `-1` when the
  /// op annihilated itself with no survivor (e.g. deleteChat over a pending
  /// createChat).
  ///
  /// MUST be invoked inside an open transaction; the coalescing read + delete
  /// + insert must be atomic with the caller's row writes.
  Future<int> enqueue({
    required OutboxKind kind,
    String? chatId,
    Map<String, dynamic> payload = const {},
    String? contentHash,
  }) async {
    _validatePayload(kind, payload, contentHash);

    final decision = await _coalesce(
      kind: kind,
      chatId: chatId,
      payload: payload,
    );

    if (decision.deletions.isNotEmpty) {
      await (delete(outboxOps)..where(
            (t) =>
                t.seq.isIn(decision.deletions) &
                t.status.equals(OutboxStatus.pending),
          ))
          .go();
    }

    // Payload merge into a surviving op: when consecutive patch-like ops
    // collapse, the survivor's payload is the UNION of the earlier patch and the
    // new one (new keys win, with per-kind exceptions such as local folder
    // create). Done before the early return so a collapse still persists the
    // merged map.
    if ((decision.mergedPayload != null ||
            decision.mergedContentHash != null) &&
        decision.survivorSeq != null) {
      await (update(
        outboxOps,
      )..where((t) => t.seq.equals(decision.survivorSeq!))).write(
        OutboxOpsCompanion(
          payload: decision.mergedPayload == null
              ? const Value.absent()
              : Value(jsonEncode(decision.mergedPayload)),
          contentHash: decision.mergedContentHash == null
              ? const Value.absent()
              : Value(decision.mergedContentHash),
        ),
      );
    }

    if (!decision.insert) {
      return decision.survivorSeq ?? -1;
    }

    final seq = await into(outboxOps).insert(
      OutboxOpsCompanion.insert(
        kind: kind.name,
        chatId: Value(chatId),
        payload: Value(jsonEncode(payload)),
        status: const Value(OutboxStatus.pending),
        attempts: const Value(0),
        nextAttemptAt: const Value(null),
        contentHash: Value(contentHash),
      ),
    );
    return seq;
  }

  /// Atomically claims the lowest-seq runnable op (A2). Runnable means:
  /// `status='pending'`, due (`nextAttemptAt IS NULL OR <= now`), its queue
  /// domain is not [busyChatIds], AND it is the per-domain head (no smaller-seq
  /// op for the same domain+id is still live — strict FIFO for chat, folder, and
  /// note domains). On hit, flips the row to `inFlight` and returns it; null
  /// when nothing is runnable.
  ///
  /// chatId-NULL ops form a single independent stream keyed on the SQL NULL
  /// group; [busyChatIds] may contain the sentinel `'<null>'` to mark that
  /// stream busy.
  Future<OutboxOp?> claimNextRunnable({
    required int nowEpochSeconds,
    required Set<String> busyChatIds,
  }) {
    return transaction(() async {
      var offset = 0;
      while (true) {
        final candidates =
            await (select(outboxOps)
                  ..where(
                    (t) =>
                        t.status.equals(OutboxStatus.pending) &
                        (t.nextAttemptAt.isNull() |
                            t.nextAttemptAt.isSmallerOrEqualValue(
                              nowEpochSeconds,
                            )),
                  )
                  ..orderBy([(t) => OrderingTerm.asc(t.seq)])
                  ..limit(_claimCandidateBatchSize, offset: offset))
                .get();

        if (candidates.isEmpty) return null;

        for (final op in candidates) {
          final busyKey = busyKeyFor(op);
          if (busyChatIds.contains(busyKey)) {
            continue;
          }

          if (!await _isChatHead(op)) continue;

          await (update(outboxOps)..where((t) => t.seq.equals(op.seq))).write(
            const OutboxOpsCompanion(status: Value(OutboxStatus.inFlight)),
          );
          return op.copyWith(status: OutboxStatus.inFlight);
        }

        if (candidates.length < _claimCandidateBatchSize) return null;
        offset += _claimCandidateBatchSize;
      }
    });
  }

  /// True when no still-live (pending|inFlight) OR parked (failed) op with a
  /// smaller seq shares [op]'s chat. A parked predecessor is NOT success, so it
  /// must block a dependent op (e.g. a requestCompletion behind a parked
  /// createChat) from running — §7.2 "requestCompletion executes only after the
  /// chat's preceding ops succeeded". The manual-retry affordance
  /// ([requeueParked]) re-arms the parked head, which then unblocks its
  /// dependents on the next claim.
  Future<bool> _isChatHead(OutboxOp op) async {
    final blockingStatuses = _failedPredecessorsBlock(op)
        ? const [
            OutboxStatus.pending,
            OutboxStatus.inFlight,
            OutboxStatus.failed,
          ]
        : const [OutboxStatus.pending, OutboxStatus.inFlight];
    final predecessor =
        await (select(outboxOps)
              ..where(
                (t) =>
                    t.kind.isIn(_domainKindNamesForName(op.kind)) &
                    (op.chatId == null
                        ? t.chatId.isNull()
                        : t.chatId.equals(op.chatId!)) &
                    t.seq.isSmallerThanValue(op.seq) &
                    t.status.isIn(blockingStatuses),
              )
              ..limit(1))
            .getSingleOrNull();
    return predecessor == null;
  }

  bool _failedPredecessorsBlock(OutboxOp op) {
    return switch (OutboxKind.fromName(op.kind)) {
      OutboxKind.deleteChat ||
      OutboxKind.folderDelete ||
      OutboxKind.noteDelete => false,
      _ => true,
    };
  }

  /// Removes a completed op (A2 — no terminal history, mirrors the lean
  /// legacy queue). Success implicitly resets backoff (the row is gone).
  Future<void> markDone(int seq) {
    return (delete(outboxOps)..where((t) => t.seq.equals(seq))).go();
  }

  /// Stays `pending` (so the next claim re-picks it after backoff) with a
  /// bumped attempt count and a fresh [nextAttemptAt] (A2).
  Future<void> markFailedRetryable(
    int seq, {
    required String error,
    required int nextAttemptAt,
  }) {
    return customUpdate(
      'UPDATE outbox_ops SET status = ?, attempts = attempts + 1, '
      'last_error = ?, next_attempt_at = ? WHERE seq = ?',
      variables: [
        Variable.withString(OutboxStatus.pending),
        Variable.withString(error),
        Variable.withInt(nextAttemptAt),
        Variable.withInt(seq),
      ],
      updates: {outboxOps},
      updateKind: UpdateKind.update,
    );
  }

  /// Reschedules an op that should remain pending without burning retry
  /// attempts. Used for non-attempt deferrals such as offline checks or a live
  /// stream already owning a queued completion.
  Future<void> markDeferred(
    int seq, {
    required String error,
    required int nextAttemptAt,
  }) {
    return customUpdate(
      'UPDATE outbox_ops SET status = ?, last_error = ?, '
      'next_attempt_at = ? WHERE seq = ?',
      variables: [
        Variable.withString(OutboxStatus.pending),
        Variable.withString(error),
        Variable.withInt(nextAttemptAt),
        Variable.withInt(seq),
      ],
      updates: {outboxOps},
      updateKind: UpdateKind.update,
    );
  }

  /// Reschedules an op that could not be tried only because the device was
  /// offline (§7.2). Stays `pending` and pushes [nextAttemptAt] forward to pace
  /// re-checks, but does NOT bump `attempts`: an offline no-op is not a real
  /// send attempt, so it must not consume the requestCompletion N=5 budget
  /// (otherwise a long offline stretch parks a perfectly good completion the
  /// instant connectivity returns). `lastError` is recorded for diagnostics.
  Future<void> markOfflineDeferred(int seq, {required int nextAttemptAt}) {
    return markDeferred(seq, error: 'offline', nextAttemptAt: nextAttemptAt);
  }

  /// Terminal `failed` until a manual retry (requestCompletion N=5 §7.2).
  Future<void> markParked(int seq, {required String error}) {
    return customUpdate(
      'UPDATE outbox_ops SET status = ?, attempts = attempts + 1, '
      'last_error = ?, next_attempt_at = NULL WHERE seq = ?',
      variables: [
        Variable.withString(OutboxStatus.failed),
        Variable.withString(error),
        Variable.withInt(seq),
      ],
      updates: {outboxOps},
      updateKind: UpdateKind.update,
    );
  }

  /// Crash recovery (§7.2/§11): an op flipped to `inFlight` by [claimNextRunnable]
  /// is only marked done AFTER its network push fully returns. If the process is
  /// killed mid-push the op is left stranded as `inFlight`: it never re-runs AND
  /// (because [_isChatHead] treats inFlight as a live predecessor) it
  /// permanently blocks every later op for the same chat. This resets every
  /// stranded `inFlight` row back to `pending` so it is re-claimable, leaving
  /// `attempts`/`nextAttemptAt` intact so backoff/N=5 budgets still apply across
  /// process death. MUST run once at drainer/engine startup BEFORE the first
  /// drain. Returns the number of ops reclaimed.
  Future<int> resetInFlightToPending() {
    return (update(outboxOps)
          ..where((t) => t.status.equals(OutboxStatus.inFlight)))
        .write(const OutboxOpsCompanion(status: Value(OutboxStatus.pending)));
  }

  /// Looks up a PENDING create op carrying [contentHash] (§7.3 crash heal).
  /// Used by pull-merge paths to detect that a server object was already minted
  /// for a local create that crashed before committing its remap, so the remap
  /// can be completed instead of inserting/POSTing a duplicate.
  ///
  /// `inFlight` is deliberately EXCLUDED: an inFlight op is owned by a live
  /// drain worker (mid-push/mid-remap), so the heal must not race it. Stranded
  /// inFlight ops are first reset to `pending` by [resetInFlightToPending] at
  /// startup, after which they become eligible here. `failed`/parked rows are
  /// also excluded (a parked create is not awaiting heal).
  Future<OutboxOp?> pendingCreateForHash(
    String contentHash, {
    OutboxKind kind = OutboxKind.createChat,
  }) {
    return (select(outboxOps)
          ..where(
            (t) =>
                t.kind.equals(kind.name) &
                t.contentHash.equals(contentHash) &
                t.status.equals(OutboxStatus.pending),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.seq)])
          ..limit(1))
        .getSingleOrNull();
  }

  /// Atomically reserves the pending create op carrying [contentHash] for
  /// crash-heal. The row is flipped to `inFlight` before pull-side remap takes
  /// any local-id lock, so a drain worker cannot claim the same create and form
  /// an opposite-order lock cycle.
  Future<OutboxOp?> claimPendingCreateForHash(
    String contentHash, {
    OutboxKind kind = OutboxKind.createChat,
  }) {
    return transaction(() async {
      final op =
          await (select(outboxOps)
                ..where(
                  (t) =>
                      t.kind.equals(kind.name) &
                      t.contentHash.equals(contentHash) &
                      t.status.equals(OutboxStatus.pending),
                )
                ..orderBy([(t) => OrderingTerm.asc(t.seq)])
                ..limit(1))
              .getSingleOrNull();
      if (op == null) return null;

      final updated =
          await (update(outboxOps)..where(
                (t) =>
                    t.seq.equals(op.seq) &
                    t.status.equals(OutboxStatus.pending),
              ))
              .write(
                const OutboxOpsCompanion(status: Value(OutboxStatus.inFlight)),
              );
      if (updated == 0) return null;
      return op.copyWith(status: OutboxStatus.inFlight);
    });
  }

  /// Cheap preflight for the §7.3 crash-heal path. Lets pull skip expensive
  /// content-hash computation when no pending create of [kind] could match.
  Future<bool> hasPendingCreateContentHashes({
    OutboxKind kind = OutboxKind.createChat,
  }) async {
    final row =
        await (select(outboxOps)
              ..where(
                (t) =>
                    t.kind.equals(kind.name) &
                    t.contentHash.isNotNull() &
                    t.status.equals(OutboxStatus.pending),
              )
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  /// Manual-retry affordance (A2): re-arms a parked op for an immediate
  /// attempt. attempts is reset to 0 so the user gets a fresh N=5 budget;
  /// lastError is cleared.
  Future<void> requeueParked(int seq, {required int nowEpochSeconds}) {
    return (update(outboxOps)..where((t) => t.seq.equals(seq))).write(
      OutboxOpsCompanion(
        status: const Value(OutboxStatus.pending),
        attempts: const Value(0),
        nextAttemptAt: Value(nowEpochSeconds),
        lastError: const Value(null),
      ),
    );
  }

  /// Manual retry for an already-pending op whose backoff/offline marker is
  /// keeping it from being claimed immediately.
  Future<void> retryPendingNow(int seq, {required int nowEpochSeconds}) {
    return (update(outboxOps)..where(
          (t) => t.seq.equals(seq) & t.status.equals(OutboxStatus.pending),
        ))
        .write(
          OutboxOpsCompanion(
            nextAttemptAt: Value(nowEpochSeconds),
            lastError: const Value(null),
          ),
        );
  }

  /// Connectivity-regained backoff reset (A6/A7): re-arms every pending op for
  /// an immediate attempt. attempts/lastError are left intact.
  Future<void> resetBackoffForPending({required int nowEpochSeconds}) {
    return (update(outboxOps)
          ..where((t) => t.status.equals(OutboxStatus.pending)))
        .write(OutboxOpsCompanion(nextAttemptAt: Value(nowEpochSeconds)));
  }

  /// Rewrites the chat id on live and parked ops during ID remap (§7.3, §B).
  /// Called ONLY inside the IdRemapper transaction; never standalone.
  Future<void> rewriteChatId({
    required String fromChatId,
    required String toChatId,
  }) {
    return (update(outboxOps)..where(
          (t) =>
              t.chatId.equals(fromChatId) &
              t.status.isIn(const [
                OutboxStatus.pending,
                OutboxStatus.inFlight,
                OutboxStatus.failed,
              ]),
        ))
        .write(OutboxOpsCompanion(chatId: Value(toChatId)));
  }

  /// Live count of not-yet-terminal ops (pending|inFlight) — drives the
  /// "drain on increase" trigger (A7).
  Stream<int> watchPendingCount() {
    final countExpr = outboxOps.seq.count();
    final query = selectOnly(outboxOps)
      ..addColumns([countExpr])
      ..where(
        outboxOps.status.isIn(const [
          OutboxStatus.pending,
          OutboxStatus.inFlight,
        ]),
      );
    return query.watchSingle().map((row) => row.read(countExpr) ?? 0);
  }

  /// Parked ops for [chatId] — drives the parked-failure UI affordance (A7,
  /// Wiring D).
  Stream<List<OutboxOp>> watchParkedForChat(String chatId) {
    return (select(outboxOps)
          ..where(
            (t) =>
                t.chatId.equals(chatId) & t.status.equals(OutboxStatus.failed),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.seq)]))
        .watch();
  }

  /// Queued request-completion ops for [chatId] (pending|failed, seq ASC).
  /// This is intentionally narrower than [watchPendingCount]: the chat UI only
  /// needs user-actionable assistant placeholders, not unrelated sync work.
  Stream<List<OutboxOp>> watchQueuedCompletionsForChat(String chatId) {
    return (select(outboxOps)
          ..where(
            (t) =>
                t.chatId.equals(chatId) &
                t.kind.equals(OutboxKind.requestCompletion.name) &
                t.status.isIn(const [
                  OutboxStatus.pending,
                  OutboxStatus.failed,
                ]),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.seq)]))
        .watch();
  }

  /// All pending ops for [chatId] (seq ASC) — coalescing + tests (A2).
  Future<List<OutboxOp>> pendingForChat(
    String chatId, {
    OutboxKind? domainKind,
  }) {
    final query = select(outboxOps)
      ..where(
        (t) => t.chatId.equals(chatId) & t.status.equals(OutboxStatus.pending),
      );
    if (domainKind != null) {
      query.where((t) => t.kind.isIn(_domainKindNamesForName(domainKind.name)));
    }
    return (query..orderBy([(t) => OrderingTerm.asc(t.seq)])).get();
  }

  /// All still-owned ops for [chatId] (pending|inFlight, seq ASC).
  /// Used by merge paths that must not enqueue a duplicate while a drain
  /// worker already owns the covering op.
  Future<List<OutboxOp>> activeForChat(
    String chatId, {
    OutboxKind? domainKind,
  }) {
    final query = select(outboxOps)
      ..where(
        (t) =>
            t.chatId.equals(chatId) &
            t.status.isIn(const [OutboxStatus.pending, OutboxStatus.inFlight]),
      );
    if (domainKind != null) {
      query.where((t) => t.kind.isIn(_domainKindNamesForName(domainKind.name)));
    }
    return (query..orderBy([(t) => OrderingTerm.asc(t.seq)])).get();
  }

  // --- coalescing (A3) -----------------------------------------------------

  /// Sentinel busy-key for the chatId-NULL op stream (A2).
  static const String _nullChatKey = '<null>';

  /// Worker busy key for one outbox op. The persisted `chat_id` column stores
  /// chat ids, folder ids, and note ids, so the logical domain must be part of
  /// the key to avoid false blocking across entity types.
  static String busyKeyFor(OutboxOp op) =>
      busyKeyForKindName(op.kind, op.chatId);

  static String busyKeyForKind(OutboxKind kind, String? chatId) =>
      busyKeyForKindName(kind.name, chatId);

  static String busyKeyForKindName(String kindName, String? chatId) {
    return '${_domainNameForKindName(kindName)}:${chatId ?? _nullChatKey}';
  }

  Future<_CoalesceDecision> _coalesce({
    required OutboxKind kind,
    required String? chatId,
    Map<String, dynamic> payload = const {},
  }) async {
    // Every Phase 2 kind carries an entity id in the chatId column (chat id
    // or folder id). With no id there is nothing to coalesce against.
    if (chatId == null) {
      return const _CoalesceDecision(insert: true);
    }

    final pending = await pendingForChat(chatId, domainKind: kind);
    final pendingKinds = {
      for (final op in pending) OutboxKind.fromName(op.kind),
    };

    OutboxOp? newestOfKind(OutboxKind k) {
      OutboxOp? found;
      for (final op in pending) {
        if (OutboxKind.fromName(op.kind) == k) found = op;
      }
      return found;
    }

    switch (kind) {
      case OutboxKind.updateChat:
        // §7.2: createChat+updateChat collapse into the create; consecutive
        // updateChat collapse to newest. Both survivors reconstruct live rows
        // at push time, so the newest committed state is pushed regardless.
        // Refresh the surviving create's contentHash too; crash-heal matches
        // the server-created chat against the CURRENT rows pushCreateChat will
        // POST.
        final create = newestOfKind(OutboxKind.createChat);
        if (create != null) {
          return _CoalesceDecision(
            insert: false,
            survivorSeq: create.seq,
            mergedContentHash: await _currentCreateChatContentHash(chatId),
          );
        }
        final update = newestOfKind(OutboxKind.updateChat);
        if (update != null) {
          return _CoalesceDecision(insert: false, survivorSeq: update.seq);
        }
        return const _CoalesceDecision(insert: true);

      case OutboxKind.createChat:
        // Fresh local id: there can be no prior pending op for it.
        assert(
          pending.isEmpty,
          'createChat enqueued for a chatId with pending ops: $chatId',
        );
        return const _CoalesceDecision(insert: true);

      case OutboxKind.deleteChat:
        // Annihilates EVERY earlier pending op for this chat.
        final priorDelete = newestOfKind(OutboxKind.deleteChat);
        if (pendingKinds.contains(OutboxKind.createChat)) {
          // Never reached the server ⇒ pure local drop: delete all pending,
          // emit no deleteChat op.
          return _CoalesceDecision(
            insert: false,
            deletions: [for (final op in pending) op.seq],
          );
        }
        return _CoalesceDecision(
          insert: priorDelete == null,
          survivorSeq: priorDelete?.seq,
          deletions: [
            for (final op in pending)
              if (OutboxKind.fromName(op.kind) != OutboxKind.deleteChat) op.seq,
          ],
        );

      case OutboxKind.requestCompletion:
        // Never coalesced; ordered after preceding ops by seq (A3).
        return const _CoalesceDecision(insert: true);

      case OutboxKind.folderUpsert:
        // folderUpsert coalesces among itself only, keyed by folderId (== the
        // chatId column). A pending folderDelete is kept (re-create after
        // delete preserves order).
        final upsert = newestOfKind(OutboxKind.folderUpsert);
        if (upsert != null) {
          final priorPayload = _decodePayload(upsert.payload);
          final merged = <String, dynamic>{...priorPayload, ...payload};
          if (priorPayload['createIfAbsent'] == true) {
            merged['createIfAbsent'] = true;
          }
          return _CoalesceDecision(
            insert: false,
            survivorSeq: upsert.seq,
            mergedPayload: merged,
          );
        }
        return const _CoalesceDecision(insert: true);

      case OutboxKind.folderDelete:
        final hasLocalCreate = pending.any(_isLocalFolderCreate);
        final priorDelete = newestOfKind(OutboxKind.folderDelete);
        return _CoalesceDecision(
          // A brand-new local folderUpsert means the folder never reached the
          // server ⇒ drop both, emit nothing. Otherwise emit one delete, reusing
          // an existing pending delete if present.
          insert: !hasLocalCreate && priorDelete == null,
          survivorSeq: priorDelete?.seq,
          deletions: [
            for (final op in pending)
              if (OutboxKind.fromName(op.kind) == OutboxKind.folderUpsert)
                op.seq,
          ],
        );

      // ---- Phase 5 notes (CDT-RFC-001 D-11) ----
      case OutboxKind.noteCreate:
        // Fresh local note id: there can be no prior pending op for it.
        assert(
          pending.isEmpty,
          'noteCreate enqueued for a noteId with pending ops: $chatId',
        );
        return const _CoalesceDecision(insert: true);

      case OutboxKind.noteUpdate:
        if (pendingKinds.contains(OutboxKind.noteDelete)) {
          return const _CoalesceDecision(insert: false);
        }
        // createChat-analog: a pending noteCreate reconstructs the live row at
        // push (note_mapper builds title+data from the row), so it already
        // carries the latest title/data. Refresh the surviving create's
        // contentHash too; crash-heal matches the server-created note against
        // the CURRENT row content that pushNoteCreate will POST.
        final create = newestOfKind(OutboxKind.noteCreate);
        if (create != null) {
          final note = await attachedDatabase.notesDao.getNote(chatId);
          if (note == null) {
            throw StateError('pending noteCreate without note row: $chatId');
          }
          return _CoalesceDecision(
            insert: false,
            survivorSeq: create.seq,
            mergedContentHash: noteCreateContentHashFromRow(note),
          );
        }
        // Consecutive noteUpdate collapse to the newest, MERGING patch maps.
        // Keep an older `data` key only while the live row still has dirtyData;
        // an intervening pull may have cleared that axis before a title-only
        // edit enqueues the replacement op.
        final priorUpdate = newestOfKind(OutboxKind.noteUpdate);
        if (priorUpdate != null) {
          final merged = <String, dynamic>{
            ..._decodePayload(priorUpdate.payload),
            ...payload,
          };
          if (!payload.containsKey('data')) {
            final note = await attachedDatabase.notesDao.getNote(chatId);
            if (note != null && !note.dirtyData) {
              merged.remove('data');
            }
          }
          return _CoalesceDecision(
            insert: false,
            survivorSeq: priorUpdate.seq,
            mergedPayload: merged,
          );
        }
        return const _CoalesceDecision(insert: true);

      case OutboxKind.notePin:
        if (pendingKinds.contains(OutboxKind.noteDelete)) {
          return _CoalesceDecision(
            insert: false,
            deletions: [
              for (final op in pending)
                if (OutboxKind.fromName(op.kind) != OutboxKind.noteDelete)
                  op.seq,
            ],
          );
        }
        // Pin lives on its own axis (dedicated /pin endpoint). Coalesce among
        // itself: the newest desired-state wins (the row already holds it).
        final pin = newestOfKind(OutboxKind.notePin);
        if (pin != null) {
          return _CoalesceDecision(
            insert: false,
            survivorSeq: pin.seq,
            mergedPayload: payload,
          );
        }
        return const _CoalesceDecision(insert: true);

      case OutboxKind.noteDelete:
        // Annihilates EVERY earlier pending op for this note.
        final priorDelete = newestOfKind(OutboxKind.noteDelete);
        if (pendingKinds.contains(OutboxKind.noteCreate)) {
          // Never reached the server ⇒ pure local drop: delete all pending,
          // emit no noteDelete op. NotesDao.tombstoneWithOutbox removes the
          // local note row inline after this returns -1.
          return _CoalesceDecision(
            insert: false,
            deletions: [for (final op in pending) op.seq],
          );
        }
        return _CoalesceDecision(
          insert: priorDelete == null,
          survivorSeq: priorDelete?.seq,
          deletions: [
            for (final op in pending)
              if (OutboxKind.fromName(op.kind) != OutboxKind.noteDelete) op.seq,
          ],
        );
    }
  }

  /// A pending folderUpsert that creates a brand-new local folder
  /// (`createIfAbsent` true AND a `local:` folderId): never created remotely,
  /// so a folderDelete should annihilate it locally (A3).
  static bool _isLocalFolderCreate(OutboxOp op) {
    if (OutboxKind.fromName(op.kind) != OutboxKind.folderUpsert) return false;
    final payload = _decodePayload(op.payload);
    final createIfAbsent = payload['createIfAbsent'] == true;
    final folderId = payload['folderId'];
    final isLocal = folderId is String && folderId.startsWith('local:');
    return createIfAbsent && isLocal;
  }

  static String _domainNameForKindName(String kindName) {
    final kind = OutboxKind.fromName(kindName);
    if (kind == null) return kindName;
    if (kind.isFolderKind) return 'folder';
    if (kind.isNoteKind) return 'note';
    return 'chat';
  }

  static List<String> _domainKindNamesForName(String kindName) {
    final kind = OutboxKind.fromName(kindName);
    if (kind == null) return [kindName];
    if (kind.isFolderKind) {
      return const [
        OutboxKind.folderUpsert,
        OutboxKind.folderDelete,
      ].map((kind) => kind.name).toList();
    }
    if (kind.isNoteKind) {
      return const [
        OutboxKind.noteCreate,
        OutboxKind.noteUpdate,
        OutboxKind.noteDelete,
        OutboxKind.notePin,
      ].map((kind) => kind.name).toList();
    }
    return const [
      OutboxKind.createChat,
      OutboxKind.updateChat,
      OutboxKind.deleteChat,
      OutboxKind.requestCompletion,
    ].map((kind) => kind.name).toList();
  }

  Future<String?> _currentCreateChatContentHash(String chatId) async {
    final chat = await attachedDatabase.chatsDao.getChat(chatId);
    if (chat == null) return null;
    final messages = await attachedDatabase.messagesDao.getForChat(chatId);
    return createChatContentHash(chatRowsFromDb(chat, messages));
  }

  static Map<String, dynamic> _decodePayload(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return <String, dynamic>{};
  }

  // --- payload validation (A1) ---------------------------------------------

  void _validatePayload(
    OutboxKind kind,
    Map<String, dynamic> payload,
    String? contentHash,
  ) {
    switch (kind) {
      case OutboxKind.createChat:
        _require(payload.isEmpty, 'createChat payload must be empty');
        _require(
          contentHash != null,
          'createChat requires a contentHash fingerprint',
        );
        break;
      case OutboxKind.updateChat:
      case OutboxKind.deleteChat:
        _require(payload.isEmpty, '${kind.name} payload must be empty');
        break;
      case OutboxKind.requestCompletion:
        _require(
          payload['assistantMessageId'] is String,
          'requestCompletion.assistantMessageId must be a String',
        );
        _require(
          payload['model'] is String,
          'requestCompletion.model must be a String',
        );
        _require(
          payload['toolIds'] is List,
          'requestCompletion.toolIds must be a List',
        );
        break;
      case OutboxKind.folderUpsert:
        _require(
          payload['folderId'] is String,
          'folderUpsert.folderId must be a String',
        );
        _require(
          payload['createIfAbsent'] is bool,
          'folderUpsert.createIfAbsent must be a bool',
        );
        break;
      case OutboxKind.folderDelete:
        _require(
          payload['folderId'] is String,
          'folderDelete.folderId must be a String',
        );
        break;
      // ---- Phase 5 notes (CDT-RFC-001 D-11) ----
      case OutboxKind.noteCreate:
        // Empty payload: title/data reconstructed from the row at push
        // (note_mapper), mirroring createChat/deleteChat (§3.iii).
        _require(payload.isEmpty, 'noteCreate payload must be empty');
        _require(
          contentHash != null,
          'noteCreate requires a contentHash fingerprint',
        );
        break;
      case OutboxKind.noteDelete:
        _require(payload.isEmpty, 'noteDelete payload must be empty');
        break;
      case OutboxKind.noteUpdate:
        // Carries the patch map; `title` is ALWAYS present (WARNING B: the
        // router's NoteForm requires it, and the merge union must never lose it).
        _require(
          payload['title'] is String,
          'noteUpdate.title must be a String',
        );
        break;
      case OutboxKind.notePin:
        _require(payload['desired'] is bool, 'notePin.desired must be a bool');
        break;
    }
  }

  void _require(bool condition, String message) {
    if (!condition) {
      DebugLogger.error(message, scope: 'outbox/drain');
      throw ArgumentError(message);
    }
  }
}

/// Outcome of [OutboxDao._coalesce]: whether to insert the new op, the seqs to
/// delete (always pending-only), and the surviving seq when collapsed.
class _CoalesceDecision {
  const _CoalesceDecision({
    required this.insert,
    this.deletions = const [],
    this.survivorSeq,
    this.mergedPayload,
    this.mergedContentHash,
  });

  final bool insert;
  final List<int> deletions;
  final int? survivorSeq;

  /// When non-null, the surviving op's payload is rewritten to this merged map.
  final Map<String, dynamic>? mergedPayload;

  /// When non-null, the surviving op's content hash is refreshed.
  final String? mergedContentHash;
}
