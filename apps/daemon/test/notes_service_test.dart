@TestOn('vm')
library;

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/note_mapper.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/notes/providers/notes_providers.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/models/note.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/src/notes_service.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// The list, settled at once: nothing here reads the server.
final class _NoNotes extends NotesList {
  @override
  Future<List<Note>> build() async => const <Note>[];
}

void main() {
  group('an account switch', () {
    late AppDatabase first;
    late AppDatabase second;
    late AppDatabase? active;
    late ProviderContainer container;

    setUp(() async {
      // Two accounts, two databases, as the app keeps them.
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      first = AppDatabase(NativeDatabase.memory());
      second = AppDatabase(NativeDatabase.memory());
      active = first;
      PreferencesStore.debugOverride(InMemoryKeyValueStore());
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-a');
      container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => active),
          notesListProvider.overrideWith(_NoNotes.new),
          currentUserProvider2.overrideWithValue(null),
          workspaceCapabilitiesProvider.overrideWith(
            (ref) async => throw StateError('offline'),
          ),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await first.close();
      await second.close();
      PreferencesStore.debugReset();
    });

    test('keeps a note opened under one account out of the next', () async {
      // An edit of account A's note still waiting for its outbox: opened
      // from this computer's copy.
      await first
          .into(first.notes)
          .insert(
            serverToNoteRow(<String, dynamic>{
              'id': 'trail-log',
              'title': 'Trail log',
              'data': <String, dynamic>{
                'content': <String, dynamic>{'md': 'Ridge at dawn'},
              },
              'created_at': 1,
              'updated_at': 1,
            }).copyWith(dirtyData: const Value(true)),
          );
      final notes = NotesService(container);
      expect((await notes.get('trail-log'))?.summary.title, 'Trail log');

      // Account B becomes active; A's editor saves the note after it.
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-b');
      active = second;
      container.invalidate(appDatabaseProvider);
      await expectLater(
        notes.save(
          const NoteSave(
            id: 'trail-log',
            title: 'Trail log',
            ops: <Map<String, dynamic>>[
              <String, dynamic>{'insert': 'Ridge at dawn, then rain\n'},
            ],
          ),
        ),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.sessionExpired,
          ),
        ),
      );
      expect(await second.select(second.notes).get(), isEmpty);

      // Nor does a recording made for it go to the next account.
      await expectLater(
        notes.addRecording(
          const NoteRecordingAdd(noteId: 'trail-log', path: '/tmp/take.wav'),
        ),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.sessionExpired,
          ),
        ),
      );

      final refused = throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      );
      const typed = <Map<String, dynamic>>[
        <String, dynamic>{'insert': 'Ridge at dawn, then rain\n'},
      ];
      // A rename goes nowhere either.
      await expectLater(
        notes.save(const NoteSave(id: 'trail-log', title: 'Trail log, ridge')),
        refused,
      );
      // Nor does the text into a note of account B's with the same id.
      await second
          .into(second.notes)
          .insert(
            serverToNoteRow(<String, dynamic>{
              'id': 'trail-log',
              'title': 'B log',
              'data': <String, dynamic>{
                'content': <String, dynamic>{'md': 'B text'},
              },
              'created_at': 1,
              'updated_at': 1,
            }),
          );
      await expectLater(
        notes.save(
          const NoteSave(id: 'trail-log', title: 'Trail log', ops: typed),
        ),
        refused,
      );
      final kept = await second.notesDao.getNote('trail-log');
      expect(kept?.title, 'B log');
      expect(kept?.data, contains('B text'));
      // Nor, with no database at all, through the core's updater.
      active = null;
      container.invalidate(appDatabaseProvider);
      await expectLater(
        notes.save(
          const NoteSave(id: 'trail-log', title: 'Trail log', ops: typed),
        ),
        refused,
      );
    });
  });
}
