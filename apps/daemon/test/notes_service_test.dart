@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

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
import 'package:conduitd/src/daemon_paths.dart';
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
    // Holds the account's sharing rights read (`_access`) while set.
    Completer<void>? rights;
    // Told when that read has begun (the read is then waiting on [rights]).
    Completer<void>? rightsAsked;

    setUp(() async {
      // Two accounts, two databases, as the app keeps them.
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      first = AppDatabase(NativeDatabase.memory());
      second = AppDatabase(NativeDatabase.memory());
      active = first;
      rights = null;
      rightsAsked = null;
      PreferencesStore.debugOverride(InMemoryKeyValueStore());
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-a');
      container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => active),
          notesListProvider.overrideWith(_NoNotes.new),
          currentUserProvider2.overrideWithValue(null),
          workspaceCapabilitiesProvider.overrideWith((ref) async {
            if (rightsAsked case final asked? when !asked.isCompleted) {
              asked.complete();
            }
            await rights?.future;
            throw StateError('offline');
          }),
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

    test('refuses a save or new note meant for another account', () async {
      await first
          .into(first.notes)
          .insert(
            serverToNoteRow(<String, dynamic>{
              'id': 'tide-table',
              'title': 'Tide table',
              'data': <String, dynamic>{
                'content': <String, dynamic>{'md': 'Low at noon'},
              },
              'created_at': 1,
              'updated_at': 1,
            }).copyWith(dirtyData: const Value(true)),
          );
      final notes = NotesService(container);
      expect((await notes.get('tide-table'))?.summary.title, 'Tide table');
      final refused = throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      );
      const typed = <Map<String, dynamic>>[
        <String, dynamic>{'insert': 'Low at one\n'},
      ];
      // The editor's account is B; conduitd is on A.
      await expectLater(
        notes.save(
          const NoteSave(
            id: 'tide-table',
            title: 'Tide table',
            ops: typed,
            accountId: 'server-b',
          ),
        ),
        refused,
      );
      await expectLater(
        notes.save(
          const NoteSave(
            title: 'Tide table, mine',
            ops: typed,
            accountId: 'server-b',
          ),
        ),
        refused,
      );
      final rows = await first.select(first.notes).get();
      expect(rows.map((r) => r.id), <String>['tide-table']);
      expect(rows.single.data, contains('Low at noon'));
    });

    test('refuses a note read under one account once another is active', () async {
      await first
          .into(first.notes)
          .insert(
            serverToNoteRow(<String, dynamic>{
              'id': 'ridge-notes',
              'title': 'Ridge notes',
              'data': <String, dynamic>{
                'content': <String, dynamic>{'md': 'Cairns'},
              },
              'created_at': 1,
              'updated_at': 1,
            }).copyWith(dirtyData: const Value(true)),
          );
      final notes = NotesService(container);
      // The read waits on the account's rights; account B becomes active
      // meanwhile.
      rights = Completer<void>();
      rightsAsked = Completer<void>();
      container.invalidate(workspaceCapabilitiesProvider);
      final reading = notes.get('ridge-notes');
      await rightsAsked!.future;
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-b');
      active = second;
      container.invalidate(appDatabaseProvider);
      rights!.complete();
      await expectLater(
        reading,
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.sessionExpired,
          ),
        ),
      );

      // Save as My Own Note begun under A: made under no other account.
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-a');
      active = first;
      container.invalidate(appDatabaseProvider);
      rights = Completer<void>();
      rightsAsked = Completer<void>();
      container.invalidate(workspaceCapabilitiesProvider);
      final making = notes.save(
        const NoteSave(
          title: 'Ridge notes, mine',
          ops: <Map<String, dynamic>>[
            <String, dynamic>{'insert': 'Cairns\n'},
          ],
        ),
      );
      await rightsAsked!.future;
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-b');
      active = second;
      container.invalidate(appDatabaseProvider);
      rights!.complete();
      await expectLater(
        making,
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.sessionExpired,
          ),
        ),
      );
      expect(await second.select(second.notes).get(), isEmpty);
    });

    test('lists or removes no recording of a note opened under the last account', () async {
      await first
          .into(first.notes)
          .insert(
            serverToNoteRow(<String, dynamic>{
              'id': 'kiln-log',
              'title': 'Kiln log',
              'data': <String, dynamic>{
                'content': <String, dynamic>{'md': 'Cone 6, slow cool'},
              },
              'created_at': 1,
              'updated_at': 1,
            }).copyWith(dirtyData: const Value(true)),
          );
      final dir = await Directory.systemTemp.createTemp('conduit-notes-rec-');
      addTearDown(() => dir.delete(recursive: true));
      final notes = NotesService(
        container,
        paths: DaemonDirectories.create(dir.path),
      );
      addTearDown(notes.dispose);
      expect((await notes.get('kiln-log'))?.summary.title, 'Kiln log');
      // A's editor takes a recording off the note: the note's recorder is
      // made under A.
      await notes.removeRecording(
        const NoteRecordingRef(noteId: 'kiln-log', id: 'take-0'),
      );

      // Account B becomes active; the recorder is still A's.
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-b');
      active = second;
      container.invalidate(appDatabaseProvider);
      final refused = throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      );
      await expectLater(notes.recordings('kiln-log'), refused);
      await expectLater(
        notes.removeRecording(
          const NoteRecordingRef(noteId: 'kiln-log', id: 'take-1'),
        ),
        refused,
      );
    });
  });
}
