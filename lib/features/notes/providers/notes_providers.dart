import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/notes_dao.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/database/mappers/note_mapper.dart';
import 'package:conduit/core/models/note.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/connectivity_service.dart';
import 'package:conduit/core/sync/chat_locks.dart';
import 'package:conduit/core/sync/sync_engine.dart';
import 'package:conduit/core/utils/debug_logger.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';

part 'notes_providers.g.dart';

List<Note> _sortNotes(Iterable<Note> notes) {
  final sorted = notes.toList(growable: true);
  sorted.sort((a, b) {
    final updatedCompare = b.updatedAt.compareTo(a.updatedAt);
    if (updatedCompare != 0) {
      return updatedCompare;
    }

    final createdCompare = b.createdAt.compareTo(a.createdAt);
    if (createdCompare != 0) {
      return createdCompare;
    }

    return a.id.compareTo(b.id);
  });
  return List<Note>.unmodifiable(sorted);
}

Note _noteFromRow(NoteRow row) => Note.fromJson(noteRowToServer(row));

/// Reads a note straight from the local Drift row, with no server fetch.
///
/// Use this after a sync ([SyncEngine.requestPull]) when you need the
/// reconciled local state and must NOT let a stale/behind server copy clobber
/// not-yet-pushed local content (e.g. the note editor's pull-to-refresh).
/// Returns null when the row is missing or tombstoned.
Future<Note?> readLocalNote(AppDatabase db, String id, {String? userId}) async {
  final row = userId == null || userId.isEmpty
      ? await db.notesDao.getNote(id)
      : await db.notesDao.getNoteForUser(id, userId: userId);
  if (row == null || row.deleted) return null;
  return _noteFromRow(row);
}

Note _noteFromListEntry(NoteListEntry entry) {
  final meta = entry.previewMarkdown.isEmpty
      ? null
      : <String, dynamic>{
          kNoteListPreviewMarkdownMetaKey: entry.previewMarkdown,
        };
  return Note(
    id: entry.id,
    userId: entry.userId,
    title: entry.title,
    meta: meta,
    createdAt: entry.createdAt,
    updatedAt: entry.updatedAt,
    isPinned: entry.isPinned,
  );
}

Future<void> _persistServerNoteRow(
  AppDatabase db,
  Map<String, dynamic> raw, {
  required String noteId,
}) async {
  try {
    await db.notesDao.mergeServerNote(serverRaw: raw);
  } catch (error, stackTrace) {
    DebugLogger.error(
      'row-upsert-failed',
      scope: 'notes',
      error: error,
      stackTrace: stackTrace,
      data: {'id': noteId},
    );
  }
}

bool _canUseCachedNoteAfterDetailError(Object error) {
  if (error is! DioException) return false;
  if (error.type == DioExceptionType.cancel) return false;

  final statusCode = error.response?.statusCode;
  if (statusCode != null) return statusCode >= 500;

  return error.type != DioExceptionType.badResponse;
}

bool _isCurrentDatabase(Ref ref, AppDatabase? db) {
  final currentDb = ref.read(appDatabaseProvider);
  return db == null ? currentDb == null : identical(currentDb, db);
}

bool _isCurrentNoteSession(
  Ref ref, {
  required Object? api,
  required AppDatabase? db,
}) {
  return identical(ref.read(apiServiceProvider), api) &&
      _isCurrentDatabase(ref, db);
}

// ---- durable note mutations (CDT-RFC-001 §7 write path) -------------------
//
// When a Drift database is active, note mutations write the row AND the outbox
// op in ONE transaction via the `*WithOutbox` DAO methods under
// `noteLocks.runExclusive(id)`, then kick the drainer so an online edit pushes
// immediately. Offline, the op waits durably in the outbox so the edit is never
// lost — the UI updates from the reactive `watchNotes` stream regardless. These
// mirror the chat durable-send write path (`durableSend`) and take a loosely
// typed `ref` so both the keep-alive providers (`Ref`) and the note editor
// (`WidgetRef`) can drive them. Callers without a database keep the legacy
// API-first path (reviewer mode / no active server).

/// PROVISIONAL local nanosecond stamp for list ordering; the server overwrites
/// `updated_at` on push (see [NotesDao.updateNoteWithOutbox]).
int _localNoteNowNs() => DateTime.now().microsecondsSinceEpoch * 1000;

/// Fire-and-forget drainer kick; failures are non-fatal (the op stays queued).
Future<void> _drainNotes(dynamic ref) async {
  try {
    await ref.read(syncEngineProvider.notifier).drainNow();
  } catch (error) {
    DebugLogger.warning(
      'drain-failed',
      scope: 'notes',
      data: {'errorType': error.runtimeType.toString()},
    );
  }
}

/// Reads the just-written note back, THEN kicks the drainer. The write already
/// committed under the note lock, so reading first returns it deterministically
/// and cannot race the push+remap the drain may trigger (which deletes the
/// `local:` row). The drainer is still fire-and-forget so the UI never blocks on
/// the network. (Resolving the remap target is a no-op here since no remap can
/// have happened yet, but is kept for callers that pass a pre-existing id.)
Future<Note?> _readBackThenDrainNote(
  dynamic ref,
  AppDatabase db,
  String id,
) async {
  final resolvedId = await db.notesDao.resolveNoteRemapTarget(id);
  final row = await db.notesDao.getNote(resolvedId);
  unawaited(_drainNotes(ref));
  return row == null ? null : _noteFromRow(row);
}

/// Durable note title/data edit. Returns the stored note (from the just-written
/// row) or `null` if the row no longer exists (e.g. concurrently deleted).
Future<Note?> durableUpdateNote(
  dynamic ref,
  AppDatabase db, {
  required String id,
  String? title,
  Map<String, dynamic>? data,
}) async {
  // Resolve a stale `local:` id to the server id BEFORE locking so the lock,
  // write, and read-back all key on the row the DAO actually mutates.
  final resolvedId = await db.notesDao.resolveNoteRemapTarget(id);

  final noteLocks = ref.read(noteLocksProvider);
  await noteLocks.runExclusive(resolvedId, () async {
    // Merge a partial `data` patch onto the existing note data so an update that
    // only carries `content` doesn't silently drop `versions`/`files` (the patch
    // becomes the note's whole data, locally and on the next server push). The
    // patch's sub-objects (content, and files when provided) override; everything
    // else (versions, etc.) is preserved. The read+merge runs INSIDE the lock so
    // a concurrent pull/merge (which takes the same note lock) can't change the
    // row between the read and the write and invalidate the merge baseline.
    Map<String, dynamic>? mergedData;
    if (data != null) {
      final existingRow = await db.notesDao.getNote(resolvedId);
      final existing = existingRow == null
          ? const <String, dynamic>{}
          : decodeNoteData(existingRow.data);
      mergedData = <String, dynamic>{...existing, ...data};
    }

    await db.notesDao.updateNoteWithOutbox(
      resolvedId,
      title: title == null ? const Value<String>.absent() : Value(title),
      data: mergedData == null
          ? const Value<String>.absent()
          : Value(jsonEncode(mergedData)),
      localUpdatedAtNs: _localNoteNowNs(),
      enqueue: true,
    );
  });
  return _readBackThenDrainNote(ref, db, resolvedId);
}

/// Durable pin toggle. Returns the stored note (from the just-written row) or
/// `null` if the row no longer exists.
Future<Note?> durablePinNote(
  dynamic ref,
  AppDatabase db, {
  required String id,
  required bool desiredPinned,
}) async {
  final resolvedId = await db.notesDao.resolveNoteRemapTarget(id);
  final noteLocks = ref.read(noteLocksProvider);
  await noteLocks.runExclusive(resolvedId, () async {
    await db.notesDao.pinNoteWithOutbox(
      resolvedId,
      desiredPinned: desiredPinned,
    );
  });
  return _readBackThenDrainNote(ref, db, resolvedId);
}

/// Durable delete (tombstone + `noteDelete` op).
Future<void> durableDeleteNote(
  dynamic ref,
  AppDatabase db, {
  required String id,
}) async {
  final resolvedId = await db.notesDao.resolveNoteRemapTarget(id);
  final noteLocks = ref.read(noteLocksProvider);
  await noteLocks.runExclusive(resolvedId, () async {
    await db.notesDao.tombstoneWithOutbox(resolvedId);
  });
  unawaited(_drainNotes(ref));
}

/// Durable offline create: inserts a `local:<uuid>` row + `noteCreate` op. The
/// `rawExtra.user_id` is stamped so the row matches the owner predicate used by
/// [NotesDao.watchNotes]/[NotesDao.getNoteForUser]. Returns the stored note.
Future<Note?> durableCreateNote(
  dynamic ref,
  AppDatabase db, {
  required String? userId,
  required String title,
  required Map<String, dynamic> data,
}) async {
  final localId = 'local:${const Uuid().v4()}';
  final nowNs = _localNoteNowNs();
  final rawExtra = (userId == null || userId.isEmpty)
      ? '{}'
      : jsonEncode(<String, dynamic>{'user_id': userId});
  final companion = NotesCompanion.insert(
    id: localId,
    title: title,
    data: Value(jsonEncode(data)),
    createdAt: nowNs,
    updatedAt: nowNs,
    rawExtra: Value(rawExtra),
  );
  final noteLocks = ref.read(noteLocksProvider);
  await noteLocks.runExclusive(localId, () async {
    await db.notesDao.insertLocalNoteWithCreateOp(note: companion);
  });
  return _readBackThenDrainNote(ref, db, localId);
}

/// Provider for the list of all notes with user information.
@Riverpod(keepAlive: true)
class NotesList extends _$NotesList {
  StreamSubscription<List<NoteListEntry>>? _notesSubscription;

  @override
  Future<List<Note>> build() async {
    _registerDispose();

    if (!ref.watch(isAuthenticatedProvider2)) {
      await _cancelLocalWatch();
      return const <Note>[];
    }

    final db = ref.watch(appDatabaseProvider);
    if (db != null) {
      final userId = ref.watch(currentUserProvider2)?.id;
      if (userId == null || userId.isEmpty) {
        await _cancelLocalWatch();
        return const <Note>[];
      }
      return _watchLocalNotes(db, userId: userId);
    }

    return _loadFromApi();
  }

  Future<List<Note>> _loadFromApi({List<Note>? staleFallback}) async {
    final api = ref.read(apiServiceProvider);
    final db = ref.read(appDatabaseProvider);
    if (api == null) return const <Note>[];
    final (rawNotes, featureEnabled) = await api.getNotes();

    if (!ref.mounted) {
      return staleFallback ?? const <Note>[];
    }
    if (!_isCurrentNoteSession(ref, api: api, db: db)) {
      return staleFallback ?? state.value ?? const <Note>[];
    }

    ref.read(notesFeatureEnabledProvider.notifier).setEnabled(featureEnabled);

    return _sortNotes(rawNotes.map((json) => Note.fromJson(json)));
  }

  Future<List<Note>> _watchLocalNotes(
    AppDatabase db, {
    required String userId,
  }) async {
    // Always tear down any prior watch and re-subscribe: the dispose callback
    // (run before every recompute) cancels the subscription, so a fresh one is
    // required on each build.
    await _cancelLocalWatch();

    final completer = Completer<List<Note>>();
    _notesSubscription = db.notesDao
        .watchNotes(userId: userId)
        .listen(
          (entries) {
            final notes = _sortNotes(entries.map(_noteFromListEntry));
            if (!completer.isCompleted) {
              completer.complete(notes);
              return;
            }
            if (ref.mounted) {
              state = AsyncValue.data(notes);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'watch-failed',
              scope: 'notes',
              error: error,
              stackTrace: stackTrace,
            );
            if (!completer.isCompleted) {
              completer.complete(const <Note>[]);
            } else if (ref.mounted) {
              state = AsyncValue.error(error, stackTrace);
            }
          },
        );

    return completer.future;
  }

  void _registerDispose() {
    // Registered on every build. Riverpod runs (and clears) onDispose
    // callbacks before each recompute, so this keeps exactly one live
    // cleanup tied to the current build and ensures the Drift watch
    // subscription is cancelled on every recompute and on final disposal.
    ref.onDispose(() {
      unawaited(_notesSubscription?.cancel());
      _notesSubscription = null;
    });
  }

  Future<void> _cancelLocalWatch() async {
    await _notesSubscription?.cancel();
    _notesSubscription = null;
  }

  /// Refresh the notes list from the server.
  Future<void> refresh() async {
    if (ref.read(appDatabaseProvider) != null) {
      try {
        await ref
            .read(syncEngineProvider.notifier)
            .requestPull(reason: 'notes-refresh');
      } catch (error, stackTrace) {
        DebugLogger.error(
          'refresh-failed',
          scope: 'notes',
          error: error,
          stackTrace: stackTrace,
        );
      }
      return;
    }

    final previousNotes = state.value;
    state = const AsyncValue<List<Note>>.loading();
    final result = await AsyncValue.guard(
      () => _loadFromApi(staleFallback: previousNotes),
    );
    if (ref.mounted) {
      state = result;
    }
  }

  /// Add a newly created note to the list.
  void addNote(Note note, {AppDatabase? sourceDb}) {
    final current = state.value ?? [];
    state = AsyncValue.data(_sortNotes([note, ...current]));
    _persistServerNote(note, sourceDb: sourceDb);
  }

  /// Update an existing note in the list.
  void updateNote(Note updatedNote, {AppDatabase? sourceDb}) {
    final current = state.value ?? [];
    final updated = current.map((n) {
      return n.id == updatedNote.id ? updatedNote : n;
    }).toList();
    state = AsyncValue.data(_sortNotes(updated));
    _persistServerNote(updatedNote, sourceDb: sourceDb);
  }

  /// Remove a note from the list.
  void removeNote(String noteId, {AppDatabase? sourceDb}) {
    final current = state.value ?? [];
    final updated = current.where((n) => n.id != noteId).toList();
    state = AsyncValue.data(_sortNotes(updated));
    final db = sourceDb;
    if (db == null) return;
    if (!_isCurrentDatabase(ref, db)) return;
    unawaited(
      db.notesDao.purgeReconciledNote(noteId).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        DebugLogger.error(
          'row-delete-failed',
          scope: 'notes',
          error: error,
          stackTrace: stackTrace,
          data: {'id': noteId},
        );
      }),
    );
  }

  void _persistServerNote(Note note, {AppDatabase? sourceDb}) {
    final db = sourceDb;
    if (db == null) return;
    if (!_isCurrentDatabase(ref, db)) return;
    unawaited(_persistServerNoteRow(db, note.toJson(), noteId: note.id));
  }
}

/// Provider for a single note by ID.
@Riverpod(keepAlive: true)
Future<Note?> noteById(Ref ref, String id) async {
  if (!ref.watch(isAuthenticatedProvider2)) {
    return null;
  }

  // Read every provider dependency up-front, before the first await. Calling
  // ref.watch after an await is a Riverpod anti-pattern (the dependency may not
  // be registered and can throw on newer SDK versions).
  final db = ref.watch(appDatabaseProvider);
  final userId = ref.watch(currentUserProvider2)?.id;
  final api = ref.watch(apiServiceProvider);
  final isOnline = ref.watch(isOnlineProvider);

  Note? cachedNote;
  if (db != null) {
    final row = userId == null || userId.isEmpty
        ? null
        : await db.notesDao.getNoteForUser(id, userId: userId);
    if (row != null && !row.deleted) {
      cachedNote = _noteFromRow(row);
    }
  }

  if (api == null) return cachedNote;
  if (!isOnline) return cachedNote;

  try {
    final json = await api.getNoteById(id);
    if (!ref.mounted) return null;
    if (!_isCurrentNoteSession(ref, api: api, db: db)) {
      return null;
    }
    final note = Note.fromJson(json);
    if (db != null) {
      await _persistServerNoteRow(db, json, noteId: id);
    }
    return note;
  } catch (error) {
    if (cachedNote != null && _canUseCachedNoteAfterDetailError(error)) {
      // `cachedNote` was read before the await; if the session switched during
      // the failed detail fetch, don't leak a note from the previous account
      // into the new session.
      if (!ref.mounted || !_isCurrentNoteSession(ref, api: api, db: db)) {
        return null;
      }
      DebugLogger.warning(
        'detail-refresh-failed-using-cache',
        scope: 'notes',
        data: {'id': id, 'errorType': error.runtimeType.toString()},
      );
      return cachedNote;
    }
    rethrow;
  }
}

/// Helper to group notes by time range.
enum TimeRange {
  today,
  yesterday,
  previousSevenDays,
  previousThirtyDays,
  older,
}

/// Determine which time range a timestamp belongs to.
/// Uses `!isBefore` instead of `isAfter` to include boundary timestamps
/// (e.g., exactly midnight) in the correct range.
TimeRange getTimeRangeForTimestamp(DateTime timestamp) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final sevenDaysAgo = today.subtract(const Duration(days: 7));
  final thirtyDaysAgo = today.subtract(const Duration(days: 30));

  if (!timestamp.isBefore(today)) {
    return TimeRange.today;
  } else if (!timestamp.isBefore(yesterday)) {
    return TimeRange.yesterday;
  } else if (!timestamp.isBefore(sevenDaysAgo)) {
    return TimeRange.previousSevenDays;
  } else if (!timestamp.isBefore(thirtyDaysAgo)) {
    return TimeRange.previousThirtyDays;
  } else {
    return TimeRange.older;
  }
}

/// Provider that returns notes grouped by time range.
@Riverpod(keepAlive: true)
Map<TimeRange, List<Note>> notesGroupedByTime(Ref ref) {
  final notesAsync = ref.watch(notesListProvider);
  final notes = notesAsync.value ?? [];

  final grouped = <TimeRange, List<Note>>{};

  for (final note in notes) {
    final range = getTimeRangeForTimestamp(note.updatedDateTime);
    grouped.putIfAbsent(range, () => []).add(note);
  }

  return grouped;
}

/// Provider for notes filtered by search query.
List<Note> filterNotesByQuery(List<Note> notes, String query) {
  if (query.isEmpty) return notes;

  final lowerQuery = query.toLowerCase();
  return notes.where((note) {
    final titleMatch = note.title.toLowerCase().contains(lowerQuery);
    final contentMatch = note.listPreviewMarkdown.toLowerCase().contains(
      lowerQuery,
    );
    return titleMatch || contentMatch;
  }).toList();
}

Future<List<Note>> _searchCachedNotes(
  AppDatabase db,
  String query, {
  required String userId,
}) async {
  try {
    final rows = await db.notesDao.searchNotesByQuery(query, userId: userId);
    return _sortNotes(rows.map(_noteFromRow));
  } catch (error, stackTrace) {
    DebugLogger.error(
      'search-failed',
      scope: 'notes',
      error: error,
      stackTrace: stackTrace,
    );
    return const <Note>[];
  }
}

/// Provider for notes filtered by search query.
@Riverpod(keepAlive: true)
Future<List<Note>> filteredNotes(Ref ref, String query) async {
  final trimmedQuery = query.trim();
  if (trimmedQuery.isEmpty) {
    return ref.watch(notesListProvider.future);
  }

  final db = ref.watch(appDatabaseProvider);
  final notesAsync = ref.watch(notesListProvider);
  if (db != null) {
    final userId = ref.watch(currentUserProvider2)?.id;
    if (userId != null && userId.isNotEmpty) {
      final cachedMatches = await _searchCachedNotes(
        db,
        trimmedQuery,
        userId: userId,
      );
      if (cachedMatches.isNotEmpty) {
        return cachedMatches;
      }
    }
  }

  if (notesAsync.hasValue) {
    return filterNotesByQuery(notesAsync.requireValue, trimmedQuery);
  }

  final notes = await ref.watch(notesListProvider.future);
  return filterNotesByQuery(notes, trimmedQuery);
}

/// Provider for creating a new note.
@Riverpod(keepAlive: true)
class NoteCreator extends _$NoteCreator {
  @override
  AsyncValue<Note?> build() => const AsyncValue.data(null);

  /// Create a new note and return it.
  Future<Note?> createNote({
    required String title,
    String? markdownContent,
    String? htmlContent,
  }) async {
    state = const AsyncValue.loading();

    final api = ref.read(apiServiceProvider);
    final db = ref.read(appDatabaseProvider);

    final data = <String, dynamic>{
      'content': <String, dynamic>{
        'json': null,
        'html': htmlContent ?? '',
        'md': markdownContent ?? '',
      },
      'versions': <dynamic>[],
      'files': null,
    };

    // Offline with a durable backend: create a local note + `noteCreate` op so
    // the edit survives until connectivity returns. Online (or reviewer mode
    // without a database) keeps the API-first path so the editor opens on the
    // server id with no local→server remap underneath it.
    if (db != null && !ref.read(isOnlineProvider)) {
      try {
        final userId = ref.read(currentUserProvider2)?.id;
        final note = await durableCreateNote(
          ref,
          db,
          userId: userId,
          title: title,
          data: data,
        );
        if (!ref.mounted) return null;
        // The session may have switched during the durable await; don't publish
        // a note from the previous database into the new session.
        if (!_isCurrentNoteSession(ref, api: api, db: db)) {
          state = const AsyncValue.data(null);
          return null;
        }
        state = AsyncValue.data(note);
        return note;
      } catch (e, st) {
        if (!ref.mounted) return null;
        state = AsyncValue.error(e, st);
        return null;
      }
    }

    if (api == null) {
      if (!ref.mounted) return null;
      state = AsyncValue.error(
        Exception('API service not available'),
        StackTrace.current,
      );
      return null;
    }

    try {
      final json = await api.createNote(
        title: title,
        data: data,
        accessControl: <String, dynamic>{},
      );

      if (!ref.mounted) return null;
      if (!_isCurrentNoteSession(ref, api: api, db: db)) {
        state = const AsyncValue.data(null);
        return null;
      }

      final note = Note.fromJson(json);

      // Add to the notes list
      ref.read(notesListProvider.notifier).addNote(note, sourceDb: db);

      state = AsyncValue.data(note);
      return note;
    } catch (e, st) {
      if (!ref.mounted) return null;
      state = AsyncValue.error(e, st);
      return null;
    }
  }
}

/// Provider for updating an existing note.
@Riverpod(keepAlive: true)
class NoteUpdater extends _$NoteUpdater {
  @override
  AsyncValue<Note?> build() => const AsyncValue.data(null);

  /// Update a note with new content.
  Future<Note?> updateNote(
    String id, {
    String? title,
    String? markdownContent,
    String? htmlContent,
    Object? jsonContent,
  }) async {
    state = const AsyncValue.loading();

    final api = ref.read(apiServiceProvider);
    final db = ref.read(appDatabaseProvider);

    // A content-only patch: the durable path (durableUpdateNote) merges this
    // onto the note's existing data, so `versions`/`files` are preserved rather
    // than dropped. (The reviewer/no-db API path below has no local data to
    // merge from; reviewer mode is ephemeral and carries no attachments.)
    Map<String, dynamic>? data;
    if (markdownContent != null || htmlContent != null || jsonContent != null) {
      data = <String, dynamic>{
        'content': <String, dynamic>{
          'json': jsonContent,
          'html': htmlContent ?? '',
          'md': markdownContent ?? '',
        },
      };
    }

    // Durable backend: write the row + `noteUpdate` op transactionally so an
    // offline edit is never lost; the list updates from the watch stream.
    if (db != null) {
      try {
        final note = await durableUpdateNote(
          ref,
          db,
          id: id,
          title: title,
          data: data,
        );
        if (!ref.mounted) return null;
        // The session may have switched during the durable await; don't publish
        // a note from the previous database into the new session.
        if (!_isCurrentNoteSession(ref, api: api, db: db)) {
          state = const AsyncValue.data(null);
          return null;
        }
        state = AsyncValue.data(note);
        return note;
      } catch (e, st) {
        if (!ref.mounted) return null;
        state = AsyncValue.error(e, st);
        return null;
      }
    }

    if (api == null) {
      if (!ref.mounted) return null;
      state = AsyncValue.error(
        Exception('API service not available'),
        StackTrace.current,
      );
      return null;
    }

    try {
      final json = await api.updateNote(id, title: title, data: data);

      if (!ref.mounted) return null;
      if (!_isCurrentNoteSession(ref, api: api, db: db)) {
        state = const AsyncValue.data(null);
        return null;
      }

      final note = Note.fromJson(json);

      // Update in the notes list
      ref.read(notesListProvider.notifier).updateNote(note, sourceDb: db);

      state = AsyncValue.data(note);
      return note;
    } catch (e, st) {
      if (!ref.mounted) return null;
      state = AsyncValue.error(e, st);
      return null;
    }
  }
}

/// Provider for toggling a note's pinned state.
@Riverpod(keepAlive: true)
class NotePinToggler extends _$NotePinToggler {
  @override
  AsyncValue<Note?> build() => const AsyncValue.data(null);

  Future<Note?> togglePin(Note note) async {
    state = const AsyncValue.loading();

    final api = ref.read(apiServiceProvider);
    final db = ref.read(appDatabaseProvider);

    // Durable backend: write the pin axis + `notePin` op transactionally so an
    // offline toggle is never lost; the list updates from the watch stream.
    if (db != null) {
      try {
        final updatedNote = await durablePinNote(
          ref,
          db,
          id: note.id,
          desiredPinned: !note.isPinned,
        );
        if (!ref.mounted) return null;
        // The session may have switched during the durable await; don't publish
        // a note from the previous database into the new session.
        if (!_isCurrentNoteSession(ref, api: api, db: db)) {
          state = const AsyncValue.data(null);
          return null;
        }
        if (updatedNote != null) {
          final activeNote = ref.read(activeNoteProvider);
          if (activeNote?.id == updatedNote.id) {
            ref.read(activeNoteProvider.notifier).set(updatedNote);
          }
        }
        state = AsyncValue.data(updatedNote);
        return updatedNote;
      } catch (e, st) {
        if (!ref.mounted) return null;
        state = AsyncValue.error(e, st);
        return null;
      }
    }

    if (api == null) {
      if (!ref.mounted) return null;
      state = AsyncValue.error(
        Exception('API service not available'),
        StackTrace.current,
      );
      return null;
    }

    try {
      final json = await api.toggleNotePinned(note.id);
      if (!ref.mounted) return null;
      if (!_isCurrentNoteSession(ref, api: api, db: db)) {
        state = const AsyncValue.data(null);
        return null;
      }

      final updatedNote = Note.fromJson(json);
      ref.read(notesListProvider.notifier).updateNote(updatedNote);
      if (db != null) {
        await db.notesDao.storeNotePinMirror(
          updatedNote.id,
          isPinned: updatedNote.isPinned,
        );
      }

      final activeNote = ref.read(activeNoteProvider);
      if (activeNote?.id == updatedNote.id) {
        ref.read(activeNoteProvider.notifier).set(updatedNote);
      }

      ref.invalidate(noteByIdProvider(updatedNote.id));
      state = AsyncValue.data(updatedNote);
      return updatedNote;
    } catch (e, st) {
      if (!ref.mounted) return null;
      state = AsyncValue.error(e, st);
      return null;
    }
  }
}

/// Provider for deleting a note.
@Riverpod(keepAlive: true)
class NoteDeleter extends _$NoteDeleter {
  @override
  AsyncValue<bool> build() => const AsyncValue.data(false);

  /// Delete a note by ID.
  Future<bool> deleteNote(String id) async {
    state = const AsyncValue.loading();

    final api = ref.read(apiServiceProvider);
    final db = ref.read(appDatabaseProvider);

    // Durable backend: tombstone the row + enqueue a `noteDelete` op
    // transactionally so an offline delete is never lost; the list drops the
    // note from the watch stream (WHERE deleted = 0).
    if (db != null) {
      try {
        await durableDeleteNote(ref, db, id: id);
        if (!ref.mounted) return false;
        // The session may have switched during the durable await; don't report
        // success into the new session (the editor caller navigates away on it).
        if (!_isCurrentNoteSession(ref, api: api, db: db)) {
          state = const AsyncValue.data(false);
          return false;
        }
        state = const AsyncValue.data(true);
        return true;
      } catch (e, st) {
        if (!ref.mounted) return false;
        state = AsyncValue.error(e, st);
        return false;
      }
    }

    if (api == null) {
      if (!ref.mounted) return false;
      state = AsyncValue.error(
        Exception('API service not available'),
        StackTrace.current,
      );
      return false;
    }

    try {
      final success = await api.deleteNote(id);

      if (!ref.mounted) return false;
      if (!_isCurrentNoteSession(ref, api: api, db: db)) {
        state = const AsyncValue.data(false);
        return false;
      }

      if (success) {
        // Remove from the notes list
        ref.read(notesListProvider.notifier).removeNote(id, sourceDb: db);
      }

      state = AsyncValue.data(success);
      return success;
    } catch (e, st) {
      if (!ref.mounted) return false;
      state = AsyncValue.error(e, st);
      return false;
    }
  }
}

/// Provider for the currently active/selected note.
@Riverpod(keepAlive: true)
class ActiveNote extends _$ActiveNote {
  @override
  Note? build() => null;

  void set(Note? note) => state = note;

  void clear() => state = null;
}
