import 'dart:async';

import 'package:conduit/features/chat/services/voice_input_service.dart';
import 'package:conduit/features/notes/utils/note_file_download.dart';
import 'package:conduit/features/notes/views/note_editor_page.dart';
import 'package:conduit/features/notes/widgets/audio_player_dialog.dart';
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
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
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
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fleather/fleather.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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

  /// File ids whose content was asked for, and the size each could be.
  final fileReads = <String>[];
  final fileReadLimits = <int?>[];

  /// Runs while a file is downloaded; with it the download succeeds.
  void Function()? duringFileRead;

  @override
  Future<String> getFileContent(
    String fileId, {
    int? maxBytes,
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async {
    fileReads.add(fileId);
    fileReadLimits.add(maxBytes);
    final during = duringFileRead;
    if (during == null) throw StateError('offline');
    during();
    return 'JVBERi0='; // %PDF-
  }

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

class _DelayedNoteDeleter extends NoteDeleter {
  final result = Completer<bool>();
  int calls = 0;
  final ids = <String>[];

  @override
  Future<bool> deleteNote(String id) {
    calls++;
    ids.add(id);
    return result.future;
  }
}

/// Dictation whose start is held until the test lets it go.
class _HeldVoice extends VoiceInputService {
  final ready = Completer<bool>();
  StreamController<String>? run;

  @override
  bool get isSupportedPlatform => true;

  @override
  Stream<String> get textStream => run?.stream ?? const Stream<String>.empty();

  @override
  Future<bool> initialize({bool forceLocalStt = false}) => ready.future;

  @override
  Future<Stream<String>> beginListening({
    bool iosAudioSessionManagedExternally = false,
    bool nativeAccumulateResults = true,
    bool holdServerRecorderForResponseWait = false,
    VoiceInputRecording? recording,
  }) async => (run = StreamController<String>.broadcast()).stream;

  @override
  Future<void> stopListening() async {
    final current = run;
    run = null;
    await current?.close();
  }

  @override
  Future<void> dispose() async {}
}

/// Dictation that hands over its last words as it stops, as a speech engine
/// finishing its transcript does.
class _LastWordsVoice extends _HeldVoice {
  @override
  Future<void> stopListening() async {
    run?.add('spoken words, last words');
    await super.stopListening();
  }
}

Map<String, dynamic> _noteJson({
  required bool writeAccess,
  String owner = 'creator',
  String? ownerName,
  String md = 'original',
  String title = 'Shared note',
  List<Map<String, dynamic>>? pages,
}) => {
  'id': 'note-1',
  'user_id': owner,
  if (ownerName != null) 'user': {'id': owner, 'name': ownerName},
  'title': title,
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
    NoteDeleter? deleter,
    AppSettings settings = const AppSettings(),
    VoiceInputService? voice,
  }) async {
    final container = ProviderContainer(
      // A provider that errors would otherwise schedule a retry timer.
      retry: (_, _) => null,
      overrides: [
        if (deleter != null) noteDeleterProvider.overrideWith(() => deleter),
        appDatabaseProvider.overrideWith((ref) => db),
        apiServiceProvider.overrideWithValue(api),
        isAuthenticatedProvider2.overrideWithValue(true),
        authTokenProvider3.overrideWithValue('token'),
        currentUserProvider2.overrideWith((ref) => ref.watch(_currentUser)),
        connectivityStatusProvider.overrideWithValue(ConnectivityStatus.online),
        isOnlineProvider.overrideWithValue(true),
        // Advanced stays off: nothing here depends on it.
        appSettingsProvider.overrideWithValue(settings),
        workspaceCapabilitiesProvider.overrideWith(
          (ref) async => WorkspaceCapabilities.all,
        ),
        syncEngineProvider.overrideWith(_QuietSyncEngine.new),
        if (voice != null) voiceInputServiceProvider.overrideWithValue(voice),
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

  testWidgets('moving to a page takes the title a sync gave the note', (
    tester,
  ) async {
    final note = twoPageNote();
    await storeLocally(note);
    await pumpEditor(tester, _DetailApi(detail: note));
    await storeLocally(twoPageNote()..['title'] = 'Renamed on the web');

    await tester.tap(find.byKey(const ValueKey<String>('note-page-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('note-page-p2')));
    await tester.pumpAndSettle();
    typeInto(tester, 'more ');
    await letAutosaveRun(tester);

    expect(find.text('Renamed on the web'), findsWidgets);
    final row = (await db.notesDao.getNote('note-1'))!;
    expect(row.title, 'Renamed on the web');
    expect(
      notePageMarkdown(decodeNoteData(row.data), 'p2'),
      startsWith('more two'),
    );
  });

  testWidgets('the page chip is a labelled button that opens the Pages sheet', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final note = twoPageNote();
    await storeLocally(note);
    await pumpEditor(tester, _DetailApi(detail: note));

    final chip = find.bySemanticsLabel(
      l10n(tester).notePageChipLabel('Shared note'),
    );
    expect(chip, findsOneWidget);
    expect(
      tester.getSemantics(chip),
      matchesSemantics(
        label: l10n(tester).notePageChipLabel('Shared note'),
        isButton: true,
        hasTapAction: true,
      ),
    );
    tester.semantics.tap(
      find.semantics.byLabel(l10n(tester).notePageChipLabel('Shared note')),
    );
    await tester.pumpAndSettle();
    expect(find.text(l10n(tester).notePages), findsOneWidget);
    handle.dispose();
  });

  testWidgets('text typed while a save runs is still unsaved after it', (
    tester,
  ) async {
    final note = _noteJson(writeAccess: true);
    await storeLocally(note);
    final container = await pumpEditor(tester, _DetailApi(detail: note));
    // Something else holds the note while the first save waits for it.
    final held = Completer<void>();
    unawaited(
      container.read(noteLocksProvider).runExclusive('note-1', () => held.future),
    );

    typeInto(tester, 'first ');
    await letAutosaveRun(tester);
    typeInto(tester, 'second ');
    held.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final pop = tester.widget<PopScope<Object?>>(
      find.byWidgetPredicate((widget) => widget is PopScope),
    );
    expect(pop.canPop, isFalse);
    await letAutosaveRun(tester);
    final data = decodeNoteData((await db.notesDao.getNote('note-1'))!.data);
    expect((data['content'] as Map)['md'], startsWith('second first original'));
  });

  testWidgets('dictation asked for before a page switch writes into the page '
      'it was asked on', (tester) async {
    // The voice options sheet trips a debug check about its tiles' ink,
    // which has nothing to do with what is tested here.
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('ink splashes may be invisible')) {
        return;
      }
      originalOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = originalOnError);
    final voice = _HeldVoice();
    final note = twoPageNote();
    await storeLocally(note);
    await pumpEditor(tester, _DetailApi(detail: note), voice: voice);

    await tester.tap(find.byTooltip(l10n(tester).voiceOptions));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n(tester).dictation).last);
    await tester.pumpAndSettle();
    // Listening is still starting when the user picks another page.
    await tester.tap(find.byKey(const ValueKey<String>('note-page-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('note-page-p2')));
    await tester.pumpAndSettle();
    expect(contentController(tester).document.toPlainText().trim(), 'one');

    voice.ready.complete(true);
    await tester.pumpAndSettle();
    voice.run!.add('spoken');
    await tester.pump();

    final text = contentController(tester).document.toPlainText();
    expect(text, contains('spoken'));
    expect(text, contains('one'));
    expect(text, isNot(contains('two')));
  });

  testWidgets('dictation stops when its page turns out removed at save, and '
      'the text stays as it was', (tester) async {
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('ink splashes may be invisible')) {
        return;
      }
      originalOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = originalOnError);
    final voice = _HeldVoice()..ready.complete(true);
    final note = twoPageNote();
    await storeLocally(note);
    await pumpEditor(tester, _DetailApi(detail: note), voice: voice);
    await tester.tap(find.byKey(const ValueKey<String>('note-page-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('note-page-p2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(l10n(tester).voiceOptions));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n(tester).dictation).last);
    await tester.pumpAndSettle();

    // The web removes the page, then the first words are saved to it.
    await storeLocally(
      _noteJson(
        writeAccess: true,
        md: 'one',
        pages: [
          {
            'id': 'main',
            'title': 'Shared note',
            'content': {'md': 'one', 'html': '', 'json': null},
          },
        ],
      ),
    );
    final run = voice.run!;
    run.add('spoken');
    await tester.pump();
    await letAutosaveRun(tester);
    await tester.pump();
    expect(find.text(l10n(tester).notePageMissingNotice), findsOneWidget);

    // Listening ended: no later words reach the kept text.
    expect(run.isClosed, isTrue);
    expect(voice.run, isNull);
    expect(contentController(tester).document.toPlainText(), contains('spoken'));
  });

  testWidgets('dictation that was starting when its page turned out removed '
      'does not start', (tester) async {
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('ink splashes may be invisible')) {
        return;
      }
      originalOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = originalOnError);
    final voice = _HeldVoice();
    final note = twoPageNote();
    await storeLocally(note);
    await pumpEditor(tester, _DetailApi(detail: note), voice: voice);
    await tester.tap(find.byKey(const ValueKey<String>('note-page-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('note-page-p2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(l10n(tester).voiceOptions));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n(tester).dictation).last);
    await tester.pumpAndSettle();

    // While listening starts, the web removes the page and a save of the
    // text typed meanwhile finds it gone.
    typeInto(tester, 'draft ');
    await storeLocally(
      _noteJson(
        writeAccess: true,
        md: 'one',
        pages: [
          {
            'id': 'main',
            'title': 'Shared note',
            'content': {'md': 'one', 'html': '', 'json': null},
          },
        ],
      ),
    );
    await letAutosaveRun(tester);
    await tester.pump();
    expect(find.text(l10n(tester).notePageMissingNotice), findsOneWidget);

    voice.ready.complete(true);
    await tester.pumpAndSettle();

    expect(voice.run, isNull);
  });

  testWidgets('Discard waits while the draft is saved as a note of its own', (
    tester,
  ) async {
    final note = twoPageNote();
    await storeLocally(note);
    await pumpEditor(tester, _DetailApi(detail: note));
    await tester.tap(find.byKey(const ValueKey<String>('note-page-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('note-page-p2')));
    await tester.pumpAndSettle();
    await storeLocally(
      _noteJson(
        writeAccess: true,
        md: 'one',
        pages: [
          {
            'id': 'main',
            'title': 'Shared note',
            'content': {'md': 'one', 'html': '', 'json': null},
          },
        ],
      ),
    );
    typeInto(tester, 'kept ');
    await letAutosaveRun(tester);
    await tester.pump();
    expect(find.text(l10n(tester).notePageMissingNotice), findsOneWidget);

    // Discard is tapped while the new note is still being created.
    final discard = tester.getCenter(
      find.byKey(const ValueKey<String>('note-discard-draft')),
    );
    await tester.tap(find.byKey(const ValueKey<String>('note-save-as-own')));
    await tester.tapAt(discard);
    await tester.pumpAndSettle();
    await letAutosaveRun(tester);

    final copies = [
      for (final row in await db.select(db.notes).get())
        if (row.id.startsWith('local:')) row,
    ];
    expect(copies, hasLength(1));
    expect(
      (decodeJsonMap(copies.single.data)['content'] as Map)['md'],
      startsWith('kept two'),
    );
  });

  testWidgets('once a refused draft is discarded, the other pages can be '
      'read', (tester) async {
    final note = twoPageNote();
    await storeLocally(note);
    await pumpEditor(tester, _DetailApi(detail: note));

    typeInto(tester, 'unsaved ');
    await db.notesDao.storeNoteAccessProjection('note-1', writeAccess: false);
    await letAutosaveRun(tester);
    expect(find.text(l10n(tester).noteAccessRevokedNotice), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('note-discard-draft')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('note-page-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('note-page-p2')));
    await tester.pumpAndSettle();

    expect(contentController(tester).document.toPlainText().trim(), 'two');
    expect(
      tester.widget<FleatherEditor>(find.byType(FleatherEditor)).readOnly,
      isTrue,
    );
    await expectNothingQueued();
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

  testWidgets('once a draft whose save as a note of its own failed is '
      'discarded, the next edit is saved to the note', (tester) async {
    final note = twoPageNote();
    await storeLocally(note);
    await pumpEditor(tester, _DetailApi(detail: note));
    await tester.tap(find.byKey(const ValueKey<String>('note-page-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('note-page-p2')));
    await tester.pumpAndSettle();
    await storeLocally(
      _noteJson(
        writeAccess: true,
        md: 'one',
        pages: [
          {
            'id': 'main',
            'title': 'Shared note',
            'content': {'md': 'one', 'html': '', 'json': null},
          },
        ],
      ),
    );
    typeInto(tester, 'lost? ');
    await letAutosaveRun(tester);
    await tester.pump();
    expect(find.text(l10n(tester).notePageMissingNotice), findsOneWidget);

    // Saving the page as a note of its own fails: the store refuses it.
    await tester.runAsync(
      () => db.customStatement(
        "CREATE TRIGGER refuse_local_note BEFORE INSERT ON notes "
        "WHEN NEW.id LIKE 'local:%' BEGIN SELECT RAISE(ABORT, 'refused'); END",
      ),
    );
    await tester.tap(find.byKey(const ValueKey<String>('note-save-as-own')));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => db.customStatement('DROP TRIGGER refuse_local_note'),
    );

    await tester.tap(find.byKey(const ValueKey<String>('note-discard-draft')));
    await tester.pumpAndSettle();
    expect(contentController(tester).document.toPlainText().trim(), 'one');

    // The next edit is the note's own, saved to it, not another try at the
    // discarded draft.
    typeInto(tester, 'more ');
    await letAutosaveRun(tester);
    await tester.pumpAndSettle();
    final copies = [
      for (final row in await db.select(db.notes).get())
        if (row.id.startsWith('local:')) row,
    ];
    expect(copies, isEmpty);
    final row = (await db.notesDao.getNote('note-1'))!;
    expect(row.dirtyData, isTrue);
    expect(
      (decodeJsonMap(row.data)['content'] as Map)['md'],
      startsWith('more one'),
    );
  });

  testWidgets('text put back as it was while its save waited leaves a removed '
      'page for the main page', (tester) async {
    final note = twoPageNote();
    await storeLocally(note);
    final container = await pumpEditor(tester, _DetailApi(detail: note));
    await tester.tap(find.byKey(const ValueKey<String>('note-page-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('note-page-p2')));
    await tester.pumpAndSettle();

    // Something else holds the note while the edit's save waits for it.
    final held = Completer<void>();
    unawaited(
      container.read(noteLocksProvider).runExclusive('note-1', () => held.future),
    );
    typeInto(tester, 'lost? ');
    await letAutosaveRun(tester);
    // Meanwhile a sync removes the page, and the user takes the edit back.
    await storeLocally(
      _noteJson(
        writeAccess: true,
        md: 'one',
        pages: [
          {
            'id': 'main',
            'title': 'Shared note',
            'content': {'md': 'one', 'html': '', 'json': null},
          },
        ],
      ),
    );
    contentController(tester).replaceText(0, 'lost? '.length, '');
    await tester.pump();
    held.complete();
    await tester.pumpAndSettle();

    // Nothing unsaved is left of the page: the editor shows the main page,
    // to be edited, rather than a removed page it cannot leave.
    expect(find.text(l10n(tester).notePageMissingNotice), findsNothing);
    expect(
      tester.widget<FleatherEditor>(find.byType(FleatherEditor)).readOnly,
      isFalse,
    );
    expect(contentController(tester).document.toPlainText().trim(), 'one');
  });

  testWidgets('a removed page whose stored note cannot be read back keeps '
      'its recovery choices', (tester) async {
    final note = twoPageNote();
    await storeLocally(note);
    final container = await pumpEditor(tester, _DetailApi(detail: note));
    await tester.tap(find.byKey(const ValueKey<String>('note-page-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('note-page-p2')));
    await tester.pumpAndSettle();

    final held = Completer<void>();
    unawaited(
      container.read(noteLocksProvider).runExclusive('note-1', () => held.future),
    );
    typeInto(tester, 'lost? ');
    await letAutosaveRun(tester);
    // A sync removes the page, and the note's row can no longer be read back
    // as it is; the user takes the edit back while the save waits.
    await storeLocally(
      _noteJson(
        writeAccess: true,
        md: 'one',
        pages: [
          {
            'id': 'main',
            'title': 'Shared note',
            'content': {'md': 'one', 'html': '', 'json': null},
          },
        ],
      ),
    );
    await tester.runAsync(
      () => (db.update(db.notes)..where((t) => t.id.equals('note-1'))).write(
        const NotesCompanion(deleted: Value(true)),
      ),
    );
    contentController(tester).replaceText(0, 'lost? '.length, '');
    // The undone edit's own save finds nothing to save before the first one
    // fails.
    await letAutosaveRun(tester);
    held.complete();
    await tester.pumpAndSettle();
    expect(find.text(l10n(tester).notePageMissingNotice), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('note-discard-draft')),
      findsOneWidget,
    );

    // Trying another page saves first; that save must not drop the choices.
    await tester.tap(find.byKey(const ValueKey<String>('note-page-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('note-page-main')));
    await tester.pumpAndSettle();
    expect(find.text(l10n(tester).notePageMissingNotice), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('note-discard-draft')),
      findsOneWidget,
    );
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

  testWidgets('a file a 0.12.5 note links in a sentence is listed, to be '
      'played', (tester) async {
    const md =
        'Listen to [Rec.m4a](/api/v1/files/f1/content)\n\n'
        '[Doc.pdf](/api/v1/files/f2/content)';
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

    // The link on a line of its own is a card; the one in a sentence is
    // listed above the text.
    expect(
      find.byKey(const ValueKey<String>('note-file-card-f2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('note-file-card-f1')),
      findsNothing,
    );
    final shown = [
      for (final widget in tester.widgetList<NoteFileAttachment>(
        find.byType(NoteFileAttachment),
      ))
        widget.file['id'],
    ];
    expect(shown, unorderedEquals(['f1', 'f2']));
  });

  testWidgets('a card removal the server refuses keeps the draft and stops '
      'saving', (tester) async {
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
    // An earlier build also listed the file.
    (note['data'] as Map)['files'] = [
      {'type': 'file', 'id': 'f1', 'name': 'Rec.m4a'},
    ];
    await storeLocally(note);
    await pumpEditor(tester, _DetailApi(detail: note));

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('note-file-card-f1')),
        matching: find.byIcon(Icons.cancel_rounded),
      ),
    );
    await tester.pumpAndSettle();
    await db.notesDao.storeNoteAccessProjection('note-1', writeAccess: false);
    await tester.tap(find.text(l10n(tester).delete).last);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(l10n(tester).noteAccessRevokedNotice), findsOneWidget);
    await expectNothingQueued();
  });

  testWidgets('a file being removed keeps the editor on its page, so the '
      'other page keeps its link', (tester) async {
    const link = '[Rec.m4a](/api/v1/files/f1/content)';
    final note = _noteJson(
      writeAccess: true,
      md: '## Shared note\n\nsee $link here\n\n## Two\n\nalso $link there',
      pages: [
        {
          'id': 'main',
          'title': 'Shared note',
          'content': {'md': 'see $link here', 'html': '', 'json': null},
        },
        {
          'id': 'p2',
          'title': 'Two',
          'content': {'md': 'also $link there', 'html': '', 'json': null},
        },
      ],
    );
    await storeLocally(note);
    final container = await pumpEditor(tester, _DetailApi(detail: note));
    // Something else holds the note while the removal waits for it.
    final held = Completer<void>();
    unawaited(
      container.read(noteLocksProvider).runExclusive('note-1', () => held.future),
    );

    await tester.tap(
      find.descendant(
        of: find.byType(NoteFileAttachment),
        matching: find.byIcon(Icons.cancel_rounded),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n(tester).delete).last);
    // A spinner runs while the removal waits, so time is pumped by hand.
    Future<void> settleByHand() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    await settleByHand();
    await tester.tap(find.byKey(const ValueKey<String>('note-page-chip')));
    for (var i = 0; i < 4; i++) {
      await settleByHand();
    }
    await tester.tap(find.byKey(const ValueKey<String>('note-page-p2')));
    // The sheet closes, then the switch reads the stored note.
    for (var i = 0; i < 4; i++) {
      await settleByHand();
    }
    held.complete();
    await tester.pumpAndSettle();
    await letAutosaveRun(tester);

    final data = decodeNoteData((await db.notesDao.getNote('note-1'))!.data);
    expect(notePageMarkdown(data, 'main'), isNot(contains('/files/f1/')));
    expect(notePageMarkdown(data, 'p2'), contains(link));
    expect(contentController(tester).document.toPlainText(), contains('see'));
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

  testWidgets('a document card opens the file, not the audio player', (
    tester,
  ) async {
    const md = 'original\n\n[Plan.pdf](/api/v1/files/f2/content)';
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
    final api = _DetailApi(detail: note);
    await pumpEditor(tester, api);

    await tester.tap(find.byKey(const ValueKey<String>('note-file-card-f2')));
    await tester.pumpAndSettle();

    expect(api.fileReads, ['f2']);
    expect(api.fileReadLimits, [kNoteFileShareMaxBytes]);
    expect(find.byType(AudioPlayerDialog), findsNothing);
  });

  testWidgets('a document downloaded while another account signed in is not '
      'shared', (tester) async {
    const md = 'original\n\n[Plan.pdf](/api/v1/files/f2/content)';
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
    final api = _DetailApi(detail: note);
    final container = await pumpEditor(tester, api);
    api.duringFileRead = () =>
        container.read(_currentUser.notifier).switchTo(_bob);

    await tester.tap(find.byKey(const ValueKey<String>('note-file-card-f2')));
    await tester.pumpAndSettle();
    // Real time for any platform call the download goes on to make: with no
    // plugin in tests, writing the file would fail and say so.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();

    expect(api.fileReads, ['f2']);
    // Nothing went on to be written or shared, so nothing failed either.
    expect(find.text(l10n(tester).errorMessage), findsNothing);
  });

  testWidgets('removing a file card stops dictation, whose place it moves', (
    tester,
  ) async {
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('ink splashes may be invisible')) {
        return;
      }
      originalOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = originalOnError);
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
    final voice = _HeldVoice()..ready.complete(true);
    await pumpEditor(tester, _DetailApi(detail: note), voice: voice);
    await tester.tap(find.byTooltip(l10n(tester).voiceOptions));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n(tester).dictation).last);
    await tester.pumpAndSettle();
    expect(voice.run, isNotNull);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('note-file-card-f1')),
        matching: find.byIcon(Icons.cancel_rounded),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n(tester).delete).last);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('note-file-card-f1')), findsNothing);
    expect(voice.run, isNull);
  });

  testWidgets('a card that arrives during dictation goes to the end, clear of '
      'the dictated text', (tester) async {
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('ink splashes may be invisible')) {
        return;
      }
      originalOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = originalOnError);
    final note = _noteJson(
      writeAccess: true,
      md: 'hello',
      pages: [
        {
          'id': 'main',
          'title': 'Shared note',
          'content': {'md': 'hello', 'html': '', 'json': null},
        },
      ],
    );
    await storeLocally(note);
    final voice = _HeldVoice()..ready.complete(true);
    await pumpEditor(tester, _DetailApi(detail: note), voice: voice);
    await tester.tap(find.byTooltip(l10n(tester).voiceOptions));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n(tester).dictation).last);
    await tester.pumpAndSettle();
    final run = voice.run!;
    run.add('spoken');
    await tester.pump();
    // The user puts the cursor before the dictated text.
    await tester.tap(find.byType(FleatherEditor));
    await tester.pump();
    contentController(
      tester,
    ).updateSelection(const TextSelection.collapsed(offset: 0));
    await tester.pump();

    // A sync attaches a file meanwhile; the next save brings its card in.
    const link = '[Rec.m4a](/api/v1/files/f1/content)';
    await storeLocally(
      _noteJson(
        writeAccess: true,
        md: 'hello\n\n$link',
        pages: [
          {
            'id': 'main',
            'title': 'Shared note',
            'content': {'md': 'hello\n\n$link', 'html': '', 'json': null},
          },
        ],
      ),
    );
    await letAutosaveRun(tester);
    await tester.pump();
    expect(noteFileCardsIn(contentController(tester).document), isNotEmpty);

    run.add('spoken more');
    await tester.pump();

    final text = contentController(tester).document.toPlainText();
    expect(text, contains('spoken more'));
    expect(text.indexOf('spoken more'), lessThan(text.indexOf('\uFFFC')));
    expect(noteFileCardsIn(contentController(tester).document), isNotEmpty);
  });

  testWidgets('once dictation has ended by itself, a card goes in at the '
      'cursor again', (tester) async {
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('ink splashes may be invisible')) {
        return;
      }
      originalOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = originalOnError);
    final note = _noteJson(
      writeAccess: true,
      md: 'hello',
      pages: [
        {
          'id': 'main',
          'title': 'Shared note',
          'content': {'md': 'hello', 'html': '', 'json': null},
        },
      ],
    );
    await storeLocally(note);
    final voice = _HeldVoice()..ready.complete(true);
    await pumpEditor(tester, _DetailApi(detail: note), voice: voice);
    await tester.tap(find.byTooltip(l10n(tester).voiceOptions));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n(tester).dictation).last);
    await tester.pumpAndSettle();
    voice.run!
      ..add('spoken')
      ..close();
    await tester.pumpAndSettle();

    // The user puts the cursor at the start; a sync attaches a file, and the
    // next save brings its card in there.
    await tester.tap(find.byType(FleatherEditor));
    await tester.pump();
    contentController(
      tester,
    ).updateSelection(const TextSelection.collapsed(offset: 0));
    await tester.pump();
    const link = '[Rec.m4a](/api/v1/files/f1/content)';
    await storeLocally(
      _noteJson(
        writeAccess: true,
        md: 'hello\n\n$link',
        pages: [
          {
            'id': 'main',
            'title': 'Shared note',
            'content': {'md': 'hello\n\n$link', 'html': '', 'json': null},
          },
        ],
      ),
    );
    await letAutosaveRun(tester);
    await tester.pump();

    final text = contentController(tester).document.toPlainText();
    expect(noteFileCardsIn(contentController(tester).document), isNotEmpty);
    expect(text.indexOf('\uFFFC'), lessThan(text.indexOf('hello')));
  });

  testWidgets('removing a file card calls off dictation that is still '
      'starting', (tester) async {
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('ink splashes may be invisible')) {
        return;
      }
      originalOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = originalOnError);
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
    final voice = _HeldVoice();
    await pumpEditor(tester, _DetailApi(detail: note), voice: voice);
    await tester.tap(find.byTooltip(l10n(tester).voiceOptions));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n(tester).dictation).last);
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('note-file-card-f1')),
        matching: find.byIcon(Icons.cancel_rounded),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n(tester).delete).last);
    await tester.pumpAndSettle();
    voice.ready.complete(true);
    await tester.pumpAndSettle();

    expect(voice.run, isNull);
  });

  testWidgets('removing a file linked in a sentence stops dictation before '
      'the removal is done', (tester) async {
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('ink splashes may be invisible')) {
        return;
      }
      originalOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = originalOnError);
    const md = 'see [Rec.m4a](/api/v1/files/f1/content) here';
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
    final voice = _HeldVoice()..ready.complete(true);
    final container = await pumpEditor(
      tester,
      _DetailApi(detail: note),
      voice: voice,
    );
    await tester.tap(find.byTooltip(l10n(tester).voiceOptions));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n(tester).dictation).last);
    await tester.pumpAndSettle();
    expect(voice.run, isNotNull);
    // The removal waits for the note, which something else holds.
    final held = Completer<void>();
    unawaited(
      container.read(noteLocksProvider).runExclusive('note-1', () => held.future),
    );

    await tester.tap(
      find.descendant(
        of: find.byType(NoteFileAttachment),
        matching: find.byIcon(Icons.cancel_rounded),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n(tester).delete).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(voice.run, isNull);
    held.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a file card is kept when the account changed during its '
      'removal', (tester) async {
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
    final container = await pumpEditor(tester, _DetailApi(detail: note));

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('note-file-card-f1')),
        matching: find.byIcon(Icons.cancel_rounded),
      ),
    );
    await tester.pumpAndSettle();
    container.read(_currentUser.notifier).switchTo(_bob);
    await tester.tap(find.text(l10n(tester).delete).last);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('note-file-card-f1')),
      findsOneWidget,
    );
    expect(find.text(l10n(tester).noteSessionChangedNotice), findsOneWidget);
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

  testWidgets('back saves an edit typed while an earlier save runs', (
    tester,
  ) async {
    final note = _noteJson(writeAccess: true);
    await storeLocally(note);
    final container = await pumpEditor(
      tester,
      _DetailApi(detail: note),
      settings: const AppSettings(slidingSidebarEnabled: true),
    );
    final router = GoRouter(
      initialLocation: '/notes',
      routes: [
        GoRoute(
          path: '/notes',
          builder: (_, _) => const Scaffold(body: Text('Notes list')),
        ),
        GoRoute(
          path: '/notes/:id',
          builder: (_, _) => const NoteEditorPage(noteId: 'note-1'),
        ),
      ],
    );
    addTearDown(router.dispose);
    NavigationService.attachRouter(router);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    router.go('/notes/note-1');
    await tester.pumpAndSettle();

    // Holding the note's lock keeps the back button's save in flight.
    final gate = Completer<void>();
    unawaited(
      container.read(noteLocksProvider).runExclusive('note-1', () => gate.future),
    );
    typeInto(tester, 'first ');
    await tester.tap(
      find.byKey(const ValueKey<String>('sidebar-page-back-button')),
    );
    await tester.pump();
    typeInto(tester, 'second ');
    gate.complete();
    await tester.pumpAndSettle();

    expect(router.routeInformationProvider.value.uri.path, '/notes');
    final row = (await db.notesDao.getNote('note-1'))!;
    expect(row.data, contains('second'));
    expect(row.data, contains('first'));
  });

  /// Shows the note's editor in the chat branch of a shell beside a Notes
  /// branch, as the app's router does, so the editor stays mounted out of
  /// sight once Notes is shown.
  Future<GoRouter> openInShell(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    final router = GoRouter(
      initialLocation: '/notes',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (_, _, shell) => shell,
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/chat',
                  builder: (_, _) => const Scaffold(body: Text('Chat')),
                ),
                GoRoute(
                  path: '/notes/:id',
                  builder: (_, _) => const NoteEditorPage(noteId: 'note-1'),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/notes',
                  builder: (_, _) => const Scaffold(body: Text('Notes list')),
                ),
              ],
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    NavigationService.attachRouter(router);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    router.go('/notes/note-1');
    await tester.pumpAndSettle();
    return router;
  }

  Future<void> startDictation(WidgetTester tester) async {
    // The voice options sheet trips a debug check about its tiles' ink,
    // which has nothing to do with what is tested here.
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains(
        'ink splashes may be invisible',
      )) {
        return;
      }
      originalOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = originalOnError);
    await tester.tap(find.byTooltip(l10n(tester).voiceOptions));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n(tester).dictation).last);
    await tester.pumpAndSettle();
  }

  testWidgets('back ends dictation before it saves the note', (tester) async {
    final voice = _HeldVoice()..ready.complete(true);
    final note = _noteJson(writeAccess: true);
    await storeLocally(note);
    final container = await pumpEditor(
      tester,
      _DetailApi(detail: note),
      voice: voice,
      settings: const AppSettings(slidingSidebarEnabled: true),
    );
    final router = await openInShell(tester, container);
    await startDictation(tester);
    voice.run!.add('spoken words');
    await tester.pump();

    // Holding the note's lock keeps the back button's save in flight.
    final gate = Completer<void>();
    unawaited(
      container
          .read(noteLocksProvider)
          .runExclusive('note-1', () => gate.future),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('sidebar-page-back-button')),
    );
    await tester.pump();
    expect(voice.run, isNull, reason: 'dictation ends before the save');
    gate.complete();
    await tester.pumpAndSettle();

    expect(router.routeInformationProvider.value.uri.path, '/notes');
    final row = (await db.notesDao.getNote('note-1'))!;
    expect(row.data, contains('spoken words'));
  });

  testWidgets('dictation ends when another page takes the editor\'s place', (
    tester,
  ) async {
    final voice = _HeldVoice()..ready.complete(true);
    final note = _noteJson(writeAccess: true);
    await storeLocally(note);
    final container = await pumpEditor(
      tester,
      _DetailApi(detail: note),
      voice: voice,
      settings: const AppSettings(slidingSidebarEnabled: true),
    );
    final router = await openInShell(tester, container);
    await startDictation(tester);
    voice.run!.add('spoken words');
    await tester.pump();

    // As choosing Notes in the sidebar does.
    router.go('/notes');
    await tester.pumpAndSettle();

    expect(find.byType(NoteEditorPage, skipOffstage: false), findsOneWidget);
    expect(voice.run, isNull);
    final row = (await db.notesDao.getNote('note-1'))!;
    expect(row.data, contains('spoken words'));
  });

  // Server speech-to-text sends nothing until it stops, so the note may not
  // have changed yet when back is pressed.
  for (final interim in [true, false]) {
    testWidgets('back in the tabbed layout keeps dictation\'s last words '
        '(interim words: $interim)', (tester) async {
      final voice = _LastWordsVoice()..ready.complete(true);
      final note = _noteJson(writeAccess: true);
      await storeLocally(note);
      final container = await pumpEditor(
        tester,
        _DetailApi(detail: note),
        voice: voice,
      );
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: navigator,
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: Text('Notes list')),
          ),
        ),
      );
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const NoteEditorPage(noteId: 'note-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await startDictation(tester);
      if (interim) voice.run!.add('spoken words');
      // An edit marks the note changed by the next frame.
      await tester.pump();
      await tester.pump();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(NoteEditorPage), findsNothing);
      expect(voice.run, isNull);
      final row = (await db.notesDao.getNote('note-1'))!;
      expect(row.data, contains('last words'));
    });
  }

  // A stored title that is empty or padded is not an edit, and neither is a
  // cleared title, which saves as the "Untitled" already stored.
  for (final (title, writeAccess, clearTitle) in [
    ('', true, false),
    ('', false, false),
    (' Padded title ', true, false),
    ('Untitled', true, true),
  ]) {
    testWidgets('back leaves a note titled "$title" '
        '(write: $writeAccess, cleared: $clearTitle)', (tester) async {
      final note = _noteJson(writeAccess: writeAccess, title: title);
      await storeLocally(note);
      final api = _DetailApi(detail: note);
      final container = await pumpEditor(
        tester,
        api,
        settings: const AppSettings(slidingSidebarEnabled: true),
      );
      final router = GoRouter(
        initialLocation: '/notes',
        routes: [
          GoRoute(
            path: '/notes',
            builder: (_, _) => const Scaffold(body: Text('Notes list')),
          ),
          GoRoute(
            path: '/notes/:id',
            builder: (_, _) => const NoteEditorPage(noteId: 'note-1'),
          ),
        ],
      );
      addTearDown(router.dispose);
      NavigationService.attachRouter(router);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      router.go('/notes/note-1');
      await tester.pumpAndSettle();
      if (clearTitle) {
        tester
                .widget<AdaptiveTextField>(find.byType(AdaptiveTextField))
                .controller!
                .text =
            '';
        await letAutosaveRun(tester);
      }

      await tester.tap(
        find.byKey(const ValueKey<String>('sidebar-page-back-button')),
      );
      await tester.pumpAndSettle();

      expect(router.routeInformationProvider.value.uri.path, '/notes');
      expect(api.updates, 0);
    });
  }

  for (final navigation in ['stay', 'leave', 'return']) {
    testWidgets('pending note deletion respects navigation: $navigation', (
      tester,
    ) async {
      final deleter = _DelayedNoteDeleter();
      final note = _noteJson(writeAccess: true);
      await storeLocally(note);
      final container = await pumpEditor(
        tester,
        _DetailApi(detail: note),
        deleter: deleter,
      );
      final router = GoRouter(
        initialLocation: '/notes/note-1',
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (_, _, shell) => shell,
            branches: [
              StatefulShellBranch(
                initialLocation: '/notes/note-1',
                routes: [
                  GoRoute(
                    path: '/notes/:id',
                    builder: (_, _) => const NoteEditorPage(noteId: 'note-1'),
                  ),
                ],
              ),
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/other',
                    builder: (_, _) => const Scaffold(body: Text('Other page')),
                  ),
                ],
              ),
            ],
          ),
          GoRoute(
            path: '/chat',
            builder: (_, _) => const Scaffold(body: Text('Chat')),
          ),
        ],
      );
      addTearDown(router.dispose);
      NavigationService.attachRouter(router);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final delete = l10n(tester).delete;
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text(delete));
      await tester.pumpAndSettle();
      await tester.tap(find.text(delete));
      await tester.pumpAndSettle();
      expect(deleter.calls, 1);
      if (navigation != 'stay') {
        router.go('/other');
        await tester.pumpAndSettle();
        if (navigation == 'return') {
          router.go('/notes/note-1');
          await tester.pumpAndSettle();
        }
      }
      deleter.result.complete(true);
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.path,
        navigation == 'stay'
            ? '/chat'
            : navigation == 'return'
            ? '/notes/note-1'
            : '/other',
      );
      if (navigation == 'leave') {
        // Back no longer returns to the deleted note.
        NavigationService.returnToPreviousPage(fallback: '/chat');
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.path, '/chat');
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a note opened by its offline id is forgotten by it too', (
    tester,
  ) async {
    final deleter = _DelayedNoteDeleter();
    final note = _noteJson(writeAccess: true);
    await storeLocally(note);
    // The editor holds the note by its server id, as once the note made
    // offline was remapped, while its location keeps the id it opened with.
    final container = await pumpEditor(
      tester,
      _DetailApi(detail: note),
      deleter: deleter,
    );
    final router = GoRouter(
      initialLocation: '/notes/local:draft',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (_, _, shell) => shell,
          branches: [
            StatefulShellBranch(
              initialLocation: '/notes/local:draft',
              routes: [
                GoRoute(
                  path: '/notes/:id',
                  builder: (_, state) =>
                      NoteEditorPage(noteId: state.pathParameters['id']!),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/other',
                  builder: (_, _) => const Scaffold(body: Text('Other page')),
                ),
              ],
            ),
          ],
        ),
        GoRoute(
          path: '/chat',
          builder: (_, _) => const Scaffold(body: Text('Chat')),
        ),
      ],
    );
    addTearDown(router.dispose);
    NavigationService.attachRouter(router);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final delete = l10n(tester).delete;
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text(delete));
    await tester.pumpAndSettle();
    await tester.tap(find.text(delete));
    await tester.pumpAndSettle();
    expect(deleter.ids, ['note-1']);
    router.go('/other');
    await tester.pumpAndSettle();
    deleter.result.complete(true);
    await tester.pumpAndSettle();

    NavigationService.returnToPreviousPage(fallback: '/chat');
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/chat');
    expect(tester.takeException(), isNull);
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
