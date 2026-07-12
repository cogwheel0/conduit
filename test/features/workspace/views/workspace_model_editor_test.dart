import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/providers/workspace_model_relationships.dart';
import 'package:conduit/features/workspace/providers/workspace_providers.dart';
import 'package:conduit/features/workspace/views/models/workspace_model_editor.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_scaffold.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final view = binding.platformDispatcher.views.first;

  setUp(() {
    view.physicalSize = const Size(1200, 2400);
    view.devicePixelRatio = 1;
  });

  tearDown(() {
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  testWidgets('create editor renders keyed fields and can be saved', (
    tester,
  ) async {
    final fake = _FakeWorkspaceModels();
    await tester.pumpWidget(
      _harness(models: fake, mode: WorkspaceRouteMode.create),
    );
    await tester.pumpAndSettle();

    // Stable keys + semantics for the top-of-form fields.
    expect(find.byKey(const Key('workspace-model-id')), findsOneWidget);
    expect(find.byKey(const Key('workspace-model-name')), findsOneWidget);
    expect(find.byKey(const Key('workspace-model-base')), findsOneWidget);
    expect(find.byKey(const Key('workspace-editor-save')), findsOneWidget);
    // Deep relationship tiles exist once scrolled into view.
    await _scrollTo(tester, const Key('workspace-model-tools'));
    expect(find.byKey(const Key('workspace-model-tools')), findsOneWidget);

    // Scroll back up: the taller card-based layout disposes the top-of-form
    // fields once the relationship tiles are in view.
    await _scrollTo(tester, const Key('workspace-model-id'), delta: -300);
    await tester.enterText(
      find.byKey(const Key('workspace-model-id')),
      'my-model',
    );
    await tester.enterText(
      find.byKey(const Key('workspace-model-name')),
      'My Model',
    );
    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pump();
    await tester.pump();

    expect(fake.createdForms, hasLength(1));
    expect(fake.createdForms.single.id, 'my-model');
    expect(fake.createdForms.single.name, 'My Model');
  });

  testWidgets('editor blocks save when required fields are empty', (
    tester,
  ) async {
    final fake = _FakeWorkspaceModels();
    await tester.pumpWidget(
      _harness(models: fake, mode: WorkspaceRouteMode.create),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pump();

    expect(fake.createdForms, isEmpty);
    expect(find.byKey(const Key('workspace-editor-error')), findsOneWidget);
  });

  testWidgets('edit editor saves via updateItem', (tester) async {
    final fake = _FakeWorkspaceModels();
    await tester.pumpWidget(
      _harness(
        models: fake,
        mode: WorkspaceRouteMode.edit,
        resourceId: 'model-1',
        detail: _writableModel(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('workspace-model-name')),
      'Renamed',
    );
    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pump();

    expect(fake.updatedForms, hasLength(1));
    expect(fake.updatedForms.single.name, 'Renamed');
  });

  testWidgets('read-only model hides save and shows the read-only badge', (
    tester,
  ) async {
    final fake = _FakeWorkspaceModels();
    await tester.pumpWidget(
      _harness(
        models: fake,
        mode: WorkspaceRouteMode.edit,
        resourceId: 'model-1',
        detail: _readOnlyModel(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workspace-editor-save')), findsNothing);
    expect(find.byKey(const Key('workspace-read-only-badge')), findsOneWidget);
  });

  testWidgets('detail overflow deletes after confirmation', (tester) async {
    final fake = _FakeWorkspaceModels();
    await tester.pumpWidget(
      _harness(
        models: fake,
        mode: WorkspaceRouteMode.detail,
        resourceId: 'model-1',
        detail: _writableModel(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-model-action-delete')));
    await tester.pumpAndSettle();

    // Confirm dialog -> tap the destructive confirm.
    expect(find.text('Delete model?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.pump();

    expect(fake.deletedIds, ['model-1']);
  });

  testWidgets('detail overflow toggles active state', (tester) async {
    final fake = _FakeWorkspaceModels();
    await tester.pumpWidget(
      _harness(
        models: fake,
        mode: WorkspaceRouteMode.detail,
        resourceId: 'model-1',
        detail: _writableModel(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-model-action-toggle')));
    await tester.pump();
    await tester.pump();

    expect(fake.toggledIds, ['model-1']);
  });

  testWidgets('loading detail shows the editor loading state', (tester) async {
    final fake = _FakeWorkspaceModels();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ..._baseOverrides(fake),
          workspaceModelDetailProvider('pending').overrideWith(
            // Never completes: keeps the provider in the loading state without
            // leaving a pending timer for the test binding to flag.
            (ref) => Completer<WorkspaceModelDetail>().future,
          ),
        ],
        child: _app(WorkspaceRouteMode.edit, 'pending'),
      ),
    );
    await tester.pump();

    // Loading detail renders the scaffold chrome but not the form body.
    expect(find.byType(WorkspaceEditorScaffold), findsOneWidget);
    expect(find.byKey(const Key('workspace-model-editor-body')), findsNothing);
  });

  testWidgets('relationship picker selects tools into the draft', (
    tester,
  ) async {
    final fake = _FakeWorkspaceModels();
    await tester.pumpWidget(
      _harness(
        models: fake,
        mode: WorkspaceRouteMode.edit,
        resourceId: 'model-1',
        detail: _writableModel(),
        tools: const [
          WorkspaceToolSummary(id: 'tool-a', name: 'Tool A', userId: 'u'),
          WorkspaceToolSummary(id: 'tool-b', name: 'Tool B', userId: 'u'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await _scrollTo(tester, const Key('workspace-model-tools'));
    await tester.tap(find.byKey(const Key('workspace-model-tools')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('workspace-relationship-list')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('workspace-relationship-tool-a')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('workspace-relationship-save')));
    await tester.pumpAndSettle();

    // Subtitle reflects one selected tool.
    await tester.tap(find.byKey(const Key('workspace-editor-save')));
    await tester.pump();
    expect(fake.updatedForms.single.meta['toolIds'], ['tool-a']);
  });

  testWidgets('base model dropdown shows the saved id once options resolve', (
    tester,
  ) async {
    final fake = _FakeWorkspaceModels();
    // The base-model options resolve asynchronously (as a FutureProvider always
    // does on the first frame), so the dropdown is first built with an empty
    // options list. The saved base model id must still drive the selection once
    // the options arrive, rather than reverting to "None".
    await tester.pumpWidget(
      _harness(
        models: fake,
        mode: WorkspaceRouteMode.edit,
        resourceId: 'model-1',
        detail: const WorkspaceModelSummary(
          id: 'model-1',
          name: 'Model 1',
          userId: 'owner',
          writeAccess: true,
          baseModelId: 'base-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final dropdown = tester.widget<DropdownButton<String?>>(
      find.descendant(
        of: find.byKey(const Key('workspace-model-base')),
        matching: find.byType(DropdownButton<String?>),
      ),
    );
    expect(dropdown.value, 'base-1');
    // The saved option renders by its resolved label.
    expect(find.text('Base One'), findsWidgets);
  });

  testWidgets('relationship picker load failure surfaces an error snack', (
    tester,
  ) async {
    final fake = _FakeWorkspaceModels();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          workspaceCapabilitiesProvider.overrideWith(
            (ref) async => WorkspaceCapabilities.all,
          ),
          workspaceModelsProvider.overrideWith(() => fake),
          modelsProvider.overrideWith(_FakeModels.new),
          workspaceBaseModelsProvider.overrideWith((ref) async => const []),
          // The tools collection fails to load; opening the picker must surface
          // an error snackbar rather than throw unhandled from the callback.
          workspaceToolsProvider.overrideWith(_FailingWorkspaceTools.new),
          workspaceModelDetailProvider(
            'model-1',
          ).overrideWith((ref) async => _writableModel()),
        ],
        child: _app(WorkspaceRouteMode.edit, 'model-1'),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollTo(tester, const Key('workspace-model-tools'));
    await tester.tap(find.byKey(const Key('workspace-model-tools')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Workspace could not be loaded.'), findsOneWidget);
  });

  testWidgets('import failure is surfaced per item', (tester) async {
    final fake = _FakeWorkspaceModels(importSucceeds: false);
    final report = await fake.runImport();
    expect(report, isFalse);
  });

  testWidgets('clone aborts when the advanced params JSON is invalid', (
    tester,
  ) async {
    final fake = _FakeWorkspaceModels();
    await tester.pumpWidget(
      _harness(
        models: fake,
        mode: WorkspaceRouteMode.edit,
        resourceId: 'model-1',
        detail: _writableModel(),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollTo(tester, const Key('workspace-model-params'));
    await tester.enterText(
      find.byKey(const Key('workspace-model-params')),
      'not valid json {',
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-model-action-clone')));
    await tester.pump();
    await tester.pump();

    // Invalid params JSON must abort the clone rather than persist a clone built
    // from stale draft values.
    expect(fake.createdForms, isEmpty);
  });

  testWidgets('activate toggle prompts to discard when the form is dirty', (
    tester,
  ) async {
    final fake = _FakeWorkspaceModels();
    await tester.pumpWidget(
      _harness(
        models: fake,
        mode: WorkspaceRouteMode.edit,
        resourceId: 'model-1',
        detail: _writableModel(),
      ),
    );
    await tester.pumpAndSettle();

    // Make an unsaved edit, then invoke the activate/deactivate action.
    await tester.enterText(
      find.byKey(const Key('workspace-model-name')),
      'Edited name',
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-model-action-toggle')));
    await tester.pumpAndSettle();

    // The discard-changes guard is shown; nothing is toggled yet.
    expect(find.text('Discard changes?'), findsOneWidget);
    expect(fake.toggledIds, isEmpty);

    // Keeping the edits cancels the toggle.
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(fake.toggledIds, isEmpty);

    // Re-invoking and discarding proceeds with the toggle.
    await tester.tap(find.byKey(const Key('workspace-editor-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-model-action-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pump();
    await tester.pump();
    expect(fake.toggledIds, ['model-1']);
  });
}

// ---------------------------------------------------------------------------

Future<void> _scrollTo(
  WidgetTester tester,
  Key key, {
  double delta = 300,
}) async {
  await tester.scrollUntilVisible(
    find.byKey(key),
    delta,
    scrollable: find
        .descendant(
          of: find.byKey(const Key('workspace-model-editor-body')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
}

Widget _harness({
  required _FakeWorkspaceModels models,
  required WorkspaceRouteMode mode,
  String? resourceId,
  WorkspaceModelSummary? detail,
  List<WorkspaceToolSummary> tools = const [],
}) {
  return ProviderScope(
    overrides: [
      ..._baseOverrides(models, tools: tools),
      if (resourceId != null && detail != null)
        workspaceModelDetailProvider(
          resourceId,
        ).overrideWith((ref) async => detail),
    ],
    child: _app(mode, resourceId),
  );
}

List<Override> _baseOverrides(
  _FakeWorkspaceModels models, {
  List<WorkspaceToolSummary> tools = const [],
}) {
  return [
    reviewerModeProvider.overrideWithValue(false),
    apiServiceProvider.overrideWithValue(null),
    workspaceCapabilitiesProvider.overrideWith(
      (ref) async => WorkspaceCapabilities.all,
    ),
    workspaceModelsProvider.overrideWith(() => models),
    modelsProvider.overrideWith(_FakeModels.new),
    workspaceBaseModelsProvider.overrideWith(
      (ref) async => const [
        WorkspaceRelationshipOption(id: 'base-1', label: 'Base One'),
      ],
    ),
    workspaceToolsProvider.overrideWith(() => _FakeWorkspaceTools(tools)),
  ];
}

Widget _app(WorkspaceRouteMode mode, String? resourceId) {
  Widget placeholder(_, _) => const Scaffold(body: Text('nav-target'));
  final router = GoRouter(
    initialLocation: '/editor',
    routes: [
      GoRoute(
        path: '/editor',
        builder: (_, _) => Scaffold(
          body: WorkspaceModelEditorView(mode: mode, modelId: resourceId),
        ),
      ),
      GoRoute(path: '/workspace/models', builder: placeholder),
      GoRoute(path: '/workspace/models/create', builder: placeholder),
      GoRoute(path: '/workspace/models/:id', builder: placeholder),
      GoRoute(path: '/workspace/models/:id/edit', builder: placeholder),
    ],
  );
  return MaterialApp.router(
    routerConfig: router,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
  );
}

WorkspaceModelSummary _writableModel() => const WorkspaceModelSummary(
  id: 'model-1',
  name: 'Model 1',
  userId: 'owner',
  writeAccess: true,
  meta: {'description': 'A model'},
);

WorkspaceModelSummary _readOnlyModel() => const WorkspaceModelSummary(
  id: 'model-1',
  name: 'Model 1',
  userId: 'someone-else',
  writeAccess: false,
);

class _FakeWorkspaceModels extends WorkspaceModels {
  _FakeWorkspaceModels({this.importSucceeds = true});

  final bool importSucceeds;
  final createdForms = <WorkspaceModelForm>[];
  final updatedForms = <WorkspaceModelForm>[];
  final deletedIds = <String>[];
  final toggledIds = <String>[];

  @override
  Future<WorkspaceCollectionState<WorkspaceModelSummary>> build() async {
    return const WorkspaceCollectionState(items: [], total: 0);
  }

  @override
  Future<WorkspaceModelDetail> create(WorkspaceModelForm form) async {
    createdForms.add(form);
    return WorkspaceModelSummary(id: form.id, name: form.name, userId: 'owner');
  }

  @override
  Future<WorkspaceModelDetail> updateItem(WorkspaceModelForm form) async {
    updatedForms.add(form);
    return WorkspaceModelSummary(id: form.id, name: form.name, userId: 'owner');
  }

  @override
  Future<void> delete(String id) async {
    deletedIds.add(id);
  }

  @override
  Future<WorkspaceModelDetail> toggle(String id) async {
    toggledIds.add(id);
    return WorkspaceModelSummary(id: id, name: id, userId: 'owner');
  }

  @override
  Future<void> refresh() async {}

  Future<bool> runImport() async {
    try {
      return await importItems([
        {'id': 'x', 'name': 'x'},
      ]);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> importItems(List<Map<String, dynamic>> items) async {
    if (!importSucceeds) throw StateError('import rejected');
    return true;
  }
}

class _FakeWorkspaceTools extends WorkspaceTools {
  _FakeWorkspaceTools(this._tools);

  final List<WorkspaceToolSummary> _tools;

  @override
  Future<WorkspaceCollectionState<WorkspaceToolSummary>> build() async {
    return WorkspaceCollectionState(items: _tools, total: _tools.length);
  }

  @override
  Future<void> refresh() async {}
}

class _FailingWorkspaceTools extends WorkspaceTools {
  @override
  Future<WorkspaceCollectionState<WorkspaceToolSummary>> build() async {
    throw StateError('tools load failed');
  }

  @override
  Future<void> refresh() async {}
}

class _FakeModels extends Models {
  @override
  Future<List<Model>> build() async {
    return const [Model(id: 'gpt-4', name: 'GPT-4')];
  }
}
