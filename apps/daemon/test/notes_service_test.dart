@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/note_mapper.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/notes/providers/notes_providers.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/models/file_info.dart';
import 'package:conduit_core/models/note.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/paths_port.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart'
    show PrimaryAccountKind;
import 'package:conduit_core/providers/primary_account_providers.dart'
    show PrimaryAccountRef, primaryAccountProvider;
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/src/daemon_paths.dart';
import 'package:conduitd/src/event_bus.dart';
import 'package:conduitd/src/notes_service.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/drift.dart'
    show
        QueryExecutor,
        QueryInterceptor,
        ApplyInterceptor,
        Value,
        driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// The list, settled at once (or once [_listHold] lets it): nothing here
/// reads the server.
final class _NoNotes extends NotesList {
  @override
  Future<List<Note>> build() async {
    await _listHold?.future;
    return const <Note>[];
  }
}

/// Holds the notes list's next read while set.
Completer<void>? _listHold;

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
          // Who is in charge, as the account scope reads it; the switches
          // below move the active account's preference.
          ..._signedIn,
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

      // Nor does a recording made for it go to the next account, nor are
      // its recordings listed or taken off there.
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
      await expectLater(
        notes.recordings('trail-log'),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.sessionExpired,
          ),
        ),
      );
      await expectLater(
        notes.removeRecording(
          const NoteRecordingRef(noteId: 'trail-log', id: 'take-1'),
        ),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.sessionExpired,
          ),
        ),
      );
      // Nor is a recording still waiting played there.
      await expectLater(
        notes.waitingRecording('trail-log', 'take-1'),
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

    test(
      'refuses a note read under one account once another is active',
      () async {
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
      },
    );

    test('writes no save begun under one account into the next one\'s note '
        'of the same id, even once that account has read it', () async {
      Future<void> seed(AppDatabase db, String md) => db
          .into(db.notes)
          .insert(
            serverToNoteRow(<String, dynamic>{
              'id': 'trail-log',
              'title': 'Trail log',
              'data': <String, dynamic>{
                'content': <String, dynamic>{'md': md},
              },
              'created_at': 1,
              'updated_at': 1,
            }).copyWith(dirtyData: const Value(true)),
          );
      await seed(first, 'Ridge at dawn');
      await seed(second, 'B text');
      final notes = NotesService(container);
      expect((await notes.get('trail-log'))?.summary.title, 'Trail log');

      // A's editor saves (naming no account); the save waits for the list.
      _listHold = Completer<void>();
      addTearDown(() => _listHold = null);
      container.invalidate(notesListProvider);
      final saving = notes.save(
        const NoteSave(
          id: 'trail-log',
          title: 'Trail log',
          ops: <Map<String, dynamic>>[
            <String, dynamic>{'insert': 'Ridge at dawn, then rain\n'},
          ],
        ),
      );
      final refused = expectLater(
        saving,
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.sessionExpired,
          ),
        ),
      );
      final held = _listHold!;

      // B becomes active and reads its own note of the same id.
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-b');
      active = second;
      container.invalidate(appDatabaseProvider);
      expect((await notes.get('trail-log'))?.summary.title, 'Trail log');

      held.complete();
      await refused;
      final kept = await second.notesDao.getNote('trail-log');
      expect(kept?.data, contains('B text'));
      expect(kept?.data, isNot(contains('then rain')));
    });

    test('a recordings request still reading its note when shutdown begins '
        'gets no recorder', () async {
      final gate = _ReadGate();
      final gated = AppDatabase(NativeDatabase.memory().interceptWith(gate));
      addTearDown(gated.close);
      active = gated;
      container.invalidate(appDatabaseProvider);
      final dir = await Directory.systemTemp.createTemp('conduit-notes-rec-');
      addTearDown(() => dir.delete(recursive: true));
      final notes = NotesService(
        container,
        paths: DaemonDirectories.create(dir.path),
      );
      addTearDown(notes.close);
      final release = gate.hold();
      final listing = notes.recordings('kiln-log');
      await gate.asked;
      // Shutdown takes its snapshot of the recorders while the note is read.
      await notes.close();
      release.complete();
      await expectLater(
        listing,
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.daemonUnavailable,
          ),
        ),
      );
    });

    test(
      'lists no recording for a request begun under the last account',
      () async {
        // The daemon restarted under an open editor: it never handed this
        // note out. Its recordings are asked for under A; the note read is
        // slow, and B becomes active meanwhile.
        final gate = _ReadGate();
        final gated = AppDatabase(NativeDatabase.memory().interceptWith(gate));
        addTearDown(gated.close);
        active = gated;
        container.invalidate(appDatabaseProvider);
        final dir = await Directory.systemTemp.createTemp('conduit-notes-rec-');
        addTearDown(() => dir.delete(recursive: true));
        final notes = NotesService(
          container,
          paths: DaemonDirectories.create(dir.path),
        );
        addTearDown(notes.close);
        final release = gate.hold();
        final listing = notes.recordings('kiln-log');
        await gate.asked;
        await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-b');
        active = second;
        container.invalidate(appDatabaseProvider);
        release.complete();
        await expectLater(
          listing,
          throwsA(
            isA<RpcError>().having(
              (e) => e.code,
              'code',
              ConduitErrorCodes.sessionExpired,
            ),
          ),
        );
      },
    );
  });

  test('a recovered note hears of its own recordings', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    addTearDown(PreferencesStore.debugReset);
    await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-a');
    final api = _OfflineApi();
    addTearDown(api.dispose);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        notesListProvider.overrideWith(_NoNotes.new),
        apiServiceProvider.overrideWith((ref) => api),
        isAuthenticatedProvider2.overrideWithValue(true),
        currentUserProvider2.overrideWithValue(_ren),
        ..._signedIn,
        workspaceCapabilitiesProvider.overrideWith(
          (ref) async => throw StateError('offline'),
        ),
      ],
    );
    addTearDown(container.dispose);
    await db
        .into(db.notes)
        .insert(
          serverToNoteRow(<String, dynamic>{
            'id': 'glaze-tests',
            'title': 'Glaze tests',
            'data': <String, dynamic>{
              'content': <String, dynamic>{'md': 'Celadon, thin'},
            },
            'created_at': 1,
            'updated_at': 1,
          }).copyWith(dirtyData: const Value(true)),
        );
    final dir = await Directory.systemTemp.createTemp('conduit-notes-rec-');
    addTearDown(() => dir.delete(recursive: true));
    final events = EventBus();
    final changed = <String?>[];
    events.attach('window', (envelope) {
      if (envelope.event == ConduitEventSpecs.notesChanged.name) {
        changed.add(envelope.payload['noteId'] as String?);
      }
    });
    final notes = NotesService(
      container,
      events: events,
      paths: DaemonDirectories.create(dir.path),
    );
    addTearDown(notes.close);
    expect((await notes.get('glaze-tests'))?.summary.title, 'Glaze tests');
    // The editor's recordings are asked for: the note's recorder is made.
    await notes.removeRecording(
      const NoteRecordingRef(noteId: 'glaze-tests', id: 'take-0'),
    );

    // The note is deleted behind the editor; its next save keeps the text
    // as a new note, and the recorder moves to it.
    await (db.update(db.notes)..where((n) => n.id.equals('glaze-tests'))).write(
      const NotesCompanion(deleted: Value(true)),
    );
    final recovered = await notes.save(
      const NoteSave(
        id: 'glaze-tests',
        title: 'Glaze tests',
        ops: <Map<String, dynamic>>[
          <String, dynamic>{'insert': 'Celadon, thin; shino next\n'},
        ],
      ),
    );
    expect(recovered.recoveredFrom, 'glaze-tests');
    final id = recovered.summary.id;
    expect(id, isNot('glaze-tests'));

    // A recording made in the recovered note: its window is told.
    final take = File('${dir.path}/take.m4a')..writeAsBytesSync(<int>[0, 1, 2]);
    changed.clear();
    final listed = await notes.addRecording(
      NoteRecordingAdd(noteId: id, path: take.path),
    );
    expect(listed.recordings, hasLength(1));
    expect(changed, contains(id));

    // Shut down twice (another caller closing too): the second returns only
    // once the recorders the first waits for have stopped writing.
    var firstDone = false;
    final first = notes.close().then((_) => firstDone = true);
    await notes.close();
    expect(firstDone, isTrue, reason: 'the second close did not wait');
    await first;
  });
  test('a recording kept while another account took charge is not this '
      'request\'s to list', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    addTearDown(PreferencesStore.debugReset);
    await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-a');
    final api = _OfflineApi();
    addTearDown(api.dispose);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        notesListProvider.overrideWith(_NoNotes.new),
        apiServiceProvider.overrideWith((ref) => api),
        isAuthenticatedProvider2.overrideWithValue(true),
        currentUserProvider2.overrideWithValue(_ren),
        ..._signedIn,
        workspaceCapabilitiesProvider.overrideWith(
          (ref) async => throw StateError('offline'),
        ),
      ],
    );
    addTearDown(container.dispose);
    await db
        .into(db.notes)
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
    final paths = _HeldPaths(DaemonDirectories.create(dir.path));
    final notes = NotesService(container, paths: paths);
    addTearDown(notes.close);
    expect((await notes.get('kiln-log'))?.summary.title, 'Kiln log');
    // The note's recorder is made under A, and settles.
    await notes.removeRecording(
      const NoteRecordingRef(noteId: 'kiln-log', id: 'take-0'),
    );
    await pumpEventQueue();

    // A recording is kept; while it is written, B becomes active.
    final take = File('${dir.path}/take.m4a')..writeAsBytesSync([1, 2, 3]);
    final release = paths.hold();
    final adding = notes.addRecording(
      NoteRecordingAdd(noteId: 'kiln-log', path: take.path),
    );
    await paths.asked;
    await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-b');
    release.complete();
    await expectLater(
      adding,
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
    );
  });
}

/// A daemon's directories whose next application-support lookup waits once
/// [hold] is called: [asked] completes as it arrives.
final class _HeldPaths implements PathsPort {
  _HeldPaths(this._inner);

  final PathsPort _inner;
  Completer<void>? _release;
  final Completer<void> _asked = Completer<void>();

  Future<void> get asked => _asked.future;

  Completer<void> hold() => _release = Completer<void>();

  @override
  Future<Directory> applicationSupport() async {
    final release = _release;
    if (release != null) {
      _release = null;
      _asked.complete();
      await release.future;
    }
    return _inner.applicationSupport();
  }

  @override
  Future<Directory> cache() => _inner.cache();

  @override
  Future<Directory> logs() => _inner.logs();

  @override
  Future<Directory> staging() => _inner.staging();
}

const _ren = User(
  id: 'user-ren',
  username: 'ren',
  email: 'ren@example.com',
  name: 'Ren',
  role: 'user',
);

/// A signed-in account whose server cannot be reached: every recording
/// stays waiting.
final class _OfflineApi extends ApiService {
  _OfflineApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'server-a',
          name: 'Studio server',
          url: 'https://studio.invalid',
        ),
        workerManager: WorkerManager(),
      );

  @override
  Future<List<FileInfo>> getUserFilesForSession({
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async => throw StateError('offline');

  @override
  Future<String> uploadFile(
    String filePath,
    String fileName, {
    String? contentType,
    Map<String, dynamic>? metadata,
    CancelToken? cancelToken,
    ApiAuthSnapshot? authSnapshot,
  }) async => throw StateError('offline');
}

/// Holds the next read of a database once [hold] is called: [asked]
/// completes when that read arrives, and it goes on once the returned
/// completer completes.
final class _ReadGate extends QueryInterceptor {
  Completer<void>? _release;
  final Completer<void> _asked = Completer<void>();

  Future<void> get asked => _asked.future;

  Completer<void> hold() => _release = Completer<void>();

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final release = _release;
    if (release != null) {
      _release = null;
      _asked.complete();
      await release.future;
    }
    return executor.runSelect(statement, args);
  }
}

/// The account in charge and its session, for services the account scope
/// checks, without the core's storage behind them.
final _session = Object();
final _signedIn = <Override>[
  primaryAccountProvider.overrideWith(
    (ref) => const PrimaryAccountRef(PrimaryAccountKind.openWebUi, 'server-a'),
  ),
  openWebUiAuthSessionEpochProvider.overrideWith((ref) => _session),
];
