import 'package:drift/drift.dart';

/// Note rows (CDT-RFC-001 Phase 5, D-11, R-09).
///
/// A FLAT document — exactly ONE row per note, NO child rows (the key
/// divergence from chats: no mapper-to-rows, no messages, no blobMeta).
///
/// All timestamps are server NANOSECONDS (`time.time_ns()`, vendored
/// `models/notes.py:135,318`) stored as `int` (int64), per R-09. They are
/// NEVER epoch seconds and NEVER compared to `chats.updatedAt` (which is
/// SECONDS); the unit divergence is load-bearing — see [Notes.updatedAt] and
/// `note_sync.dart`'s `notes_pull_watermark` (also nanoseconds, a separate
/// `sync_meta` key never read against the chat `pull_watermark`).
@DataClassName('NoteRow')
class Notes extends Table {
  /// Server uuid, or `local:<uuid>` pre-remap (D-10, like chats.dart:9).
  TextColumn get id => text()();
  TextColumn get title => text()();

  /// `jsonEncode` of the full server `data` dict, stored VERBATIM. The note
  /// body lives at `data['content']['md']`; the whole sub-object round-trips
  /// here so the mapper is identity over it (non-neg 2).
  TextColumn get data => text().withDefault(const Constant('{}'))();

  /// `jsonEncode` of the server `meta` dict.
  TextColumn get meta => text().withDefault(const Constant('{}'))();

  /// LOCAL MIRROR ONLY (WARNING A). `is_pinned` is NOT in the note's
  /// `updated_at` stream and NOT a server `note` column — it is per-user
  /// toggle state synced via the dedicated `/pin` axis, never via the
  /// title/data watermark merge.
  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();

  /// Server NANOSECONDS.
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  /// Merge BASE (NANOSECONDS); null = never synced (mirrors chats.dart:24).
  IntColumn get serverUpdatedAt => integer().nullable()();

  // ---- FIELD-LWW dirty model (D-11, non-neg 4) ----
  // THREE independent dirty flags, NOT one chat-style `dirty`. The server has
  // exactly ONE `updated_at` per note (no per-field server timestamps), so the
  // independent title-vs-data LWW and the conflict-copy decision are 100%
  // client-side and need the dirty axes split.
  BoolColumn get dirtyTitle => boolean().withDefault(const Constant(false))();
  BoolColumn get dirtyData => boolean().withDefault(const Constant(false))();
  BoolColumn get dirtyPinned => boolean().withDefault(const Constant(false))();

  /// Tombstone (like chats.dart:28).
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  /// NON-NEG 2: round-trips `access_grants`/`access_control`/`user`/
  /// `write_access` + any unknown server keys (mirrors chats `rawExtra`). The
  /// mapper preserves these so `noteRowToServer(serverToNoteRow(n))` is
  /// identity over unknown fields. Our own-notes sync NEVER sends
  /// `access_grants` (it has its own endpoint); it round-trips untouched.
  TextColumn get rawExtra => text().withDefault(const Constant('{}'))();

  /// True for a note created by the D-11 conflict-copy branch so the UI can
  /// badge it and link it back to the canonical note.
  BoolColumn get isConflictCopy =>
      boolean().withDefault(const Constant(false))();

  /// The server id of the canonical note this is a conflict copy of.
  TextColumn get conflictOf => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
