import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/note_mapper.dart';
import 'package:conduit_core/models/note.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/notes/providers/notes_providers.dart';
import 'package:conduit_core/features/notes/utils/note_access.dart';
import 'package:conduit_core/features/notes/utils/note_persistence.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _testUser = User(
  id: 'user-1',
  username: 'user',
  email: 'user@example.com',
  role: 'user',
);

/// Replaces the real engine so the durable write path's fire-and-forget drain
/// kick is a no-op: the outbox op stays PENDING (never claimed) for assertions.
class _NoDrainSyncEngine extends SyncEngine {
  final List<String> pulls = <String>[];
  int reconcileNowCalls = 0;

  @override
  Future<void> drainNow() async {}

  @override
  Future<void> drainOutbox() async {}

  @override
  Future<PullResult?> requestPull({required String reason}) async {
    pulls.add(reason);
    return null;
  }

  @override
  Future<void> reconcileNow() async {
    reconcileNowCalls++;
  }
}

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

    test('manual refresh runs the unthrottled deletion reconcile', () async {
      final syncEngine = _NoDrainSyncEngine();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          apiServiceProvider.overrideWithValue(null),
          isAuthenticatedProvider2.overrideWithValue(true),
          currentUserProvider2.overrideWithValue(_testUser),
          syncEngineProvider.overrideWith(() => syncEngine),
        ],
      );
      addTearDown(container.dispose);
      await container.read(notesListProvider.future);

      await container.read(notesListProvider.notifier).refresh();

      check(syncEngine.pulls).deepEquals(['notes-refresh']);
      check(syncEngine.reconcileNowCalls).equals(1);
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
          isOnlineProvider.overrideWithValue(true),
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
      check(searchResults.map((note) => note.id).toList())
          .deepEquals(['own-note']);
      check(otherNote).isNull();
    });

    group('shared notes', () {
      Map<String, dynamic> sharedDetail() => {
        ..._buildNoteJson(
          id: 'shared-note',
          title: 'Shared needle',
          markdown: 'shared body needle',
          updatedAt: 1713786305000000000,
        ),
        'user_id': 'creator-9',
        'write_access': false,
        'access_grants': [
          {
            'principal_type': 'group',
            'principal_id': 'g1',
            'permission': 'read',
          },
        ],
      };

      ProviderContainer open({
        required String userId,
        ApiService? api,
        bool online = false,
      }) {
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => db),
            apiServiceProvider.overrideWithValue(api),
            isAuthenticatedProvider2.overrideWithValue(true),
            currentUserProvider2.overrideWithValue(
              User(
                id: userId,
                username: userId,
                email: '$userId@example.com',
                role: 'user',
              ),
            ),
            isOnlineProvider.overrideWithValue(online),
          ],
        );
        addTearDown(container.dispose);
        return container;
      }

      Future<Map<String, List<String>>> offlineView(String userId) async {
        final container = open(userId: userId);
        final list = await container.read(notesListProvider.future);
        final search = await container.read(
          filteredNotesProvider('needle').future,
        );
        final detail = await container.read(
          noteByIdProvider('shared-note').future,
        );
        return {
          'list': [for (final n in list) n.id],
          'search': [for (final n in search) n.id],
          'detail': [?detail?.id],
        };
      }

      test('a note the server served to the account is listed, searched and '
          'reopened offline, and no other account sees it', () async {
        // A foreign row that was never served to the account.
        await db
            .into(db.notes)
            .insertOnConflictUpdate(
              serverToNoteRow({
                'id': 'foreign-note',
                'user_id': 'user-2',
                'title': 'Foreign needle',
                'data': {
                  'content': {'md': 'foreign needle', 'html': ''},
                },
                'created_at': 1713786305000000000,
                'updated_at': 1713786305000000000,
              }),
            );
        final online = open(
          userId: 'user-1',
          api: _FakeNotesApiService(fetchedRaw: sharedDetail()),
          online: true,
        );
        check(await online.read(noteByIdProvider('shared-note').future))
            .isNotNull();

        check(await offlineView('user-1')).deepEquals({
          'list': ['shared-note'],
          'search': ['shared-note'],
          'detail': ['shared-note'],
        });
        // The creator id stays what the server said it is.
        check((await db.notesDao.getNote('shared-note'))!.rawExtra)
            .contains('creator-9');
        check(await offlineView('user-3')).deepEquals({
          'list': <String>[],
          'search': <String>[],
          'detail': <String>[],
        });
      });

      test('a 403 on the detail retires the account\'s read eligibility and '
          'keeps its draft and refused operation', () async {
        await db.notesDao.mergeServerNote(
          serverRaw: sharedDetail(),
          readerId: 'user-1',
        );
        await db.notesDao.updateNoteWithOutbox(
          'shared-note',
          title: const Value('My draft'),
          localUpdatedAtNs: 1713786306000000000,
          enqueue: true,
        );
        check(await offlineView('user-1'))
            .has((v) => v['list'], 'list')
            .isNotNull()
            .deepEquals(['shared-note']);

        final revoked = open(
          userId: 'user-1',
          api: _FakeNotesApiService(
            fetchError: _noteDioException(
              type: DioExceptionType.badResponse,
              statusCode: 403,
            ),
          ),
          online: true,
        );
        final provider = noteByIdProvider('shared-note');
        final subscription = revoked.listen<AsyncValue<Note?>>(
          provider,
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);
        await _waitFor(() => revoked.read(provider).hasError);
        check(revoked.read(provider).error).isA<DioException>();

        check(await offlineView('user-1')).deepEquals({
          'list': <String>[],
          'search': <String>[],
          'detail': <String>[],
        });
        final row = (await db.notesDao.getNote('shared-note'))!;
        check(row.title).equals('My draft');
        check(row.dirtyTitle).isTrue();
        check(
          (await db.outboxDao.pendingForChat('shared-note')).map((o) => o.kind),
        ).deepEquals([OutboxKind.noteUpdate.name]);
      });
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
      check(notes.single.listPreviewMarkdown)
          .equals(longBody.substring(0, 1000));
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
            isOnlineProvider.overrideWithValue(true),
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

    test('does not publish stale individual note responses after the active API changes', () async {
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
    });

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
        check(notes.map((note) => note.id).toList())
            .deepEquals(['note-1', 'note-2']);
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

    test('writes the edit durably to the active database and enqueues a '
        'noteUpdate op (never the REST update endpoint)', () async {
      await db
          .into(db.notes)
          .insertOnConflictUpdate(
            serverToNoteRow({
              'id': 'note-1',
              'user_id': 'user-1',
              'title': 'Original',
              'data': {
                'content': {'md': 'original body', 'html': ''},
              },
              'meta': {},
              'is_pinned': false,
              'created_at': 1713786305000000000,
              'updated_at': 1713786305000000000,
            }),
          );

      // The durable path never touches the REST update endpoint, so the
      // fake's `updatedRaw` is intentionally left unset.
      final api = _FakeNotesApiService();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          apiServiceProvider.overrideWithValue(api),
          isAuthenticatedProvider2.overrideWithValue(true),
          currentUserProvider2.overrideWithValue(_testUser),
          syncEngineProvider.overrideWith(_NoDrainSyncEngine.new),
        ],
      );
      addTearDown(container.dispose);

      final note = await container
          .read(noteUpdaterProvider.notifier)
          .updateNote(
            'note-1',
            title: 'Durable title',
            markdownContent: 'durable body',
          );

      check(note)
          .isNotNull()
          .has((it) => it.title, 'title')
          .equals('Durable title');
      final row = await db.notesDao.getNote('note-1');
      check(row).isNotNull().has((it) => it.dirtyTitle, 'dirtyTitle').isTrue();
      check(row).isNotNull().has((it) => it.dirtyData, 'dirtyData').isTrue();
      check((await db.outboxDao.pendingForChat('note-1')).map((op) => op.kind))
          .deepEquals([OutboxKind.noteUpdate.name]);
      check(api.updatedIds).isEmpty();
    });

    test(
      'a content-only update preserves existing versions and files',
      () async {
        await db
            .into(db.notes)
            .insertOnConflictUpdate(
              serverToNoteRow({
                'id': 'note-1',
                'user_id': 'user-1',
                'title': 'Original',
                'data': {
                  'content': {'md': 'original body', 'html': ''},
                  'versions': [
                    {'md': 'v1', 'html': ''},
                  ],
                  'files': [
                    {'id': 'f1', 'name': 'a.pdf'},
                  ],
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
            apiServiceProvider.overrideWithValue(_FakeNotesApiService()),
            isAuthenticatedProvider2.overrideWithValue(true),
            currentUserProvider2.overrideWithValue(_testUser),
            syncEngineProvider.overrideWith(_NoDrainSyncEngine.new),
          ],
        );
        addTearDown(container.dispose);

        await container
            .read(noteUpdaterProvider.notifier)
            .updateNote('note-1', markdownContent: 'new body');

        final row = await db.notesDao.getNote('note-1');
        final data = decodeNoteData(row!.data);
        check((data['content'] as Map)['md']).equals('new body');
        check((data['versions'] as List).length).equals(1);
        check((data['files'] as List).length).equals(1);
      },
    );

    group('shared note access', () {
      Future<void> seedShared({bool? writeAccess, String owner = 'creator-9'}) {
        return db
            .into(db.notes)
            .insertOnConflictUpdate(
              serverToNoteRow({
                'id': 'shared-1',
                'user_id': owner,
                'title': 'Original',
                'data': {
                  'content': {'md': 'original body', 'html': ''},
                },
                'meta': {},
                'is_pinned': false,
                'created_at': 1713786305000000000,
                'updated_at': 1713786305000000000,
                'write_access': ?writeAccess,
              }),
            );
      }

      ProviderContainer open({_FakeNotesApiService? api}) {
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => db),
            apiServiceProvider.overrideWithValue(api ?? _FakeNotesApiService()),
            isAuthenticatedProvider2.overrideWithValue(true),
            currentUserProvider2.overrideWithValue(_testUser),
            syncEngineProvider.overrideWith(_NoDrainSyncEngine.new),
          ],
        );
        addTearDown(container.dispose);
        return container;
      }

      Future<void> expectUntouched() async {
        final row = (await db.notesDao.getNote('shared-1'))!;
        check(row.title).equals('Original');
        check(row.dirtyTitle).isFalse();
        check(row.dirtyData).isFalse();
        check(row.deleted).isFalse();
        check(await db.outboxDao.pendingForChat('shared-1')).isEmpty();
      }

      test(
        'a read-only note is refused before the row or outbox change',
        () async {
          await seedShared(writeAccess: false);
          final container = open();

          final note = await container
              .read(noteUpdaterProvider.notifier)
              .updateNote('shared-1', title: 'Mine', markdownContent: 'mine');

          check(note).isNull();
          check(container.read(noteUpdaterProvider).error)
              .isA<NoteWriteDeniedException>()
              .has((e) => e.unverified, 'unverified')
              .isFalse();
          await expectUntouched();
        },
      );

      test(
        'a write recipient is admitted although the creator owns the note',
        () async {
          await seedShared(writeAccess: true);
          final container = open();

          final note = await container
              .read(noteUpdaterProvider.notifier)
              .updateNote('shared-1', title: 'Mine', markdownContent: 'mine');

          check(note).isNotNull();
          check(
            (await db.outboxDao.pendingForChat('shared-1'))
                .map((op) => op.kind),
          ).deepEquals([OutboxKind.noteUpdate.name]);
        },
      );

      test(
        'unknown access is settled by the authoritative detail before a write',
        () async {
          await seedShared();
          final container = open(
            api: _FakeNotesApiService(
              rawDetail: {
                ..._buildNoteJson(
                  id: 'shared-1',
                  title: 'Original',
                  updatedAt: 1713786305000000000,
                ),
                'user_id': 'creator-9',
                'write_access': true,
              },
            ),
          );

          final note = await container
              .read(noteUpdaterProvider.notifier)
              .updateNote('shared-1', markdownContent: 'mine');

          check(note).isNotNull();
          check(
            decodeJsonMap((await db.notesDao.getNote('shared-1'))!.rawExtra),
          ).containsKey('write_access');
        },
      );

      test(
        'unknown access with no detail available refuses as unverified',
        () async {
          await seedShared();
          final container = open();

          final note = await container
              .read(noteUpdaterProvider.notifier)
              .updateNote('shared-1', markdownContent: 'mine');

          check(note).isNull();
          check(container.read(noteUpdaterProvider).error)
              .isA<NoteWriteDeniedException>()
              .has((e) => e.unverified, 'unverified')
              .isTrue();
          await expectUntouched();
        },
      );

      test('a read-only note is not tombstoned by delete', () async {
        await seedShared(writeAccess: false);
        final container = open();

        final deleted = await container
            .read(noteDeleterProvider.notifier)
            .deleteNote('shared-1');

        check(deleted).isFalse();
        await expectUntouched();
      });

      test('pinning stays available on a read-only note', () async {
        await seedShared(writeAccess: false);
        final container = open();

        final pinned = await container
            .read(notePinTogglerProvider.notifier)
            .togglePin(
              Note.fromJson(
                noteRowToServer((await db.notesDao.getNote('shared-1'))!),
              ),
            );

        check(pinned).isNotNull().has((n) => n.isPinned, 'isPinned').isTrue();
      });
    });
  });

  group('a note mutation opened under one account', () {
    const userB = User(
      id: 'user-2',
      username: 'b',
      email: 'b@example.com',
      role: 'user',
    );

    late AppDatabase db;
    late ApiService api;
    late _RecordingAdapter wire;
    late ProviderContainer container;
    late Object opening;
    var epoch = Object();
    var user = _testUser;

    Future<void> seed({bool? writeAccess}) => db
        .into(db.notes)
        .insertOnConflictUpdate(
          serverToNoteRow({
            'id': 'shared-1',
            'user_id': 'creator-9',
            'title': 'Original',
            'data': {
              'content': {'md': 'original body', 'html': ''},
            },
            'created_at': 1713786305000000000,
            'updated_at': 1713786305000000000,
            'write_access': ?writeAccess,
          }),
        );

    /// What the editor does when the user changes account on the same API.
    void switchToB() {
      user = userB;
      epoch = Object();
      api.updateAuthToken('token-b');
      container.invalidate(currentUserProvider2);
      container.invalidate(openWebUiAuthSessionEpochProvider);
    }

    Future<void> expectUntouched() async {
      final row = (await db.notesDao.getNote('shared-1'))!;
      check(row.title).equals('Original');
      check(row.deleted).isFalse();
      check(row.dirtyTitle).isFalse();
      check(await db.outboxDao.pendingForChat('shared-1')).isEmpty();
    }

    Future<Note?> save() => persistNoteUpdate(
      container,
      noteId: 'shared-1',
      api: api,
      db: db,
      authEpoch: opening,
      title: 'A draft',
      data: {
        'content': {'md': 'a draft'},
      },
    );

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      wire = _RecordingAdapter();
      api = ApiService(
        serverConfig: const ServerConfig(
          id: 'test',
          name: 'Test',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
        authToken: 'token-a',
      );
      api.dio.httpClientAdapter = wire;
      epoch = Object();
      opening = epoch;
      user = _testUser;
      container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          apiServiceProvider.overrideWithValue(api),
          isAuthenticatedProvider2.overrideWithValue(true),
          currentUserProvider2.overrideWith((ref) => user),
          openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
          syncEngineProvider.overrideWith(_NoDrainSyncEngine.new),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      api.dispose();
      await db.close();
    });

    test('a save does not read permission as the account that replaced it '
        'while the remap lookup was pending', () async {
      await seed();

      final saving = save();
      switchToB();
      final saved = await saving;

      check(saved).isNull();
      check(wire.authorizations).not((it) => it.contains('Bearer token-b'));
      await expectUntouched();
    });

    test('a permission answer that arrives after the account changed is not '
        'stored and the save does not proceed', () async {
      await seed();
      final answer = Completer<void>();
      wire.hold = answer.future;

      final saving = save();
      await _waitFor(() => wire.authorizations.isNotEmpty);
      check(wire.authorizations).deepEquals(['Bearer token-a']);
      switchToB();
      answer.complete();
      final saved = await saving;

      check(saved).isNull();
      check(decodeJsonMap((await db.notesDao.getNote('shared-1'))!.rawExtra))
          .not((it) => it.containsKey('write_access'));
      await expectUntouched();
    });

    test('an account change while the note lock is held keeps the edit out of '
        'the replacement session', () async {
      await seed(writeAccess: true);
      final held = Completer<void>();
      final holding = Completer<void>();
      final lockHolder = container.read(noteLocksProvider).runExclusive(
        'shared-1',
        () async {
          holding.complete();
          await held.future;
        },
      );
      await holding.future;

      final saving = save();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      switchToB();
      held.complete();
      await lockHolder;

      check(await saving).isNull();
      await expectUntouched();
    });

    test('a delete does not tombstone the note for the replacement '
        'account', () async {
      await seed();

      final deleting = container
          .read(noteDeleterProvider.notifier)
          .deleteNote('shared-1');
      switchToB();

      check(await deleting).isFalse();
      check(wire.authorizations).not((it) => it.contains('Bearer token-b'));
      await expectUntouched();
    });
  });

  group('reopening a note after a durable edit', () {
    const userB = User(
      id: 'user-2',
      username: 'b',
      email: 'b@example.com',
      role: 'user',
    );
    const readGroup = {
      'principal_type': 'group',
      'principal_id': 'g1',
      'permission': 'read',
    };

    late AppDatabase db;
    late ApiService api;
    late _RecordingAdapter wire;
    late ProviderContainer container;
    var epoch = Object();
    var user = _testUser;
    var online = true;

    Map<String, dynamic> serverNote({
      required String creator,
      required bool? writeAccess,
      List<Map<String, dynamic>> grants = const [],
    }) => {
      'id': 'note-1',
      'user_id': creator,
      'title': 'Disposable note',
      'data': {
        'content': {'md': 'Original content', 'html': ''},
      },
      'created_at': 1713786305000000000,
      'updated_at': 1713786305000000000,
      'write_access': ?writeAccess,
      'access_grants': grants,
    };

    Future<Note?> reopen() => container.read(noteByIdProvider('note-1').future);

    Future<Note?> saveEdit() => persistNoteUpdate(
      container,
      noteId: 'note-1',
      api: api,
      db: db,
      authEpoch: epoch,
      title: 'Disposable note',
      data: {
        'content': {'md': 'Saved edit', 'html': ''},
      },
    );

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      wire = _RecordingAdapter();
      api = ApiService(
        serverConfig: const ServerConfig(
          id: 'test',
          name: 'Test',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
        authToken: 'token-a',
      );
      api.dio.httpClientAdapter = wire;
      epoch = Object();
      user = _testUser;
      online = true;
      container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          apiServiceProvider.overrideWithValue(api),
          isAuthenticatedProvider2.overrideWithValue(true),
          currentUserProvider2.overrideWith((ref) => user),
          openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
          isOnlineProvider.overrideWith((ref) => online),
          syncEngineProvider.overrideWith(_NoDrainSyncEngine.new),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      api.dispose();
      await db.close();
    });

    // The push waits in the outbox, so the server still has the older text
    // when the note is opened again.
    for (final scenario in [
      (
        name: 'own note',
        creator: 'user-1',
        stored: null as bool?,
        reopened: null as bool?,
      ),
      (
        name: 'writable recipient',
        creator: 'creator-9',
        stored: true as bool?,
        reopened: true as bool?,
      ),
      (
        name: 'recipient whose write grant was revoked meanwhile',
        creator: 'creator-9',
        stored: true as bool?,
        reopened: false as bool?,
      ),
    ]) {
      test('${scenario.name}: shows the saved edit and the access the server '
          'just sent', () async {
        wire.body = serverNote(
          creator: scenario.creator,
          writeAccess: scenario.stored,
        );
        await db.notesDao.mergeServerNote(
          serverRaw: wire.body!,
          readerId: _testUser.id,
        );
        check((await reopen())!.markdownContent).equals('Original content');

        check((await saveEdit())!.markdownContent).equals('Saved edit');

        wire.body = serverNote(
          creator: scenario.creator,
          writeAccess: scenario.reopened,
          grants: [readGroup],
        );
        final reopened = (await reopen())!;

        check(reopened.markdownContent).equals('Saved edit');
        check(reopened.writeAccess).equals(scenario.reopened);
        check(reopened.accessGrants).isNotNull().deepEquals([readGroup]);
        final row = (await db.notesDao.getNote('note-1'))!;
        check(row.dirtyData).isTrue();
        check((await db.outboxDao.pendingForChat('note-1')).map((o) => o.kind))
            .deepEquals([OutboxKind.noteUpdate.name]);
      });
    }

    test('an answer for the previous account does not expose the saved edit '
        'to the account that replaced it', () async {
      wire.body = serverNote(creator: 'creator-9', writeAccess: true);
      await db.notesDao.mergeServerNote(
        serverRaw: wire.body!,
        readerId: _testUser.id,
      );
      await saveEdit();

      final answer = Completer<void>();
      wire.hold = answer.future;
      final reading = reopen();
      await _waitFor(() => wire.authorizations.isNotEmpty);
      user = userB;
      epoch = Object();
      online = false;
      api.updateAuthToken('token-b');
      container
        ..invalidate(currentUserProvider2)
        ..invalidate(openWebUiAuthSessionEpochProvider)
        ..invalidate(isOnlineProvider);
      answer.complete();
      await reading.then<void>((_) {}, onError: (_) {});

      check(await reopen()).isNull();
      final row = (await db.notesDao.getNote('note-1'))!;
      check(row.dirtyData).isTrue();
      check(noteReadAccounts(decodeJsonMap(row.rawExtra)))
          .deepEquals([_testUser.id]);
    });
  });

  group('NotePinToggler', () {
    test('enqueues a durable pin toggle (row + notePin op)', () async {
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
          syncEngineProvider.overrideWith(_NoDrainSyncEngine.new),
        ],
      );
      addTearDown(container.dispose);

      await container.read(notesListProvider.future);

      final updatedNote = await container
          .read(notePinTogglerProvider.notifier)
          .togglePin(originalNote);

      check(updatedNote)
          .isNotNull()
          .has((it) => it.isPinned, 'isPinned')
          .isTrue();
      final row = await db.notesDao.getNote('note-1');
      check(row).isNotNull().has((it) => it.isPinned, 'isPinned').isTrue();
      // The pin is a local change awaiting push: dirtyPinned stays set until the
      // drainer confirms it, and a notePin op is queued in the outbox.
      check(row)
          .isNotNull()
          .has((it) => it.dirtyPinned, 'dirtyPinned')
          .isTrue();
      check((await db.outboxDao.pendingForChat('note-1')).map((op) => op.kind))
          .deepEquals([OutboxKind.notePin.name]);
      check(api.toggledIds).isEmpty();
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
        check(container.read(notesListProvider).requireValue.first)
            .has((it) => it.isPinned, 'isPinned')
            .isTrue();
        check(container.read(activeNoteProvider))
            .isNotNull()
            .has((it) => it.isPinned, 'isPinned')
            .isTrue();
        check(container.read(notePinTogglerProvider).requireValue)
            .isNotNull()
            .has((it) => it.isPinned, 'isPinned')
            .isTrue();
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
    this.rawDetail,
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

  /// What the sync-facing detail read (`getNoteRaw`) answers; null reads as a
  /// transport failure.
  final Map<String, dynamic>? rawDetail;
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
  Future<Map<String, dynamic>?> getNoteRaw(
    String id, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    return rawDetail ?? (throw StateError('detail unavailable'));
  }

  @override
  Future<Map<String, dynamic>> updateNote(
    String id, {
    String? title,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
    Map<String, dynamic>? accessControl,
  }) async {
    // The durable write path must never hit the REST update endpoint; record
    // the call so tests can assert it stayed unused.
    updatedIds.add(id);
    throw StateError(
      'REST updateNote should not be called on the durable path',
    );
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

/// Answers every request with a note the account may edit, recording which
/// bearer token each one carried.
class _RecordingAdapter implements HttpClientAdapter {
  final authorizations = <String>[];

  /// What the server currently says about the note; defaults to a writable
  /// one for [shared-1].
  Map<String, dynamic>? body;

  /// When set, a response waits for it, so a test can change account while a
  /// request is in flight.
  Future<void>? hold;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    authorizations.add('${options.headers['Authorization']}');
    final gate = hold;
    if (gate != null) await gate;
    return ResponseBody.fromString(
      jsonEncode(
        body ??
            {
              'id': 'shared-1',
              'user_id': 'creator-9',
              'write_access': true,
              'access_grants': <Map<String, dynamic>>[],
            },
      ),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
