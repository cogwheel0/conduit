import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/note_mapper.dart';
import 'package:conduit_core/models/note.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/notes/providers/notes_providers.dart';
import 'package:conduit/features/notes/views/note_editor_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:drift/native.dart';
import 'package:fleather/fleather.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' as flutter;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

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

class _DeletingOnReconcileSyncEngine extends _NoDrainSyncEngine {
  _DeletingOnReconcileSyncEngine(this.db, {this.pullStarted, this.releasePull});

  final AppDatabase db;
  final Completer<void>? pullStarted;
  final Completer<void>? releasePull;

  @override
  Future<PullResult?> requestPull({required String reason}) async {
    pulls.add(reason);
    final started = pullStarted;
    if (started != null && !started.isCompleted) started.complete();
    await releasePull?.future;
    return null;
  }

  @override
  Future<void> reconcileNow() async {
    reconcileNowCalls++;
    await db.notesDao.purgeReconciledNote('deleted-note');
  }
}

class _EnabledNotesFeature extends NotesFeatureEnabledNotifier {
  @override
  bool build() => true;
}

Map<String, dynamic> _deletedNoteJson() => <String, dynamic>{
  'id': 'deleted-note',
  'user_id': _testUser.id,
  'title': 'Deleted title',
  'data': {
    'content': {'md': 'Deleted body', 'html': '<p>Deleted body</p>'},
  },
  'meta': {},
  'is_pinned': false,
  'created_at': 1713786305000000000,
  'updated_at': 1713786305000000000,
};

Future<void> _seedDeletedNote(AppDatabase db) {
  return db
      .into(db.notes)
      .insertOnConflictUpdate(serverToNoteRow(_deletedNoteJson()));
}

Widget _noteEditorHarness({
  required AppDatabase db,
  required SyncEngine syncEngine,
  bool withBackRoute = false,
  TargetPlatform platform = TargetPlatform.android,
  Map<String, dynamic>? noteJson,
  GoRouter? router,
}) {
  final initialNote = noteJson ?? _deletedNoteJson();
  return ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWith((ref) => db),
      apiServiceProvider.overrideWithValue(null),
      isAuthenticatedProvider2.overrideWithValue(true),
      currentUserProvider2.overrideWithValue(_testUser),
      connectivityStatusProvider.overrideWithValue(ConnectivityStatus.online),
      openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
      syncEngineProvider.overrideWith(() => syncEngine),
      notesFeatureEnabledProvider.overrideWith(_EnabledNotesFeature.new),
      noteByIdProvider('deleted-note')
          .overrideWith((ref) async => Note.fromJson(initialNote)),
    ],
    child: router != null
        ? MaterialApp.router(
            theme: AppTheme.light(TweakcnThemes.conduit)
                .copyWith(platform: platform),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          )
        : MaterialApp(
            theme: AppTheme.light(TweakcnThemes.conduit)
                .copyWith(platform: platform),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: noteJson == null
                ? null
                : (context, child) => flutter.Material(child: child),
            initialRoute: withBackRoute ? '/editor' : null,
            home: withBackRoute
                ? null
                : const NoteEditorPage(noteId: 'deleted-note'),
            routes: withBackRoute
                ? <String, WidgetBuilder>{
                    '/': (_) => const Scaffold(key: Key('notes-root')),
                    '/editor': (_) =>
                        const NoteEditorPage(noteId: 'deleted-note'),
                  }
                : const <String, WidgetBuilder>{},
          ),
  );
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

    testWidgets(
      'note context-menu copy keeps a scroll client on Android and iOS',
      (tester) async {
        final originalErrorWidgetBuilder = ErrorWidget.builder;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final platformCalls = <MethodCall>[];
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          platformCalls.add(call);
          return null;
        });

        try {
          await tester.binding.setSurfaceSize(const Size(1200, 900));
          await tester.pumpWidget(
            _noteEditorHarness(
              db: db,
              syncEngine: _NoDrainSyncEngine(),
              platform: defaultTargetPlatform,
            ),
          );
          await tester.pumpAndSettle();

          final editorState = tester.state<EditorState>(find.byType(RawEditor));
          editorState.userUpdateTextEditingValue(
            editorState.textEditingValue.copyWith(
              selection: const TextSelection(baseOffset: 0, extentOffset: 7),
            ),
            SelectionChangedCause.longPress,
          );
          await tester.pump();

          final copyButton = editorState.contextMenuButtonItems.singleWhere(
            (button) => button.type == ContextMenuButtonType.copy,
          );
          expect(copyButton.onPressed, isNotNull);
          copyButton.onPressed!();
          await tester.pumpAndSettle();

          final editor = tester.widget<FleatherEditor>(
            find.byType(FleatherEditor),
          );
          final pageScrollView = tester.widget<SingleChildScrollView>(
            find
                .ancestor(
                  of: find.byType(FleatherEditor),
                  matching: find.byType(SingleChildScrollView),
                )
                .first,
          );
          expect(editor.scrollController, same(pageScrollView.controller));
          expect(editor.scrollController?.hasClients, isTrue);
          final clipboardCall = platformCalls.singleWhere(
            (call) => call.method == 'Clipboard.setData',
          );
          expect(clipboardCall.arguments, <String, dynamic>{'text': 'Deleted'});
          expect(tester.takeException(), isNull);
        } finally {
          messenger.setMockMethodCallHandler(SystemChannels.platform, null);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.binding.setSurfaceSize(null);
          ErrorWidget.builder = originalErrorWidgetBuilder;
        }
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );

    testWidgets('checkbox toggles autosave canonical markdown', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final noteJson = <String, dynamic>{
        ..._deletedNoteJson(),
        'data': {
          'content': {
            'md': '- [ ] Task',
            'html': '<div class="checklist">Task</div>',
          },
        },
      };
      await db.into(db.notes).insertOnConflictUpdate(serverToNoteRow(noteJson));
      await tester.pumpWidget(
        _noteEditorHarness(
          db: db,
          syncEngine: _NoDrainSyncEngine(),
          noteJson: noteJson,
        ),
      );
      await tester.pumpAndSettle();

      final checkbox = find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == 'FleatherCheckbox',
      );
      check(checkbox.evaluate()).length.equals(1);
      await tester.tap(checkbox);
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();

      final row = await db.notesDao.getNote('deleted-note');
      final content = decodeNoteData(row!.data)['content'] as Map;
      check(content['md'] as String).contains('[X] Task');
      check(content['html']).equals('');
    });

    testWidgets(
      'editor refresh clears a remotely deleted note title and content',
      (tester) async {
        final originalErrorWidgetBuilder = ErrorWidget.builder;
        await tester.binding.setSurfaceSize(const Size(1200, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await _seedDeletedNote(db);
        final syncEngine = _DeletingOnReconcileSyncEngine(db);
        await tester.pumpWidget(
          _noteEditorHarness(db: db, syncEngine: syncEngine),
        );
        await tester.pumpAndSettle();

        check(find.text('Deleted title').evaluate()).isNotEmpty();
        final refresh = tester.widget<RefreshIndicator>(
          find.byType(RefreshIndicator),
        );
        await refresh.onRefresh();
        await tester.pumpAndSettle();

        check(find.text('Note not found').evaluate()).isNotEmpty();
        check(find.text('Deleted title').evaluate()).isEmpty();
        check(find.text('Deleted body').evaluate()).isEmpty();
        await tester.pumpWidget(const SizedBox.shrink());
        ErrorWidget.builder = originalErrorWidgetBuilder;
      },
    );

    testWidgets('Go Back on a deleted note returns to chat when it is the '
        'only page', (tester) async {
      final originalErrorWidgetBuilder = ErrorWidget.builder;
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _seedDeletedNote(db);
      final router = GoRouter(
        initialLocation: '/notes/deleted-note',
        routes: [
          GoRoute(
            path: '/chat',
            builder: (_, _) => const Scaffold(key: Key('chat-root')),
          ),
          GoRoute(
            path: '/notes/:id',
            builder: (_, state) =>
                NoteEditorPage(noteId: state.pathParameters['id']!),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        _noteEditorHarness(
          db: db,
          syncEngine: _DeletingOnReconcileSyncEngine(db),
          router: router,
        ),
      );
      await tester.pumpAndSettle();

      final refresh = tester.widget<RefreshIndicator>(
        find.byType(RefreshIndicator),
      );
      await refresh.onRefresh();
      await tester.pumpAndSettle();
      check(find.text('Note not found').evaluate()).isNotEmpty();

      await tester.tap(find.text('Go Back'));
      await tester.pumpAndSettle();

      check(find.byKey(const Key('chat-root')).evaluate()).isNotEmpty();
      check(router.routerDelegate.currentConfiguration.uri.path)
          .equals('/chat');
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
    });

    testWidgets('editor refresh recovers edits autosaved before deletion', (
      tester,
    ) async {
      final originalErrorWidgetBuilder = ErrorWidget.builder;
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _seedDeletedNote(db);
      final syncEngine = _DeletingOnReconcileSyncEngine(db);
      await tester.pumpWidget(
        _noteEditorHarness(db: db, syncEngine: syncEngine),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Deleted title').last);
      await tester.pump();
      final titleField = find.byWidgetPredicate(
        (widget) =>
            widget is EditableText && widget.controller.text == 'Deleted title',
      );
      check(titleField.evaluate()).length.equals(1);
      await tester.enterText(titleField, 'Edited before refresh');

      final refresh = tester.widget<RefreshIndicator>(
        find.byType(RefreshIndicator),
      );
      await refresh.onRefresh();
      await tester.pump();

      check(find.text('Note not found').evaluate()).isEmpty();
      final editedTitle = find.byWidgetPredicate(
        (widget) =>
            widget is EditableText &&
            widget.controller.text == 'Edited before refresh',
      );
      check(editedTitle.evaluate()).length.equals(1);
      check(await db.notesDao.getNote('deleted-note')).isNull();
      final recoveredRows = await db.select(db.notes).get();
      check(recoveredRows).length.equals(1);
      final recovered = recoveredRows.single;
      check(recovered.id.startsWith('local:')).isTrue();
      check(recovered.title).equals('Edited before refresh');
      check(recovered.dirtyTitle).isTrue();
      check(recovered.dirtyData).isTrue();
      check(
        (await db.outboxDao.pendingForChat(recovered.id)).map((op) => op.kind),
      ).deepEquals([OutboxKind.noteCreate.name]);
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
    });

    testWidgets('editor refresh preserves edits entered while deleting', (
      tester,
    ) async {
      final originalErrorWidgetBuilder = ErrorWidget.builder;
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _seedDeletedNote(db);
      final pullStarted = Completer<void>();
      final releasePull = Completer<void>();
      final syncEngine = _DeletingOnReconcileSyncEngine(
        db,
        pullStarted: pullStarted,
        releasePull: releasePull,
      );
      await tester.pumpWidget(
        _noteEditorHarness(db: db, syncEngine: syncEngine),
      );
      await tester.pumpAndSettle();

      final refresh = tester.widget<RefreshIndicator>(
        find.byType(RefreshIndicator),
      );
      final refreshing = refresh.onRefresh();
      await pullStarted.future;
      await tester.tap(find.text('Deleted title').last);
      await tester.pump();
      final titleField = find.byWidgetPredicate(
        (widget) =>
            widget is EditableText && widget.controller.text == 'Deleted title',
      );
      check(titleField.evaluate()).length.equals(1);
      await tester.enterText(titleField, 'Edited during refresh');

      releasePull.complete();
      await refreshing;
      await tester.pump();

      check(find.text('Note not found').evaluate()).isEmpty();
      final editedTitle = find.byWidgetPredicate(
        (widget) =>
            widget is EditableText &&
            widget.controller.text == 'Edited during refresh',
      );
      check(editedTitle.evaluate()).length.equals(1);
      check(await db.notesDao.getNote('deleted-note')).isNull();
      final recoveredRows = await db.select(db.notes).get();
      check(recoveredRows).length.equals(1);
      final recovered = recoveredRows.single;
      check(recovered.id.startsWith('local:')).isTrue();
      check(recovered.title).equals('Edited during refresh');
      check(recovered.dirtyTitle).isTrue();
      check(recovered.dirtyData).isTrue();
      check(
        (await db.outboxDao.pendingForChat(recovered.id)).map((op) => op.kind),
      ).deepEquals([OutboxKind.noteCreate.name]);
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
    });

    testWidgets(
      'failed post-recovery save keeps the dirty editor open on back',
      (tester) async {
        final originalErrorWidgetBuilder = ErrorWidget.builder;
        await tester.binding.setSurfaceSize(const Size(1200, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await _seedDeletedNote(db);
        final syncEngine = _DeletingOnReconcileSyncEngine(db);
        await tester.pumpWidget(
          _noteEditorHarness(
            db: db,
            syncEngine: syncEngine,
            withBackRoute: true,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Deleted title').last);
        await tester.pump();
        var titleField = find.byWidgetPredicate(
          (widget) =>
              widget is EditableText &&
              widget.controller.text == 'Deleted title',
        );
        await tester.enterText(titleField, 'Recovered title');
        final refresh = tester.widget<RefreshIndicator>(
          find.byType(RefreshIndicator),
        );
        await refresh.onRefresh();
        await tester.pump();

        titleField = find.byWidgetPredicate(
          (widget) =>
              widget is EditableText &&
              widget.controller.text == 'Recovered title',
        );
        check(titleField.evaluate()).length.equals(1);
        await tester.enterText(titleField, 'Unsaved after recovery');
        await tester.pump();

        // Closing the active database forces the back-navigation autosave to
        // fail after recovery has already cleared its dedicated retry callback.
        final failedDb = db;
        await failedDb.close();
        db = AppDatabase(NativeDatabase.memory());
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();

        final dirtyTitle = find.byWidgetPredicate(
          (widget) =>
              widget is EditableText &&
              widget.controller.text == 'Unsaved after recovery',
        );
        check(dirtyTitle.evaluate()).length.equals(1);
        check(find.byKey(const Key('notes-root')).evaluate()).isEmpty();
        await tester.pumpWidget(const SizedBox.shrink());
        ErrorWidget.builder = originalErrorWidgetBuilder;
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
  });

  group('NotePinToggler', () {});
}
