import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/providers/workspace_providers.dart';
import 'package:conduit/features/workspace/views/tools/workspace_tool_editor.dart';
import 'package:conduit/features/workspace/widgets/workspace_import_sheet.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';

TextField _textFieldByKey(WidgetTester tester, String key) {
  return tester.widget<TextField>(
    find.descendant(
      of: find.byKey(Key(key)),
      matching: find.byType(TextField),
    ),
  );
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final view = binding.platformDispatcher.views.first;

  setUp(() {
    view.physicalSize = const Size(1400, 3600);
    view.devicePixelRatio = 1;
  });

  tearDown(() {
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  testWidgets('create form renders stable keys and saves', (tester) async {
    final tools = _FakeTools();
    await tester.pumpWidget(_harness(tools, mode: WorkspaceRouteMode.create));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workspace-tool-name')), findsOneWidget);
    expect(find.byKey(const Key('workspace-tool-id')), findsOneWidget);
    expect(find.byKey(const Key('workspace-tool-description')), findsOneWidget);
    expect(find.byKey(const Key('workspace-tool-content')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('workspace-tool-name')),
      'Web Search',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pump();
    await tester.pump();

    expect(tools.created, hasLength(1));
    // The id auto-derives from the name via nameToId (underscores).
    expect(tools.created.single.id, 'web_search');
    expect(tools.created.single.name, 'Web Search');
    // The Python boilerplate is submitted as the source.
    expect(tools.created.single.content, contains('class Tools'));
  });

  testWidgets('empty source blocks save', (tester) async {
    final tools = _FakeTools();
    await tester.pumpWidget(_harness(tools, mode: WorkspaceRouteMode.create));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('workspace-tool-name')),
      'Named',
    );
    await tester.enterText(
      find.byKey(const Key('workspace-tool-content')),
      '',
    );
    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pump();

    expect(tools.created, isEmpty);
    expect(find.byKey(const Key('workspace-editor-error')), findsOneWidget);
  });

  testWidgets('incompatible required version blocks save', (tester) async {
    final tools = _FakeTools();
    await tester.pumpWidget(
      _harness(
        tools,
        mode: WorkspaceRouteMode.create,
        serverVersion: '0.10.0',
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('workspace-tool-name')),
      'Future Tool',
    );
    await tester.enterText(
      find.byKey(const Key('workspace-tool-content')),
      '"""\ntitle: Future Tool\nrequired_open_webui_version: 0.11.0\n"""\n'
          'class Tools:\n    pass\n',
    );
    await tester.pump();

    // The incompatibility banner is shown and the save affordance is disabled.
    expect(find.byKey(const Key('workspace-tool-incompatible')), findsOneWidget);
    final saveButton = tester.widget<ConduitButton>(
      find.byKey(const Key('workspace-editor-save')),
    );
    expect(saveButton.onPressed, isNull);

    await tester.tap(
      find.byKey(const Key('workspace-editor-save')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(tools.created, isEmpty);
  });

  testWidgets('edit form updates the tool', (tester) async {
    final tools = _FakeTools();
    await tester.pumpWidget(
      _harness(
        tools,
        mode: WorkspaceRouteMode.edit,
        resourceId: 't-1',
        detail: _writable(),
      ),
    );
    await tester.pumpAndSettle();

    // The id is immutable in edit mode.
    final id = _textFieldByKey(tester, 'workspace-tool-id');
    expect(id.enabled, isFalse);

    await tester.enterText(
      find.byKey(const Key('workspace-tool-content')),
      '"""\ntitle: Search\n"""\nclass Tools:\n    pass\n',
    );
    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pump();
    await tester.pump();

    expect(tools.updated, hasLength(1));
    expect(tools.updated.single.$1, 't-1');
    expect(tools.updated.single.$2.content, contains('class Tools'));
  });

  testWidgets('clone creates a copy without inherited grants', (tester) async {
    final tools = _FakeTools();
    await tester.pumpWidget(
      _harness(
        tools,
        mode: WorkspaceRouteMode.detail,
        resourceId: 't-1',
        detail: _writable(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-tool-action-clone')));
    await tester.pump();
    await tester.pump();

    expect(tools.created, hasLength(1));
    expect(tools.created.single.id, contains('_clone'));
    expect(tools.created.single.accessGrants, isEmpty);
  });

  testWidgets('delete action deletes after confirmation', (tester) async {
    final tools = _FakeTools();
    await tester.pumpWidget(
      _harness(
        tools,
        mode: WorkspaceRouteMode.detail,
        resourceId: 't-1',
        detail: _writable(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-tool-action-delete')));
    await tester.pumpAndSettle();

    expect(find.text('Delete tool?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.pump();

    expect(tools.deleted, ['t-1']);
  });

  testWidgets('url import is admin-only', (tester) async {
    // Admin sees the URL import action.
    final tools = _FakeTools();
    await tester.pumpWidget(
      _harness(tools, mode: WorkspaceRouteMode.create, isAdmin: true),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('workspace-tool-action-import-url')),
      findsOneWidget,
    );
    // JSON import is available to any user with the import permission.
    expect(
      find.byKey(const Key('workspace-tool-action-import-json')),
      findsOneWidget,
    );
  });

  testWidgets('non-admin cannot import from URL', (tester) async {
    final tools = _FakeTools();
    await tester.pumpWidget(
      _harness(tools, mode: WorkspaceRouteMode.create, isAdmin: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('workspace-tool-action-import-url')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('workspace-tool-action-import-json')),
      findsOneWidget,
    );
  });

  testWidgets('json import records per-item failures without aborting', (
    tester,
  ) async {
    final tools = _FakeTools();
    tools.importShouldFail = true;
    final report = await runWorkspaceImport(
      [
        {'id': 'a', 'name': 'A', 'content': 'x'},
        {'id': 'b', 'name': 'B', 'content': 'y'},
      ],
      importItem: (item) => tools.importTool(
        WorkspaceToolForm(
          id: item['id'] as String,
          name: item['name'] as String,
          content: item['content'] as String,
        ),
      ),
    );
    expect(report.total, 2);
    expect(report.hasFailures, isTrue);
    expect(report.failureCount, 2);
  });

  testWidgets('read-only tool hides save and mutation actions', (tester) async {
    final tools = _FakeTools();
    await tester.pumpWidget(
      _harness(
        tools,
        mode: WorkspaceRouteMode.detail,
        resourceId: 't-ro',
        detail: _readOnly(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workspace-editor-save')), findsNothing);
    expect(find.byKey(const Key('workspace-read-only-badge')), findsWidgets);
    expect(find.byKey(const Key('workspace-tool-edit')), findsNothing);

    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('workspace-tool-action-clone')), findsNothing);
    expect(find.byKey(const Key('workspace-tool-action-delete')), findsNothing);
    expect(find.byKey(const Key('workspace-tool-action-valves')), findsNothing);
    expect(
      find.byKey(const Key('workspace-tool-action-access')),
      findsOneWidget,
    );
  });
}

// ---------------------------------------------------------------------------

Widget _harness(
  _FakeTools tools, {
  required WorkspaceRouteMode mode,
  String? resourceId,
  WorkspaceToolDetail? detail,
  WorkspaceCapabilities capabilities = WorkspaceCapabilities.all,
  String? serverVersion = '0.10.2',
  bool isAdmin = true,
}) {
  return ProviderScope(
    overrides: [
      reviewerModeProvider.overrideWithValue(false),
      apiServiceProvider.overrideWithValue(null),
      workspaceCapabilitiesProvider.overrideWith((ref) async => capabilities),
      workspaceServerVersionProvider.overrideWithValue(serverVersion),
      currentUserProvider2.overrideWithValue(
        User(
          id: 'user-1',
          username: 'user',
          email: 'user@example.com',
          role: isAdmin ? 'admin' : 'user',
        ),
      ),
      workspaceToolsProvider.overrideWith(() => tools),
      if (resourceId != null && detail != null)
        workspaceToolDetailProvider(
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
          body: WorkspaceToolEditorView(mode: mode, toolId: resourceId),
        ),
      ),
      GoRoute(path: '/workspace/tools', builder: placeholder),
      GoRoute(path: '/workspace/tools/create', builder: placeholder),
      GoRoute(path: '/workspace/tools/:id', builder: placeholder),
      GoRoute(path: '/workspace/tools/:id/edit', builder: placeholder),
    ],
  );
  return MaterialApp.router(
    routerConfig: router,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
  );
}

WorkspaceToolDetail _writable() => const WorkspaceToolSummary(
  id: 't-1',
  name: 'Search',
  userId: 'owner',
  content: '"""\ntitle: Search\n"""\nclass Tools:\n    pass\n',
  writeAccess: true,
);

WorkspaceToolDetail _readOnly() => const WorkspaceToolSummary(
  id: 't-ro',
  name: 'Shared',
  userId: 'someone',
  content: 'class Tools:\n    pass\n',
  writeAccess: false,
);

class _FakeTools extends WorkspaceTools {
  final created = <WorkspaceToolForm>[];
  final updated = <(String, WorkspaceToolForm)>[];
  final deleted = <String>[];
  bool importShouldFail = false;

  @override
  Future<WorkspaceCollectionState<WorkspaceToolSummary>> build() async {
    return const WorkspaceCollectionState(items: [], total: 0);
  }

  WorkspaceToolDetail _detail(String id) => WorkspaceToolSummary(
    id: id,
    name: 'Search',
    userId: 'owner',
    content: 'class Tools:\n    pass\n',
    writeAccess: true,
  );

  @override
  Future<WorkspaceToolDetail> create(WorkspaceToolForm form) async {
    created.add(form);
    return _detail(form.id.isEmpty ? 't-new' : form.id);
  }

  @override
  Future<WorkspaceToolDetail> updateItem(
    String id,
    WorkspaceToolForm form,
  ) async {
    updated.add((id, form));
    return _detail(id);
  }

  @override
  Future<void> delete(String id) async {
    deleted.add(id);
  }

  @override
  Future<void> importTool(WorkspaceToolForm form) async {
    if (importShouldFail) throw StateError('rejected');
  }

  @override
  Future<void> refresh() async {}
}
