import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/providers/workspace_knowledge_files.dart';
import 'package:conduit/features/workspace/providers/workspace_providers.dart';
import 'package:conduit/features/workspace/views/knowledge/workspace_knowledge_editor.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final view = binding.platformDispatcher.views.first;

  setUp(() {
    view.physicalSize = const Size(1400, 2600);
    view.devicePixelRatio = 1;
  });

  tearDown(() {
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  testWidgets('create form saves via create and keys are stable', (
    tester,
  ) async {
    final knowledge = _FakeKnowledge();
    await tester.pumpWidget(
      _harness(
        knowledge: knowledge,
        mode: WorkspaceRouteMode.create,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workspace-knowledge-name')), findsOneWidget);
    expect(
      find.byKey(const Key('workspace-knowledge-description')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('workspace-editor-save')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('workspace-knowledge-name')),
      'Docs',
    );
    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pump();
    await tester.pump();

    expect(knowledge.createdForms, hasLength(1));
    expect(knowledge.createdForms.single.name, 'Docs');
  });

  testWidgets('create form blocks save when name is empty', (tester) async {
    final knowledge = _FakeKnowledge();
    await tester.pumpWidget(
      _harness(knowledge: knowledge, mode: WorkspaceRouteMode.create),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pump();

    expect(knowledge.createdForms, isEmpty);
    expect(find.byKey(const Key('workspace-editor-error')), findsOneWidget);
  });

  testWidgets('external knowledge is read-only with no file mutation controls', (
    tester,
  ) async {
    final knowledge = _FakeKnowledge();
    await tester.pumpWidget(
      _harness(
        knowledge: knowledge,
        mode: WorkspaceRouteMode.detail,
        resourceId: 'kb-ext',
        detail: _externalDetail(),
        files: _FakeFiles(const WorkspaceKnowledgeBrowserState()),
      ),
    );
    await tester.pumpAndSettle();

    // No save affordance, a read-only badge, and no add menu on the browser.
    expect(find.byKey(const Key('workspace-editor-save')), findsNothing);
    expect(find.byKey(const Key('workspace-read-only-badge')), findsWidgets);
    expect(find.byKey(const Key('knowledge-add-menu')), findsNothing);
  });

  testWidgets('detail overflow resets after confirmation', (tester) async {
    final knowledge = _FakeKnowledge();
    await tester.pumpWidget(
      _harness(
        knowledge: knowledge,
        mode: WorkspaceRouteMode.detail,
        resourceId: 'kb-1',
        detail: _writableDetail(),
        files: _FakeFiles(const WorkspaceKnowledgeBrowserState()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-knowledge-action-reset')));
    await tester.pumpAndSettle();

    expect(find.text('Reset knowledge base?'), findsOneWidget);
    await tester.tap(find.text('Reset'));
    await tester.pump();
    await tester.pump();

    expect(knowledge.resetIds, ['kb-1']);
  });

  testWidgets('detail overflow deletes after confirmation', (tester) async {
    final knowledge = _FakeKnowledge();
    await tester.pumpWidget(
      _harness(
        knowledge: knowledge,
        mode: WorkspaceRouteMode.detail,
        resourceId: 'kb-1',
        detail: _writableDetail(),
        files: _FakeFiles(const WorkspaceKnowledgeBrowserState()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-knowledge-action-delete')));
    await tester.pumpAndSettle();

    expect(find.text('Delete knowledge base?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.pump();

    expect(knowledge.deletedIds, ['kb-1']);
  });

  testWidgets('file browser renders directories and files with stable keys', (
    tester,
  ) async {
    final knowledge = _FakeKnowledge();
    final files = _FakeFiles(
      const WorkspaceKnowledgeBrowserState(
        directories: [
          WorkspaceKnowledgeDirectory(
            id: 'dir-1',
            knowledgeId: 'kb-1',
            name: 'Guides',
            userId: 'owner',
          ),
        ],
        files: [
          WorkspaceKnowledgeFile(id: 'file-1', filename: 'readme.md', size: 12),
        ],
      ),
    );
    await tester.pumpWidget(
      _harness(
        knowledge: knowledge,
        mode: WorkspaceRouteMode.edit,
        resourceId: 'kb-1',
        detail: _writableDetail(),
        files: files,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('knowledge-directory-dir-1')), findsOneWidget);
    expect(find.byKey(const Key('knowledge-file-file-1')), findsOneWidget);
    expect(find.byKey(const Key('knowledge-breadcrumb-root')), findsOneWidget);
    expect(find.byKey(const Key('knowledge-add-menu')), findsOneWidget);
  });

  testWidgets('empty file browser shows the empty state', (tester) async {
    final knowledge = _FakeKnowledge();
    await tester.pumpWidget(
      _harness(
        knowledge: knowledge,
        mode: WorkspaceRouteMode.edit,
        resourceId: 'kb-1',
        detail: _writableDetail(),
        files: _FakeFiles(const WorkspaceKnowledgeBrowserState()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('knowledge-files-empty')), findsOneWidget);
  });

  testWidgets('owner can delete the underlying file on detach', (tester) async {
    final knowledge = _FakeKnowledge();
    final files = _FakeFiles(
      const WorkspaceKnowledgeBrowserState(
        files: [WorkspaceKnowledgeFile(id: 'file-1', filename: 'readme.md')],
      ),
    );
    await tester.pumpWidget(
      _harness(
        knowledge: knowledge,
        mode: WorkspaceRouteMode.edit,
        resourceId: 'kb-1',
        detail: _writableDetail(),
        files: files,
        user: const User(
          id: 'owner',
          username: 'owner',
          email: 'o@e.com',
          role: 'user',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('knowledge-file-menu-file-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('knowledge-file-detach-file-1')));
    await tester.pumpAndSettle();

    // Owner sees the underlying-delete checkbox; enable it then confirm.
    expect(
      find.byKey(const Key('knowledge-detach-delete-underlying')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('knowledge-detach-delete-underlying')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('knowledge-detach-confirm')));
    await tester.pumpAndSettle();

    expect(files.detached, [('file-1', true)]);
  });

  testWidgets('non-owner cannot delete the underlying file on detach', (
    tester,
  ) async {
    final knowledge = _FakeKnowledge();
    final files = _FakeFiles(
      const WorkspaceKnowledgeBrowserState(
        files: [WorkspaceKnowledgeFile(id: 'file-1', filename: 'readme.md')],
      ),
    );
    await tester.pumpWidget(
      _harness(
        knowledge: knowledge,
        mode: WorkspaceRouteMode.edit,
        resourceId: 'kb-1',
        detail: _writableDetail(),
        files: files,
        user: const User(
          id: 'collaborator',
          username: 'collab',
          email: 'c@e.com',
          role: 'user',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('knowledge-file-menu-file-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('knowledge-file-detach-file-1')));
    await tester.pumpAndSettle();

    // No underlying-delete checkbox for a non-owner collaborator.
    expect(
      find.byKey(const Key('knowledge-detach-delete-underlying')),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('knowledge-detach-confirm')));
    await tester.pumpAndSettle();

    expect(files.detached, [('file-1', false)]);
  });
}

// ---------------------------------------------------------------------------

Widget _harness({
  required _FakeKnowledge knowledge,
  required WorkspaceRouteMode mode,
  String? resourceId,
  WorkspaceKnowledgeDetail? detail,
  _FakeFiles? files,
  User user = const User(
    id: 'owner',
    username: 'owner',
    email: 'o@e.com',
    role: 'user',
  ),
}) {
  return ProviderScope(
    overrides: [
      reviewerModeProvider.overrideWithValue(false),
      apiServiceProvider.overrideWithValue(null),
      currentUserProvider2.overrideWithValue(user),
      workspaceCapabilitiesProvider.overrideWith(
        (ref) async => WorkspaceCapabilities.all,
      ),
      workspaceKnowledgeProvider.overrideWith(() => knowledge),
      if (resourceId != null && detail != null)
        workspaceKnowledgeDetailProvider(resourceId).overrideWith(
          (ref) async => detail,
        ),
      if (resourceId != null && files != null)
        workspaceKnowledgeFilesProvider(resourceId).overrideWith(() => files),
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
          body: WorkspaceKnowledgeEditorView(mode: mode, knowledgeId: resourceId),
        ),
      ),
      GoRoute(path: '/workspace/knowledge', builder: placeholder),
      GoRoute(path: '/workspace/knowledge/create', builder: placeholder),
      GoRoute(path: '/workspace/knowledge/:id', builder: placeholder),
      GoRoute(path: '/workspace/knowledge/:id/edit', builder: placeholder),
    ],
  );
  return MaterialApp.router(
    routerConfig: router,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
  );
}

WorkspaceKnowledgeDetail _writableDetail() => const WorkspaceKnowledgeDetail(
  summary: WorkspaceKnowledgeSummary(
    id: 'kb-1',
    name: 'Docs',
    userId: 'owner',
    description: 'Docs base',
    writeAccess: true,
  ),
);

WorkspaceKnowledgeDetail _externalDetail() => const WorkspaceKnowledgeDetail(
  summary: WorkspaceKnowledgeSummary(
    id: 'kb-ext',
    name: 'Connected',
    userId: 'someone',
    writeAccess: false,
    meta: {'source': 'external'},
  ),
);

class _FakeKnowledge extends WorkspaceKnowledge {
  final createdForms = <WorkspaceKnowledgeForm>[];
  final updatedForms = <WorkspaceKnowledgeForm>[];
  final resetIds = <String>[];
  final deletedIds = <String>[];

  @override
  Future<WorkspaceCollectionState<WorkspaceKnowledgeSummary>> build() async {
    return const WorkspaceCollectionState(items: [], total: 0);
  }

  @override
  Future<WorkspaceKnowledgeDetail> create(WorkspaceKnowledgeForm form) async {
    createdForms.add(form);
    return WorkspaceKnowledgeDetail(
      summary: WorkspaceKnowledgeSummary(
        id: 'kb-new',
        name: form.name,
        userId: 'owner',
        writeAccess: true,
      ),
    );
  }

  @override
  Future<WorkspaceKnowledgeDetail> updateItem(
    String id,
    WorkspaceKnowledgeForm form,
  ) async {
    updatedForms.add(form);
    return WorkspaceKnowledgeDetail(
      summary: WorkspaceKnowledgeSummary(
        id: id,
        name: form.name,
        userId: 'owner',
        writeAccess: true,
      ),
    );
  }

  @override
  Future<WorkspaceKnowledgeDetail> reset(
    String id, {
    bool includeDirectories = true,
  }) async {
    resetIds.add(id);
    return _writableDetail();
  }

  @override
  Future<void> delete(String id) async {
    deletedIds.add(id);
  }

  @override
  Future<void> refresh() async {}
}

class _FakeFiles extends WorkspaceKnowledgeFiles {
  _FakeFiles(this._initial);

  final WorkspaceKnowledgeBrowserState _initial;
  final detached = <(String, bool)>[];

  @override
  Future<WorkspaceKnowledgeBrowserState> build(String knowledgeId) async {
    return _initial;
  }

  @override
  Future<void> detach(String fileId, {required bool deleteUnderlying}) async {
    detached.add((fileId, deleteUnderlying));
  }

  @override
  Future<void> refresh() async {}

  @override
  Future<void> refreshPending() async {}
}
