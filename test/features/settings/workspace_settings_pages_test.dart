import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit/features/settings/pages/workspace_model_settings_pages.dart';
import 'package:conduit/features/settings/pages/workspace_page_ids.dart';
import 'package:conduit/features/settings/pages/workspace_prompt_settings_pages.dart';
import 'package:conduit/features/settings/pages/workspace_settings_pages.dart';
import 'package:conduit/features/settings/settings_page_module.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:conduit/features/workspace/widgets/workspace_export_controller.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/workspace/editor/workspace_model_editor_state.dart'
    show WorkspaceModelRelationshipKind;
import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/features/workspace/providers/workspace_model_relationships.dart';
import 'package:conduit_core/features/workspace/providers/workspace_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

final AppLocalizations _l10n = lookupAppLocalizations(const Locale('en'));

const _server = ServerConfig(
  id: 'server-1',
  name: 'Home server',
  url: 'https://owui.example',
);

User _user({String role = 'user'}) =>
    User(id: 'user-1', username: 'ada', email: 'ada@example.com', role: role);

const _newModel = '$workspaceModelPagePrefix$workspaceNewKey';
const _newPrompt = '$workspacePromptPagePrefix$workspaceNewKey';
final _model1 = workspaceModelPageId('model-1');
final _prompt1 = workspacePromptPageId('prompt-1');
final _model1Key = workspaceEditorKey('model-1');
final _prompt1Key = workspaceEditorKey('prompt-1');

WorkspaceModelSummary _writableModel({bool active = true}) =>
    WorkspaceModelSummary(
      id: 'model-1',
      name: 'Orbit Model',
      userId: 'user-1',
      baseModelId: 'base-1',
      writeAccess: true,
      isActive: active,
      meta: const {'description': 'Answers about orbits'},
    );

const _readOnlyModel = WorkspaceModelSummary(
  id: 'model-1',
  name: 'Orbit Model',
  userId: 'someone-else',
  writeAccess: false,
);

WorkspacePromptSummary _prompt({
  bool writeAccess = true,
  List<String> tags = const ['travel'],
  String? versionId = 'v2',
  String content = 'List what to pack for {{destination}}.',
}) => WorkspacePromptSummary(
  id: 'prompt-1',
  command: 'packing-list',
  name: 'Packing List',
  content: content,
  userId: 'user-1',
  tags: tags,
  versionId: versionId,
  writeAccess: writeAccess,
  accessGrants: const [
    WorkspaceAccessGrant(
      principalType: WorkspacePrincipalType.group,
      principalId: 'group-1',
      permission: WorkspaceGrantPermission.read,
    ),
  ],
);

final class _Models extends WorkspaceModels {
  _Models([this.items = const []]);

  final List<WorkspaceModelSummary> items;
  final created = <WorkspaceModelForm>[];
  final updated = <WorkspaceModelForm>[];
  final deleted = <String>[];
  final toggled = <String>[];
  final accessSaves = <List<WorkspaceAccessGrantInput>>[];
  final queries = <String>[];
  final imported = <Map<String, dynamic>>[];
  bool failAccess = false;
  Completer<void>? saveGate;

  @override
  Future<WorkspaceCollectionState<WorkspaceModelSummary>> build() async =>
      WorkspaceCollectionState(items: items, total: items.length);

  /// The list read again, as after a change made elsewhere.
  void reread() =>
      state = AsyncData(WorkspaceCollectionState(items: items, total: 1));

  @override
  Future<WorkspaceModelDetail> create(WorkspaceModelForm form) async {
    created.add(form);
    await saveGate?.future;
    return WorkspaceModelSummary(id: form.id, name: form.name, userId: 'u');
  }

  @override
  Future<WorkspaceModelDetail> updateItem(WorkspaceModelForm form) async {
    updated.add(form);
    await saveGate?.future;
    return WorkspaceModelSummary(id: form.id, name: form.name, userId: 'u');
  }

  @override
  Future<WorkspaceModelDetail> updateAccess(
    String id,
    String name,
    List<WorkspaceAccessGrantInput> grants,
  ) async {
    accessSaves.add(grants);
    if (failAccess) throw StateError('refused');
    return WorkspaceModelSummary(id: id, name: name, userId: 'u');
  }

  @override
  Future<WorkspaceModelDetail> toggle(String id) async {
    toggled.add(id);
    return WorkspaceModelSummary(id: id, name: id, userId: 'u');
  }

  @override
  Future<void> delete(String id) async => deleted.add(id);

  @override
  Future<List<WorkspaceModelDetail>> exportAll() async => items;

  @override
  Future<bool> importItems(List<Map<String, dynamic>> items) async {
    imported.addAll(items);
    return true;
  }

  @override
  Future<void> setQuery(String query) async => queries.add(query);

  @override
  Future<void> refresh() async {}
}

final class _Prompts extends WorkspacePrompts {
  final List<WorkspacePromptSummary> items = const [];
  final created = <WorkspacePromptForm>[];
  final updated = <WorkspacePromptForm>[];
  final toggled = <String>[];
  final deleted = <String>[];
  final liveSet = <String>[];
  Object? createError;
  List<WorkspacePromptHistoryEntry> versions = const [];
  Object? liveError;

  @override
  Future<WorkspaceCollectionState<WorkspacePromptSummary>> build() async =>
      WorkspaceCollectionState(items: items, total: items.length);

  @override
  Future<WorkspacePromptDetail> create(WorkspacePromptForm form) async {
    final error = createError;
    if (error != null) throw error;
    created.add(form);
    return WorkspacePromptSummary(
      id: 'new',
      command: form.command,
      name: form.name,
      content: form.content,
      userId: 'u',
    );
  }

  @override
  Future<WorkspacePromptDetail> updateItem(
    String id,
    WorkspacePromptForm form,
  ) async {
    updated.add(form);
    return _prompt();
  }

  @override
  Future<WorkspacePromptDetail> toggle(String id) async {
    toggled.add(id);
    return _prompt();
  }

  @override
  Future<WorkspacePromptDetail> updateMetadata(
    String id, {
    required String name,
    required String command,
    List<String> tags = const [],
  }) async => _prompt();

  @override
  Future<void> delete(String id) async => deleted.add(id);

  @override
  Future<WorkspacePromptDetail> setProductionVersion(
    String id,
    String versionId,
  ) async {
    liveSet.add(versionId);
    final error = liveError;
    if (error != null) throw error;
    final live = versions.where((entry) => entry.id == versionId).firstOrNull;
    return _prompt(
      versionId: versionId,
      content: live?.snapshot['content'] as String? ?? _prompt().content,
    );
  }

  final diffs = <(String, String)>[];
  Object? diffError;

  @override
  Future<Map<String, dynamic>> historyDiff(
    String id, {
    required String fromId,
    required String toId,
  }) async {
    diffs.add((fromId, toId));
    final error = diffError;
    if (error != null) throw error;
    return {
      'content_diff': [
        '--- v$fromId',
        '+++ v$toId',
        '@@ -1,2 +1,2 @@',
        ' Packing list',
        '-Pack a towel.',
        '+Pack a hat.',
      ],
      'name_changed': true,
    };
  }

  @override
  Future<List<WorkspacePromptHistoryEntry>> history(
    String id, {
    int page = 0,
  }) async => versions
      .skip(page * workspacePromptHistoryPageSize)
      .take(workspacePromptHistoryPageSize)
      .toList();

  @override
  Future<void> deleteHistoryEntry(String id, String historyId) async {
    versions = [
      for (final entry in versions)
        if (entry.id != historyId) entry,
    ];
  }

  @override
  Future<void> refresh() async {}
}

final class _Tools extends WorkspaceTools {
  @override
  Future<WorkspaceCollectionState<WorkspaceToolSummary>> build() async =>
      const WorkspaceCollectionState(
        items: [
          WorkspaceToolSummary(id: 'tool-1', name: 'Star Chart', userId: 'u'),
        ],
        total: 1,
      );
}

/// Who is signed in, when a test switches to another account.
final class _SignedIn extends Notifier<User?> {
  @override
  User? build() => null;

  void use(User user) => state = user;
}

final _signedInProvider = NotifierProvider<_SignedIn, User?>(_SignedIn.new);

/// Two knowledge bases, served a page at a time.
final class _Knowledge extends WorkspaceKnowledge {
  static const _all = [
    WorkspaceKnowledgeSummary(id: 'kb-1', name: 'Star Atlas', userId: 'u'),
    WorkspaceKnowledgeSummary(id: 'kb-2', name: 'Moon Notes', userId: 'u'),
  ];

  @override
  Future<WorkspaceCollectionState<WorkspaceKnowledgeSummary>> build() async =>
      WorkspaceCollectionState(items: _all.take(1).toList(), total: 2);

  @override
  Future<void> loadMore() async {
    final current = state.requireValue;
    state = AsyncData(current.copyWith(page: current.page + 1, items: _all));
  }
}

/// Settings as the pages see it: each question is answered with [answer].
final class _Surface extends SettingsSurface {
  _Surface(super.ref);

  final asked = <String>[];
  String? answer;

  /// Holds each page update, when a test sets it.
  Completer<void>? gate;

  @override
  Future<bool> applyDetail(
    NativeSheetDetailConfig detail, {
    List<NativeSheetDetailConfig> detailSheets = const [],
  }) async {
    final applied = await super.applyDetail(detail, detailSheets: detailSheets);
    await gate?.future;
    return applied;
  }

  @override
  Future<String?> ask({
    required String title,
    String? message,
    required List<NativeSheetAlertAction> actions,
  }) async {
    asked.add(title);
    return answer;
  }
}

final class _Export extends WorkspaceExportController {
  final shared = <Object?>[];

  @override
  Future<ShareResult> shareJson({
    required String filename,
    required Object? data,
    String? subject,
    Rect? sharePositionOrigin,
  }) async {
    shared.add(data);
    return const ShareResult('ok', ShareResultStatus.success);
  }
}

final class _Rig {
  _Rig(this.tester, this.container, this.surface, this.export);

  final WidgetTester tester;
  final ProviderContainer container;
  final _Surface surface;
  final _Export export;

  T module<T extends SettingsPageModule>() =>
      container.read(settingsPageModulesProvider).whereType<T>().single;

  SettingsPageModule _owner(String id) => container
      .read(settingsPageModulesProvider)
      .firstWhere((module) => module.ownsPage(id));

  NativeSheetDetailConfig page(String id) =>
      container.read(settingsPagesProvider)[id]!;

  List<NativeSheetItemConfig> rows(String id) {
    final detail = page(id);
    return [...detail.items, for (final s in detail.sections) ...s.items];
  }

  NativeSheetItemConfig? row(String pageId, String rowId) =>
      rows(pageId).where((row) => row.id == rowId).firstOrNull;

  Iterable<String> titles(String pageId) => rows(pageId).map((r) => r.title);

  List<String> get closed => [
    for (final MapEntry(:key, :value)
        in container.read(settingsPagesProvider).closeRequests.entries)
      for (var i = 0; i < value; i++) key,
  ];

  Future<void> open(String id) async {
    if (!container.read(settingsPagesProvider).contains(id)) {
      container.read(settingsPagesProvider.notifier).register([
        buildNativeLoadingDetail(l10n: _l10n, id: id, title: ''),
      ]);
    }
    await settle(_owner(id).hydrate(id, _l10n));
  }

  /// A row change, handed to the modules as the controller does.
  Future<void> change(
    String id, [
    Object? value = true,
    AppLocalizations? l10n,
  ]) => settle(() async {
    for (final module in container.read(settingsPageModulesProvider)) {
      if (await module.handleChange(id, value, l10n ?? _l10n)) return;
    }
  }());

  void leave(String id) => _owner(id).pageLeft(id);

  Future<void> settle(Future<Object?> work) async {
    var done = false;
    unawaited(work.whenComplete(() => done = true));
    for (var round = 0; round < 60 && !done; round++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    for (var round = 0; round < 3; round++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await work;
  }
}

String _modelRow(String field, [String? key, String? extra]) =>
    workspaceRowId('model-$field', key ?? workspaceNewKey, extra);

String _promptRow(String field, [String? key, String? extra]) =>
    workspaceRowId('prompt-$field', key ?? workspaceNewKey, extra);

void main() {
  late ApiService api;

  setUp(() {
    api = ApiService(
      serverConfig: _server,
      workerManager: WorkerManager(),
      authToken: 'token-a',
    );
  });

  Future<_Rig> pump(
    WidgetTester tester, {
    _Models? models,
    _Prompts? prompts,
    WorkspaceCapabilities capabilities = WorkspaceCapabilities.all,
    Object? capabilitiesError,
    bool reviewer = false,
    String role = 'user',
    Map<String, WorkspaceModelSummary> modelDetails = const {},
    Map<String, WorkspacePromptSummary> promptDetails = const {},
    Future<List<WorkspaceToolSummary>> Function()? tools,
    String? importFile,
    Future<String?> Function()? picker,
    Future<List<WorkspaceRelationshipOption>> Function()? baseModels,
  }) async {
    late final _Surface surface;
    final export = _Export();
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        reviewerModeProvider.overrideWithValue(reviewer),
        currentUserProvider2.overrideWith(
          (ref) => ref.watch(_signedInProvider) ?? _user(role: role),
        ),
        apiServiceProvider.overrideWithValue(api),
        authTokenProvider3.overrideWithValue('token-a'),
        activeServerProvider.overrideWith((ref) async => _server),
        workspaceCapabilitiesProvider.overrideWith(
          (ref) async => capabilitiesError == null
              ? capabilities
              : throw capabilitiesError,
        ),
        workspaceModelsProvider.overrideWith(() => models ?? _Models()),
        workspacePromptsProvider.overrideWith(() => prompts ?? _Prompts()),
        workspaceToolsProvider.overrideWith(_Tools.new),
        workspaceKnowledgeProvider.overrideWith(_Knowledge.new),
        workspaceBaseModelsProvider.overrideWith(
          (ref) =>
              baseModels?.call() ??
              Future.value(const [
                WorkspaceRelationshipOption(id: 'base-1', label: 'Base One'),
              ]),
        ),
        for (final entry in modelDetails.entries)
          workspaceModelDetailProvider(entry.key)
              .overrideWith((ref) async => entry.value),
        for (final entry in promptDetails.entries)
          workspacePromptDetailProvider(entry.key)
              .overrideWith((ref) async => entry.value),
        settingsSurfaceProvider.overrideWith((ref) => surface = _Surface(ref)),
        workspaceExportControllerProvider.overrideWithValue(export),
        workspaceImportFilePickerProvider.overrideWithValue(
          picker ?? () async => importFile,
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(settingsSurfaceProvider);
    // Capabilities and the session load before any page appears.
    container.listen(workspaceCapabilitiesProvider, (_, _) {});
    container.listen(activeServerProvider, (_, _) {});
    final rig = _Rig(tester, container, surface, export);
    await rig.settle(Future<void>.value());
    return rig;
  }

  group('the Workspace page', () {
    testWidgets('lists the sections the account may manage', (tester) async {
      final rig = await pump(tester);
      await rig.open(workspaceHubPageId);

      check(rig.titles(workspaceHubPageId)).deepEquals([
        _l10n.workspaceModels,
        _l10n.workspaceKnowledge,
        _l10n.workspacePrompts,
        _l10n.workspaceTools,
        _l10n.workspaceSkills,
      ]);
      // Models and Prompts are pages of Settings's own; the others open the
      // Workspace's pages over the app.
      check(
        rig.row(
          workspaceHubPageId,
          workspaceSectionPageId(WorkspaceSection.models),
        ),
      ).isNotNull();
      check(
        rig.row(
          workspaceHubPageId,
          workspaceRowId('open', 'hub', WorkspaceSection.tools.name),
        ),
      ).isNotNull();
      check(
        rig.container
            .read(settingsPagesProvider)
            .contains(workspaceSectionPageId(WorkspaceSection.prompts)),
      ).isTrue();
    });

    testWidgets('says why when it cannot be shown', (tester) async {
      final denied = await pump(tester, reviewer: true);
      await denied.open(workspaceHubPageId);
      check(denied.titles(workspaceHubPageId))
          .deepEquals([_l10n.workspaceDenied]);
    });

    testWidgets('offers Retry when the capabilities cannot be read', (
      tester,
    ) async {
      final rig = await pump(tester, capabilitiesError: StateError('offline'));
      await rig.open(workspaceHubPageId);
      check(rig.row(workspaceHubPageId, workspaceRowId('gate-retry', 'hub')))
          .isNotNull();
    });
  });

  group("a section's list", () {
    final modelsPage = workspaceSectionPageId(WorkspaceSection.models);

    testWidgets('shows the models, a search and what the account may do', (
      tester,
    ) async {
      const readOnly = WorkspaceModelSummary(
        id: 'model-2',
        name: 'Tide Model',
        userId: 'someone-else',
        writeAccess: false,
      );
      final models = _Models([_writableModel(), readOnly]);
      final rig = await pump(tester, models: models);
      await rig.open(modelsPage);

      // Only the account's own model may be switched off or deleted.
      Iterable<String> actions(String id) => rig
          .rows(modelsPage)
          .singleWhere((r) => r.id == workspaceModelPageId(id))
          .rowActions
          .map((action) => action.id);
      check(actions('model-1'))
          .contains(workspaceRowId('list-delete', 'models', 'model-1'));
      check(
        actions('model-2').where(
          (id) => id.contains('list-delete') || id.contains('list-active'),
        ),
      ).isEmpty();
      final row = rig.rows(modelsPage).firstWhere((r) => r.id == _model1);
      check(row.title).equals('Orbit Model');
      check(row.subtitle!).contains(_l10n.activeStatus);
      check(rig.page(modelsPage).search!.placeholder)
          .equals(_l10n.workspaceSearchHint);
      check(rig.titles(modelsPage)).contains(_l10n.workspaceCreate);
      check(rig.titles(modelsPage)).contains(_l10n.workspaceModelImport);
      check(rig.titles(modelsPage)).contains(_l10n.workspaceModelExportAll);

      await rig.change(workspaceRowId('list-search', 'models'), 'orbit');
      check(models.queries).deepEquals(['orbit']);
    });

    testWidgets('a row menu deletes or switches off its model', (tester) async {
      final models = _Models([_writableModel()]);
      final rig = await pump(tester, models: models);
      await rig.open(modelsPage);

      await rig.change(workspaceRowId('list-active', 'models', 'model-1'));
      await rig.change(workspaceRowId('list-delete', 'models', 'model-1'));

      check(models.toggled).deepEquals(['model-1']);
      check(models.deleted).deepEquals(['model-1']);
    });

    testWidgets('hides import without the import capability', (tester) async {
      final rig = await pump(
        tester,
        capabilities: const WorkspaceCapabilities(
          prompts: WorkspaceSectionCapabilities(manage: true),
        ),
      );
      final promptsPage = workspaceSectionPageId(WorkspaceSection.prompts);
      await rig.open(promptsPage);

      check(rig.titles(promptsPage))
          .not((it) => it.contains(_l10n.workspacePromptImport));
      check(rig.titles(promptsPage)).contains(_l10n.workspaceCreate);
    });

    testWidgets('imports a picked file and says how it went', (tester) async {
      final models = _Models();
      final rig = await pump(
        tester,
        models: models,
        importFile: jsonEncode([
          {'id': 'imported-1', 'name': 'Imported One'},
        ]),
      );
      await rig.open(modelsPage);

      await rig.change(workspaceRowId('list-import', 'models'));

      check(models.imported.single['id']).equals('imported-1');
      check(rig.page(modelsPage).announcement)
          .equals(_l10n.workspaceImportSummary(1, 1));
    });

    testWidgets('an editor open over the list keeps its rows as the list '
        'is drawn again', (tester) async {
      final models = _Models([_writableModel()]);
      final rig = await pump(
        tester,
        models: models,
        modelDetails: {'model-1': _writableModel()},
      );
      await rig.open(modelsPage);
      await rig.open(_model1);
      check(rig.page(_model1).confirmActionId).isNotNull();

      // The list hears of a change and is drawn again, under the editor.
      models.reread();
      await rig.settle(Future<void>.value());

      check(rig.page(_model1).confirmActionId).isNotNull();
      check(rig.row(_model1, _modelRow('name', _model1Key))).isNotNull();
    });

    test('an empty list that could not be read again offers Retry', () {
      final page = buildWorkspaceListPage(
        _l10n,
        const WorkspaceListState(
          section: WorkspaceSection.models,
          items: [],
          loadFailed: true,
        ),
      );
      final ids = [
        for (final section in page.sections)
          for (final item in section.items) item.id,
      ];

      check(ids).contains(workspaceRowId('list-retry', 'models'));
      check(ids).not((it) => it.contains('$modelsPage-empty'));
    });

    testWidgets('a file chosen as another account signs in is not imported', (
      tester,
    ) async {
      final models = _Models();
      late final _Rig rig;
      rig = await pump(
        tester,
        models: models,
        picker: () async {
          rig.container
              .read(_signedInProvider.notifier)
              .use(
                const User(
                  id: 'user-2',
                  username: 'grace',
                  email: 'grace@example.com',
                  role: 'user',
                ),
              );
          return jsonEncode([
            {'id': 'imported-1', 'name': 'Imported One'},
          ]);
        },
      );
      await rig.open(modelsPage);

      await rig.change(workspaceRowId('list-import', 'models'));

      check(models.imported).isEmpty();
    });

    testWidgets('a file that is not JSON imports nothing and says so', (
      tester,
    ) async {
      final models = _Models();
      final rig = await pump(tester, models: models, importFile: 'not json');
      await rig.open(modelsPage);

      await rig.change(workspaceRowId('list-import', 'models'));

      check(models.imported).isEmpty();
      check(rig.page(modelsPage).announcement)
          .equals(_l10n.workspaceImportInvalidJson);
    });

    testWidgets('exports every model through the share sheet', (tester) async {
      final rig = await pump(tester, models: _Models([_writableModel()]));
      await rig.open(modelsPage);

      await rig.change(workspaceRowId('list-export', 'models'));

      final shared = rig.export.shared.single! as List;
      check((shared.single as Map)['id']).equals('model-1');
      check((shared.single as Map)['name']).equals('Orbit Model');
    });
  });

  group("a model's editor", () {
    testWidgets('creates a model from its fields, then goes back', (
      tester,
    ) async {
      final models = _Models();
      final rig = await pump(tester, models: models);
      await rig.open(_newModel);

      await rig.change(_modelRow('id'), 'my-model');
      await rig.change(_modelRow('name'), 'My Model');
      await rig.change(_modelRow('base'), 'base-1');
      check(rig.page(_newModel).edited).isTrue();
      await rig.change(_modelRow('save'));

      check(models.created.single.id).equals('my-model');
      check(models.created.single.name).equals('My Model');
      check(models.created.single.baseModelId).equals('base-1');
      check(rig.closed).deepEquals([_newModel]);
    });

    testWidgets('saves nothing while a required field is empty', (
      tester,
    ) async {
      final models = _Models();
      final rig = await pump(tester, models: models, role: 'admin');
      await rig.open(_newModel);

      await rig.change(_modelRow('save'));

      check(models.created).isEmpty();
      check(rig.page(_newModel).announcement)
          .equals(_l10n.workspaceModelIdRequired);
    });

    testWidgets('asks a non-admin for a base model, with no None to pick', (
      tester,
    ) async {
      final models = _Models();
      final rig = await pump(tester, models: models);
      await rig.open(_newModel);

      await rig.change(_modelRow('id'), 'my-model');
      await rig.change(_modelRow('name'), 'My Model');
      await rig.change(_modelRow('save'));

      check(models.created).isEmpty();
      check(rig.page(_newModel).announcement)
          .equals(_l10n.workspaceModelBaseModelRequired);
      final base = rig.row(_newModel, _modelRow('base'))!;
      check(base.options.map((o) => o.label))
          .not((it) => it.contains(_l10n.workspaceModelBaseModelNone));
    });

    testWidgets('an edit saves the model in place', (tester) async {
      final models = _Models();
      final rig = await pump(
        tester,
        models: models,
        modelDetails: {'model-1': _writableModel()},
      );
      await rig.open(_model1);

      await rig.change(_modelRow('description', _model1Key), 'Charts stars');
      await rig.change(_modelRow('save', _model1Key));

      check(models.updated.single.id).equals('model-1');
      check(models.updated.single.meta['description']).equals('Charts stars');
      check(rig.closed).deepEquals([_model1]);
    });

    testWidgets('a model the account may only view reads without fields', (
      tester,
    ) async {
      final rig = await pump(tester, modelDetails: {'model-1': _readOnlyModel});
      await rig.open(_model1);

      final page = rig.page(_model1);
      check(page.confirmActionId).isNull();
      check(rig.titles(_model1)).contains(_l10n.workspaceReadOnlyExplanation);
      check(rig.row(_model1, _modelRow('name', _model1Key))!.kind)
          .equals(NativeSheetItemKind.readOnlyText);
      check(rig.titles(_model1))
          .not((it) => it.contains(_l10n.workspaceModelDelete));
    });

    testWidgets('shows its loading row until the model is read', (
      tester,
    ) async {
      final rig = await pump(
        tester,
        modelDetails: {'model-1': _writableModel()},
      );
      rig.container.read(settingsPagesProvider.notifier).register([
        buildNativeLoadingDetail(l10n: _l10n, id: _model1, title: ''),
      ]);
      final opening = rig.module<WorkspaceModelSettingsPages>().hydrate(
        _model1,
        _l10n,
      );
      check(rig.titles(_model1)).deepEquals([_l10n.loadingShort]);
      await rig.settle(opening);
      check(rig.page(_model1).title).equals('Orbit Model');
    });

    testWidgets('deletes the model, then goes back', (tester) async {
      final models = _Models();
      final rig = await pump(
        tester,
        models: models,
        modelDetails: {'model-1': _writableModel()},
      );
      await rig.open(_model1);

      await rig.change(_modelRow('delete', _model1Key));

      check(models.deleted).deepEquals(['model-1']);
      check(rig.closed).deepEquals([_model1]);
    });

    testWidgets('switching it off asks first when it holds changes', (
      tester,
    ) async {
      final models = _Models();
      final rig = await pump(
        tester,
        models: models,
        modelDetails: {'model-1': _writableModel()},
      );
      await rig.open(_model1);
      await rig.change(_modelRow('name', _model1Key), 'Renamed');

      rig.surface.answer = 'keep';
      await rig.change(_modelRow('active', _model1Key));
      check(models.toggled).isEmpty();
      check(rig.surface.asked).deepEquals([_l10n.workspaceEditorDiscardTitle]);

      rig.surface.answer = 'discard';
      await rig.change(_modelRow('active', _model1Key));
      check(models.toggled).deepEquals(['model-1']);
    });

    testWidgets('a duplicate is not made from parameters that are not JSON', (
      tester,
    ) async {
      final models = _Models();
      final rig = await pump(
        tester,
        models: models,
        modelDetails: {'model-1': _writableModel()},
      );
      await rig.open(_model1);

      await rig.change(_modelRow('params', _model1Key), '{not json');
      await rig.change(_modelRow('clone', _model1Key));

      check(models.created).isEmpty();
      check(rig.page(_model1).announcement)
          .equals(_l10n.workspaceModelInvalidJson);
    });

    testWidgets('tools chosen on their page are saved with the model', (
      tester,
    ) async {
      final models = _Models();
      final rig = await pump(
        tester,
        models: models,
        modelDetails: {'model-1': _writableModel()},
      );
      await rig.open(_model1);
      final toolsPage = workspaceModelRelationshipPageId(
        WorkspaceModelRelationshipKind.tools,
        _model1Key,
      );
      await rig.open(toolsPage);

      await rig.change(_modelRow('relationship', _model1Key, 'tools|tool-1'));

      check(
        rig
            .row(
              toolsPage,
              _modelRow('relationship', _model1Key, 'tools|tool-1'),
            )!
            .checked,
      ).isTrue();
      // The editor under it learns of the change.
      check(rig.page(_model1).edited).isTrue();
      await rig.change(_modelRow('save', _model1Key));
      check(models.updated.single.meta['toolIds'] as List)
          .deepEquals(['tool-1']);
    });

    testWidgets('base models that could not be read offer Retry', (
      tester,
    ) async {
      var offline = true;
      final rig = await pump(
        tester,
        modelDetails: {'model-1': _writableModel()},
        baseModels: () async => offline
            ? throw StateError('offline')
            : const [WorkspaceRelationshipOption(id: 'base-1', label: 'One')],
      );
      await rig.open(_model1);
      final retry = _modelRow('base-retry', _model1Key);
      check(rig.row(_model1, retry)).isNotNull();
      check(rig.row(_model1, _modelRow('base', _model1Key))!.disabled).isTrue();

      offline = false;
      await rig.change(retry);

      check(rig.row(_model1, retry)).isNull();
      check(rig.row(_model1, _modelRow('base', _model1Key))!.disabled)
          .isFalse();
    });

    testWidgets('knowledge past the first page can be chosen', (tester) async {
      final rig = await pump(
        tester,
        modelDetails: {'model-1': _writableModel()},
      );
      await rig.open(_model1);
      final page = workspaceModelRelationshipPageId(
        WorkspaceModelRelationshipKind.knowledge,
        _model1Key,
      );
      await rig.open(page);

      check(
        rig.row(page, _modelRow('relationship', _model1Key, 'knowledge|kb-2')),
      ).isNotNull();
    });

    testWidgets('a capability switched on Advanced marks the editor edited', (
      tester,
    ) async {
      final rig = await pump(
        tester,
        modelDetails: {'model-1': _writableModel()},
      );
      await rig.open(_model1);
      await rig.open('$workspaceModelAdvancedPagePrefix$_model1Key');
      check(rig.page(_model1).edited).isFalse();

      await rig.change(_modelRow('capability', _model1Key, 'vision'), true);

      check(rig.page(_model1).edited).isTrue();
    });

    testWidgets('capabilities read by name, and a new one by its key', (
      tester,
    ) async {
      check(workspaceModelCapabilityLabel(_l10n, 'file_upload'))
          .equals(_l10n.workspaceModelCapabilityFileUpload);
      check(workspaceModelCapabilityLabel(_l10n, 'web_search'))
          .equals(_l10n.webSearch);
      check(workspaceModelCapabilityLabel(_l10n, 'time_travel'))
          .equals('time_travel');
      final rig = await pump(
        tester,
        modelDetails: {'model-1': _writableModel()},
      );
      await rig.open(_model1);
      final advanced = '$workspaceModelAdvancedPagePrefix$_model1Key';
      await rig.open(advanced);
      check(rig.titles(advanced))
          .contains(_l10n.workspaceModelCapabilityVision);
    });

    testWidgets('a save that lands after the editor was left closes nothing', (
      tester,
    ) async {
      final models = _Models()..saveGate = Completer<void>();
      final rig = await pump(
        tester,
        models: models,
        modelDetails: {'model-1': _writableModel()},
      );
      await rig.open(_model1);
      final saving = rig.module<WorkspaceModelSettingsPages>().handleChange(
        _modelRow('save', _model1Key),
        true,
        _l10n,
      );
      await rig.settle(Future<void>.value());

      rig.leave(_model1);
      models.saveGate!.complete();
      await rig.settle(saving);

      check(rig.closed).isEmpty();
    });

    group('its access', () {
      final access = workspaceAccessPageId(WorkspaceSection.models, _model1Key);
      final newAccess = workspaceAccessPageId(
        WorkspaceSection.models,
        workspaceNewKey,
      );
      final everyone = workspaceRowId(
        'access-general',
        '${WorkspaceSection.models.name}|$_model1Key',
      );

      testWidgets('of a saved model saves on Done, and stays with why when '
          'that fails', (tester) async {
        final models = _Models()..failAccess = true;
        final rig = await pump(
          tester,
          models: models,
          modelDetails: {'model-1': _writableModel()},
        );
        await rig.open(_model1);
        await rig.open(access);

        await rig.change(everyone, 'server');
        check(rig.page(access).edited).isTrue();
        await rig.change(
          workspaceRowId(
            'access-done',
            '${WorkspaceSection.models.name}|$_model1Key',
          ),
        );
        check(models.accessSaves).length.equals(1);
        check(rig.page(access).announcement)
            .equals(_l10n.workspaceModelSaveFailed);
        check(rig.closed).isEmpty();

        models.failAccess = false;
        await rig.change(
          workspaceRowId(
            'access-done',
            '${WorkspaceSection.models.name}|$_model1Key',
          ),
        );
        check(models.accessSaves).length.equals(2);
        check(rig.closed).deepEquals([access]);
      });

      testWidgets('its Add rows open pages of their own', (tester) async {
        final rig = await pump(
          tester,
          modelDetails: {'model-1': _writableModel()},
        );
        await rig.open(_model1);
        await rig.open(access);

        final adds = rig
            .rows(access)
            .where((row) => row.id.startsWith(workspaceAccessAddPagePrefix));
        check(adds).isNotEmpty();
        for (final add in adds) {
          // Known, so a tap pushes the page rather than sending the row.
          check(rig.container.read(settingsPagesProvider).contains(add.id))
              .isTrue();
        }
      });

      testWidgets('of a new model is kept for its first save', (tester) async {
        final models = _Models();
        final rig = await pump(tester, models: models);
        await rig.open(_newModel);
        await rig.open(newAccess);

        await rig.change(
          workspaceRowId(
            'access-general',
            '${WorkspaceSection.models.name}|$workspaceNewKey',
          ),
          'server',
        );
        await rig.change(
          workspaceRowId(
            'access-done',
            '${WorkspaceSection.models.name}|$workspaceNewKey',
          ),
        );
        check(models.accessSaves).isEmpty();

        await rig.change(_modelRow('id'), 'my-model');
        await rig.change(_modelRow('name'), 'My Model');
        await rig.change(_modelRow('base'), 'base-1');
        await rig.change(_modelRow('save'));
        check(models.created.single.accessGrants.map((g) => g.principalId))
            .contains('*');
      });
    });
  });

  group("a prompt's editor", () {
    testWidgets('creates a prompt with the command its name makes', (
      tester,
    ) async {
      final prompts = _Prompts();
      final rig = await pump(tester, prompts: prompts);
      await rig.open(_newPrompt);

      await rig.change(_promptRow('name'), 'Weekend Plans');
      check(rig.row(_newPrompt, _promptRow('command'))!.value)
          .equals('weekend-plans');
      await rig.change(_promptRow('content'), 'Plan a weekend in {{city}}.');
      await rig.change(_promptRow('save'));

      check(prompts.created.single.command).equals('weekend-plans');
      check(prompts.created.single.name).equals('Weekend Plans');
      check(rig.closed).deepEquals([_newPrompt]);
    });

    testWidgets('a typed command loses its slash', (tester) async {
      final prompts = _Prompts();
      final rig = await pump(tester, prompts: prompts);
      await rig.open(_newPrompt);

      await rig.change(_promptRow('name'), 'Weekend Plans');
      await rig.change(_promptRow('command'), '/weekend');
      await rig.change(_promptRow('content'), 'Plan a weekend.');
      await rig.change(_promptRow('save'));

      check(prompts.created.single.command).equals('weekend');
    });

    testWidgets('a command that is not one, or no content, saves nothing', (
      tester,
    ) async {
      final prompts = _Prompts();
      final rig = await pump(tester, prompts: prompts);
      await rig.open(_newPrompt);

      await rig.change(_promptRow('name'), 'Weekend Plans');
      await rig.change(_promptRow('command'), 'not a command!');
      await rig.change(_promptRow('content'), 'Plan a weekend.');
      await rig.change(_promptRow('save'));
      check(rig.page(_newPrompt).announcement)
          .equals(_l10n.workspacePromptCommandInvalid);

      await rig.change(_promptRow('command'), 'weekend');
      await rig.change(_promptRow('content'), '  ');
      await rig.change(_promptRow('save'));
      check(rig.page(_newPrompt).announcement)
          .equals(_l10n.workspacePromptContentRequired);
      check(prompts.created).isEmpty();
    });

    testWidgets('a command already in use says so', (tester) async {
      final prompts = _Prompts()
        ..createError = DioException(
          requestOptions: RequestOptions(path: '/api/v1/prompts/create'),
          response: Response(
            requestOptions: RequestOptions(path: '/api/v1/prompts/create'),
            statusCode: 400,
            data: const {'detail': 'Command already exists'},
          ),
        );
      final rig = await pump(tester, prompts: prompts);
      await rig.open(_newPrompt);

      await rig.change(_promptRow('name'), 'Weekend Plans');
      await rig.change(_promptRow('content'), 'Plan a weekend.');
      await rig.change(_promptRow('save'));

      check(rig.page(_newPrompt).announcement)
          .equals(_l10n.workspacePromptCommandTaken);
      check(rig.closed).isEmpty();
    });

    testWidgets('an edit saves its version message and live choice', (
      tester,
    ) async {
      final prompts = _Prompts();
      final rig = await pump(
        tester,
        prompts: prompts,
        promptDetails: {'prompt-1': _prompt()},
      );
      await rig.open(_prompt1);

      await rig.change(_promptRow('content', _prompt1Key), 'Pack light.');
      await rig.change(_promptRow('commit', _prompt1Key), 'Shorter');
      await rig.change(_promptRow('production', _prompt1Key), false);
      await rig.change(_promptRow('save', _prompt1Key));

      final form = prompts.updated.single;
      check(form.content).equals('Pack light.');
      check(form.commitMessage).equals('Shorter');
      check(form.isProduction).isFalse();
      check(form.command).equals('packing-list');
    });

    testWidgets('a prompt the account may only view offers no changes', (
      tester,
    ) async {
      final rig = await pump(
        tester,
        promptDetails: {'prompt-1': _prompt(writeAccess: false)},
        prompts: _Prompts()
          ..versions = const [
            WorkspacePromptHistoryEntry(
              id: 'v1',
              promptId: 'prompt-1',
              snapshot: {'content': 'Old'},
              userId: 'u',
              createdAt: 1,
            ),
          ],
      );
      await rig.open(_prompt1);
      check(rig.page(_prompt1).confirmActionId).isNull();
      check(rig.titles(_prompt1))
          .not((it) => it.contains(_l10n.workspacePromptDelete));

      await rig.open('$workspacePromptHistoryPagePrefix$_prompt1Key');
      final version = workspacePromptVersionPageId(_prompt1Key, 'v1');
      await rig.open(version);
      check(rig.titles(version))
          .not((it) => it.contains(_l10n.workspacePromptHistoryRestore));
      check(rig.titles(version))
          .not((it) => it.contains(_l10n.workspacePromptHistorySetProduction));
    });

    testWidgets('a save is not sent once another account signed in while '
        'the editor was drawn busy', (tester) async {
      final prompts = _Prompts();
      final rig = await pump(
        tester,
        prompts: prompts,
        promptDetails: {'prompt-1': _prompt()},
      );
      await rig.open(_prompt1);
      await rig.change(_promptRow('content', _prompt1Key), 'Pack a scarf.');
      final gate = rig.surface.gate = Completer<void>();

      final saving = rig.module<WorkspacePromptSettingsPages>().handleChange(
        _promptRow('save', _prompt1Key),
        true,
        _l10n,
      );
      await tester.pump(const Duration(milliseconds: 20));
      rig.container
          .read(_signedInProvider.notifier)
          .use(
            const User(
              id: 'user-2',
              username: 'grace',
              email: 'grace@example.com',
              role: 'user',
            ),
          );
      await tester.pump(const Duration(milliseconds: 20));
      rig.surface.gate = null;
      gate.complete();
      await rig.settle(saving);

      check(prompts.updated).isEmpty();
    });

    testWidgets('a version left not to be made live keeps the editor edited '
        'after Update Details', (tester) async {
      final rig = await pump(tester, promptDetails: {'prompt-1': _prompt()});
      await rig.open(_prompt1);

      await rig.change(_promptRow('production', _prompt1Key), false);
      await rig.change(_promptRow('name', _prompt1Key), 'Trip Packing');
      await rig.change(_promptRow('details', _prompt1Key));

      check(rig.page(_prompt1).announcement)
          .equals(_l10n.workspacePromptDetailsSaved);
      check(rig.page(_prompt1).edited).isTrue();
    });

    testWidgets('a duplicate keeps none of the access list', (tester) async {
      final prompts = _Prompts();
      final rig = await pump(
        tester,
        prompts: prompts,
        promptDetails: {'prompt-1': _prompt()},
      );
      await rig.open(_prompt1);

      await rig.change(_promptRow('clone', _prompt1Key));

      check(prompts.created.single.accessGrants).isEmpty();
      check(prompts.created.single.name).contains('Packing List');
    });

    for (final (locale, expected) in [
      ('en', 'packing-list-copy'),
      ('de', 'packing-list-kopie'),
      // A suffix that makes no command of its own.
      ('zh', 'packing-list-copy'),
    ]) {
      testWidgets('a duplicate made in $locale is named $expected', (
        tester,
      ) async {
        final prompts = _Prompts();
        final rig = await pump(
          tester,
          prompts: prompts,
          promptDetails: {'prompt-1': _prompt()},
        );
        await rig.open(_prompt1);

        await rig.change(
          _promptRow('clone', _prompt1Key),
          true,
          lookupAppLocalizations(Locale(locale)),
        );

        check(prompts.created.single.command).equals(expected);
      });
    }

    testWidgets('switches the prompt off, and deletes it', (tester) async {
      final prompts = _Prompts();
      final rig = await pump(
        tester,
        prompts: prompts,
        promptDetails: {'prompt-1': _prompt()},
      );
      await rig.open(_prompt1);

      await rig.change(_promptRow('active', _prompt1Key));
      await rig.change(_promptRow('delete', _prompt1Key));

      check(prompts.toggled).deepEquals(['prompt-1']);
      check(prompts.deleted).deepEquals(['prompt-1']);
      check(rig.closed).deepEquals([_prompt1]);
    });

    test('the rows of a comparison leave out its headers and mark gaps', () {
      final rows = workspacePromptDiffRows(_l10n, 'page', const [
        '--- va',
        '+++ vb',
        '@@ -1,2 +1,2 @@',
        ' Same',
        '-',
        '+New',
        '@@ -9 +9 @@',
        ' Later',
      ]);
      check(rows.map((row) => row.title))
          .deepEquals(['Same', ' ', 'New', '\u2026', 'Later']);
      check(rows.map((row) => row.value))
          .deepEquals(['context', 'removed', 'added', 'context', 'context']);
      check(rows[2].subtitle)
          .equals(_l10n.workspacePromptHistoryDiffAddedLine('New'));
    });

    group('its history', () {
      final history = '$workspacePromptHistoryPagePrefix$_prompt1Key';
      const versions = [
        WorkspacePromptHistoryEntry(
          id: 'v2',
          promptId: 'prompt-1',
          snapshot: {'content': 'Current'},
          userId: 'u',
          createdAt: 2,
          commitMessage: 'Now',
        ),
        WorkspacePromptHistoryEntry(
          id: 'v1',
          promptId: 'prompt-1',
          snapshot: {'content': 'Pack a towel.', 'name': 'Old Packing'},
          userId: 'u',
          createdAt: 1,
          commitMessage: 'First',
        ),
      ];

      testWidgets('lists the versions and makes one live', (tester) async {
        final prompts = _Prompts()..versions = versions;
        final rig = await pump(
          tester,
          prompts: prompts,
          promptDetails: {'prompt-1': _prompt()},
        );
        await rig.open(_prompt1);
        await rig.open(history);
        check(rig.titles(history)).deepEquals(['Now', 'First']);
        check(
          rig
              .row(history, workspacePromptVersionPageId(_prompt1Key, 'v2'))!
              .subtitle!,
        ).startsWith(_l10n.workspacePromptHistoryLive);

        await rig.change(_promptRow('version-live', _prompt1Key, 'v1'));

        check(prompts.liveSet).deepEquals(['v1']);
        check(
          rig
              .row(history, workspacePromptVersionPageId(_prompt1Key, 'v1'))!
              .subtitle!,
        ).startsWith(_l10n.workspacePromptHistoryLive);
      });

      testWidgets('an editor with no edits shows the version made live', (
        tester,
      ) async {
        final prompts = _Prompts()..versions = versions;
        final rig = await pump(
          tester,
          prompts: prompts,
          promptDetails: {'prompt-1': _prompt()},
        );
        await rig.open(_prompt1);
        await rig.open(history);

        await rig.change(_promptRow('version-live', _prompt1Key, 'v1'));

        check(rig.row(_prompt1, _promptRow('content', _prompt1Key))!.value)
            .equals('Pack a towel.');
        check(rig.page(_prompt1).edited).isFalse();
      });

      testWidgets('a restored version fills the editor, its command kept', (
        tester,
      ) async {
        final prompts = _Prompts()..versions = versions;
        final rig = await pump(
          tester,
          prompts: prompts,
          promptDetails: {'prompt-1': _prompt()},
        );
        await rig.open(_prompt1);
        await rig.open(history);

        await rig.change(_promptRow('version-restore', _prompt1Key, 'v1'));

        check(rig.row(_prompt1, _promptRow('content', _prompt1Key))!.value)
            .equals('Pack a towel.');
        check(rig.row(_prompt1, _promptRow('name', _prompt1Key))!.value)
            .equals('Old Packing');
        check(rig.row(_prompt1, _promptRow('command', _prompt1Key))!.value)
            .equals('packing-list');
        // The version had no tags, so none stay.
        check(rig.titles(_prompt1)).not((it) => it.contains('travel'));
        check(rig.page(_prompt1).edited).isTrue();
        check(rig.closed).deepEquals([history]);
      });

      testWidgets('compares a version with the live one, line by line', (
        tester,
      ) async {
        final prompts = _Prompts()..versions = versions;
        final rig = await pump(
          tester,
          prompts: prompts,
          promptDetails: {'prompt-1': _prompt()},
        );
        await rig.open(_prompt1);
        await rig.open(history);
        final version = workspacePromptVersionPageId(_prompt1Key, 'v1');
        await rig.open(version);
        final compare = workspacePromptDiffPageId(_prompt1Key, 'v1');
        check(rig.row(version, compare)!.title)
            .equals(_l10n.workspacePromptHistoryDiff);
        // The live version has nothing to compare with itself.
        final live = workspacePromptVersionPageId(_prompt1Key, 'v2');
        await rig.open(live);
        check(rig.row(live, workspacePromptDiffPageId(_prompt1Key, 'v2')))
            .isNull();

        await rig.open(compare);

        check(prompts.diffs).deepEquals([('v1', 'v2')]);
        final lines = rig
            .rows(compare)
            .where((row) => row.kind == NativeSheetItemKind.diffLine)
            .toList();
        check(lines.map((row) => row.title))
            .deepEquals(['Packing list', 'Pack a towel.', 'Pack a hat.']);
        check(lines.map((row) => row.value))
            .deepEquals(['context', 'removed', 'added']);
        check(
          lines[1].subtitle,
        ).equals(_l10n.workspacePromptHistoryDiffRemovedLine('Pack a towel.'));
        check(rig.titles(compare))
            .contains(_l10n.workspacePromptHistoryDiffNameChanged);
      });

      testWidgets('a version that could not be made live says so on its '
          'page', (tester) async {
        final prompts = _Prompts()
          ..versions = versions
          ..liveError = StateError('refused');
        final rig = await pump(
          tester,
          prompts: prompts,
          promptDetails: {'prompt-1': _prompt()},
        );
        await rig.open(_prompt1);
        await rig.open(history);
        final version = workspacePromptVersionPageId(_prompt1Key, 'v1');
        await rig.open(version);

        await rig.change(_promptRow('version-live', _prompt1Key, 'v1'));

        check(rig.page(version).announcement)
            .equals(_l10n.workspacePromptSaveFailed);
        check(rig.titles(version)).contains(_l10n.workspacePromptSaveFailed);
      });

      testWidgets('a deleted version brings in the one after the page', (
        tester,
      ) async {
        final prompts = _Prompts()
          ..versions = [
            for (var i = 0; i <= workspacePromptHistoryPageSize; i++)
              WorkspacePromptHistoryEntry(
                id: i == 0 ? 'v2' : 'old-$i',
                promptId: 'prompt-1',
                snapshot: {'content': 'Text $i'},
                userId: 'u',
                createdAt: 100 - i,
                commitMessage: 'Change $i',
              ),
          ];
        final rig = await pump(
          tester,
          prompts: prompts,
          promptDetails: {'prompt-1': _prompt()},
        );
        await rig.open(_prompt1);
        await rig.open(history);
        final last = 'Change $workspacePromptHistoryPageSize';
        check(rig.titles(history)).not((it) => it.contains(last));

        await rig.change(_promptRow('version-delete', _prompt1Key, 'old-5'));

        check(rig.titles(history))
          ..not((it) => it.contains('Change 5'))
          ..contains(last);
      });

      test('a comparison not read yet is loading, not failed', () {
        final page = buildWorkspacePromptDiffPage(
          _l10n,
          editor: WorkspacePromptEditor(_prompt1Key, null),
          versionId: 'v1',
          comparison: WorkspacePromptComparison(),
        );
        final ids = [
          for (final section in page.sections)
            for (final item in section.items) item.id,
        ];

        check(ids).deepEquals([
          '${workspacePromptDiffPageId(_prompt1Key, 'v1')}-loading',
        ]);
      });

      test('a removed line that began with dashes is kept', () {
        final rows = workspacePromptDiffRows(_l10n, 'diff', const [
          '--- v1',
          '+++ v2',
          '@@ -1 +1 @@',
          '--- old comment',
          '+-- new comment',
        ]);

        check(rows.map((row) => row.title))
            .deepEquals(['-- old comment', '-- new comment']);
        check(rows.map((row) => row.value)).deepEquals(['removed', 'added']);
      });

      testWidgets('versions too long to compare say so', (tester) async {
        final prompts = _Prompts()
          ..versions = versions
          ..diffError = const WorkspacePromptDiffTooLargeException();
        final rig = await pump(
          tester,
          prompts: prompts,
          promptDetails: {'prompt-1': _prompt()},
        );
        await rig.open(_prompt1);
        await rig.open(history);
        await rig.open(workspacePromptVersionPageId(_prompt1Key, 'v1'));
        final compare = workspacePromptDiffPageId(_prompt1Key, 'v1');
        await rig.open(compare);

        check(rig.titles(compare))
            .deepEquals([_l10n.workspacePromptHistoryDiffTooLarge]);
      });
    });
  });
}
