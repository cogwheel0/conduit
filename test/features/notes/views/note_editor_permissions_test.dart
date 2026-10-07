import 'dart:async';

import 'package:conduit/features/notes/views/note_editor_page.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/note_mapper.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/notes/providers/notes_providers.dart';
import 'package:conduit_core/features/notes/utils/note_persistence.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:fleather/fleather.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/test_fonts.dart';

const _alice = User(
  id: 'alice',
  username: 'alice',
  email: 'alice@example.com',
  role: 'user',
);
const _bob = User(
  id: 'bob',
  username: 'bob',
  email: 'bob@example.com',
  role: 'user',
);

/// The two accounts of one app session; switching the user rebuilds the auth
/// epoch exactly as a real same-server account change does, while the API and
/// database objects stay the same.
class _CurrentUser extends Notifier<User?> {
  @override
  User? build() => _alice;

  void switchTo(User user) => state = user;
}

final _currentUser = NotifierProvider<_CurrentUser, User?>(_CurrentUser.new);

/// Keeps the drain kick a no-op so the queued outbox op stays observable.
class _QuietSyncEngine extends SyncEngine {
  @override
  Future<void> drainNow() async {}

  @override
  Future<void> drainOutbox() async {}

  @override
  Future<PullResult?> requestPull({required String reason}) async => null;

  @override
  Future<void> reconcileNow() async {}
}

class _DetailApi extends ApiService {
  _DetailApi({this.detail, this.detailError})
    : super(
        serverConfig: const ServerConfig(
          id: 'test',
          name: 'Test',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  Map<String, dynamic>? detail;
  Object? detailError;
  int updates = 0;
  final accessReads = <String>[];

  /// While set, a detail read stays in flight until the test completes it.
  Completer<Map<String, dynamic>>? heldDetail;

  @override
  Future<Map<String, dynamic>> getNoteForSession(
    String noteId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    accessReads.add(noteId);
    return detail ?? (throw StateError('no detail'));
  }

  @override
  Future<Map<String, dynamic>> getNoteById(String id) async {
    final held = heldDetail;
    if (held != null) return held.future;
    final error = detailError;
    if (error != null) throw error;
    return detail ?? (throw StateError('no detail'));
  }

  @override
  Future<Map<String, dynamic>?> getNoteRaw(
    String id, {
    ApiAuthSnapshot? authSnapshot,
  }) async => detail;

  @override
  Future<Map<String, dynamic>> updateNote(
    String id, {
    String? title,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
    Map<String, dynamic>? accessControl,
  }) async {
    updates++;
    throw StateError('the durable path must not call the REST update');
  }
}

Map<String, dynamic> _noteJson({
  required bool writeAccess,
  String owner = 'creator',
}) => {
  'id': 'note-1',
  'user_id': owner,
  'title': 'Shared note',
  'write_access': writeAccess,
  'data': {
    'content': {'md': 'original', 'html': '', 'json': null},
  },
  'meta': {},
  'is_pinned': false,
  'access_grants': <Map<String, dynamic>>[],
  'created_at': 1713786305000000000,
  'updated_at': 1713786305000000000,
};

void main() {
  late AppDatabase db;

  setUpAll(loadTestFonts);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> storeLocally(Map<String, dynamic> note) => db
      .into(db.notes)
      .insertOnConflictUpdate(serverToNoteRow(note, overrideId: 'note-1'));

  /// Mounts a fresh editor for the note in [container], as opening it again
  /// from the list does.
  Future<void> openEditor(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const NoteEditorPage(noteId: 'note-1'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<ProviderContainer> pumpEditor(
    WidgetTester tester,
    _DetailApi api, {
    bool advanced = false,
  }) async {
    final container = ProviderContainer(
      // A provider that errors would otherwise schedule a retry timer.
      retry: (_, _) => null,
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        apiServiceProvider.overrideWithValue(api),
        isAuthenticatedProvider2.overrideWithValue(true),
        authTokenProvider3.overrideWithValue('token'),
        currentUserProvider2.overrideWith((ref) => ref.watch(_currentUser)),
        connectivityStatusProvider.overrideWithValue(ConnectivityStatus.online),
        isOnlineProvider.overrideWithValue(true),
        appSettingsProvider.overrideWithValue(
          AppSettings(advancedFeaturesEnabled: advanced),
        ),
        workspaceCapabilitiesProvider.overrideWith(
          (ref) async => WorkspaceCapabilities.all,
        ),
        syncEngineProvider.overrideWith(_QuietSyncEngine.new),
      ],
    );
    addTearDown(container.dispose);
    await openEditor(tester, container);
    return container;
  }

  /// Leaves the editor; the keep-alive detail provider stays in the container.
  Future<void> closeEditor(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox.shrink());

  FleatherController contentController(WidgetTester tester) =>
      tester.widget<FleatherEditor>(find.byType(FleatherEditor)).controller;

  /// Types as the user does: the document change drives the editor's
  /// debounced autosave.
  void typeInto(WidgetTester tester, String text) {
    contentController(tester).replaceText(0, 0, text);
  }

  Future<void> letAutosaveRun(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> expectNothingQueued() async {
    final row = (await db.notesDao.getNote('note-1'))!;
    expect(row.dirtyData, isFalse);
    expect(row.dirtyTitle, isFalse);
    expect(await db.outboxDao.pendingForChat('note-1'), isEmpty);
  }

  AppLocalizations l10n(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(NoteEditorPage)))!;

  testWidgets('a read-only note opens for reading and cannot be edited', (
    tester,
  ) async {
    final api = _DetailApi(detail: _noteJson(writeAccess: false));
    await storeLocally(_noteJson(writeAccess: false));
    await pumpEditor(tester, api);

    final editor = tester.widget<FleatherEditor>(find.byType(FleatherEditor));
    expect(editor.readOnly, isTrue);
    expect(find.text(l10n(tester).noteReadOnlyNotice), findsOneWidget);
    expect(
      contentController(tester).document.toPlainText(),
      contains('original'),
    );

    // Even if a change reaches the document, nothing is saved.
    typeInto(tester, 'sneaky ');
    await letAutosaveRun(tester);
    await expectNothingQueued();
    expect(api.updates, 0);
  });

  testWidgets(
    'a write recipient edits a note the creator owns, through the outbox',
    (tester) async {
      final api = _DetailApi(detail: _noteJson(writeAccess: true));
      await storeLocally(_noteJson(writeAccess: true));
      await pumpEditor(tester, api);

      expect(
        tester.widget<FleatherEditor>(find.byType(FleatherEditor)).readOnly,
        isFalse,
      );
      typeInto(tester, 'mine ');
      await letAutosaveRun(tester);

      final ops = await db.outboxDao.pendingForChat('note-1');
      expect(ops, hasLength(1));
      expect(api.updates, 0);
    },
  );

  testWidgets('access revoked before save keeps the draft and never resends', (
    tester,
  ) async {
    final api = _DetailApi(detail: _noteJson(writeAccess: true));
    await storeLocally(_noteJson(writeAccess: true));
    await pumpEditor(tester, api);

    typeInto(tester, 'unsaved ');
    // The server revokes access while the page is open; the next pull or
    // detail read stores that.
    await db.notesDao.storeNoteAccessProjection('note-1', writeAccess: false);
    await letAutosaveRun(tester);

    expect(find.text(l10n(tester).noteAccessRevokedNotice), findsOneWidget);
    expect(
      contentController(tester).document.toPlainText(),
      contains('unsaved'),
      reason: 'the typed text stays on screen',
    );
    expect(
      tester.widget<FleatherEditor>(find.byType(FleatherEditor)).readOnly,
      isTrue,
    );
    expect(find.text(l10n(tester).noteSaveAsOwnNote), findsOneWidget);
    await expectNothingQueued();

    // Time passing never retries the refused write.
    await tester.pump(const Duration(seconds: 5));
    expect(await db.outboxDao.pendingForChat('note-1'), isEmpty);
    expect(api.updates, 0);

    // The draft can still leave the page: saved as a note the user owns.
    await tester.tap(find.text(l10n(tester).noteSaveAsOwnNote));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    final copies = [
      for (final row in await db.select(db.notes).get())
        if (row.id.startsWith('local:')) row,
    ];
    expect(copies, hasLength(1));
    expect(decodeJsonMap(copies.single.data)['content'], isA<Map>());
    expect(copies.single.data, contains('unsaved'));
    expect(
      (await db.notesDao.getNote('note-1'))!.dirtyData,
      isFalse,
      reason: 'the shared note itself is never written',
    );
  });

  testWidgets(
    'an account switched on the same API between open and save is refused',
    (tester) async {
      final api = _DetailApi(detail: _noteJson(writeAccess: true));
      await storeLocally(_noteJson(writeAccess: true));
      final container = await pumpEditor(tester, api);
      final apiBefore = container.read(apiServiceProvider);
      final dbBefore = container.read(appDatabaseProvider);

      typeInto(tester, 'alice draft ');
      container.read(_currentUser.notifier).switchTo(_bob);
      await letAutosaveRun(tester);

      // The very same API and database objects, so only the opening account's
      // epoch can tell the two sessions apart.
      expect(identical(container.read(apiServiceProvider), apiBefore), isTrue);
      expect(identical(container.read(appDatabaseProvider), dbBefore), isTrue);
      expect(find.text(l10n(tester).noteSessionChangedNotice), findsWidgets);
      await expectNothingQueued();
      expect(api.updates, 0);
    },
  );

  testWidgets('a 403 on open says access is gone, not that the note is gone', (
    tester,
  ) async {
    final api = _DetailApi(
      detailError: DioException(
        requestOptions: RequestOptions(path: '/api/v1/notes/note-1'),
        response: Response<void>(
          requestOptions: RequestOptions(path: '/api/v1/notes/note-1'),
          statusCode: 403,
        ),
        type: DioExceptionType.badResponse,
      ),
    );
    await pumpEditor(tester, api);

    expect(find.text(l10n(tester).noteNoAccess), findsOneWidget);
    expect(find.text(l10n(tester).noteNotFound), findsNothing);
  });

  testWidgets('an account switched while the note loads never hydrates it', (
    tester,
  ) async {
    final gate = Completer<void>();
    final api = _GatedDetailApi(
      gate.future,
      detail: _noteJson(writeAccess: true),
    );
    final container = await pumpEditor(tester, api);

    container.read(_currentUser.notifier).switchTo(_bob);
    gate.complete();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(FleatherEditor), findsNothing);
    expect(find.text(l10n(tester).noteSessionChangedNotice), findsOneWidget);
  });

  testWidgets(
    'reopening a saved note during its detail refresh shows the saved edit '
    'under the refreshed permissions',
    (tester) async {
      final original = _noteJson(writeAccess: true);
      final api = _DetailApi(detail: original);
      await storeLocally(original);
      final container = await pumpEditor(tester, api);
      final provider = noteByIdProvider('note-1');
      expect(
        contentController(tester).document.toPlainText(),
        contains('original'),
      );

      await closeEditor(tester);
      api.heldDetail = Completer<Map<String, dynamic>>();
      final saved = await persistNoteUpdate(
        container,
        noteId: 'note-1',
        api: api,
        db: db,
        title: 'Shared note',
        data: {
          'content': {'md': 'Saved reopen proof', 'html': '', 'json': null},
        },
      );
      expect(saved!.markdownContent, 'Saved reopen proof');
      // The save invalidated the detail, which keeps the pre-save note while
      // the held read recomputes it.
      final refreshing = container.read(provider);
      expect(refreshing.isLoading, isTrue);
      expect(refreshing.value!.markdownContent, 'original');

      await openEditor(tester, container);
      expect(
        find.byType(FleatherEditor),
        findsNothing,
        reason: 'the retained pre-save note is not what the page opened with',
      );

      // The server answers with its older body, which no longer grants write.
      api.heldDetail!.complete(_noteJson(writeAccess: false));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        contentController(tester).document.toPlainText(),
        contains('Saved reopen proof'),
      );
      expect(
        tester.widget<FleatherEditor>(find.byType(FleatherEditor)).readOnly,
        isTrue,
      );

      // Once settled, opening the note again reads it straight away.
      await closeEditor(tester);
      api.heldDetail = null;
      await openEditor(tester, container);
      expect(
        contentController(tester).document.toPlainText(),
        contains('Saved reopen proof'),
      );
    },
  );

  testWidgets('a failure retained from an earlier open does not outrank the '
      'refresh that follows it', (tester) async {
    final api = _DetailApi(
      detailError: DioException(
        requestOptions: RequestOptions(path: '/api/v1/notes/note-1'),
        response: Response<void>(
          requestOptions: RequestOptions(path: '/api/v1/notes/note-1'),
          statusCode: 403,
        ),
        type: DioExceptionType.badResponse,
      ),
    );
    final container = await pumpEditor(tester, api);
    expect(find.text(l10n(tester).noteNoAccess), findsOneWidget);

    await closeEditor(tester);
    api
      ..detailError = null
      ..detail = _noteJson(writeAccess: true)
      ..heldDetail = Completer<Map<String, dynamic>>();
    container.invalidate(noteByIdProvider('note-1'));
    await openEditor(tester, container);
    expect(find.text(l10n(tester).noteNoAccess), findsNothing);

    api.heldDetail!.complete(_noteJson(writeAccess: true));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      contentController(tester).document.toPlainText(),
      contains('original'),
    );
  });

  group('note Share menu', () {
    Future<void> openOverflow(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
    }

    testWidgets('is offered with Advanced on and opens the access sheet', (
      tester,
    ) async {
      final api = _DetailApi(detail: _noteJson(writeAccess: true));
      await storeLocally(_noteJson(writeAccess: true));
      await pumpEditor(tester, api, advanced: true);

      await openOverflow(tester);
      await tester.tap(find.text(l10n(tester).noteShare));
      await tester.pumpAndSettle();

      expect(api.accessReads, ['note-1']);
      expect(find.byKey(const Key('workspace-access-list')), findsOneWidget);
    });

    testWidgets('is hidden with Advanced off while editing still works', (
      tester,
    ) async {
      final api = _DetailApi(detail: _noteJson(writeAccess: true));
      await storeLocally(_noteJson(writeAccess: true));
      await pumpEditor(tester, api);

      await openOverflow(tester);

      expect(find.text(l10n(tester).noteShare), findsNothing);
      expect(
        tester.widget<FleatherEditor>(find.byType(FleatherEditor)).readOnly,
        isFalse,
      );
    });

    testWidgets('is hidden on a read-only note even with Advanced on', (
      tester,
    ) async {
      final api = _DetailApi(detail: _noteJson(writeAccess: false));
      await storeLocally(_noteJson(writeAccess: false));
      await pumpEditor(tester, api, advanced: true);

      await openOverflow(tester);

      expect(find.text(l10n(tester).noteShare), findsNothing);
      expect(find.text(l10n(tester).delete), findsNothing);
    });
  });
}

class _GatedDetailApi extends _DetailApi {
  _GatedDetailApi(this._gate, {super.detail});

  final Future<void> _gate;

  @override
  Future<Map<String, dynamic>> getNoteById(String id) async {
    await _gate;
    return super.getNoteById(id);
  }
}
