import 'package:checks/checks.dart';
import 'package:conduit/core/models/note.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/notes/providers/notes_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NotesList', () {
    test(
      're-sorts notes when an updated note gets a newer timestamp',
      () async {
        final olderNote = _buildNote(
          id: 'note-1',
          title: 'Older',
          updatedAt: 1713786305000000000,
        );
        final newerNote = _buildNote(
          id: 'note-2',
          title: 'Newer',
          updatedAt: 1713872705000000000,
        );

        final container = ProviderContainer(
          overrides: [
            notesListProvider.overrideWith(
              () => _TestNotesList([newerNote, olderNote]),
            ),
          ],
        );
        addTearDown(container.dispose);

        await container.read(notesListProvider.future);

        container
            .read(notesListProvider.notifier)
            .updateNote(
              olderNote.copyWith(
                isPinned: true,
                updatedAt: 1713959105000000000,
              ),
            );

        final notes = container.read(notesListProvider).requireValue;
        check(
          notes.map((note) => note.id).toList(),
        ).deepEquals(['note-1', 'note-2']);
        check(notes.first.isPinned).isTrue();
      },
    );
  });

  group('NotePinToggler', () {
    test(
      'keeps the async toggle alive long enough to update shared note state',
      () async {
        final originalNote = _buildNote(
          id: 'note-1',
          title: 'Pinned later',
          updatedAt: 1713786305000000000,
        );
        final toggledNote = originalNote.copyWith(
          isPinned: true,
          updatedAt: 1713872705000000000,
        );
        final api = _FakeNotesApiService(toggledNote: toggledNote);

        final container = ProviderContainer(
          overrides: [
            apiServiceProvider.overrideWithValue(api),
            notesListProvider.overrideWith(
              () => _TestNotesList([originalNote]),
            ),
          ],
        );
        addTearDown(container.dispose);

        await container.read(notesListProvider.future);
        final activeNoteSubscription = container.listen<Note?>(
          activeNoteProvider,
          (previous, next) {},
          fireImmediately: true,
        );
        addTearDown(activeNoteSubscription.close);
        container.read(activeNoteProvider.notifier).set(originalNote);

        final toggleFuture = container
            .read(notePinTogglerProvider.notifier)
            .togglePin(originalNote);

        await Future<void>.delayed(Duration.zero);

        final updatedNote = await toggleFuture;
        final resolvedNote = updatedNote ?? (throw StateError('toggle failed'));

        check(resolvedNote.isPinned).isTrue();
        check(api.toggledIds).deepEquals(['note-1']);
        check(
          container.read(notesListProvider).requireValue.first,
        ).has((it) => it.isPinned, 'isPinned').isTrue();
        check(
          container.read(activeNoteProvider),
        ).isNotNull().has((it) => it.isPinned, 'isPinned').isTrue();
        check(
          container.read(notePinTogglerProvider).requireValue,
        ).isNotNull().has((it) => it.isPinned, 'isPinned').isTrue();
      },
    );
  });
}

class _TestNotesList extends NotesList {
  _TestNotesList(this._notes);

  final List<Note> _notes;

  @override
  Future<List<Note>> build() async => _notes;
}

class _FakeNotesApiService extends ApiService {
  _FakeNotesApiService({required this.toggledNote})
    : super(
        serverConfig: const ServerConfig(
          id: 'test',
          name: 'Test',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  final Note toggledNote;
  final toggledIds = <String>[];

  @override
  Future<Map<String, dynamic>> toggleNotePinned(String id) async {
    toggledIds.add(id);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return toggledNote.toJson();
  }
}

Note _buildNote({
  required String id,
  required String title,
  required int updatedAt,
  bool isPinned = false,
}) {
  return Note.fromJson({
    'id': id,
    'user_id': 'user-1',
    'title': title,
    'is_pinned': isPinned,
    'data': {
      'content': {'md': title, 'html': '<p>$title</p>', 'json': null},
    },
    'created_at': 1713786305000000000,
    'updated_at': updatedAt,
  });
}
