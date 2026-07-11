import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/providers/workspace_providers.dart';
import 'package:conduit/features/workspace/views/prompts/workspace_prompt_editor.dart';
import 'package:conduit/features/workspace/widgets/workspace_import_sheet.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final view = binding.platformDispatcher.views.first;

  setUp(() {
    view.physicalSize = const Size(1400, 3200);
    view.devicePixelRatio = 1;
  });

  tearDown(() {
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  testWidgets('create form saves with a stripped command', (tester) async {
    final prompts = _FakePrompts();
    await tester.pumpWidget(_harness(prompts, mode: WorkspaceRouteMode.create));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workspace-prompt-name')), findsOneWidget);
    expect(find.byKey(const Key('workspace-prompt-command')), findsOneWidget);
    expect(find.byKey(const Key('workspace-prompt-content')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('workspace-prompt-name')),
      'Summarize',
    );
    await tester.enterText(
      find.byKey(const Key('workspace-prompt-command')),
      '/summary',
    );
    await tester.enterText(
      find.byKey(const Key('workspace-prompt-content')),
      'Summarize the text.',
    );
    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pump();
    await tester.pump();

    expect(prompts.created, hasLength(1));
    expect(prompts.created.single.command, 'summary');
    expect(prompts.created.single.name, 'Summarize');
    expect(prompts.created.single.content, 'Summarize the text.');
  });

  testWidgets('invalid command blocks save and surfaces an error', (
    tester,
  ) async {
    final prompts = _FakePrompts();
    await tester.pumpWidget(_harness(prompts, mode: WorkspaceRouteMode.create));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('workspace-prompt-name')),
      'Bad',
    );
    await tester.enterText(
      find.byKey(const Key('workspace-prompt-command')),
      'no spaces here',
    );
    await tester.enterText(
      find.byKey(const Key('workspace-prompt-content')),
      'body',
    );
    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pump();

    expect(prompts.created, isEmpty);
    expect(find.byKey(const Key('workspace-editor-error')), findsOneWidget);
  });

  testWidgets('empty content blocks save', (tester) async {
    final prompts = _FakePrompts();
    await tester.pumpWidget(_harness(prompts, mode: WorkspaceRouteMode.create));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('workspace-prompt-name')),
      'Named',
    );
    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pump();

    expect(prompts.created, isEmpty);
    expect(find.byKey(const Key('workspace-editor-error')), findsOneWidget);
  });

  testWidgets('edit form updates with commit message and production flag', (
    tester,
  ) async {
    final prompts = _FakePrompts();
    await tester.pumpWidget(
      _harness(
        prompts,
        mode: WorkspaceRouteMode.edit,
        resourceId: 'p-1',
        detail: _writable(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('workspace-prompt-content')),
      'Updated body',
    );
    await tester.enterText(
      find.byKey(const Key('workspace-prompt-commit-message')),
      'Tighten wording',
    );
    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pump();
    await tester.pump();

    expect(prompts.updated, hasLength(1));
    expect(prompts.updated.single.$1, 'p-1');
    expect(prompts.updated.single.$2.content, 'Updated body');
    expect(prompts.updated.single.$2.commitMessage, 'Tighten wording');
    expect(prompts.updated.single.$2.isProduction, isTrue);
    // Restore/identity: command is preserved (stripped) on save.
    expect(prompts.updated.single.$2.command, 'summary');
  });

  testWidgets('read-only prompt hides save and history mutation controls', (
    tester,
  ) async {
    final prompts = _FakePrompts(historyEntries: _history());
    await tester.pumpWidget(
      _harness(
        prompts,
        mode: WorkspaceRouteMode.detail,
        resourceId: 'p-ro',
        detail: _readOnly(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workspace-editor-save')), findsNothing);
    expect(find.byKey(const Key('workspace-read-only-badge')), findsWidgets);
    expect(find.byKey(const Key('workspace-prompt-edit')), findsNothing);
    // History is visible but not mutable.
    expect(find.byKey(const Key('prompt-history-h1')), findsOneWidget);
    expect(find.byKey(const Key('prompt-history-production-h2')), findsNothing);
    expect(find.byKey(const Key('prompt-history-delete-h2')), findsNothing);
  });

  testWidgets('clone creates a copy without inherited grants', (tester) async {
    final prompts = _FakePrompts();
    await tester.pumpWidget(
      _harness(
        prompts,
        mode: WorkspaceRouteMode.detail,
        resourceId: 'p-1',
        detail: _writable(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-prompt-action-clone')));
    await tester.pump();
    await tester.pump();

    expect(prompts.created, hasLength(1));
    expect(prompts.created.single.command, contains('copy'));
    expect(prompts.created.single.accessGrants, isEmpty);
  });

  testWidgets('toggle action toggles active state', (tester) async {
    final prompts = _FakePrompts();
    await tester.pumpWidget(
      _harness(
        prompts,
        mode: WorkspaceRouteMode.detail,
        resourceId: 'p-1',
        detail: _writable(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-prompt-action-toggle')));
    await tester.pump();
    await tester.pump();

    expect(prompts.toggled, ['p-1']);
  });

  testWidgets('delete action deletes after confirmation', (tester) async {
    final prompts = _FakePrompts();
    await tester.pumpWidget(
      _harness(
        prompts,
        mode: WorkspaceRouteMode.detail,
        resourceId: 'p-1',
        detail: _writable(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-prompt-action-delete')));
    await tester.pumpAndSettle();

    expect(find.text('Delete prompt?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.pump();

    expect(prompts.deleted, ['p-1']);
  });

  testWidgets('history renders prompt-history-* keys and sets production', (
    tester,
  ) async {
    final prompts = _FakePrompts(historyEntries: _history());
    await tester.pumpWidget(
      _harness(
        prompts,
        mode: WorkspaceRouteMode.edit,
        resourceId: 'p-1',
        detail: _writable(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('prompt-history-h1')), findsOneWidget);
    expect(find.byKey(const Key('prompt-history-h2')), findsOneWidget);
    // h1 is the live/production version.
    expect(find.byKey(const Key('prompt-history-live-h1')), findsOneWidget);

    // Select h2 and pin it as production.
    await tester.tap(find.byKey(const Key('prompt-history-h2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('prompt-history-production-h2')));
    await tester.pump();
    await tester.pump();

    expect(prompts.production, [('p-1', 'h2')]);
  });

  testWidgets('history diff opens the diff sheet', (tester) async {
    final prompts = _FakePrompts(historyEntries: _history());
    await tester.pumpWidget(
      _harness(
        prompts,
        mode: WorkspaceRouteMode.edit,
        resourceId: 'p-1',
        detail: _writable(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('prompt-history-h2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('prompt-history-diff-h2')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workspace-prompt-diff-empty')), findsOneWidget);
  });

  testWidgets('restore loads snapshot content without changing command', (
    tester,
  ) async {
    final prompts = _FakePrompts(historyEntries: _history());
    await tester.pumpWidget(
      _harness(
        prompts,
        mode: WorkspaceRouteMode.edit,
        resourceId: 'p-1',
        detail: _writable(),
      ),
    );
    await tester.pumpAndSettle();

    // Select h2 (older snapshot) and restore it.
    await tester.tap(find.byKey(const Key('prompt-history-h2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('prompt-history-restore-h2')));
    await tester.pumpAndSettle();

    final content = tester.widget<TextField>(
      find.byKey(const Key('workspace-prompt-content')),
    );
    final command = tester.widget<TextField>(
      find.byKey(const Key('workspace-prompt-command')),
    );
    expect(content.controller!.text, 'older body');
    // Command is identity and must be preserved by a restore.
    expect(command.controller!.text, 'summary');
  });

  testWidgets('restoring a tagless snapshot clears the current tags', (
    tester,
  ) async {
    final prompts = _FakePrompts(historyEntries: _history());
    await tester.pumpWidget(
      _harness(
        prompts,
        mode: WorkspaceRouteMode.edit,
        resourceId: 'p-1',
        // Current prompt carries tags; the restored h2 snapshot has none.
        detail: const WorkspacePromptSummary(
          id: 'p-1',
          command: 'summary',
          name: 'Summary',
          content: 'Summarize the text.',
          userId: 'owner',
          writeAccess: true,
          versionId: 'h1',
          tags: ['keep-me'],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('prompt-history-h2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('prompt-history-restore-h2')));
    await tester.pumpAndSettle();

    // Saving after the restore must persist the cleared tag list, not the stale
    // tags from before the restore.
    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pump();
    await tester.pump();

    expect(prompts.updated, hasLength(1));
    expect(prompts.updated.single.$2.tags, isEmpty);
  });

  testWidgets('successful edit pops the editor even when the form is disposed', (
    tester,
  ) async {
    final prompts = _InvalidatingFakePrompts();
    const detail = WorkspacePromptSummary(
      id: 'p-1',
      command: 'summary',
      name: 'Summary',
      content: 'body',
      userId: 'owner',
      writeAccess: true,
      versionId: 'h1',
    );
    final router = GoRouter(
      initialLocation: '/list',
      routes: [
        GoRoute(
          path: '/list',
          builder: (_, _) => const Scaffold(body: Text('list-page')),
        ),
        GoRoute(
          path: '/editor',
          builder: (_, _) => const Scaffold(
            body: WorkspacePromptEditorView(
              mode: WorkspaceRouteMode.edit,
              promptId: 'p-1',
            ),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          workspaceCapabilitiesProvider.overrideWith(
            (ref) async => WorkspaceCapabilities.all,
          ),
          workspacePromptsProvider.overrideWith(() => prompts),
          workspacePromptDetailProvider(
            'p-1',
          ).overrideWith((ref) async => detail),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Push the editor so the successful save has somewhere to pop back to.
    router.push('/editor');
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('workspace-prompt-content')),
      'Updated body',
    );
    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pumpAndSettle();

    // The edit was recorded and the editor popped back to the list even though
    // the detail-provider invalidation disposed the form mid-save.
    expect(prompts.updated, hasLength(1));
    expect(prompts.updated.single.$2.content, 'Updated body');
    expect(find.text('list-page'), findsOneWidget);
  });

  testWidgets('import gates on capability and captures per-item failures', (
    tester,
  ) async {
    // Import is gated on the import capability: with only export granted the
    // overflow shows Export but never Import.
    final prompts = _FakePrompts();
    await tester.pumpWidget(
      _harness(
        prompts,
        mode: WorkspaceRouteMode.create,
        capabilities: const WorkspaceCapabilities(
          prompts: WorkspaceSectionCapabilities(
            manage: true,
            exportItems: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('workspace-prompt-action-export')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('workspace-prompt-action-import')),
      findsNothing,
    );

    // A failing import is reported as a per-item failure, not a thrown batch.
    prompts.importShouldFail = true;
    final report = await runWorkspaceImport(
      [
        {'name': 'A', 'command': 'a', 'content': 'x'},
      ],
      importItem: (item) => prompts.importPrompt(
        const WorkspacePromptForm(command: 'a', name: 'A', content: 'x'),
      ),
    );
    expect(report.hasFailures, isTrue);
    expect(report.failureCount, 1);
  });
}

// ---------------------------------------------------------------------------

Widget _harness(
  _FakePrompts prompts, {
  required WorkspaceRouteMode mode,
  String? resourceId,
  WorkspacePromptDetail? detail,
  WorkspaceCapabilities capabilities = WorkspaceCapabilities.all,
}) {
  return ProviderScope(
    overrides: [
      reviewerModeProvider.overrideWithValue(false),
      apiServiceProvider.overrideWithValue(null),
      workspaceCapabilitiesProvider.overrideWith((ref) async => capabilities),
      workspacePromptsProvider.overrideWith(() => prompts),
      if (resourceId != null && detail != null)
        workspacePromptDetailProvider(
          resourceId,
        ).overrideWith((ref) async => detail),
    ],
    child: _app(mode, resourceId),
  );
}

Widget _app(WorkspaceRouteMode mode, String? resourceId) {
  Widget placeholder(_, _) => const Scaffold(body: Text('nav-target'));
  final router = GoRouter(
    initialLocation: '/editor',
    routes: [
      GoRoute(
        path: '/editor',
        builder: (_, _) => Scaffold(
          body: WorkspacePromptEditorView(mode: mode, promptId: resourceId),
        ),
      ),
      GoRoute(path: '/workspace/prompts', builder: placeholder),
      GoRoute(path: '/workspace/prompts/create', builder: placeholder),
      GoRoute(path: '/workspace/prompts/:id', builder: placeholder),
      GoRoute(path: '/workspace/prompts/:id/edit', builder: placeholder),
    ],
  );
  return MaterialApp.router(
    routerConfig: router,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
  );
}

WorkspacePromptDetail _writable() => const WorkspacePromptSummary(
  id: 'p-1',
  command: 'summary',
  name: 'Summary',
  content: 'Summarize the text.',
  userId: 'owner',
  writeAccess: true,
  versionId: 'h1',
);

WorkspacePromptDetail _readOnly() => const WorkspacePromptSummary(
  id: 'p-ro',
  command: 'shared',
  name: 'Shared',
  content: 'Shared body.',
  userId: 'someone',
  writeAccess: false,
  versionId: 'h1',
);

List<WorkspacePromptHistoryEntry> _history() => const [
  WorkspacePromptHistoryEntry(
    id: 'h1',
    promptId: 'p-1',
    snapshot: {'content': 'current body', 'name': 'Summary'},
    userId: 'owner',
    createdAt: 1000,
    commitMessage: 'Initial version',
  ),
  WorkspacePromptHistoryEntry(
    id: 'h2',
    promptId: 'p-1',
    snapshot: {'content': 'older body', 'name': 'Summary'},
    userId: 'owner',
    createdAt: 900,
    commitMessage: 'Older',
  ),
];

class _FakePrompts extends WorkspacePrompts {
  _FakePrompts({this.historyEntries = const []});

  final List<WorkspacePromptSummary> items = const [];
  final List<WorkspacePromptHistoryEntry> historyEntries;

  final created = <WorkspacePromptForm>[];
  final updated = <(String, WorkspacePromptForm)>[];
  final toggled = <String>[];
  final deleted = <String>[];
  final metadata = <(String, String, String)>[];
  final production = <(String, String)>[];
  final deletedHistory = <(String, String)>[];
  final importedForms = <WorkspacePromptForm>[];
  bool importShouldFail = false;

  @override
  Future<WorkspaceCollectionState<WorkspacePromptSummary>> build() async {
    return WorkspaceCollectionState(items: items, total: items.length);
  }

  WorkspacePromptDetail _detail(String id, {String command = 'summary'}) =>
      WorkspacePromptSummary(
        id: id,
        command: command,
        name: 'Summary',
        content: 'body',
        userId: 'owner',
        writeAccess: true,
        versionId: 'h1',
      );

  @override
  Future<WorkspacePromptDetail> create(WorkspacePromptForm form) async {
    created.add(form);
    return _detail('p-new', command: form.command);
  }

  @override
  Future<WorkspacePromptDetail> updateItem(
    String id,
    WorkspacePromptForm form,
  ) async {
    updated.add((id, form));
    return _detail(id, command: form.command);
  }

  @override
  Future<WorkspacePromptDetail> updateMetadata(
    String id, {
    required String name,
    required String command,
    List<String> tags = const [],
  }) async {
    metadata.add((id, name, command));
    return _detail(id, command: command);
  }

  @override
  Future<WorkspacePromptDetail> setProductionVersion(
    String id,
    String versionId,
  ) async {
    production.add((id, versionId));
    return _detail(id);
  }

  @override
  Future<WorkspacePromptDetail> toggle(String id) async {
    toggled.add(id);
    return _detail(id);
  }

  @override
  Future<void> delete(String id) async {
    deleted.add(id);
  }

  @override
  Future<List<WorkspacePromptHistoryEntry>> history(
    String id, {
    int page = 0,
  }) async {
    return page == 0 ? historyEntries : const [];
  }

  @override
  Future<Map<String, dynamic>> historyDiff(
    String id, {
    required String fromId,
    required String toId,
  }) async {
    return <String, dynamic>{
      'content_diff': <String>[],
      'name_changed': false,
    };
  }

  @override
  Future<void> deleteHistoryEntry(String id, String historyId) async {
    deletedHistory.add((id, historyId));
  }

  @override
  Future<void> importPrompt(WorkspacePromptForm form) async {
    importedForms.add(form);
    if (importShouldFail) throw StateError('rejected');
  }

  @override
  Future<void> refresh() async {}
}

/// Reproduces the real notifier's behaviour: `updateItem` invalidates the detail
/// provider the parent view watches, which rebuilds into its loading branch and
/// disposes the form before the save future resolves.
class _InvalidatingFakePrompts extends _FakePrompts {
  @override
  Future<WorkspacePromptDetail> updateItem(
    String id,
    WorkspacePromptForm form,
  ) async {
    updated.add((id, form));
    ref.invalidate(workspacePromptDetailProvider(id));
    // Yield so the parent can rebuild and dispose the form (matching the real
    // notifier, which awaits a collection refresh after invalidating).
    await Future<void>.delayed(Duration.zero);
    return _detail(id, command: form.command);
  }
}
