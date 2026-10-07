import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/mappers/note_mapper.dart';
import 'package:conduit_core/models/note.dart';

/// Whether the signed-in account may change a note's content.
enum NoteWriteAccess {
  /// The server said so, or the account created the note.
  allowed,

  /// The server reported `write_access: false`.
  denied,

  /// A note the account did not create and the server has not described yet.
  /// Writes wait for an authoritative detail read.
  unknown,
}

/// Thrown by the durable note writers when the account may not edit a note.
///
/// It is not a missing note: the row still exists and its draft is kept, so
/// callers must not treat it as a deletion or retry it as another account.
class NoteWriteDeniedException implements Exception {
  const NoteWriteDeniedException(this.noteId, {this.unverified = false});

  final String noteId;

  /// True when access was never confirmed, as opposed to refused.
  final bool unverified;

  @override
  String toString() => 'NoteWriteDeniedException($noteId)';
}

/// Decides write access from what is known about a note.
///
/// `write_access` wins over ownership in both directions: a write recipient
/// has it true while `user_id` names the creator, and the server computes it
/// for the owner too. Ownership only matters when the server has not said.
NoteWriteAccess resolveNoteWriteAccess({
  required bool? writeAccess,
  required String noteId,
  required String? ownerId,
  required String? accountId,
}) {
  if (writeAccess != null) {
    return writeAccess ? NoteWriteAccess.allowed : NoteWriteAccess.denied;
  }
  // A `local:` note was created on this account's database, and a row that
  // never recorded an owner predates shared notes: both keep editing as before.
  if (noteId.startsWith('local:')) return NoteWriteAccess.allowed;
  if (ownerId == null || ownerId.isEmpty) return NoteWriteAccess.allowed;
  if (ownerId == accountId) return NoteWriteAccess.allowed;
  return NoteWriteAccess.unknown;
}

NoteWriteAccess noteWriteAccess(Note note, {required String? accountId}) =>
    resolveNoteWriteAccess(
      writeAccess: note.writeAccess,
      noteId: note.id,
      ownerId: note.userId,
      accountId: accountId,
    );

String? _storedOwnerId(Map<String, dynamic> raw) {
  final user = raw['user'];
  return raw['user_id']?.toString() ??
      (user is Map ? user['id']?.toString() : null);
}

/// [noteWriteAccess] for a stored row, without building a [Note].
NoteWriteAccess noteRowWriteAccess(NoteRow row, {required String? accountId}) {
  final raw = decodeJsonMap(row.rawExtra);
  return resolveNoteWriteAccess(
    writeAccess: raw['write_access'] is bool
        ? raw['write_access'] as bool
        : null,
    noteId: row.id,
    ownerId: _storedOwnerId(raw),
    accountId: accountId,
  );
}

/// Whether [row] is the account's own note, as opposed to one shared with it.
/// Replay checks a shared note with the server before sending an edit.
bool noteRowIsOwnedBy(NoteRow row, {required String? accountId}) =>
    resolveNoteWriteAccess(
      writeAccess: null,
      noteId: row.id,
      ownerId: _storedOwnerId(decodeJsonMap(row.rawExtra)),
      accountId: accountId,
    ) ==
    NoteWriteAccess.allowed;
