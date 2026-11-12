import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit/features/settings/pages/workspace_page_ids.dart';
import 'package:conduit/features/settings/pages/workspace_settings_pages.dart';
import 'package:conduit/features/settings/pages/workspace_skill_settings_pages.dart';
import 'package:conduit/features/settings/pages/workspace_tool_settings_pages.dart';
import 'package:conduit/features/settings/settings_page_module.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:conduit/features/workspace/widgets/workspace_export_controller.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/features/workspace/providers/workspace_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

final AppLocalizations _l10n = lookupAppLocalizations(const Locale('en'));

const _server = ServerConfig(
  id: 'server-1',
  name: 'Home server',
  url: 'https://owui.example',
);

User _user({String role = 'user'}) =>
    User(id: 'owner', username: 'ada', email: 'ada@example.com', role: role);

final _newTool = workspaceToolPageId(null);
final _tool1 = workspaceToolPageId('tool-1');
final _toolKey = workspaceEditorKey('tool-1');
final _newSkill = workspaceSkillPageId(null);
final _skill1 = workspaceSkillPageId('skill-1');
final _skillKey = workspaceEditorKey('skill-1');

const _grant = WorkspaceAccessGrant(
  principalType: WorkspacePrincipalType.group,
  principalId: 'group-1',
  permission: WorkspaceGrantPermission.read,
);

WorkspaceToolSummary _tool({
  bool writeAccess = true,
  bool? isActive,
  Map<String, dynamic> meta = const {'description': 'Reads star charts'},
}) => WorkspaceToolSummary(
  id: 'tool-1',
  name: 'Star Chart',
  userId: 'owner',
  content: 'class Tools:\n    pass\n',
  specs: const [
    {'name': 'find_star', 'description': 'Finds a star'},
  ],
  meta: meta,
  accessGrants: const [_grant],
  writeAccess: writeAccess,
  isActive: isActive,
);

WorkspaceSkillSummary _skill({bool writeAccess = true, bool isActive = true}) =>
    WorkspaceSkillSummary(
      id: 'skill-1',
      name: 'Trail Planner',
      userId: 'owner',
      description: 'Plans a hike',
      content: '# Trail planner\nPick a route.',
      accessGrants: const [_grant],
      writeAccess: writeAccess,
      isActive: isActive,
    );

final class _Tools extends WorkspaceTools {
  _Tools([this.items = const []]);

  final List<WorkspaceToolSummary> items;
  final created = <WorkspaceToolForm>[];
  final updated = <WorkspaceToolForm>[];
  final toggled = <String>[];
  final deleted = <String>[];
  final fetched = <String>[];
  final valveSaves = <(bool, Map<String, dynamic>)>[];
  Object? createError;
  Object? valvesError;

  @override
  Future<WorkspaceCollectionState<WorkspaceToolSummary>> build() async =>
      WorkspaceCollectionState(items: items, total: items.length);

  @override
  Future<WorkspaceToolDetail> create(WorkspaceToolForm form) async {
    final error = createError;
    if (error != null) throw error;
    created.add(form);
    return WorkspaceToolSummary(id: form.id, name: form.name, userId: 'owner');
  }

  @override
  Future<WorkspaceToolDetail> updateItem(
    String id,
    WorkspaceToolForm form,
  ) async {
    updated.add(form);
    return _tool();
  }

  @override
  Future<WorkspaceToolDetail> toggle(String id) async {
    toggled.add(id);
    // As Open WebUI answers a toggle: no source, no write access.
    return const WorkspaceToolSummary(
      id: 'tool-1',
      name: 'Star Chart',
      userId: 'owner',
      isActive: false,
    );
  }

  @override
  Future<void> delete(String id) async => deleted.add(id);

  @override
  Future<Map<String, dynamic>> loadFromUrl(String url) async {
    fetched.add(url);
    return {
      'name': 'moon_phase',
      'content': '"""\ntitle: Moon Phase\n"""\nclass Tools:\n    pass\n',
      'meta': {'description': 'Says the phase of the moon'},
    };
  }

  @override
  Future<WorkspaceValveSpec?> toolValvesSpec(String id) async =>
      const WorkspaceValveSpec(
        schema: {
          'properties': {
            'units': {
              'title': 'Units',
              'type': 'string',
              'enum': ['metric', 'imperial'],
            },
            'limit': {'title': 'Limit', 'type': 'integer', 'default': 5},
          },
        },
      );

  @override
  Future<Map<String, dynamic>> toolValves(String id) async {
    final error = valvesError;
    if (error != null) throw error;
    return {'units': null, 'limit': null};
  }

  @override
  Future<WorkspaceValveSpec?> userToolValvesSpec(String id) async => null;

  @override
  Future<Map<String, dynamic>> userToolValves(String id) async => {};

  @override
  Future<void> updateToolValves(String id, Map<String, dynamic> valves) async =>
      valveSaves.add((false, valves));

  @override
  Future<void> refresh() async {}
}

final class _Skills extends WorkspaceSkills {
  _Skills();

  final List<WorkspaceSkillSummary> items = const [];
  final created = <WorkspaceSkillForm>[];
  final updated = <WorkspaceSkillForm>[];
  final toggled = <String>[];
  final deleted = <String>[];

  @override
  Future<WorkspaceCollectionState<WorkspaceSkillSummary>> build() async =>
      WorkspaceCollectionState(items: items, total: items.length);

  Object? createError;

  @override
  Future<WorkspaceSkillDetail> create(WorkspaceSkillForm form) async {
    final error = createError;
    if (error != null) throw error;
    created.add(form);
    return WorkspaceSkillSummary(id: form.id, name: form.name, userId: 'owner');
  }

  @override
  Future<WorkspaceSkillDetail> updateItem(
    String id,
    WorkspaceSkillForm form,
  ) async {
    updated.add(form);
    return _skill();
  }

  @override
  Future<WorkspaceSkillDetail> toggle(String id) async {
    toggled.add(id);
    // As Open WebUI answers a toggle: no write access.
    return const WorkspaceSkillSummary(
      id: 'skill-1',
      name: 'Trail Planner',
      userId: 'owner',
      isActive: false,
    );
  }

  @override
  Future<void> delete(String id) async => deleted.add(id);

  @override
  Future<void> refresh() async {}
}

/// Settings as the pages see it: each question is answered with [answer].
final class _Surface extends SettingsSurface {
  _Surface(super.ref);

  String? answer;
  final asked = <String>[];

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
  final shared = <String>[];

  @override
  Future<ShareResult> shareJson({
    required String filename,
    required Object? data,
    String? subject,
    Rect? sharePositionOrigin,
  }) async {
    shared.add(filename);
    return const ShareResult('ok', ShareResultStatus.success);
  }
}

final class _Rig {
  _Rig(this.tester, this.container);

  final WidgetTester tester;
  final ProviderContainer container;

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

  Future<void> change(String id, [Object? value = true]) => settle(() async {
    for (final module in container.read(settingsPageModulesProvider)) {
      if (await module.handleChange(id, value, _l10n)) return;
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

String _toolRow(String field, [String? key, String? extra]) =>
    workspaceRowId('tool-$field', key ?? workspaceNewKey, extra);

String _skillRow(String field, [String? key]) =>
    workspaceRowId('skill-$field', key ?? workspaceNewKey);

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
    _Tools? tools,
    _Skills? skills,
    WorkspaceToolSummary? tool,
    WorkspaceSkillSummary? skill,
    String role = 'user',
    String? serverVersion = '0.13.0',
    String? markdown,
    _Export? export,
  }) async {
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        currentUserProvider2.overrideWithValue(_user(role: role)),
        apiServiceProvider.overrideWithValue(api),
        authTokenProvider3.overrideWithValue('token-a'),
        activeServerProvider.overrideWith((ref) async => _server),
        workspaceCapabilitiesProvider.overrideWith(
          (ref) async => WorkspaceCapabilities.all,
        ),
        workspaceServerVersionProvider.overrideWithValue(serverVersion),
        workspaceToolsProvider.overrideWith(() => tools ?? _Tools()),
        workspaceSkillsProvider.overrideWith(() => skills ?? _Skills()),
        workspaceToolDetailProvider('tool-1')
            .overrideWith((ref) async => tool ?? _tool()),
        workspaceSkillDetailProvider('skill-1')
            .overrideWith((ref) async => skill ?? _skill()),
        workspaceSkillMarkdownPickerProvider.overrideWithValue(
          () async => markdown,
        ),
        settingsSurfaceProvider.overrideWith(_Surface.new),
        workspaceExportControllerProvider.overrideWithValue(
          export ?? _Export(),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(settingsSurfaceProvider);
    container.listen(workspaceCapabilitiesProvider, (_, _) {});
    container.listen(activeServerProvider, (_, _) {});
    final rig = _Rig(tester, container);
    await rig.settle(Future<void>.value());
    return rig;
  }

  group('the Tools and Skills lists', () {
    testWidgets('a tool on names its functions; one off says so, and only a '
        'server with the switch offers it', (tester) async {
      final tools = _Tools([
        _tool(isActive: true),
        WorkspaceToolSummary(
          id: 'tool-2',
          name: 'Off',
          userId: 'owner',
          writeAccess: true,
          isActive: false,
        ),
        WorkspaceToolSummary(
          id: 'tool-3',
          name: 'Old',
          userId: 'owner',
          writeAccess: true,
        ),
      ]);
      final rig = await pump(tester, tools: tools);
      final list = workspaceSectionPageId(WorkspaceSection.tools);
      await rig.open(list);

      check(rig.row(list, _tool1)!.subtitle!)
          .contains(_l10n.workspaceToolFunctionCount(1));
      check(rig.row(list, workspaceToolPageId('tool-2'))!.subtitle!)
          .contains(_l10n.inactiveStatus);
      final switches = [
        for (final id in ['tool-1', 'tool-2', 'tool-3'])
          rig
              .row(list, workspaceToolPageId(id))!
              .rowActions
              .any((a) => a.id == workspaceRowId('list-active', 'tools', id)),
      ];
      check(switches).deepEquals([true, true, false]);

      await rig.change(workspaceRowId('list-active', 'tools', 'tool-1'));
      check(tools.toggled).deepEquals(['tool-1']);
    });

    testWidgets('both offer Import and Export, and the Workspace hands '
        'nothing off any more', (tester) async {
      final rig = await pump(tester);
      await rig.open(workspaceHubPageId);
      check(rig.rows(workspaceHubPageId).map((row) => row.id)).deepEquals([
        for (final section in WorkspaceSection.values)
          workspaceSectionPageId(section),
      ]);

      final skills = workspaceSectionPageId(WorkspaceSection.skills);
      await rig.open(skills);
      check(rig.row(skills, workspaceRowId('list-import', 'skills'))!.title)
          .equals(_l10n.workspaceSkillImport);
      check(rig.row(skills, workspaceRowId('list-export', 'skills'))!.title)
          .equals(_l10n.workspaceSkillExport);
    });
  });

  group("a tool's editor", () {
    testWidgets('makes a tool whose id follows its name, from the starting '
        'source, then goes back', (tester) async {
      final tools = _Tools();
      final rig = await pump(tester, tools: tools);
      await rig.open(_newTool);
      check(rig.page(_newTool).confirmActionLabel)
          .equals(_l10n.workspaceCreate);

      await rig.change(_toolRow('name'), 'Moon Phase');
      check(rig.row(_newTool, _toolRow('id'))!.value).equals('moon_phase');
      await rig.change(_toolRow('save'));

      final form = tools.created.single;
      check(form.id).equals('moon_phase');
      check(form.content).equals(workspaceToolBoilerplate);
      check(rig.closed).deepEquals([_newTool]);
    });

    testWidgets('saves nothing with no source', (tester) async {
      final tools = _Tools();
      final rig = await pump(tester, tools: tools);
      await rig.open(_newTool);
      await rig.change(_toolRow('name'), 'Moon Phase');
      await rig.change(_toolRow('content'), '');
      await rig.change(_toolRow('save'));

      check(tools.created).isEmpty();
      check(rig.page(_newTool).announcement)
          .equals(_l10n.workspaceToolContentRequired);
    });

    testWidgets('a source asking for a newer server is not saved, and says '
        'why', (tester) async {
      final tools = _Tools();
      final rig = await pump(tester, tools: tools, serverVersion: '0.10.0');
      await rig.open(_newTool);
      await rig.change(
        _toolRow('content'),
        '"""\ntitle: Future Tool\nrequired_open_webui_version: 0.11.0\n"""\n'
        'class Tools:\n    pass\n',
      );
      // The title filled the name, and the id after it.
      check(rig.row(_newTool, _toolRow('name'))!.value).equals('Future Tool');
      check(rig.row(_newTool, '$_newTool-incompatible')).isNotNull();

      await rig.change(_toolRow('save'));
      check(tools.created).isEmpty();
      check(rig.page(_newTool).announcement)
          .equals(_l10n.workspaceToolIncompatible('0.11.0', '0.10.0'));
    });

    testWidgets('a refusal that is not about the id is not said to be one', (
      tester,
    ) async {
      final tools = _Tools()
        ..createError = DioException(
          requestOptions: RequestOptions(),
          response: Response(
            requestOptions: RequestOptions(),
            statusCode: 400,
            data: {'detail': 'Error loading tool: invalid syntax'},
          ),
        );
      final rig = await pump(tester, tools: tools);
      await rig.open(_newTool);
      await rig.change(_toolRow('name'), 'Moon Phase');
      await rig.change(_toolRow('save'));

      check(rig.page(_newTool).announcement)
          .not((it) => it.equals(_l10n.workspaceToolIdTaken));
    });

    testWidgets('an id that is not one, or already used, says why', (
      tester,
    ) async {
      final tools = _Tools();
      final rig = await pump(tester, tools: tools);
      await rig.open(_newTool);
      await rig.change(_toolRow('name'), 'Moon Phase');
      await rig.change(_toolRow('id'), '9 moons');
      await rig.change(_toolRow('save'));
      check(tools.created).isEmpty();
      check(rig.page(_newTool).announcement)
          .equals(_l10n.workspaceToolIdInvalid);
    });

    testWidgets("its source is a page of code, and a change there marks the "
        'editor edited', (tester) async {
      final rig = await pump(tester);
      await rig.open(_tool1);
      final code = '$workspaceToolCodePagePrefix$_toolKey';
      await rig.open(code);
      final row = rig.rows(code).single;
      check(row.kind).equals(NativeSheetItemKind.code);
      check(row.value).equals('class Tools:\n    pass\n');
      check(rig.page(_tool1).edited).isFalse();

      await rig.change(_toolRow('content', _toolKey), 'class Tools: ...\n');

      check(rig.page(_tool1).edited).isTrue();
    });

    testWidgets('an edit saves the tool in place, then goes back', (
      tester,
    ) async {
      final tools = _Tools();
      final rig = await pump(tester, tools: tools);
      await rig.open(_tool1);
      check(rig.row(_tool1, _toolRow('id', _toolKey))!.kind)
          .equals(NativeSheetItemKind.readOnlyText);

      await rig.change(_toolRow('description', _toolKey), 'Charts stars');
      await rig.change(_toolRow('save', _toolKey));

      final form = tools.updated.single;
      check(form.id).equals('tool-1');
      check(form.meta['description']).equals('Charts stars');
      check(rig.closed).deepEquals([_tool1]);
    });

    testWidgets('a duplicate keeps none of the access list', (tester) async {
      final tools = _Tools();
      final rig = await pump(tester, tools: tools);
      await rig.open(_tool1);
      await rig.change(_toolRow('clone', _toolKey));

      check(tools.created.single.id).equals('tool-1_clone');
      check(tools.created.single.accessGrants).isEmpty();
    });

    testWidgets('switches the tool off on a server that has the switch, but '
        'not while it holds changes', (tester) async {
      final tools = _Tools();
      final rig = await pump(tester, tools: tools, tool: _tool(isActive: true));
      await rig.open(_tool1);
      check(rig.row(_tool1, _toolRow('active', _toolKey))!.title)
          .equals(_l10n.workspaceToolDeactivate);

      await rig.change(_toolRow('description', _toolKey), 'Changed');
      await rig.change(_toolRow('active', _toolKey));
      check(tools.toggled).isEmpty();
      check(rig.page(_tool1).announcement)
          .equals(_l10n.workspaceToolToggleSaveFirst);

      final switching = _Tools();
      final fresh = await pump(
        tester,
        tools: switching,
        tool: _tool(isActive: true),
      );
      await fresh.open(_tool1);
      await fresh.change(_toolRow('active', _toolKey));
      check(switching.toggled).deepEquals(['tool-1']);
      check(fresh.row(_tool1, _toolRow('active', _toolKey))!.title)
          .equals(_l10n.workspaceToolActivate);
      // Still the account's own tool, its source kept.
      check(fresh.page(_tool1).confirmActionId).isNotNull();
      final code = '$workspaceToolCodePagePrefix$_toolKey';
      await fresh.open(code);
      check(fresh.rows(code).single.value).equals('class Tools:\n    pass\n');

      final older = await pump(tester, tool: _tool());
      await older.open(_tool1);
      check(older.row(_tool1, _toolRow('active', _toolKey))).isNull();
    });

    testWidgets('deletes the tool, then goes back', (tester) async {
      final tools = _Tools();
      final rig = await pump(tester, tools: tools);
      await rig.open(_tool1);
      await rig.change(_toolRow('delete', _toolKey));

      check(tools.deleted).deepEquals(['tool-1']);
      check(rig.closed).deepEquals([_tool1]);
    });

    testWidgets('a tool the account may only view offers no changes', (
      tester,
    ) async {
      final rig = await pump(tester, tool: _tool(writeAccess: false));
      await rig.open(_tool1);

      check(rig.page(_tool1).confirmActionId).isNull();
      check(rig.row(_tool1, _toolRow('name', _toolKey))!.kind)
          .equals(NativeSheetItemKind.readOnlyText);
      check(rig.row(_tool1, _toolRow('delete', _toolKey))).isNull();
      check(rig.row(_tool1, '$workspaceToolValvesPagePrefix$_toolKey'))
          .isNull();
    });

    group('from a URL', () {
      final url = '$workspaceToolUrlPagePrefix$workspaceNewKey';

      testWidgets('is for admins only', (tester) async {
        final admin = await pump(tester, role: 'admin');
        await admin.open(_newTool);
        check(admin.row(_newTool, url)).isNotNull();

        final user = await pump(tester);
        await user.open(_newTool);
        check(user.row(_newTool, url)).isNull();
      });

      testWidgets('sends no link the server should not fetch', (tester) async {
        final tools = _Tools();
        final rig = await pump(tester, tools: tools, role: 'admin');
        await rig.open(_newTool);
        await rig.open(url);

        for (final (link, why) in [
          ('not a url', _l10n.workspaceToolImportUrlInvalid),
          (
            'http://169.254.169.254/latest/meta-data',
            _l10n.workspaceToolImportUrlHost,
          ),
          (
            'https://intranet.example/tool.py',
            _l10n.workspaceToolImportUrlHost,
          ),
        ]) {
          await rig.change(_toolRow('url'), link);
          await rig.change(_toolRow('url-load'));
          check(rig.page(url).announcement).equals(why);
        }
        check(tools.fetched).isEmpty();
      });

      testWidgets('loads a GitHub link into the new tool', (tester) async {
        final tools = _Tools();
        final rig = await pump(tester, tools: tools, role: 'admin');
        await rig.open(_newTool);
        await rig.open(url);

        await rig.change(
          _toolRow('url'),
          'https://github.com/example/tools/blob/main/moon.py',
        );
        await rig.change(_toolRow('url-load'));

        check(tools.fetched).deepEquals([
          'https://raw.githubusercontent.com/example/tools/refs/heads/main/moon.py',
        ]);
        check(rig.closed).deepEquals([url]);
        check(rig.row(_newTool, _toolRow('name'))!.value).equals('Moon Phase');
        check(rig.row(_newTool, _toolRow('description'))!.value)
            .equals('Says the phase of the moon');
        check(rig.page(_newTool).edited).isTrue();
      });
    });

    group('its valves', () {
      final valves = '$workspaceToolValvesPagePrefix$_toolKey';

      testWidgets('a value of its own is set, then saved', (tester) async {
        final tools = _Tools();
        final rig = await pump(tester, tools: tools);
        await rig.open(_tool1);
        await rig.open(valves);
        check(rig.row(valves, _toolRow('valve-mode', _toolKey, 'units'))!.value)
            .equals('default');
        check(rig.row(valves, _toolRow('valve-value', _toolKey, 'units')))
            .isNull();

        await rig.change(_toolRow('valve-mode', _toolKey, 'units'), 'custom');
        final value = rig.row(
          valves,
          _toolRow('valve-value', _toolKey, 'units'),
        )!;
        check(value.kind).equals(NativeSheetItemKind.segment);
        await rig.change(
          _toolRow('valve-value', _toolKey, 'units'),
          'imperial',
        );
        await rig.change(_toolRow('valve-mode', _toolKey, 'limit'), 'custom');
        await rig.change(_toolRow('valve-value', _toolKey, 'limit'), '12');
        check(rig.page(valves).edited).isTrue();
        await rig.change(_toolRow('valves-save', _toolKey));

        check(tools.valveSaves.single.$2)
            .deepEquals({'units': 'imperial', 'limit': 12});
        check(rig.closed).deepEquals([valves]);
        check(rig.page(_tool1).announcement)
            .equals(_l10n.workspaceToolValvesSaved);
      });

      testWidgets('a scope with unsaved edits asks before the other is shown', (
        tester,
      ) async {
        final tools = _Tools();
        final rig = await pump(tester, tools: tools);
        await rig.open(_tool1);
        await rig.open(valves);
        await rig.change(_toolRow('valve-mode', _toolKey, 'units'), 'custom');
        final scope = _toolRow('valves-scope', _toolKey);
        final surface = rig.container.read(settingsSurfaceProvider) as _Surface;

        surface.answer = 'keep';
        await rig.change(scope, 'user');
        check(surface.asked).deepEquals([_l10n.workspaceEditorDiscardTitle]);
        check(rig.row(valves, _toolRow('valve-mode', _toolKey, 'units'))!.value)
            .equals('custom');
        check(rig.page(valves).edited).isTrue();

        surface.answer = 'discard';
        await rig.change(scope, 'user');
        check(rig.page(valves).edited).isFalse();
        check(tools.valveSaves).isEmpty();
      });

      testWidgets('text that is no number is kept as typed, said, and not '
          'saved', (tester) async {
        final tools = _Tools();
        final rig = await pump(tester, tools: tools);
        await rig.open(_tool1);
        await rig.open(valves);
        await rig.change(_toolRow('valve-mode', _toolKey, 'limit'), 'custom');
        final limit = _toolRow('valve-value', _toolKey, 'limit');

        // On the way to a number, or not one: kept as typed.
        await rig.change(limit, '-');
        check(rig.row(valves, limit)!.value).equals('-');
        check(rig.row(valves, limit)!.subtitle)
            .equals(_l10n.chatSettingErrorNotAWholeNumber);
        await rig.change(_toolRow('valves-save', _toolKey));
        check(tools.valveSaves).isEmpty();

        await rig.change(limit, '-12');
        check(rig.row(valves, limit)!.subtitle).isNull();
        await rig.change(_toolRow('valves-save', _toolKey));
        check(tools.valveSaves.single.$2['limit']).equals(-12);
      });

      testWidgets('valves that cannot be read offer Retry', (tester) async {
        final tools = _Tools()..valvesError = StateError('offline');
        final rig = await pump(tester, tools: tools);
        await rig.open(_tool1);
        await rig.open(valves);

        check(rig.row(valves, _toolRow('valves-retry', _toolKey))!.title)
            .equals(_l10n.workspaceToolValvesLoadFailed);
        tools.valvesError = null;
        await rig.change(_toolRow('valves-retry', _toolKey));
        check(rig.row(valves, _toolRow('valve-mode', _toolKey, 'units')))
            .isNotNull();
      });
    });
  });

  group("a skill's editor", () {
    testWidgets('a name already in use is not said to be the id', (
      tester,
    ) async {
      final skills = _Skills()
        ..createError = DioException(
          requestOptions: RequestOptions(),
          response: Response(
            requestOptions: RequestOptions(),
            statusCode: 409,
            data: {'detail': 'A skill with this name already exists'},
          ),
        );
      final rig = await pump(tester, skills: skills);
      await rig.open(_newSkill);
      await rig.change(_skillRow('name'), 'Trail Planner');
      await rig.change(_skillRow('content'), '# Trail planner');
      await rig.change(_skillRow('save'));

      check(rig.page(_newSkill).announcement)
          .not((it) => it.equals(_l10n.workspaceSkillIdTaken));
    });

    testWidgets('makes a skill whose id follows its name', (tester) async {
      final skills = _Skills();
      final rig = await pump(tester, skills: skills);
      await rig.open(_newSkill);

      await rig.change(_skillRow('name'), 'Trail Planner');
      await rig.change(_skillRow('content'), 'Pick a route.');
      await rig.change(_skillRow('save'));

      check(skills.created.single.id).equals('trail-planner');
      check(rig.closed).deepEquals([_newSkill]);
    });

    testWidgets('saves nothing with no instructions', (tester) async {
      final skills = _Skills();
      final rig = await pump(tester, skills: skills);
      await rig.open(_newSkill);
      await rig.change(_skillRow('name'), 'Trail Planner');
      await rig.change(_skillRow('save'));

      check(skills.created).isEmpty();
      check(rig.page(_newSkill).announcement)
          .equals(_l10n.workspaceSkillContentRequired);
    });

    testWidgets('an empty id says one is needed; one with other characters '
        'says which are allowed', (tester) async {
      final skills = _Skills();
      final rig = await pump(tester, skills: skills);
      await rig.open(_newSkill);
      await rig.change(_skillRow('name'), 'Trail Planner');
      await rig.change(_skillRow('content'), 'Pick a route.');

      await rig.change(_skillRow('id'), '');
      await rig.change(_skillRow('save'));
      check(rig.page(_newSkill).announcement)
          .equals(_l10n.workspaceSkillIdRequired);

      await rig.change(_skillRow('id'), 'trail planner!');
      await rig.change(_skillRow('save'));
      check(rig.page(_newSkill).announcement)
          .equals(_l10n.workspaceSkillIdInvalid);
      check(skills.created).isEmpty();
    });

    testWidgets("front matter in its instructions fills what isn't filled", (
      tester,
    ) async {
      final rig = await pump(tester);
      await rig.open(_newSkill);

      await rig.change(
        _skillRow('content'),
        '---\nname: trail planner\ndescription: Plans a hike\n---\nBody',
      );

      check(rig.row(_newSkill, _skillRow('name'))!.value)
          .equals('Trail Planner');
      check(rig.row(_newSkill, _skillRow('id'))!.value).equals('trail-planner');
      check(rig.row(_newSkill, _skillRow('description'))!.value)
          .equals('Plans a hike');
    });

    testWidgets('a Markdown file fills the new skill, its id from the front '
        'matter', (tester) async {
      final rig = await pump(
        tester,
        markdown: '---\nid: ridge_walk\n---\nFollow the ridge.',
      );
      await rig.open(_newSkill);

      await rig.change(_skillRow('import-markdown'));

      check(rig.row(_newSkill, _skillRow('id'))!.value).equals('ridge_walk');
      check(rig.page(_newSkill).announcement)
          .equals(_l10n.workspaceSkillImportMarkdownLoaded);
      check(rig.page(_newSkill).edited).isTrue();
    });

    testWidgets('an edit saves the skill; it switches off, duplicates without '
        'its access list, and deletes', (tester) async {
      final skills = _Skills();
      final rig = await pump(tester, skills: skills);
      await rig.open(_skill1);

      await rig.change(_skillRow('clone', _skillKey));
      check(skills.created.single.id).equals('skill-1_clone');
      // Its SKILL.md alone: the content makes it, as it always did.
      check(skills.created.single.files).isNull();
      check(skills.created.single.accessGrants).isNotNull().isEmpty();

      await rig.change(_skillRow('active', _skillKey));
      check(skills.toggled).deepEquals(['skill-1']);
      check(rig.row(_skill1, _skillRow('active', _skillKey))!.title)
          .equals(_l10n.workspaceSkillActivate);
      // Still the account's own skill.
      check(rig.page(_skill1).confirmActionId).isNotNull();

      await rig.change(
        _skillRow('description', _skillKey),
        'Plans a long hike',
      );
      await rig.change(_skillRow('save', _skillKey));
      check(skills.updated.single.description).equals('Plans a long hike');
      // Who may open it is the Access page's to save.
      check(skills.updated.single.accessGrants).isNull();
      check(rig.closed).deepEquals([_skill1]);

      final removing = _Skills();
      final again = await pump(tester, skills: removing);
      await again.open(_skill1);
      await again.change(_skillRow('delete', _skillKey));
      check(removing.deleted).deepEquals(['skill-1']);
    });

    testWidgets('a skill the account may only view offers no changes', (
      tester,
    ) async {
      final rig = await pump(tester, skill: _skill(writeAccess: false));
      await rig.open(_skill1);

      check(rig.page(_skill1).confirmActionId).isNull();
      check(rig.row(_skill1, _skillRow('delete', _skillKey))).isNull();
      final content = '$workspaceSkillContentPagePrefix$_skillKey';
      await rig.open(content);
      check(rig.rows(content).single.disabled).isTrue();
    });
  });
}
