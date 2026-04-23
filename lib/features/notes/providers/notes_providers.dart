import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit/core/models/note.dart';
import 'package:conduit/core/providers/app_providers.dart';

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

/// Provider for the list of all notes with user information.
@Riverpod(keepAlive: true)
class NotesList extends _$NotesList {
  @override
  Future<List<Note>> build() async {
    final api = ref.watch(apiServiceProvider);
    if (api == null) return const <Note>[];

    final (rawNotes, featureEnabled) = await api.getNotes();

    // Update the notes feature enabled state
    ref.read(notesFeatureEnabledProvider.notifier).setEnabled(featureEnabled);

    return _sortNotes(rawNotes.map((json) => Note.fromJson(json)));
  }

  /// Refresh the notes list from the server.
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    final result = await AsyncValue.guard(() => build());
    if (!ref.mounted) return;
    state = result;
  }

  /// Add a newly created note to the list.
  void addNote(Note note) {
    final current = state.value ?? [];
    state = AsyncValue.data(_sortNotes([note, ...current]));
  }

  /// Update an existing note in the list.
  void updateNote(Note updatedNote) {
    final current = state.value ?? [];
    final updated = current.map((n) {
      return n.id == updatedNote.id ? updatedNote : n;
    }).toList();
    state = AsyncValue.data(_sortNotes(updated));
  }

  /// Remove a note from the list.
  void removeNote(String noteId) {
    final current = state.value ?? [];
    final updated = current.where((n) => n.id != noteId).toList();
    state = AsyncValue.data(_sortNotes(updated));
  }
}

/// Provider for a single note by ID.
@riverpod
Future<Note?> noteById(Ref ref, String id) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) return null;

  final json = await api.getNoteById(id);
  return Note.fromJson(json);
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
@riverpod
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
@riverpod
List<Note> filteredNotes(Ref ref, String query) {
  final notesAsync = ref.watch(notesListProvider);
  final notes = notesAsync.value ?? [];

  if (query.isEmpty) return notes;

  final lowerQuery = query.toLowerCase();
  return notes.where((note) {
    final titleMatch = note.title.toLowerCase().contains(lowerQuery);
    final contentMatch = note.markdownContent.toLowerCase().contains(
      lowerQuery,
    );
    return titleMatch || contentMatch;
  }).toList();
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
    if (api == null) {
      if (!ref.mounted) return null;
      state = AsyncValue.error(
        Exception('API service not available'),
        StackTrace.current,
      );
      return null;
    }

    try {
      final data = <String, dynamic>{
        'content': <String, dynamic>{
          'json': null,
          'html': htmlContent ?? '',
          'md': markdownContent ?? '',
        },
        'versions': <dynamic>[],
        'files': null,
      };

      final json = await api.createNote(
        title: title,
        data: data,
        accessControl: <String, dynamic>{},
      );

      if (!ref.mounted) return null;

      final note = Note.fromJson(json);

      // Add to the notes list
      ref.read(notesListProvider.notifier).addNote(note);

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
    if (api == null) {
      if (!ref.mounted) return null;
      state = AsyncValue.error(
        Exception('API service not available'),
        StackTrace.current,
      );
      return null;
    }

    try {
      Map<String, dynamic>? data;
      if (markdownContent != null ||
          htmlContent != null ||
          jsonContent != null) {
        data = <String, dynamic>{
          'content': <String, dynamic>{
            'json': jsonContent,
            'html': htmlContent ?? '',
            'md': markdownContent ?? '',
          },
        };
      }

      final json = await api.updateNote(id, title: title, data: data);

      if (!ref.mounted) return null;

      final note = Note.fromJson(json);

      // Update in the notes list
      ref.read(notesListProvider.notifier).updateNote(note);

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

      final updatedNote = Note.fromJson(json);
      ref.read(notesListProvider.notifier).updateNote(updatedNote);

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

      if (success) {
        // Remove from the notes list
        ref.read(notesListProvider.notifier).removeNote(id);
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
@riverpod
class ActiveNote extends _$ActiveNote {
  @override
  Note? build() => null;

  void set(Note? note) => state = note;

  void clear() => state = null;
}
