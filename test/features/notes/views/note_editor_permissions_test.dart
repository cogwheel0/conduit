import 'dart:async';

import 'package:conduit/features/notes/views/note_editor_page.dart';
import 'package:conduit/features/notes/widgets/note_file_attachment.dart';
import 'package:conduit_core/features/notes/utils/note_file_cards.dart';
import 'package:conduit_core/features/notes/utils/note_page_data.dart';
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
import 'package:conduit_core/features/sharing/providers/principal_lookup.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
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
  String? ownerName,
  String md = 'original',
  List<Map<String, dynamic>>? pages,
}) => {
  'id': 'note-1',
  'user_id': owner,
  if (ownerName != null) 'user': {'id': owner, 'name': ownerName},
  'title': 'Shared note',
  'write_access': writeAccess,
  'data': {
    'content': {'md': md, 'html': '', 'json': null},
    // The shape of an Open WebUI 0.12.5 note.
    if (pages != null) ...{
      'pages': pages,
      'pages_revision': 0,
      'search_text': md,
    },
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
    Map<String, String> userNames = const {},
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
        // Advanced stays off: nothing here depends on it.
        appSettingsProvider.overrideWithValue(const AppSettings()),
        workspaceCapabilitiesProvider.overrideWith(
          (ref) async => WorkspaceCapabilities.all,
        ),
        syncEngineProvider.overrideWith(_QuietSyncEngine.new),
        // People are named from a fixed list, never the network.
        workspacePrincipalLookupProvider.overrideWithValue(
          WorkspacePrincipalLookup(
            fetchUser: (id) async => switch (userNames[id]) {
              final String name => WorkspacePrincipalPreview(
                id: id,
                type: WorkspacePrincipalType.user,
                name: name,
              ),
              null => null,
            },
            fetchGroups: () async => const [],
          ),
        ),
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

  testWidgets('text typed before a sync brings new pages is still saved, to '
      'the main page', (tester) async {
    final onePage = _noteJson(
      writeAccess: true,
      pages: [
        {
          'id': 'main',
          'title': 'Shared note',
          'content': {'md': 'original', 'html': '', 'json': null},
        },
      ],
    );
    await storeLocally(onePage);
    await pumpEditor(tester, _DetailApi(detail: onePage));
    typeInto(tester, 'draft ');
    await tester.pump();

    // A sync stores the note with a second page before the draft is saved.
    await storeLocally(
      _noteJson(
        writeAccess: true,
        md: '## Shared note\n\noriginal\n\n## Two\n\ntwo',
        pages: [
          {
            'id': 'main',
            'title': 'Shared note',
            'content': {'md': 'original', 'html': '', 'json': null},
          },
          {
            'id': 'p2',
            'title': 'Two',
            'content': {'md': 'two', 'html': '', 'json': null},
          },
        ],
      ),
    );
    await letAutosaveRun(tester);

    final data = decodeNoteData((await db.notesDao.getNote('note-1'))!.data);
    expect(notePageMarkdown(data, 'main'), startsWith('draft original'));
    expect(notePageMarkdown(data, 'p2'), 'two');
  });

  Map<String, dynamic> twoPageNote() => _noteJson(
    writeAccess: true,
    md: '## Shared note\n\none\n\n## Two\n\ntwo',
    pages: [
      {
        'id': 'main',
        'title': 'Shared note',
        'content': {'md': 'one', 'html': '', 'json': null},
      },
      {
        'id': 'p2',
        'title': 'Two',
        'content': {'md': 'two', 'html': '', 'json': null},
      },
    ],
  );

  testWidgets('a note with several pages opens on its main page, editable, '
      'and moves to another page from the Pages sheet', (tester) async {
    final note = twoPageNote();
    await storeLocally(note);
    await pumpEditor(tester, _DetailApi(detail: note));

    expect(
      tester.widget<FleatherEditor>(find.byType(FleatherEditor)).readOnly,
      isFalse,
    );
    expect(contentController(tester).document.toPlainText().trim(), 'one');

    await tester.tap(find.byKey(const ValueKey<String>('note-page-chip')));
    await tester.pumpAndSettle();
    expect(find.text(l10n(tester).notePages), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('note-page-p2')));
    await tester.pumpAndSettle();

    expect(contentController(tester).document.toPlainText().trim(), 'two');
    typeInto(tester, 'more ');
    await letAutosaveRun(tester);

    final data = decodeNoteData((await db.notesDao.getNote('note-1'))!.data);
    expect(notePageMarkdown(data, 'p2'), startsWith('more two'));
    expect(notePageMarkdown(data, 'main'), 'one');
    expect(noteDirtyPageIds(data), ['p2']);
  });

  testWidgets('a page edit is saved before the editor moves to another page', (
    tester,
  ) async {
    final note = twoPageNote();
    await storeLocally(note);
    await pumpEditor(tester, _DetailApi(detail: note));

    typeInto(tester, 'first ');
    await tester.tap(find.byKey(const ValueKey<String>('note-page-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('note-page-p2')));
    await tester.pumpAndSettle();

    final data = decodeNoteData((await db.notesDao.getNote('note-1'))!.data);
    expect(notePageMarkdown(data, 'main'), startsWith('first one'));
    expect(contentController(tester).document.toPlainText().trim(), 'two');
  });

  testWidgets('moving to a page shows it as stored now', (tester) async {
    final note = twoPageNote();
    await storeLocally(note);
    await pumpEditor(tester, _DetailApi(detail: note));

    // A sync brings a newer copy of the second page while the editor is open.
    final newer = twoPageNote();
    (((newer['data'] as Map)['pages'] as List)[1] as Map)['content'] = {
      'md': 'two, edited on the web',
      'html': '',
      'json': null,
    };
    await storeLocally(newer);

    await tester.tap(find.byKey(const ValueKey<String>('note-page-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('note-page-p2')));
    await tester.pumpAndSettle();

    expect(
      contentController(tester).document.toPlainText().trim(),
      'two, edited on the web',
    );
  });

  testWidgets('text written on a page a sync removed is kept, to save as a '
      'note of its own or discard', (tester) async {
    final note = twoPageNote();
    await storeLocally(note);
    await pumpEditor(tester, _DetailApi(detail: note));
    await tester.tap(find.byKey(const ValueKey<String>('note-page-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('note-page-p2')));
    await tester.pumpAndSettle();

    // The web removes the second page; a sync stores the note without it.
    final onePage = _noteJson(
      writeAccess: true,
      md: 'one',
      pages: [
        {
          'id': 'main',
          'title': 'Shared note',
          'content': {'md': 'one', 'html': '', 'json': null},
        },
      ],
    );
    await storeLocally(onePage);
    typeInto(tester, 'lost? ');
    await letAutosaveRun(tester);
    await tester.pump();

    expect(find.text(l10n(tester).notePageMissingNotice), findsOneWidget);
    expect(
      tester.widget<FleatherEditor>(find.byType(FleatherEditor)).readOnly,
      isTrue,
    );
    expect(contentController(tester).document.toPlainText(), contains('lost?'));
    expect(
      find.byKey(const ValueKey<String>('note-save-as-own')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey<String>('note-discard-draft')));
    await tester.pumpAndSettle();
    expect(find.text(l10n(tester).notePageMissingNotice), findsNothing);
    expect(contentController(tester).document.toPlainText().trim(), 'one');
  });

  testWidgets('a one-page note from 0.12.5 shows the files its content links '
      'as cards in the text', (tester) async {
    const md = 'original\n\n[Rec.m4a](/api/v1/files/f1/content)';
    final note = _noteJson(
      writeAccess: true,
      md: md,
      pages: [
        {
          'id': 'main',
          'title': 'Shared note',
          'content': {'md': md, 'html': '', 'json': null},
        },
      ],
    );
    final api = _DetailApi(detail: note);
    await storeLocally(note);
    await pumpEditor(tester, api);

    expect(
      tester.widget<FleatherEditor>(find.byType(FleatherEditor)).readOnly,
      isFalse,
    );
    expect(find.byKey(const ValueKey<String>('note-page-chip')), findsNothing);
    final card = tester.widget<NoteFileAttachment>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('note-file-card-f1')),
        matching: find.byType(NoteFileAttachment),
      ),
    );
    expect(card.file['id'], 'f1');
    expect(card.file['name'], 'Rec.m4a');
    // No separate list: the card is the attachment.
    expect(find.byType(NoteFileAttachment), findsOneWidget);
  });

  testWidgets('removing a listed file also takes its link out of a sentence', (
    tester,
  ) async {
    const md = 'see [Rec.m4a](/api/v1/files/f1/content) here';
    final note = _noteJson(writeAccess: true, md: md);
    (note['data'] as Map)['files'] = [
      {'type': 'file', 'id': 'f1', 'name': 'Rec.m4a'},
    ];
    await storeLocally(note);
    await pumpEditor(tester, _DetailApi(detail: note));

    final listed = find.byType(NoteFileAttachment);
    expect(listed, findsOneWidget);
    await tester.tap(
      find.descendant(of: listed, matching: find.byIcon(Icons.cancel_rounded)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n(tester).delete).last);
    await tester.pumpAndSettle();
    await letAutosaveRun(tester);

    final data = decodeNoteData((await db.notesDao.getNote('note-1'))!.data);
    expect(data['files'], isEmpty);
    expect(
      (data['content'] as Map)['md'],
      isNot(contains('/api/v1/files/f1/content')),
    );
  });

  testWidgets('removing a file card detaches the file on the next save', (
    tester,
  ) async {
    const md = 'original\n\n[Rec.m4a](/api/v1/files/f1/content)';
    final note = _noteJson(
      writeAccess: true,
      md: md,
      pages: [
        {
          'id': 'main',
          'title': 'Shared note',
          'content': {'md': md, 'html': '', 'json': null},
        },
      ],
    );
    await storeLocally(note);
    await pumpEditor(tester, _DetailApi(detail: note));

    // A real tap on the card's remove button, inside the editor's text.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('note-file-card-f1')),
        matching: find.byIcon(Icons.cancel_rounded),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n(tester).delete).last);
    await tester.pumpAndSettle();
    await letAutosaveRun(tester);

    expect(find.byType(NoteFileAttachment), findsNothing);
    final data = decodeNoteData((await db.notesDao.getNote('note-1'))!.data);
    expect(notePageMarkdown(data, 'main'), isNot(contains('/files/f1/')));
    expect(notePageMarkdown(data, 'main'), contains('original'));
  });

  testWidgets('a file link a sync wrote while the note was open survives '
      'the next save, and shows in the editor', (tester) async {
    const md = 'original';
    final note = _noteJson(
      writeAccess: true,
      md: md,
      pages: [
        {
          'id': 'main',
          'title': 'Shared note',
          'content': {'md': md, 'html': '', 'json': null},
        },
      ],
    );
    final api = _DetailApi(detail: note);
    await storeLocally(note);
    await pumpEditor(tester, api);

    // A save sent from here moved a recording into the content on the server,
    // and the stored note took the server's copy.
    const link = '[Rec.m4a](/api/v1/files/f1/content)';
    const linked = '$md\n\n$link';
    await storeLocally(
      _noteJson(
        writeAccess: true,
        md: linked,
        pages: [
          {
            'id': 'main',
            'title': 'Shared note',
            'content': {'md': linked, 'html': '', 'json': null},
          },
        ],
      ),
    );

    typeInto(tester, 'more ');
    await letAutosaveRun(tester);

    final row = (await db.notesDao.getNote('note-1'))!;
    final saved = notePageMarkdown(decodeNoteData(row.data), 'main');
    expect(saved, startsWith('more original'));
    expect(saved, contains(link));
    expect(
      noteMarkdownFromDocument(contentController(tester).document),
      contains(link),
    );
  });

  testWidgets('a file link removed in the editor stays removed', (
    tester,
  ) async {
    const link = '[Rec.m4a](/api/v1/files/f1/content)';
    const md = 'original\n\n$link';
    final note = _noteJson(
      writeAccess: true,
      md: md,
      pages: [
        {
          'id': 'main',
          'title': 'Shared note',
          'content': {'md': md, 'html': '', 'json': null},
        },
      ],
    );
    await storeLocally(note);
    await pumpEditor(tester, _DetailApi(detail: note));

    final controller = contentController(tester);
    final card = noteFileCardOffsets(controller.document, 'f1').single;
    controller.replaceText(card, 1, '');
    await letAutosaveRun(tester);

    final row = (await db.notesDao.getNote('note-1'))!;
    expect(
      notePageMarkdown(decodeNoteData(row.data), 'main'),
      isNot(contains('/api/v1/files/f1/content')),
    );
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

  testWidgets('a read-only note names who shared it, with a lock', (
    tester,
  ) async {
    final note = _noteJson(writeAccess: false, ownerName: 'Casey');
    final api = _DetailApi(detail: note);
    await storeLocally(note);
    await pumpEditor(tester, api);

    expect(
      find.text(l10n(tester).libraryNoteSharedBy('Casey')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('note-access-notice')),
        matching: find.byIcon(Icons.lock_outline),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the owner of a read-only note is looked up when the note does '
      'not name them', (tester) async {
    final api = _DetailApi(detail: _noteJson(writeAccess: false));
    await storeLocally(_noteJson(writeAccess: false));
    await pumpEditor(tester, api, userNames: {'creator': 'Robin'});
    await tester.pump();
    await tester.pump();

    expect(
      find.text(l10n(tester).libraryNoteSharedBy('Robin')),
      findsOneWidget,
    );
  });

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

    testWidgets('is offered with Advanced off and opens the access sheet', (
      tester,
    ) async {
      final api = _DetailApi(detail: _noteJson(writeAccess: true));
      await storeLocally(_noteJson(writeAccess: true));
      await pumpEditor(tester, api);

      await openOverflow(tester);
      await tester.tap(find.text(l10n(tester).noteShare));
      await tester.pumpAndSettle();

      expect(api.accessReads, ['note-1']);
      expect(find.byKey(const Key('workspace-access-list')), findsOneWidget);
    });

    testWidgets('is hidden on a read-only note', (tester) async {
      final api = _DetailApi(detail: _noteJson(writeAccess: false));
      await storeLocally(_noteJson(writeAccess: false));
      await pumpEditor(tester, api);

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
