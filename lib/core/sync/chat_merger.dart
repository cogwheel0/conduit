/// Pure three-way merge of a server chat blob against local rows
/// (CDT-RFC-001 §7.4). Intentionally free of drift and Flutter imports so it
/// can be unit-tested as plain Dart: the I/O, locking, and one-transaction
/// persistence all live in `PullSync` / `ChatsDao.mergeServerChat`.
///
/// The server (§3.iii) has NO concurrency control and applies a shallow
/// top-level blob merge, so conflict detection/resolution is 100% client-side.
/// This function decides, per the §7.4 case table, what the merged chat looks
/// like; it never advances the merge base on a three-way (the base advances
/// only when the subsequent push's `response.updated_at` lands, REQ 4).
library;

import '../database/mappers/chat_blob_mapper.dart';

/// Which §7.4 branch produced a [ChatMergeResult].
enum MergeOutcome {
  /// `S.updatedAt == base`: no remote delta. Rows untouched; a still-dirty
  /// local is (re)asserted for push. This is the 5s-overlap-window no-op.
  noRemoteChange,

  /// `S.updatedAt > base && !dirty`: replace local rows wholesale with server.
  fastForward,

  /// `S.updatedAt > base && dirty`: the three-way reconcile.
  threeWay,
}

/// Outcome of [mergeChat]: the rows to persist plus the bookkeeping `PullSync`
/// needs to write the DB and decide whether to enqueue a push.
class ChatMergeResult {
  const ChatMergeResult({
    required this.merged,
    required this.mustPush,
    required this.outcome,
    required this.newServerUpdatedAt,
    required this.dirtyMessageIds,
  });

  /// Rows to persist, keyed by the server chat id.
  final ChatRows merged;

  /// True when the merged result diverges from the server blob and so must be
  /// pushed (enqueue `updateChat`, keep the chat row `dirty`).
  final bool mustPush;

  /// For logging / asserts / tests.
  final MergeOutcome outcome;

  /// `B'` to write into `chats.serverUpdatedAt`. Advances to `S.updatedAt`
  /// ONLY on a fast-forward; on a three-way it stays at `base` (the push
  /// advances it later). On no-remote-change it stays at `base`.
  final int newServerUpdatedAt;

  /// Ids of [merged] messages that remain locally dirty (survived from the
  /// local side). On fast-forward this is empty; on no-remote-change it is the
  /// passed-in set unchanged; on three-way it is the subset of survivors that
  /// came from the dirty-local side. `PullSync` writes these rows `dirty=true`.
  final Set<String> dirtyMessageIds;
}

/// What `ChatsDao.mergeServerChat` reports back to `PullSync` after writing
/// the merge result: the [MergeOutcome] (for logging) and whether the merged
/// rows diverge from the server and so need a push (REQ 4). Lives here so the
/// DAO and `PullSync` share one type without a drift import in this library.
class ChatMergeWriteResult {
  const ChatMergeWriteResult({required this.outcome, required this.mustPush});

  final MergeOutcome outcome;
  final bool mustPush;
}

/// Three-way merge of [server] against [local] given merge base [base]
/// (CDT-RFC-001 §7.4). PURE — no I/O, no clock, no drift.
///
/// [local] carries per-row dirty out-of-band: [chatEnvelopeDirty] is the
/// chat row's `dirty` flag and [dirtyMessageIds] is the set of local message
/// ids whose row is `dirty=true` (`ChatRows`/`MessageRowData` have no dirty
/// field). [base] is `chats.serverUpdatedAt`, which is non-null for every
/// merge target (the only null-base rows are pre-remap `local:` chats, which
/// the pull crash-heal intercepts before this is reached); passing a value
/// where `server.chat.updatedAt < base` is a programming error.
ChatMergeResult mergeChat({
  required ChatRows server,
  required ChatRows local,
  required int base,
  required bool chatEnvelopeDirty,
  required Set<String> dirtyMessageIds,
}) {
  final serverUpdatedAt = server.chat.updatedAt;
  final dirty = chatEnvelopeDirty || dirtyMessageIds.isNotEmpty;

  // Case 1 — no remote change (also the 5s-overlap-window re-merge). Rows are
  // left untouched; only re-assert push if still dirty. IDEMPOTENT.
  if (serverUpdatedAt == base) {
    return ChatMergeResult(
      merged: local,
      mustPush: dirty,
      outcome: MergeOutcome.noRemoteChange,
      newServerUpdatedAt: base,
      dirtyMessageIds: dirtyMessageIds,
    );
  }

  assert(
    serverUpdatedAt > base,
    'mergeChat: server.updatedAt ($serverUpdatedAt) < base ($base) — '
    'a merge base must never lead the server clock (REQ 5).',
  );

  // Defensive release-mode fallback for serverUpdatedAt < base (should be
  // impossible; the assert above surfaces it in tests). Mirrors
  // resolveNoteMerge's `<= base` handling: leave local rows UNTOUCHED rather
  // than fast-forwarding with a stale server snapshot, which would also regress
  // the merge base below its previous value.
  if (serverUpdatedAt < base) {
    return ChatMergeResult(
      merged: local,
      mustPush: dirty,
      outcome: MergeOutcome.noRemoteChange,
      newServerUpdatedAt: base,
      dirtyMessageIds: dirtyMessageIds,
    );
  }

  // Case 2 — fast-forward: remote changed, nothing local is dirty. Replace
  // local rows wholesale with the server blob.
  if (!dirty) {
    return ChatMergeResult(
      merged: server,
      mustPush: false,
      outcome: MergeOutcome.fastForward,
      newServerUpdatedAt: serverUpdatedAt,
      dirtyMessageIds: const <String>{},
    );
  }

  // Case 3 — three-way reconcile.
  return _threeWay(
    server: server,
    local: local,
    base: base,
    chatEnvelopeDirty: chatEnvelopeDirty,
    dirtyMessageIds: dirtyMessageIds,
  );
}

ChatMergeResult _threeWay({
  required ChatRows server,
  required ChatRows local,
  required int base,
  required bool chatEnvelopeDirty,
  required Set<String> dirtyMessageIds,
}) {
  final serverById = <String, MessageRowData>{
    for (final m in server.messages) m.id: m,
  };
  final localById = <String, MessageRowData>{
    for (final m in local.messages) m.id: m,
  };

  // (a) MESSAGES — union by id over server ∪ local.
  //
  // Iteration order is deterministic and rowsToBlob-friendly: first every
  // local message in its existing order (so survivors keep their relative
  // order), then server-only inserts in server map order. orderIndex is
  // reassigned in iteration order below so rowsToBlob ordering stays stable.
  final survivors = <MessageRowData>[];
  final survivingDirtyIds = <String>{};

  // Local side first (preserves local relative ordering).
  for (final localMsg in local.messages) {
    final id = localMsg.id;
    final inServer = serverById.containsKey(id);
    final isDirty = dirtyMessageIds.contains(id);
    if (inServer) {
      // In both: local wins iff dirty, else server wins.
      if (isDirty) {
        survivors.add(localMsg);
        survivingDirtyIds.add(id);
      } else {
        survivors.add(serverById[id]!);
      }
    } else {
      // Only in L: keep iff locally new (dirty); else remotely deleted → drop.
      if (isDirty) {
        survivors.add(localMsg);
        survivingDirtyIds.add(id);
      }
    }
  }

  // Server-only inserts (id present in S but not in L), in server map order.
  for (final serverMsg in server.messages) {
    if (!localById.containsKey(serverMsg.id)) {
      survivors.add(serverMsg);
    }
  }

  // (a.5) ANCESTOR REACHABILITY — a survivor whose parent was DROPPED (a clean
  // local ancestor the server deleted) would otherwise carry a dangling
  // parentId, orphaning a locally-dirty descendant into an unreachable branch.
  // Re-attach each such survivor to its nearest surviving ancestor by walking
  // the ORIGINAL parent chain upward (→ null/root when none survives), so the
  // rebuilt tree stays fully connected. Done BEFORE deriving childrenIds so the
  // rewrite sees the corrected parents (§7.4; keeps treeIsConsistent).
  final originalParentOf = <String, String?>{
    for (final m in local.messages) m.id: m.parentId,
    for (final m in server.messages) m.id: m.parentId,
  };
  final survivorIds0 = {for (final m in survivors) m.id};
  final reattached = <MessageRowData>[
    for (final m in survivors)
      _withParent(
        m,
        _nearestSurvivingAncestor(m.parentId, originalParentOf, survivorIds0),
      ),
  ];

  // Reassign orderIndex in survivor (= deterministic) order so rowsToBlob
  // emits messages in a stable sequence after adds/drops.
  final reindexed = <MessageRowData>[
    for (var i = 0; i < reattached.length; i++)
      _withOrderIndex(reattached[i], i),
  ];

  // (b) CHILDREN REWRITE — rebuild childrenIds from parentId for EVERY
  // survivor (§7.4: childrenIds are derived, never merged). rowsToBlob
  // round-trips payload verbatim, so a stale childrenIds inside a surviving
  // payload would otherwise be wrong after an add/drop.
  final merged = <MessageRowData>[
    for (final m in reindexed) _withDerivedChildren(m, reindexed),
  ];

  // (c) currentMessageId — local if any local message is dirty, else server.
  // Then clamp to a surviving id (defensive; keeps treeIsConsistent).
  final survivorIds = {for (final m in merged) m.id};
  final preferLocalCurrent = dirtyMessageIds.isNotEmpty;
  var currentId = preferLocalCurrent
      ? local.chat.currentMessageId
      : server.chat.currentMessageId;
  var currentFromLocal = preferLocalCurrent;
  if (currentId == null || !survivorIds.contains(currentId)) {
    // Fall back to server's choice, then to the deepest leaf of the active
    // branch.
    final serverCurrent = server.chat.currentMessageId;
    if (serverCurrent != null && survivorIds.contains(serverCurrent)) {
      currentId = serverCurrent;
      currentFromLocal = false;
    } else {
      currentId = _deepestLeaf(merged);
      currentFromLocal = false;
    }
  }

  // historyHadCurrentId follows whichever side won currentId.
  final historyHadCurrentId = currentFromLocal
      ? local.historyHadCurrentId
      : server.historyHadCurrentId;

  // (d) METADATA LWW (title/folderId/pinned/archived) — decided per whole
  // envelope: chatEnvelopeDirty → local envelope wins, else server.
  final envelopeFromLocal = chatEnvelopeDirty;
  final envelopeSource = envelopeFromLocal ? local.chat : server.chat;

  final mergedChat = ChatRowData(
    id: server.chat.id,
    title: envelopeSource.title,
    folderId: envelopeSource.folderId,
    pinned: envelopeSource.pinned,
    archived: envelopeSource.archived,
    currentMessageId: currentId,
    // (f) createdAt is immutable → keep server's. updatedAt stays at base's
    // worth of local-ness: the merged row is dirty and will be re-pushed; B is
    // unchanged here, and the local updatedAt is preserved so a subsequent push
    // sends the freshest local envelope clock.
    createdAt: server.chat.createdAt,
    updatedAt: local.chat.updatedAt,
    // (e) rawExtra — server wholesale (server newer by definition).
    rawExtra: server.chat.rawExtra,
  );

  return ChatMergeResult(
    merged: ChatRows(
      chat: mergedChat,
      messages: merged,
      // (e) blob bookkeeping — SERVER wholesale, EXCEPT historyHadCurrentId.
      unmappableMessages: server.unmappableMessages,
      unmappableMessageOrder: server.unmappableMessageOrder,
      blobHadTitle: server.blobHadTitle,
      blobTitleValue: server.blobTitleValue,
      blobHadHistory: server.blobHadHistory,
      historyHadMessages: server.historyHadMessages,
      historyHadCurrentId: historyHadCurrentId,
      historyExtra: server.historyExtra,
    ),
    mustPush: true,
    outcome: MergeOutcome.threeWay,
    // (g) B does NOT advance on a three-way.
    newServerUpdatedAt: base,
    dirtyMessageIds: survivingDirtyIds,
  );
}

/// Walks up [parentOf] from [parentId] to the nearest id in [survivors],
/// returning null when the chain reaches the root or a dropped ancestor with
/// no surviving forebear. Cycle-guarded.
String? _nearestSurvivingAncestor(
  String? parentId,
  Map<String, String?> parentOf,
  Set<String> survivors,
) {
  var p = parentId;
  final seen = <String>{};
  while (p != null && !survivors.contains(p)) {
    if (!seen.add(p)) return null;
    p = parentOf[p];
  }
  return p;
}

/// Returns [message] with its `parentId` column AND `payload['parentId']`
/// set to [parentId] (rowsToBlob round-trips payload verbatim, so both must
/// agree). Identity-returns when unchanged. The payload map is copied (purity).
MessageRowData _withParent(MessageRowData message, String? parentId) {
  if (message.parentId == parentId) return message;
  final payload = <String, dynamic>{...message.payload, 'parentId': parentId};
  return MessageRowData(
    id: message.id,
    chatId: message.chatId,
    parentId: parentId,
    role: message.role,
    content: message.content,
    model: message.model,
    createdAt: message.createdAt,
    orderIndex: message.orderIndex,
    payload: payload,
  );
}

/// Returns [message] with `orderIndex` replaced by [orderIndex].
MessageRowData _withOrderIndex(MessageRowData message, int orderIndex) {
  return MessageRowData(
    id: message.id,
    chatId: message.chatId,
    parentId: message.parentId,
    role: message.role,
    content: message.content,
    model: message.model,
    createdAt: message.createdAt,
    orderIndex: orderIndex,
    payload: message.payload,
  );
}

/// Returns [message] with `payload['childrenIds']` rewritten to the derived
/// child id list among [all] (§7.4). The payload map is copied so the input
/// rows are never mutated (purity).
MessageRowData _withDerivedChildren(
  MessageRowData message,
  List<MessageRowData> all,
) {
  final childrenIds = ChatBlobMapper.deriveChildrenIds(message.id, all);
  final payload = <String, dynamic>{
    ...message.payload,
    'childrenIds': childrenIds,
  };
  return MessageRowData(
    id: message.id,
    chatId: message.chatId,
    parentId: message.parentId,
    role: message.role,
    content: message.content,
    model: message.model,
    createdAt: message.createdAt,
    orderIndex: message.orderIndex,
    payload: payload,
  );
}

/// Deepest leaf reachable by walking children from the root, used only as a
/// last-resort currentId when neither side's choice survived. Walks the active
/// branch by always taking the last (newest) child; falls back to any survivor
/// when no root exists.
String? _deepestLeaf(List<MessageRowData> messages) {
  if (messages.isEmpty) return null;
  final byId = {for (final m in messages) m.id: m};

  // Find a starting node: the first root (parentId null or absent in the set),
  // falling back to any survivor when no root exists.
  MessageRowData? start;
  for (final m in messages) {
    if (m.parentId == null || !byId.containsKey(m.parentId)) {
      start = m;
      break;
    }
  }
  start ??= messages.first;

  var current = start;
  final seen = <String>{};
  while (true) {
    if (!seen.add(current.id)) return current.id;
    final children = ChatBlobMapper.deriveChildrenIds(current.id, messages);
    if (children.isEmpty) return current.id;
    final next = byId[children.last];
    if (next == null) return current.id;
    current = next;
  }
}
