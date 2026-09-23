@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/file_picker.dart';
import 'package:conduit_desktop_ui/src/file_saver.dart';
import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/pages/workspace/workspace_common.dart';
import 'package:conduit_desktop_ui/src/pages/workspace/workspace_editor.dart';
import 'package:conduit_desktop_ui/src/pages/workspace/workspace_page.dart';
import 'package:conduit_desktop_ui/src/rpc/rpc_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/workspace_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart' show button;
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_router/jaspr_router.dart';
import 'package:jaspr_test/jaspr_test.dart';

const _all = WorkspaceSectionAccess(
  manage: true,
  importItems: true,
  exportItems: true,
  share: true,
  sharePublicly: true,
);

/// The daemon, in memory.
class _FakeActions extends WorkspaceActions {
  _FakeActions(super.ref);

  WorkspaceAccess access = const WorkspaceAccess(
    models: _all,
    knowledge: _all,
    prompts: _all,
    tools: _all,
    skills: _all,
    allowUserGrants: true,
    admin: true,
  );
  final Map<WorkspaceKind, WorkspacePage> pages = {};
  final Map<String, WorkspaceDetail> details = {};
  final List<WorkspaceQuery> queries = [];
  final List<(WorkspaceDetail, bool)> saves = [];
  final List<String> deleted = [];
  final List<List<WorkspaceGrant>> accessSaves = [];
  final List<String> imported = [];
  final List<String> productionSet = [];
  final List<String> openedFolders = [];
  final List<Map<String, dynamic>> valvesSaved = [];

  @override
  Future<WorkspaceAccess> capabilities() async => access;

  @override
  Future<WorkspacePage> list(WorkspaceQuery query) async {
    queries.add(query);
    final page = pages[query.kind] ?? WorkspacePage(kind: query.kind);
    return query.more
        ? page.copyWith(
            items: [
              ...page.items,
              WorkspaceItem(kind: query.kind, id: 'more', name: 'Loaded later'),
            ],
            hasMore: false,
          )
        : page;
  }

  @override
  Future<WorkspaceDetail> get(WorkspaceKind kind, String id) async =>
      details['${kind.name}/$id'] ??
      (throw const RpcError(code: ConduitErrorCodes.notFound));

  @override
  Future<WorkspaceDetail> save(
    WorkspaceDetail detail, {
    bool create = false,
  }) async {
    saves.add((detail, create));
    return detail;
  }

  @override
  Future<void> delete(WorkspaceKind kind, String id) async => deleted.add(id);

  @override
  Future<WorkspaceDetail> setAccess(
    WorkspaceKind kind,
    String id,
    List<WorkspaceGrant> grants,
  ) async {
    accessSaves.add(grants);
    return details['${kind.name}/$id']!.copyWith(grants: grants);
  }

  @override
  Future<List<WorkspacePrincipal>> principals({
    String query = '',
    List<String> ids = const <String>[],
  }) async => const [
    WorkspacePrincipal(type: 'group', id: 'g1', name: 'Staff'),
  ];

  @override
  Future<WorkspaceExportFile> export(WorkspaceKind kind, {String? id}) async =>
      WorkspaceExportFile(filename: '${id ?? kind.name}.json', text: '[]');

  @override
  Future<WorkspaceImportResult> import(WorkspaceKind kind, String text) async {
    imported.add(text);
    return const WorkspaceImportResult(
      imported: 1,
      failed: [WorkspaceImportFailure(label: 'Tidy', reason: 'exists')],
    );
  }

  @override
  Future<WorkspaceModelOptions> modelOptions() async =>
      const WorkspaceModelOptions(
        baseModels: [WorkspaceRelation(id: 'gemma3:1b', name: 'Gemma')],
        knowledge: [
          WorkspaceRelation(id: 'k1', name: 'Handbook'),
          WorkspaceRelation(id: 'k2', name: 'Runbooks'),
        ],
        tools: [WorkspaceRelation(id: 'web', name: 'Web')],
      );

  @override
  Future<WorkspacePromptHistory> promptHistory(String promptId) async =>
      const WorkspacePromptHistory(
        promptId: 'p1',
        versions: [
          WorkspacePromptVersion(
            id: 'v2',
            commitMessage: 'Warmer',
            content: 'Say hello warmly.',
            production: true,
          ),
          WorkspacePromptVersion(id: 'v1', content: 'Say hello.'),
        ],
      );

  @override
  Future<WorkspacePromptDiff> promptDiff(
    String promptId, {
    required String fromId,
    required String toId,
  }) async => const WorkspacePromptDiff(
    lines: [
      '--- vv1',
      '+++ vv2',
      '@@ -1 +1 @@',
      '-Say hello.',
      '+Say hello warmly.',
    ],
  );

  @override
  Future<WorkspaceDetail> promptSetVersion(
    String promptId,
    String versionId,
  ) async {
    productionSet.add(versionId);
    return details['prompts/$promptId']!;
  }

  @override
  Future<WorkspaceValves> valves(String toolId, {bool user = false}) async =>
      WorkspaceValves(
        toolId: toolId,
        user: user,
        schema: const {
          'properties': {
            'limit': {
              'title': 'Limit',
              'type': 'integer',
              'default': 3,
              'description': 'How many',
            },
          },
        },
        values: const {'limit': 5},
      );

  @override
  Future<WorkspaceFiles> files(
    String knowledgeId, {
    String directoryId = '',
    bool more = false,
  }) async {
    openedFolders.add(directoryId);
    return directoryId.isEmpty
        ? const WorkspaceFiles(
            knowledgeId: 'k1',
            directories: [WorkspaceDirectory(id: 'd1', name: 'Guides')],
            files: [WorkspaceFile(id: 'f1', filename: 'notes.txt', size: 2048)],
            pending: [
              WorkspaceFile(id: 'f2', filename: 'scan.pdf', status: 'failed'),
            ],
            total: 1,
          )
        : const WorkspaceFiles(
            knowledgeId: 'k1',
            directoryId: 'd1',
            breadcrumbs: [WorkspaceDirectory(id: 'd1', name: 'Guides')],
            files: [WorkspaceFile(id: 'f3', filename: 'setup.md')],
            total: 1,
          );
  }
}

class _Seeded extends WorkspaceTemplate {
  _Seeded(this.detail);

  final WorkspaceDetail detail;

  @override
  WorkspaceDetail? build() => detail;
}

class _Picker implements FilePickerPort {
  @override
  Future<PickedTextFile?> pickText({required String accept}) async =>
      (name: 'prompts.json', content: '[{"command": "hi"}]');
}

void main() {
  late _FakeActions actions;
  late RecordingFileSaver saver;

  /// Where the page went, and the template a duplicate left for the next
  /// editor. The VM router cannot navigate, so the test watches instead.
  late List<String> went;
  WorkspaceDetail? template;

  Component app(
    void Function(_FakeActions fake) seed, {
    WorkspaceDetail? startFrom,
  }) {
    saver = RecordingFileSaver();
    went = <String>[];
    template = null;
    Component screen(RouteState state, {bool create = false}) =>
        WorkspaceScreen(
          section: state.params['section'],
          id: state.params['id'] == null
              ? null
              : Uri.decodeComponent(state.params['id']!),
          create: create,
        );
    return ProviderScope(
      overrides: [
        workspaceActionsProvider.overrideWith((ref) {
          actions = _FakeActions(ref);
          seed(actions);
          return actions;
        }),
        workspaceAccessProvider.overrideWith(
          (ref) => ref.read(workspaceActionsProvider).capabilities(),
        ),
        fileSaverProvider.overrideWithValue(saver),
        filePickerProvider.overrideWithValue(_Picker()),
        workspaceNavigateProvider.overrideWith(
          (ref) => (context, to, {replace = false}) {
            went.add(to);
            template = ref.read(workspaceTemplateProvider);
          },
        ),
        if (startFrom != null)
          workspaceTemplateProvider.overrideWith(() => _Seeded(startFrom)),
      ],
      child: Router(
        routes: [
          Route(
            path: '/workspace/:section/new',
            builder: (context, state) => screen(state, create: true),
          ),
          Route(
            path: '/workspace/:section/:id',
            builder: (context, state) => screen(state),
          ),
          Route(
            path: '/workspace/:section',
            builder: (context, state) => screen(state),
          ),
          Route(path: '/workspace', builder: (context, state) => screen(state)),
          Route(
            path: '/',
            builder: (context, state) => const Component.text('chat'),
          ),
        ],
      ),
    );
  }

  Finder buttonWith(String text) => find.componentWithText(button, text);

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await pumpEventQueue();
    }
  }

  testComponents('offers only the sections this account may manage', (
    tester,
  ) async {
    tester.pumpComponent(
      app(
        (fake) => fake.access = const WorkspaceAccess(
          prompts: _all,
          tools: WorkspaceSectionAccess(manage: true),
        ),
      ),
    );
    await settle();
    // The bare /workspace opens the first of them.
    expect(buttonWith(t.app.workspacePrompts), findsOneComponent);
    expect(buttonWith(t.app.workspaceTools), findsOneComponent);
    expect(buttonWith(t.app.workspaceModels), findsNothing);
    expect(went, ['/workspace/prompts']);
  }, url: '/workspace');

  testComponents('a section lists its items, badges and all, and more', (
    tester,
  ) async {
    tester.pumpComponent(
      app(
        (fake) => fake.pages[WorkspaceKind.models] = const WorkspacePage(
          kind: WorkspaceKind.models,
          total: 3,
          hasMore: true,
          items: [
            WorkspaceItem(
              kind: WorkspaceKind.models,
              id: 'helper',
              name: 'Helper',
              subtitle: 'Answers briefly',
              ownerName: 'Ada',
              public: true,
              writeAccess: true,
              active: true,
              tags: ['short'],
            ),
            WorkspaceItem(
              kind: WorkspaceKind.models,
              id: 'shared',
              name: 'Shared one',
              active: false,
            ),
          ],
        ),
      ),
    );
    await settle();
    expect(find.text('Helper'), findsOneComponent);
    expect(find.text('Answers briefly'), findsOneComponent);
    expect(find.text('Ada · short'), findsOneComponent);
    expect(find.text(t.app.workspaceAccessVisibilityLabel), findsOneComponent);
    expect(find.text(t.app.workspaceReadOnlyBadge), findsOneComponent);
    expect(find.text(t.app.workspaceModelDeactivate), findsOneComponent);
    expect(find.text('3'), findsOneComponent);

    await tester.click(buttonWith(t.app.workspaceLoadMore));
    await settle();
    expect(actions.queries.last.more, isTrue);
    expect(find.text('Loaded later'), findsOneComponent);
    expect(buttonWith(t.app.workspaceLoadMore), findsNothing);
  }, url: '/workspace/models');

  testComponents('import reads a file and says what went in; export saves', (
    tester,
  ) async {
    tester.pumpComponent(app((_) {}));
    await settle();
    await tester.click(buttonWith(t.desktop.desktopWorkspaceImport));
    await settle();
    expect(actions.imported.single, '[{"command": "hi"}]');
    expect(
      find.textContaining(t.app.workspaceImportSummary(success: 1, total: 2)),
      findsOneComponent,
    );
    expect(find.textContaining('Tidy (exists)'), findsOneComponent);

    await tester.click(buttonWith(t.desktop.desktopWorkspaceExportAll));
    await settle();
    expect(saver.saved.single.filename, 'prompts.json');
  }, url: '/workspace/prompts');

  testComponents('an item that is gone says so', (tester) async {
    tester.pumpComponent(app((_) {}));
    await settle();
    expect(find.text(t.desktop.desktopWorkspaceNotFound), findsOneComponent);
  }, url: '/workspace/skills/missing');

  group('a prompt', () {
    void seed(_FakeActions fake) =>
        fake.details['prompts/p1'] = const WorkspaceDetail(
          kind: WorkspaceKind.prompts,
          prompt: WorkspacePromptDto(
            id: 'p1',
            command: 'hello',
            name: 'Hello',
            content: 'Say hello warmly.',
            versionId: 'v2',
          ),
          grants: [
            WorkspaceGrant(principalId: '*'),
            WorkspaceGrant(principalType: 'group', principalId: 'g1'),
          ],
        );

    testComponents('saves only once changed, from its history too', (
      tester,
    ) async {
      tester.pumpComponent(app(seed));
      await settle();
      expect(find.text('Hello'), findsOneComponent);
      final save = find.byComponentPredicate(
        (c) => c is DomComponent && c.id == 'workspace-save',
      );
      expect(
        (save.evaluate().single.component as DomComponent)
            .attributes?['disabled'],
        isNotNull,
      );

      await tester.click(buttonWith(t.app.workspacePromptHistory));
      await settle();
      expect(find.text('Warmer'), findsOneComponent);
      expect(find.text(t.app.workspacePromptHistoryLive), findsOneComponent);

      // The older version's text, into the editor: now there is a change.
      await tester.click(buttonWith(t.app.workspacePromptHistoryRestore).last);
      await settle();
      expect(
        find.text(t.app.workspacePromptHistoryRestored),
        findsOneComponent,
      );
      await tester.click(save);
      await settle();
      final (saved, create) = actions.saves.single;
      expect(create, isFalse);
      expect(saved.prompt!.content, 'Say hello.');
      expect(find.text(t.app.workspacePromptSaved), findsOneComponent);
    }, url: '/workspace/prompts/p1');

    testComponents('compares a version with production, and promotes it', (
      tester,
    ) async {
      tester.pumpComponent(app(seed));
      await settle();
      await tester.click(buttonWith(t.app.workspacePromptHistory));
      await settle();
      await tester.click(buttonWith(t.app.workspacePromptHistoryDiff));
      await settle();
      expect(find.text('+Say hello warmly.'), findsOneComponent);
      expect(find.text('-Say hello.'), findsOneComponent);
      await tester.click(buttonWith(t.app.close));
      await settle();

      await tester.click(buttonWith(t.app.workspacePromptHistorySetProduction));
      await settle();
      expect(actions.productionSet, ['v1']);
    }, url: '/workspace/prompts/p1');

    testComponents('leaving with changes asks first', (tester) async {
      tester.pumpComponent(app(seed));
      await settle();
      await tester.click(buttonWith(t.app.workspacePromptHistory));
      await settle();
      await tester.click(buttonWith(t.app.workspacePromptHistoryRestore).last);
      await settle();

      await tester.click(buttonWith(t.app.workspaceTools));
      await settle();
      expect(find.text(t.app.workspaceEditorDiscardTitle), findsOneComponent);
      await tester.click(buttonWith(t.app.workspaceEditorKeepEditing));
      await settle();
      expect(find.text(t.app.workspaceEditorDiscardTitle), findsNothing);
      // Still here, with the change.
      expect(find.text('Hello'), findsOneComponent);

      await tester.click(buttonWith(t.app.workspaceTools));
      await settle();
      expect(went, isEmpty);
      await tester.click(buttonWith(t.app.workspaceEditorDiscardConfirm));
      await settle();
      expect(went, ['/workspace/tools']);
    }, url: '/workspace/prompts/p1');

    testComponents('access: grants named, one removed, saved together', (
      tester,
    ) async {
      tester.pumpComponent(app(seed));
      await settle();
      await tester.click(buttonWith(t.app.workspaceModelManageAccess));
      await settle();
      expect(find.text('Staff'), findsOneComponent);
      await tester.click(
        find.byComponentPredicate(
          (c) =>
              c is DomComponent &&
              c.attributes?['aria-label'] == t.app.workspaceAccessRemoveGrant,
        ),
      );
      await settle();
      expect(find.text('Staff'), findsNothing);
      await tester.click(
        find.byComponentPredicate(
          (c) => c is DomComponent && c.id == 'access-save',
        ),
      );
      await settle();
      expect(actions.accessSaves.single, const [
        WorkspaceGrant(principalId: '*'),
      ]);
      expect(
        find.text(t.desktop.desktopWorkspaceAccessSaved),
        findsOneComponent,
      );
    }, url: '/workspace/prompts/p1');

    testComponents('exported, duplicated, deleted', (tester) async {
      tester.pumpComponent(app(seed));
      await settle();
      await tester.click(buttonWith(t.desktop.desktopWorkspaceExport));
      await settle();
      expect(saver.saved.single.filename, 'p1.json');

      await tester.click(buttonWith(t.app.workspaceModelClone));
      await settle();
      expect(went, ['/workspace/prompts/new']);
      expect(template!.prompt!.command, 'hello-copy');
      expect(template!.prompt!.id, isEmpty);
      // A copy is not shared with anyone yet.
      expect(template!.grants, isEmpty);
    }, url: '/workspace/prompts/p1');

    testComponents('delete asks, then goes back to the list', (tester) async {
      tester.pumpComponent(app(seed));
      await settle();
      await tester.click(
        find.byComponentPredicate(
          (c) => c is DomComponent && c.id == 'workspace-delete',
        ),
      );
      await settle();
      expect(
        find.text(t.app.workspacePromptDeleteConfirmTitle),
        findsOneComponent,
      );
      await tester.click(buttonWith(t.app.delete).last);
      await settle();
      expect(actions.deleted, ['p1']);
      expect(went, ['/workspace/prompts']);
    }, url: '/workspace/prompts/p1');
  });

  testComponents('a new editor starts from a duplicate and creates it', (
    tester,
  ) async {
    tester.pumpComponent(
      app(
        (_) {},
        startFrom: const WorkspaceDetail(
          kind: WorkspaceKind.skills,
          skill: WorkspaceSkillDto(
            id: 'tidy-copy',
            name: 'Tidy (copy)',
            content: 'Tidy the text.',
          ),
        ),
      ),
    );
    await settle();
    expect(find.text(t.app.workspaceSkillCreateTitle), findsOneComponent);
    await tester.click(
      find.byComponentPredicate(
        (c) => c is DomComponent && c.id == 'workspace-save',
      ),
    );
    await settle();
    final (created, create) = actions.saves.single;
    expect(create, isTrue);
    expect(created.skill!.id, 'tidy-copy');
    expect(went, ['/workspace/skills/tidy-copy']);
  }, url: '/workspace/skills/new');

  testComponents('a new item is checked before it is sent', (tester) async {
    tester.pumpComponent(app((_) {}));
    await settle();
    await tester.click(
      find.byComponentPredicate(
        (c) => c is DomComponent && c.id == 'workspace-save',
      ),
    );
    await settle();
    expect(actions.saves, isEmpty);
    expect(find.text(t.app.workspacePromptCommandRequired), findsOneComponent);
  }, url: '/workspace/prompts/new');

  testComponents('a model shows its pickers from what the server offers', (
    tester,
  ) async {
    tester.pumpComponent(
      app(
        (fake) => fake.details['models/helper'] = const WorkspaceDetail(
          kind: WorkspaceKind.models,
          model: WorkspaceModelDto(
            id: 'helper',
            name: 'Helper',
            baseModelId: 'gemma3:1b',
            knowledge: [WorkspaceRelation(id: 'k2', name: 'Runbooks')],
            toolIds: ['web'],
            capabilities: {'vision': true},
            params: {'temperature': 0.2},
          ),
        ),
      ),
    );
    await settle();
    expect(find.text('Handbook'), findsOneComponent);
    expect(find.text('Runbooks'), findsOneComponent);
    expect(
      find.text(t.app.workspaceModelSelectCount(count: 1)),
      findsNComponents(2),
    );
    expect(find.text('vision'), findsOneComponent);
    expect(find.textContaining('"temperature": 0.2'), findsOneComponent);
  }, url: '/workspace/models/helper');

  testComponents('a tool opens its valves from their schema', (tester) async {
    tester.pumpComponent(
      app(
        (fake) => fake.details['tools/web'] = const WorkspaceDetail(
          kind: WorkspaceKind.tools,
          tool: WorkspaceToolDto(
            id: 'web',
            name: 'Web',
            content: 'class Tools: pass',
            functions: ['fetch'],
            hasValves: true,
            requiresServerVersion: '0.12.0',
          ),
        ),
      ),
    );
    await settle();
    expect(find.text('fetch'), findsOneComponent);
    expect(
      find.text(t.app.workspaceToolManifestRequiredVersion(version: '0.12.0')),
      findsOneComponent,
    );
    await tester.click(buttonWith(t.app.workspaceToolValvesServer));
    await settle();
    expect(find.text('Limit'), findsOneComponent);
    expect(find.text('How many'), findsOneComponent);
    expect(find.text('${t.app.workspaceValveDefault}: 3'), findsOneComponent);
  }, url: '/workspace/tools/web');

  testComponents('a knowledge base browses its folders and files', (
    tester,
  ) async {
    tester.pumpComponent(
      app(
        (fake) => fake.details['knowledge/k1'] = const WorkspaceDetail(
          kind: WorkspaceKind.knowledge,
          knowledge: WorkspaceKnowledgeDto(id: 'k1', name: 'Handbook'),
        ),
      ),
    );
    await settle();
    expect(find.text('notes.txt'), findsOneComponent);
    expect(find.text('2.0 KB'), findsOneComponent);
    expect(find.text('scan.pdf'), findsOneComponent);
    expect(
      buttonWith(t.desktop.desktopWorkspaceCleanupFailed),
      findsOneComponent,
    );

    await tester.click(buttonWith('📁 Guides'));
    await settle();
    expect(actions.openedFolders.last, 'd1');
    expect(find.text('setup.md'), findsOneComponent);
    // Back to the top through the breadcrumb.
    await tester.click(buttonWith(t.app.workspaceKnowledgeRoot));
    await settle();
    expect(actions.openedFolders.last, '');
  }, url: '/workspace/knowledge/k1');
}
