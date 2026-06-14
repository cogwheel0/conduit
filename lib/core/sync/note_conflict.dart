/// Pure field-level LWW + conflict-copy resolution for notes (CDT-RFC-001
/// Phase 5, D-11, non-neg 4).
///
/// This library is intentionally free of drift/Flutter so it is unit-testable
/// as plain Dart. `NotesDao.mergeServerNote` calls [resolveNoteMerge] then
/// performs the row writes the decision dictates.
///
/// D-11 binding interpretation (restated): the server has exactly ONE
/// `updated_at` per note, so the merge CANNOT distinguish "server edited only
/// title" from "server edited data". The conservative rule:
///   * TITLE is a last-writer scalar — a locally-dirty title WINS (it will be
///     pushed; the server title is discarded), no conflict copy ever for title.
///   * DATA: a remote bump (`server.updatedAt > base`) with locally-dirty data
///     on a canonical note is treated as a CONCURRENT DATA EDIT → conflict copy
///     (keep both). A conflict-copy note does not fork again; its local data
///     remains dirty and wins on the next push.
library;

/// What [resolveNoteMerge] decided for the canonical row + whether a conflict
/// copy must be spawned.
enum NoteMergeKind {
  /// existing==null OR base==null: plain server fast-forward write, no dirty.
  fastForward,

  /// Pending tombstone with a local dirty edit: SKIP entirely (the pending
  /// noteDelete wins; never resurrect).
  skipDirtyTombstone,

  /// `server.updatedAt == base`: overlap-window no-op; rows untouched.
  noRemoteChange,

  /// `server.updatedAt > base`, resolved field-independently. May or may not
  /// require a conflict copy (see [NoteMergeDecision.spawnConflictCopy]).
  fieldLww,
}

/// Pure inputs the resolver needs from the existing row (decoupled from drift).
class NoteMergeLocal {
  const NoteMergeLocal({
    required this.serverUpdatedAt,
    required this.deleted,
    required this.dirtyTitle,
    required this.dirtyData,
    required this.dirtyPinned,
    this.isConflictCopy = false,
  });

  /// Merge base (nanoseconds); null = never synced.
  final int? serverUpdatedAt;
  final bool deleted;
  final bool dirtyTitle;
  final bool dirtyData;
  final bool dirtyPinned;
  final bool isConflictCopy;
}

/// The resolved write plan for the CANONICAL row, plus the conflict-copy flag.
class NoteMergeDecision {
  const NoteMergeDecision({
    required this.kind,
    required this.takeServerTitle,
    required this.takeServerData,
    required this.spawnConflictCopy,
    required this.canonicalDirtyTitle,
    required this.canonicalDirtyData,
    required this.advanceServerUpdatedAt,
    required this.mustPush,
  });

  final NoteMergeKind kind;

  /// Canonical row should adopt the server title (else keep local title).
  final bool takeServerTitle;

  /// Canonical row should adopt the server data (else keep local data). False
  /// only when an existing conflict-copy note has dirty local data and should
  /// not spawn another copy.
  final bool takeServerData;

  /// A new `local:` conflict-copy note carrying the LOCAL data must be inserted
  /// (+ a `noteCreate` op) in the SAME transaction.
  final bool spawnConflictCopy;

  /// Resulting dirty flags on the canonical row after merge.
  final bool canonicalDirtyTitle;
  final bool canonicalDirtyData;

  /// Set the canonical row's `serverUpdatedAt = server.updatedAt`. False when
  /// no server data was adopted; the next push advances the base.
  final bool advanceServerUpdatedAt;

  /// Any dirty axis remains set on the canonical row → an updateChat-equivalent
  /// push is owed.
  final bool mustPush;
}

/// Resolves the merge of a server note (at [serverUpdatedAt]) against the
/// [local] row state. Pin is NEVER resolved here (WARNING A: it is reconciled
/// out-of-band via the `/pin` axis), but [local.dirtyPinned] still feeds
/// `mustPush` so a pending pin is not lost.
NoteMergeDecision resolveNoteMerge({
  required int serverUpdatedAt,
  required NoteMergeLocal? local,
}) {
  // Dirty tombstone: the pending noteDelete wins; never resurrect. Hoisted
  // ahead of the null-base branch — it fires for any dirty local tombstone,
  // whether or not a merge base exists.
  if (local != null &&
      local.deleted &&
      (local.dirtyTitle || local.dirtyData || local.dirtyPinned)) {
    return const NoteMergeDecision(
      kind: NoteMergeKind.skipDirtyTombstone,
      takeServerTitle: false,
      takeServerData: false,
      spawnConflictCopy: false,
      canonicalDirtyTitle: false,
      canonicalDirtyData: false,
      advanceServerUpdatedAt: false,
      mustPush: false,
    );
  }

  // First sync, or a never-synced row: plain server write (fast-forward).
  if (local == null || local.serverUpdatedAt == null) {
    return const NoteMergeDecision(
      kind: NoteMergeKind.fastForward,
      takeServerTitle: true,
      takeServerData: true,
      spawnConflictCopy: false,
      canonicalDirtyTitle: false,
      canonicalDirtyData: false,
      advanceServerUpdatedAt: true,
      mustPush: false,
    );
  }

  final base = local.serverUpdatedAt!;
  final anyDirty = local.dirtyTitle || local.dirtyData || local.dirtyPinned;

  // Overlap-window no-op: server has not advanced past our base. A base that
  // LEADS the server clock should never happen (parity with chat_merger.dart);
  // surface it in tests rather than silently skipping the update.
  assert(
    serverUpdatedAt >= base,
    'resolveNoteMerge: serverUpdatedAt ($serverUpdatedAt) < base ($base) — '
    'a merge base must never lead the server clock (R-09).',
  );
  if (serverUpdatedAt <= base) {
    return NoteMergeDecision(
      kind: NoteMergeKind.noRemoteChange,
      takeServerTitle: false,
      takeServerData: false,
      spawnConflictCopy: false,
      canonicalDirtyTitle: local.dirtyTitle,
      canonicalDirtyData: local.dirtyData,
      // No server state taken; keep base unchanged (push advances it).
      advanceServerUpdatedAt: false,
      mustPush: anyDirty,
    );
  }

  // server.updatedAt > base: FIELD-LWW resolved INDEPENDENTLY.
  // TITLE: dirty-local wins (scalar replace, no conflict copy); else server.
  final takeServerTitle = !local.dirtyTitle;
  // DATA: clean-local -> take server. dirty-local + remote bump normally
  // spawns a conflict copy. A conflict copy is already the preserved fork, so
  // do not fork again; keep its local data dirty and let push win.
  final spawnConflictCopy = local.dirtyData && !local.isConflictCopy;
  final takeServerData = !local.dirtyData || !local.isConflictCopy;

  // Canonical dirty after merge: data is now clean (server adopted or copied
  // out) except for conflict copies, where local data stays dirty and no second
  // copy is spawned. Title stays dirty iff the local title won.
  final canonicalDirtyTitle = local.dirtyTitle;
  final canonicalDirtyData = local.dirtyData && local.isConflictCopy;

  return NoteMergeDecision(
    kind: NoteMergeKind.fieldLww,
    takeServerTitle: takeServerTitle,
    takeServerData: takeServerData,
    spawnConflictCopy: spawnConflictCopy,
    canonicalDirtyTitle: canonicalDirtyTitle,
    canonicalDirtyData: canonicalDirtyData,
    advanceServerUpdatedAt: takeServerData,
    mustPush: canonicalDirtyTitle || canonicalDirtyData || local.dirtyPinned,
  );
}
