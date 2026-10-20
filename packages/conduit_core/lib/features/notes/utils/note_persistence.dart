import 'package:dio/dio.dart';

import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/notes/providers/notes_providers.dart';
import 'package:conduit_core/models/note.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';

/// Whether the note editor's session (the API service, database and auth
/// epoch it captured before an await) is still the active one.
///
/// A recording upload or a draft recovery outlives a tap, so it must not
/// write a note into an account the user has since switched to. [ref] is a
/// `Ref`, `WidgetRef` or `ProviderContainer`.
bool isCurrentNoteEditorSession(
  dynamic ref, {
  required Object? api,
  required AppDatabase? db,
  Object? authEpoch,
}) {
  final bool authenticated = ref.read(isAuthenticatedProvider2) as bool;
  if (!authenticated) return false;
  final Object? currentApi = ref.read(apiServiceProvider) as Object?;
  if (!identical(currentApi, api)) return false;
  if (authEpoch != null) {
    final Object currentEpoch =
        ref.read(openWebUiAuthSessionEpochProvider) as Object;
    if (!identical(currentEpoch, authEpoch)) return false;
  }
  final AppDatabase? currentDb = ref.read(appDatabaseProvider) as AppDatabase?;
  return db == null ? currentDb == null : identical(currentDb, db);
}

/// Persists a note title/data edit through the durable outbox path (when a
/// Drift database is active) so an offline edit is never lost, falling back to
/// the API-first path in reviewer mode or with no active server. Returns the
/// stored note, or `null` if it could not be persisted.
///
/// [api] and [db] are the session the caller captured BEFORE its awaits; if
/// the active account or database changed meanwhile (during an audio upload,
/// say) this bails without persisting, so the old editor's note is never
/// written into a newly active account. [isStillOpen] is the editor's
/// `mounted`: with it false the notes list is not touched.
///
/// With a database, [dataFrom] builds a further patch from the stored note's
/// data inside the note lock (over [data]), so an edit of a list such as the
/// attached files starts from the row as it is when it is written. The API
/// path has no such lock and sends [data] as given.
///
/// [noteId] is the id the editor was opened with, whose keep-alive detail is
/// invalidated; the durable write goes to [writeId] (the loaded note's id,
/// which may be the server id a `local:` one was remapped to).
Future<Note?> persistNoteUpdate(
  dynamic ref, {
  required String noteId,
  String? writeId,
  required Object? api,
  required AppDatabase? db,
  required String title,
  required Map<String, dynamic> data,
  Map<String, dynamic> Function(Map<String, dynamic> existing)? dataFrom,
  Object? authEpoch,
  String? accountId,
  ApiAuthSnapshot? authSnapshot,
  CancelToken? cancelToken,
  bool Function()? isStillOpen,
}) async {
  // The session the caller opened under, fixed before the first await. Every
  // later step (remap lookup, permission read, note lock, API fallback) is
  // judged against it and sends its requests with its auth snapshot.
  final captured = NoteMutationOwner.capture(ref);
  final owner = NoteMutationOwner(
    api: api is ApiService ? api : null,
    authSnapshot:
        authSnapshot ?? (api is ApiService ? api.captureAuthSnapshot() : null),
    db: db,
    authEpoch: authEpoch ?? captured.authEpoch,
    accountId: accountId ?? captured.accountId,
  );
  if (!(ref.read(isAuthenticatedProvider2) as bool) || !owner.isCurrent(ref)) {
    return null;
  }
  Note? note;
  if (db != null) {
    note = await durableUpdateNote(
      ref,
      db,
      id: writeId ?? noteId,
      title: title,
      data: data,
      dataFrom: dataFrom,
      owner: owner,
    );
  } else {
    // Session confirmed current, so the live API equals the captured one.
    final ApiService? currentApi = ref.read(apiServiceProvider) as ApiService?;
    if (currentApi == null) return null;
    note = Note.fromJson(
      await currentApi.updateNoteForSession(
        noteId,
        title: title,
        data: data,
        authSnapshot: owner.authSnapshot,
        cancelToken: cancelToken,
      ),
    );
    if ((isStillOpen?.call() ?? true) && owner.isCurrent(ref)) {
      ref.read(notesListProvider.notifier).updateNote(note, sourceDb: db);
    }
  }
  // `noteByIdProvider` is keepAlive, so without this it keeps serving the
  // note as it was when first opened (e.g. empty for a freshly created note)
  // and reopening the note in the same app session shows stale/empty content
  // until a full restart. Invalidate so the next open re-reads what we just
  // saved. Cover the remapped server id too, in case a `local:` id resolved.
  if (note != null && owner.isCurrent(ref)) {
    ref.invalidate(noteByIdProvider(noteId));
    if (note.id != noteId) {
      ref.invalidate(noteByIdProvider(note.id));
    }
  }
  return note;
}
