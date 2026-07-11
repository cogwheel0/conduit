import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/providers/workspace_providers.dart';
import 'package:conduit/features/workspace/views/skills/workspace_skill_editor.dart';
import 'package:conduit/features/workspace/widgets/workspace_import_sheet.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    view.physicalSize = const Size(1400, 3200);
    view.devicePixelRatio = 1;
  });

  tearDown(() {
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  testWidgets('create form renders stable keys and saves', (tester) async {
    final skills = _FakeSkills();
    await tester.pumpWidget(_harness(skills, mode: WorkspaceRouteMode.create));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workspace-skill-name')), findsOneWidget);
    expect(find.byKey(const Key('workspace-skill-id')), findsOneWidget);
    expect(find.byKey(const Key('workspace-skill-description')), findsOneWidget);
    expect(find.byKey(const Key('workspace-skill-content')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('workspace-skill-name')),
      'Code Review',
    );
    await tester.enterText(
      find.byKey(const Key('workspace-skill-content')),
      'Do the review.',
    );
    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pump();
    await tester.pump();

    expect(skills.created, hasLength(1));
    // The id auto-slugs from the name until the user edits it.
    expect(skills.created.single.id, 'code-review');
    expect(skills.created.single.name, 'Code Review');
    expect(skills.created.single.content, 'Do the review.');
  });

  testWidgets('empty content blocks save', (tester) async {
    final skills = _FakeSkills();
    await tester.pumpWidget(_harness(skills, mode: WorkspaceRouteMode.create));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('workspace-skill-name')),
      'Named',
    );
    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pump();

    expect(skills.created, isEmpty);
    expect(find.byKey(const Key('workspace-editor-error')), findsOneWidget);
  });

  testWidgets('front-matter prefills name/id/description in create mode', (
    tester,
  ) async {
    final skills = _FakeSkills();
    await tester.pumpWidget(_harness(skills, mode: WorkspaceRouteMode.create));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('workspace-skill-content')),
      '---\n'
          'name: code_review_guidelines\n'
          'description: Review checklist\n'
          '---\n'
          'Body.',
    );
    await tester.pump();

    final name = _textFieldByKey(tester, 'workspace-skill-name');
    final id = _textFieldByKey(tester, 'workspace-skill-id');
    final description = _textFieldByKey(tester, 'workspace-skill-description');
    expect(name.controller!.text, 'Code Review Guidelines');
    expect(id.controller!.text, 'code_review_guidelines');
    expect(description.controller!.text, 'Review checklist');
  });

  testWidgets('edit form updates the skill', (tester) async {
    final skills = _FakeSkills();
    await tester.pumpWidget(
      _harness(
        skills,
        mode: WorkspaceRouteMode.edit,
        resourceId: 's-1',
        detail: _writable(),
      ),
    );
    await tester.pumpAndSettle();

    // The id is immutable in edit mode.
    final id = _textFieldByKey(tester, 'workspace-skill-id');
    expect(id.enabled, isFalse);

    await tester.enterText(
      find.byKey(const Key('workspace-skill-content')),
      'Updated instructions.',
    );
    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pump();
    await tester.pump();

    expect(skills.updated, hasLength(1));
    expect(skills.updated.single.$1, 's-1');
    expect(skills.updated.single.$2.id, 's-1');
    expect(skills.updated.single.$2.content, 'Updated instructions.');
  });

  testWidgets('clone creates a copy without inherited grants', (tester) async {
    final skills = _FakeSkills();
    await tester.pumpWidget(
      _harness(
        skills,
        mode: WorkspaceRouteMode.detail,
        resourceId: 's-1',
        detail: _writable(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-skill-action-clone')));
    await tester.pump();
    await tester.pump();

    expect(skills.created, hasLength(1));
    expect(skills.created.single.id, contains('_clone'));
    expect(skills.created.single.accessGrants, isEmpty);
  });

  testWidgets('toggle action toggles active state', (tester) async {
    final skills = _FakeSkills();
    await tester.pumpWidget(
      _harness(
        skills,
        mode: WorkspaceRouteMode.detail,
        resourceId: 's-1',
        detail: _writable(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-skill-action-toggle')));
    await tester.pump();
    await tester.pump();

    expect(skills.toggled, ['s-1']);
  });

  testWidgets('delete action deletes after confirmation', (tester) async {
    final skills = _FakeSkills();
    await tester.pumpWidget(
      _harness(
        skills,
        mode: WorkspaceRouteMode.detail,
        resourceId: 's-1',
        detail: _writable(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-skill-action-delete')));
    await tester.pumpAndSettle();

    expect(find.text('Delete skill?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.pump();

    expect(skills.deleted, ['s-1']);
  });

  testWidgets('markdown import prefills the unsaved create editor', (
    tester,
  ) async {
    final skills = _FakeSkills();
    await tester.pumpWidget(
      _harness(
        skills,
        mode: WorkspaceRouteMode.create,
        markdownPicker: () async =>
            '---\nname: Imported Skill\ndescription: From file\n---\nBody text.',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('workspace-skill-action-import-markdown')),
    );
    await tester.pumpAndSettle();

    final name = _textFieldByKey(tester, 'workspace-skill-name');
    final content = _textFieldByKey(tester, 'workspace-skill-content');
    expect(name.controller!.text, 'Imported Skill');
    expect(content.controller!.text, contains('Body text.'));
    // Markdown import does not persist — it opens an unsaved editor.
    expect(skills.created, isEmpty);
  });

  testWidgets('markdown import honors front-matter id without a name', (
    tester,
  ) async {
    final skills = _FakeSkills();
    await tester.pumpWidget(
      _harness(
        skills,
        mode: WorkspaceRouteMode.create,
        markdownPicker: () async => '---\nid: my_skill\n---\nBody text.',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('workspace-skill-action-import-markdown')),
    );
    await tester.pumpAndSettle();

    final id = _textFieldByKey(tester, 'workspace-skill-id');
    // The id must survive even though no front-matter name was provided.
    expect(id.controller!.text, 'my_skill');
  });

  testWidgets('json import records per-item failures without aborting', (
    tester,
  ) async {
    final skills = _FakeSkills();
    await tester.pumpWidget(_harness(skills, mode: WorkspaceRouteMode.create));
    await tester.pumpAndSettle();

    // The create-mode overflow exposes both import affordances.
    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('workspace-skill-action-import-json')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('workspace-skill-action-import-markdown')),
      findsOneWidget,
    );
    await tester.tapAt(const Offset(10, 10)); // dismiss the menu
    await tester.pumpAndSettle();

    skills.importShouldFail = true;
    final report = await runWorkspaceImport(
      [
        {'id': 'a', 'name': 'A', 'content': 'x'},
        {'id': 'b', 'name': 'B', 'content': 'y'},
      ],
      importItem: (item) => skills.importSkill(
        WorkspaceSkillForm(
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

  testWidgets('read-only skill hides save and mutation actions', (tester) async {
    final skills = _FakeSkills();
    await tester.pumpWidget(
      _harness(
        skills,
        mode: WorkspaceRouteMode.detail,
        resourceId: 's-ro',
        detail: _readOnly(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workspace-editor-save')), findsNothing);
    expect(find.byKey(const Key('workspace-read-only-badge')), findsWidgets);
    expect(find.byKey(const Key('workspace-skill-edit')), findsNothing);

    // Only the read-only-safe access action is offered.
    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('workspace-skill-action-clone')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('workspace-skill-action-delete')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('workspace-skill-action-access')),
      findsOneWidget,
    );
  });

  testWidgets('empty id reports the required reason inline, not "invalid"', (
    tester,
  ) async {
    final skills = _FakeSkills();
    await tester.pumpWidget(_harness(skills, mode: WorkspaceRouteMode.create));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('workspace-skill-name')),
      'Review',
    );
    await tester.enterText(
      find.byKey(const Key('workspace-skill-content')),
      'Body.',
    );
    // Clear the auto-slugged id so the required branch fires.
    await tester.enterText(find.byKey(const Key('workspace-skill-id')), '');
    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pump();

    final idField = _textFieldByKey(tester, 'workspace-skill-id');
    expect(skills.created, isEmpty);
    expect(idField.decoration!.errorText, 'Skill ID is required.');
  });

  testWidgets('illegal id characters report the invalid-characters reason', (
    tester,
  ) async {
    final skills = _FakeSkills();
    await tester.pumpWidget(_harness(skills, mode: WorkspaceRouteMode.create));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('workspace-skill-name')),
      'Review',
    );
    await tester.enterText(
      find.byKey(const Key('workspace-skill-content')),
      'Body.',
    );
    await tester.enterText(
      find.byKey(const Key('workspace-skill-id')),
      'bad id',
    );
    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pump();

    final idField = _textFieldByKey(tester, 'workspace-skill-id');
    expect(skills.created, isEmpty);
    expect(
      idField.decoration!.errorText,
      'Only letters, numbers, hyphens, and underscores are allowed.',
    );
  });
}

// ---------------------------------------------------------------------------

Widget _harness(
  _FakeSkills skills, {
  required WorkspaceRouteMode mode,
  String? resourceId,
  WorkspaceSkillDetail? detail,
  WorkspaceCapabilities capabilities = WorkspaceCapabilities.all,
  WorkspaceMarkdownPicker? markdownPicker,
}) {
  return ProviderScope(
    overrides: [
      reviewerModeProvider.overrideWithValue(false),
      apiServiceProvider.overrideWithValue(null),
      workspaceCapabilitiesProvider.overrideWith((ref) async => capabilities),
      workspaceSkillsProvider.overrideWith(() => skills),
      if (resourceId != null && detail != null)
        workspaceSkillDetailProvider(
          resourceId,
        ).overrideWith((ref) async => detail),
    ],
    child: _app(mode, resourceId, markdownPicker),
  );
}

Widget _app(
  WorkspaceRouteMode mode,
  String? resourceId,
  WorkspaceMarkdownPicker? markdownPicker,
) {
  Widget placeholder(_, _) => const Scaffold(body: Text('nav-target'));
  final router = GoRouter(
    initialLocation: '/editor',
    routes: [
      GoRoute(
        path: '/editor',
        builder: (_, _) => Scaffold(
          body: WorkspaceSkillEditorView(
            mode: mode,
            skillId: resourceId,
            markdownPicker: markdownPicker,
          ),
        ),
      ),
      GoRoute(path: '/workspace/skills', builder: placeholder),
      GoRoute(path: '/workspace/skills/create', builder: placeholder),
      GoRoute(path: '/workspace/skills/:id', builder: placeholder),
      GoRoute(path: '/workspace/skills/:id/edit', builder: placeholder),
    ],
  );
  return MaterialApp.router(
    routerConfig: router,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
  );
}

WorkspaceSkillDetail _writable() => const WorkspaceSkillSummary(
  id: 's-1',
  name: 'Review',
  userId: 'owner',
  description: 'A skill',
  content: 'Original instructions.',
  writeAccess: true,
);

WorkspaceSkillDetail _readOnly() => const WorkspaceSkillSummary(
  id: 's-ro',
  name: 'Shared',
  userId: 'someone',
  content: 'Shared instructions.',
  writeAccess: false,
);

class _FakeSkills extends WorkspaceSkills {
  final List<WorkspaceSkillSummary> items = const [];

  final created = <WorkspaceSkillForm>[];
  final updated = <(String, WorkspaceSkillForm)>[];
  final toggled = <String>[];
  final deleted = <String>[];
  final importedForms = <WorkspaceSkillForm>[];
  bool importShouldFail = false;

  @override
  Future<WorkspaceCollectionState<WorkspaceSkillSummary>> build() async {
    return WorkspaceCollectionState(items: items, total: items.length);
  }

  WorkspaceSkillDetail _detail(String id) => WorkspaceSkillSummary(
    id: id,
    name: 'Review',
    userId: 'owner',
    content: 'body',
    writeAccess: true,
  );

  @override
  Future<WorkspaceSkillDetail> create(WorkspaceSkillForm form) async {
    created.add(form);
    return _detail(form.id.isEmpty ? 's-new' : form.id);
  }

  @override
  Future<WorkspaceSkillDetail> updateItem(
    String id,
    WorkspaceSkillForm form,
  ) async {
    updated.add((id, form));
    return _detail(id);
  }

  @override
  Future<WorkspaceSkillDetail> toggle(String id) async {
    toggled.add(id);
    return _detail(id);
  }

  @override
  Future<void> delete(String id) async {
    deleted.add(id);
  }

  @override
  Future<void> importSkill(WorkspaceSkillForm form) async {
    importedForms.add(form);
    if (importShouldFail) throw StateError('rejected');
  }

  @override
  Future<List<WorkspaceSkillDetail>> exportAll() async => const [];

  @override
  Future<void> refresh() async {}
}
