import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/database/mappers/note_mapper.dart';
import 'package:conduit/core/models/note.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/connectivity_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/notes/providers/notes_providers.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _testUser = User(
  id: 'user-1',
  username: 'user',
  email: 'user@example.com',
  role: 'user',
);

void main() {
  group('NotesList', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('renders cached Drift notes when the API is unavailable', () async {
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'cached-note',
              'user_id': 'user-1',
              'title': 'Offline note',
              'data': {
                'content': {'md': 'available offline', 'html': ''},
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          apiServiceProvider.overrideWithValue(null),
          isAuthenticatedProvider2.overrideWithValue(true),
          currentUserProvider2.overrideWithValue(_testUser),
        ],
      );
      addTearDown(container.dispose);

      final notes = await container.read(notesListProvider.future);

      check(notes).length.equals(1);
      check(notes.single.id).equals('cached-note');
      check(notes.single.markdownContent).isEmpty();
      check(notes.single.listPreviewMarkdown).equals('available offline');
    });

    test('does not expose cached notes owned by another user', () async {
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'own-note',
              'user_id': 'user-1',
              'title': 'Own note',
              'data': {
                'content': {'md': 'mine needle', 'html': ''},
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'other-note',
              'user_id': 'user-2',
              'title': 'Other note',
              'data': {
                'content': {'md': 'theirs needle', 'html': ''},
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713872705000000000,
            }),
          );

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          apiServiceProvider.overrideWithValue(null),
          isAuthenticatedProvider2.overrideWithValue(true),
          currentUserProvider2.overrideWithValue(_testUser),
        ],
      );
      addTearDown(container.dispose);

      final notes = await container.read(notesListProvider.future);
      final searchResults = await container.read(
        filteredNotesProvider('needle').future,
      );
      final otherNote = await container.read(
        noteByIdProvider('other-note').future,
      );

      check(notes.map((note) => note.id).toList()).deepEquals(['own-note']);
      check(
        searchResults.map((note) => note.id).toList(),
      ).deepEquals(['own-note']);
      check(otherNote).isNull();
    });

    test('uses bounded cached previews for the offline list', () async {
      final longBody = 'x' * 1500;
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'large-note',
              'user_id': 'user-1',
              'title': 'Large note',
              'data': {
                'content': {'md': longBody, 'html': ''},
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          apiServiceProvider.overrideWithValue(null),
          isAuthenticatedProvider2.overrideWithValue(true),
          currentUserProvider2.overrideWithValue(_testUser),
        ],
      );
      addTearDown(container.dispose);

      final notes = await container.read(notesListProvider.future);

      check(notes.single.markdownContent).isEmpty();
      check(
        notes.single.listPreviewMarkdown,
      ).equals(longBody.substring(0, 1000));
    });

    test(
      'searches cached note bodies beyond the bounded list preview',
      () async {
        final longBody = '${'x' * 1200} hidden needle';
        await db
            .into(db.notes)
            .insertOnConflictUpdate(
              serverToNoteRow({
                'id': 'search-note',
                'user_id': 'user-1',
                'title': 'Search note',
                'data': {
                  'content': {'md': longBody, 'html': ''},
                },
                'meta': {},
                'is_pinned': false,
                'created_at': 1713786305000000000,
                'updated_at': 1713786305000000000,
              }),
            );

        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => db),
            apiServiceProvider.overrideWithValue(null),
            isAuthenticatedProvider2.overrideWithValue(true),
            currentUserProvider2.overrideWithValue(_testUser),
          ],
        );
        addTearDown(container.dispose);

        final notes = await container.read(
          filteredNotesProvider('needle').future,
        );

        check(notes).length.equals(1);
        check(notes.single.id).equals('search-note');
        check(notes.single.markdownContent).equals(longBody);
      },
    );

    test('updates cached search results when local notes change', () async {
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'search-note',
              'user_id': 'user-1',
              'title': 'Search note',
              'data': {
                'content': {'md': 'contains needle', 'html': ''},
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          apiServiceProvider.overrideWithValue(null),
          isAuthenticatedProvider2.overrideWithValue(true),
          currentUserProvider2.overrideWithValue(_testUser),
        ],
      );
      addTearDown(container.dispose);

      final provider = filteredNotesProvider('needle');
      final subscription = container.listen<AsyncValue<List<Note>>>(
        provider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      final initial = await container.read(provider.future);
      check(initial).length.equals(1);

      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'search-note',
              'user_id': 'user-1',
              'title': 'Search note',
              'data': {
                'content': {'md': 'no match remains', 'html': ''},
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713872705000000000,
            }),
          );

      await _waitFor(() {
        final state = container.read(provider);
        return state.hasValue && (state.value ?? const <Note>[]).isEmpty;
      });

      check(container.read(provider).requireValue).isEmpty();
    });

    test(
      'loads an individual cached note when the API is unavailable',
      () async {
        await db
            .into(db.notes)
            .insertOnConflictUpdate(
              serverToNoteRow({
                'id': 'cached-note',
                'user_id': 'user-1',
                'title': 'Offline note',
                'data': {
                  'content': {'md': 'editor body', 'html': ''},
                },
                'meta': {},
                'is_pinned': true,
                'created_at': 1713786305000000000,
                'updated_at': 1713786305000000000,
              }),
            );

        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => db),
            apiServiceProvider.overrideWithValue(null),
            isAuthenticatedProvider2.overrideWithValue(true),
            currentUserProvider2.overrideWithValue(_testUser),
          ],
        );
        addTearDown(container.dispose);

        final note = await container.read(
          noteByIdProvider('cached-note').future,
        );
        final resolvedNote = note ?? (throw StateError('note missing'));

        check(resolvedNote.id).equals('cached-note');
        check(resolvedNote.markdownContent).equals('editor body');
        check(resolvedNote.isPinned).isTrue();
      },
    );

    test('does not expose cached note details after logout', () async {
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'cached-note',
              'user_id': 'user-1',
              'title': 'Private note',
              'data': {
                'content': {'md': 'private body', 'html': ''},
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          apiServiceProvider.overrideWithValue(null),
          isAuthenticatedProvider2.overrideWithValue(false),
          currentUserProvider2.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      final note = await container.read(noteByIdProvider('cached-note').future);

      check(note).isNull();
    });

    test('refreshes an individual cached note while online', () async {
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'cached-note',
              'user_id': 'user-1',
              'title': 'Stale note',
              'data': {
                'content': {'md': 'stale body', 'html': ''},
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );
      final api = _FakeNotesApiService(
        fetchedRaw: _buildNoteJson(
          id: 'cached-note',
          title: 'Fresh note',
          markdown: 'fresh body',
          updatedAt: 1713872705000000000,
        ),
      );

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          apiServiceProvider.overrideWithValue(api),
          isAuthenticatedProvider2.overrideWithValue(true),
          currentUserProvider2.overrideWithValue(_testUser),
          isOnlineProvider.overrideWithValue(true),
        ],
      );
      addTearDown(container.dispose);

      final note = await container.read(noteByIdProvider('cached-note').future);
      final resolvedNote = note ?? (throw StateError('note missing'));

      check(resolvedNote.markdownContent).equals('fresh body');
      check(api.fetchedIds).deepEquals(['cached-note']);
    });

    test(
      'does not publish stale individual note responses after the active API changes',
      () async {
        final gate = Completer<void>();
        final staleApi = _FakeNotesApiService(
          fetchedRaw: _buildNoteJson(
            id: 'stale-note',
            title: 'Stale note',
            markdown: 'stale body',
            updatedAt: 1713786305000000000,
          ),
          fetchGate: gate.future,
        );
        final currentApi = _FakeNotesApiService(
          fetchedRaw: _buildNoteJson(
            id: 'stale-note',
            title: 'Current note',
            markdown: 'current body',
            updatedAt: 1713872705000000000,
          ),
        );
        final activeApiProvider =
            NotifierProvider<_MutableValue<ApiService?>, ApiService?>(
              () => _MutableValue<ApiService?>(staleApi),
            );
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => null),
            apiServiceProvider.overrideWith(
              (ref) => ref.watch(activeApiProvider),
            ),
            isAuthenticatedProvider2.overrideWithValue(true),
            isOnlineProvider.overrideWithValue(true),
          ],
        );
        addTearDown(container.dispose);

        final provider = noteByIdProvider('stale-note');
        final emittedNotes = <Note?>[];
        final subscription = container.listen<AsyncValue<Note?>>(provider, (
          _,
          next,
        ) {
          if (next.hasValue) emittedNotes.add(next.value);
        }, fireImmediately: true);
        addTearDown(subscription.close);
        await _waitFor(() => staleApi.fetchedIds.isNotEmpty);

        container.read(activeApiProvider.notifier).set(currentApi);
        gate.complete();

        await _waitFor(() => currentApi.fetchedIds.isNotEmpty);
        final note = await container.read(provider.future);

        check(note)
            .isNotNull()
            .has((it) => it.markdownContent, 'body')
            .equals('current body');
        check(
          emittedNotes
              .where((note) => note?.markdownContent == 'stale body')
              .toList(),
        ).isEmpty();
      },
    );

    test(
      'uses an individual cached note without fetching while offline',
      () async {
        await db
            .into(db.notes)
            .insertOnConflictUpdate(
              serverToNoteRow({
                'id': 'cached-note',
                'user_id': 'user-1',
                'title': 'Offline note',
                'data': {
                  'content': {'md': 'cached body', 'html': ''},
                },
                'meta': {},
                'is_pinned': false,
                'created_at': 1713786305000000000,
                'updated_at': 1713786305000000000,
              }),
            );
        final api = _FakeNotesApiService(
          fetchedRaw: _buildNoteJson(
            id: 'cached-note',
            title: 'Server note',
            markdown: 'server body',
            updatedAt: 1713872705000000000,
          ),
        );

        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => db),
            apiServiceProvider.overrideWithValue(api),
            isAuthenticatedProvider2.overrideWithValue(true),
            currentUserProvider2.overrideWithValue(_testUser),
            isOnlineProvider.overrideWithValue(false),
          ],
        );
        addTearDown(container.dispose);

        final note = await container.read(
          noteByIdProvider('cached-note').future,
        );
        final resolvedNote = note ?? (throw StateError('note missing'));

        check(resolvedNote.markdownContent).equals('cached body');
        check(api.fetchedIds).isEmpty();
      },
    );

    test(
      'uses an individual cached note when an online refresh cannot connect',
      () async {
        await db
            .into(db.notes)
            .insertOnConflictUpdate(
              serverToNoteRow({
                'id': 'cached-note',
                'user_id': 'user-1',
                'title': 'Cached note',
                'data': {
                  'content': {'md': 'cached body', 'html': ''},
                },
                'meta': {},
                'is_pinned': false,
                'created_at': 1713786305000000000,
                'updated_at': 1713786305000000000,
              }),
            );
        final api = _FakeNotesApiService(
          fetchError: _noteDioException(type: DioExceptionType.connectionError),
        );

        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => db),
            apiServiceProvider.overrideWithValue(api),
            isAuthenticatedProvider2.overrideWithValue(true),
            currentUserProvider2.overrideWithValue(_testUser),
            isOnlineProvider.overrideWithValue(true),
          ],
        );
        addTearDown(container.dispose);

        final note = await container.read(
          noteByIdProvider('cached-note').future,
        );
        final resolvedNote = note ?? (throw StateError('note missing'));

        check(resolvedNote.markdownContent).equals('cached body');
        check(api.fetchedIds).deepEquals(['cached-note']);
      },
    );

    test(
      'uses an individual cached note when online refresh gets a server error',
      () async {
        await db
            .into(db.notes)
            .insertOnConflictUpdate(
              serverToNoteRow({
                'id': 'cached-note',
                'user_id': 'user-1',
                'title': 'Cached note',
                'data': {
                  'content': {'md': 'cached body', 'html': ''},
                },
                'meta': {},
                'is_pinned': false,
                'created_at': 1713786305000000000,
                'updated_at': 1713786305000000000,
              }),
            );
        final api = _FakeNotesApiService(
          fetchError: _noteDioException(
            type: DioExceptionType.badResponse,
            statusCode: 503,
          ),
        );

        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => db),
            apiServiceProvider.overrideWithValue(api),
            isAuthenticatedProvider2.overrideWithValue(true),
            currentUserProvider2.overrideWithValue(_testUser),
            isOnlineProvider.overrideWithValue(true),
          ],
        );
        addTearDown(container.dispose);

        final note = await container.read(
          noteByIdProvider('cached-note').future,
        );
        final resolvedNote = note ?? (throw StateError('note missing'));

        check(resolvedNote.markdownContent).equals('cached body');
        check(api.fetchedIds).deepEquals(['cached-note']);
      },
    );

    test('rethrows authoritative note detail failures while online', () async {
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'cached-note',
              'user_id': 'user-1',
              'title': 'Cached note',
              'data': {
                'content': {'md': 'cached body', 'html': ''},
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );
      final api = _FakeNotesApiService(
        fetchError: _noteDioException(
          type: DioExceptionType.badResponse,
          statusCode: 404,
        ),
      );

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          apiServiceProvider.overrideWithValue(api),
          isAuthenticatedProvider2.overrideWithValue(true),
          currentUserProvider2.overrideWithValue(_testUser),
          isOnlineProvider.overrideWithValue(true),
        ],
      );
      addTearDown(container.dispose);

      final provider = noteByIdProvider('cached-note');
      final subscription = container.listen<AsyncValue<Note?>>(
        provider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await Future<void>.delayed(Duration.zero);

      final state = container.read(provider);
      expect(state.hasError, isTrue);
      expect(state.error, isA<DioException>());
      check(api.fetchedIds).deepEquals(['cached-note']);
    });

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
            appDatabaseProvider.overrideWith((ref) => null),
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

    test(
      'ignores stale API feature results after the active API changes',
      () async {
        final gate = Completer<void>();
        final staleApi = _FakeNotesApiService(
          notesRaw: [
            _buildNoteJson(
              id: 'stale-note',
              title: 'Stale note',
              updatedAt: 1713786305000000000,
            ),
          ],
          notesFeatureEnabled: false,
          notesGate: gate.future,
        );
        final currentApi = _FakeNotesApiService(
          notesRaw: [
            _buildNoteJson(
              id: 'current-note',
              title: 'Current note',
              updatedAt: 1713872705000000000,
            ),
          ],
        );
        final activeApiProvider =
            NotifierProvider<_MutableValue<ApiService?>, ApiService?>(
              () => _MutableValue<ApiService?>(staleApi),
            );
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => null),
            apiServiceProvider.overrideWith(
              (ref) => ref.watch(activeApiProvider),
            ),
            isAuthenticatedProvider2.overrideWithValue(true),
          ],
        );
        addTearDown(container.dispose);

        final notesFuture = container.read(notesListProvider.future);
        await _waitFor(() => staleApi.notesListRequests == 1);

        container.read(activeApiProvider.notifier).set(currentApi);
        gate.complete();

        final notes = await notesFuture;

        check(notes).isEmpty();
        check(container.read(notesFeatureEnabledProvider)).isTrue();
        check(currentApi.notesListRequests).equals(0);
      },
    );
  });

  group('NoteUpdater', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test(
      'does not persist stale updates after the active database changes',
      () async {
        final secondDb = AppDatabase(NativeDatabase.memory());
        final activeDbProvider =
            NotifierProvider<_MutableValue<AppDatabase?>, AppDatabase?>(
              () => _MutableValue<AppDatabase?>(db),
            );
        final gate = Completer<void>();
        final api = _FakeNotesApiService(
          updatedRaw: _buildNoteJson(
            id: 'note-1',
            title: 'Updated on old server',
            markdown: 'old server body',
            updatedAt: 1713872705000000000,
          ),
          updateGate: gate.future,
        );
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith(
              (ref) => ref.watch(activeDbProvider),
            ),
            apiServiceProvider.overrideWithValue(api),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await secondDb.close();
        });

        final updateFuture = container
            .read(noteUpdaterProvider.notifier)
            .updateNote('note-1', title: 'Updated on old server');
        await _waitFor(() => api.updatedIds.isNotEmpty);

        container.read(activeDbProvider.notifier).set(secondDb);
        gate.complete();

        final note = await updateFuture;

        check(note).isNull();
        check(await secondDb.notesDao.getNote('note-1')).isNull();
        check(container.read(noteUpdaterProvider).requireValue).isNull();
      },
    );
  });

  group('NotePinToggler', () {
    test('persists confirmed pin toggles to the cached pin mirror', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'note-1',
              'user_id': 'user-1',
              'title': 'Pinned later',
              'data': {
                'content': {'md': 'body', 'html': ''},
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );
      final originalNote = _buildNote(
        id: 'note-1',
        title: 'Pinned later',
        updatedAt: 1713786305000000000,
      );
      final toggledNote = originalNote.copyWith(isPinned: true);
      final api = _FakeNotesApiService(toggledNote: toggledNote);

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          apiServiceProvider.overrideWithValue(api),
          isAuthenticatedProvider2.overrideWithValue(true),
          currentUserProvider2.overrideWithValue(_testUser),
        ],
      );
      addTearDown(container.dispose);

      await container.read(notesListProvider.future);

      final updatedNote = await container
          .read(notePinTogglerProvider.notifier)
          .togglePin(originalNote);

      check(
        updatedNote,
      ).isNotNull().has((it) => it.isPinned, 'isPinned').isTrue();
      final row = await db.notesDao.getNote('note-1');
      check(row).isNotNull().has((it) => it.isPinned, 'isPinned').isTrue();
      check(
        row,
      ).isNotNull().has((it) => it.dirtyPinned, 'dirtyPinned').isFalse();
    });

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
            appDatabaseProvider.overrideWith((ref) => null),
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

class _MutableValue<T> extends Notifier<T> {
  _MutableValue(this.initial);

  final T initial;

  @override
  T build() => initial;

  void set(T value) => state = value;
}

class _FakeNotesApiService extends ApiService {
  _FakeNotesApiService({
    this.toggledNote,
    this.notesRaw = const <Map<String, dynamic>>[],
    this.notesFeatureEnabled = true,
    this.notesGate,
    this.fetchedRaw,
    this.fetchGate,
    this.fetchError,
    this.updatedRaw,
    this.updateGate,
  }) : super(
         serverConfig: const ServerConfig(
           id: 'test',
           name: 'Test',
           url: 'https://example.com',
         ),
         workerManager: WorkerManager(),
       );

  final Note? toggledNote;
  final List<Map<String, dynamic>> notesRaw;
  final bool notesFeatureEnabled;
  final Future<void>? notesGate;
  final Map<String, dynamic>? fetchedRaw;
  final Future<void>? fetchGate;
  final Object? fetchError;
  final Map<String, dynamic>? updatedRaw;
  final Future<void>? updateGate;
  final toggledIds = <String>[];
  var notesListRequests = 0;
  final fetchedIds = <String>[];
  final updatedIds = <String>[];

  @override
  Future<(List<Map<String, dynamic>>, bool)> getNotes({int? page}) async {
    notesListRequests++;
    final gate = notesGate;
    if (gate != null) {
      await gate;
    }
    return (notesRaw, notesFeatureEnabled);
  }

  @override
  Future<Map<String, dynamic>> getNoteById(String id) async {
    fetchedIds.add(id);
    final gate = fetchGate;
    if (gate != null) {
      await gate;
    }
    final error = fetchError;
    if (error != null) throw error;
    return fetchedRaw ?? (throw StateError('fetchedRaw not set'));
  }

  @override
  Future<Map<String, dynamic>> updateNote(
    String id, {
    String? title,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
    Map<String, dynamic>? accessControl,
  }) async {
    updatedIds.add(id);
    final gate = updateGate;
    if (gate != null) {
      await gate;
    }
    return updatedRaw ?? (throw StateError('updatedRaw not set'));
  }

  @override
  Future<Map<String, dynamic>> toggleNotePinned(String id) async {
    toggledIds.add(id);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final note = toggledNote ?? (throw StateError('toggledNote not set'));
    return note.toJson();
  }
}

DioException _noteDioException({
  required DioExceptionType type,
  int? statusCode,
}) {
  final requestOptions = RequestOptions(path: '/api/v1/notes/cached-note');
  return DioException(
    requestOptions: requestOptions,
    type: type,
    response: statusCode == null
        ? null
        : Response<void>(
            requestOptions: requestOptions,
            statusCode: statusCode,
          ),
  );
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('waitFor timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Map<String, dynamic> _buildNoteJson({
  required String id,
  required String title,
  required int updatedAt,
  String? markdown,
  bool isPinned = false,
}) {
  return {
    'id': id,
    'user_id': 'user-1',
    'title': title,
    'is_pinned': isPinned,
    'data': {
      'content': {
        'md': markdown ?? title,
        'html': '<p>${markdown ?? title}</p>',
        'json': null,
      },
    },
    'created_at': 1713786305000000000,
    'updated_at': updatedAt,
  };
}

Note _buildNote({
  required String id,
  required String title,
  required int updatedAt,
  bool isPinned = false,
}) {
  return Note.fromJson(
    _buildNoteJson(
      id: id,
      title: title,
      updatedAt: updatedAt,
      isPinned: isPinned,
    ),
  );
}
