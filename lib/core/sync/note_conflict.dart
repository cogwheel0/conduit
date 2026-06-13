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
///   * DATA: a remote bump (`server.updatedAt > base`) with a locally-dirty
///     data axis is treated as a CONCURRENT DATA EDIT → conflict copy (keep
///     both: server data on the canonical id, local data on a new `local:` note
///     flagged `isConflictCopy`). NEVER silently drop the local data.
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
  });

  /// Merge base (nanoseconds); null = never synced.
  final int? serverUpdatedAt;
  final bool deleted;
  final bool dirtyTitle;
  final bool dirtyData;
  final bool dirtyPinned;
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

  /// Canonical row should adopt the server data (else keep local data).
  /// On a conflict copy this is TRUE: the server data lands on the canonical
  /// id and the LOCAL data is preserved on the spawned copy.
  final bool takeServerData;

  /// A new `local:` conflict-copy note carrying the LOCAL data must be inserted
  /// (+ a `noteCreate` op) in the SAME transaction.
  final bool spawnConflictCopy;

  /// Resulting dirty flags on the canonical row after merge.
  final bool canonicalDirtyTitle;
  final bool canonicalDirtyData;

  /// Set the canonical row's `serverUpdatedAt = server.updatedAt`. False only
  /// for the title-only-dirty branch, which KEEPS base unchanged (the push
  /// advances it, mirroring the chat three-way base rule, chat_merger.dart:50).
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

  // Overlap-window no-op: server has not advanced past our base.
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
  // DATA: clean-local → take server. dirty-local + remote bump → CONFLICT COPY
  // (server data on the canonical row; local data preserved on the copy).
  final spawnConflictCopy = local.dirtyData;
  final takeServerData = true; // canonical always adopts server data here.

  // Canonical dirty after merge: data is now clean (server adopted or copied
  // out). Title stays dirty iff the local title won (it still owes a push).
  final canonicalDirtyTitle = local.dirtyTitle;
  const canonicalDirtyData = false;

  return NoteMergeDecision(
    kind: NoteMergeKind.fieldLww,
    takeServerTitle: takeServerTitle,
    takeServerData: takeServerData,
    spawnConflictCopy: spawnConflictCopy,
    canonicalDirtyTitle: canonicalDirtyTitle,
    canonicalDirtyData: canonicalDirtyData,
    advanceServerUpdatedAt: true,
    mustPush: canonicalDirtyTitle || canonicalDirtyData || local.dirtyPinned,
  );
}
