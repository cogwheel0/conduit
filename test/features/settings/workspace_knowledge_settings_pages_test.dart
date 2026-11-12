import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit/features/settings/pages/workspace_knowledge_settings_pages.dart';
import 'package:conduit/features/settings/pages/workspace_page_ids.dart';
import 'package:conduit/features/settings/pages/workspace_settings_pages.dart';
import 'package:conduit/features/settings/settings_page_module.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:conduit/features/workspace/widgets/workspace_export_controller.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/features/workspace/providers/workspace_knowledge_files.dart';
import 'package:conduit_core/features/workspace/providers/workspace_providers.dart';
import 'package:conduit_core/models/file_info.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
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

User _user({String id = 'owner', String role = 'user'}) =>
    User(id: id, username: 'ada', email: 'ada@example.com', role: role);

const _newBase = '$workspaceKnowledgePagePrefix$workspaceNewKey';
final _base1 = workspaceKnowledgePageId('kb-1');
final _key = workspaceEditorKey('kb-1');
final _root = workspaceKnowledgeFolderPageId(_key, '');

WorkspaceKnowledgeSummary _summary({
  String id = 'kb-1',
  bool writeAccess = true,
  bool external = false,
  String userId = 'owner',
  Map<String, dynamic> meta = const {},
}) => WorkspaceKnowledgeSummary(
  id: id,
  name: 'Trail Notes',
  description: 'Hiking guides',
  userId: userId,
  writeAccess: writeAccess,
  meta: {if (external) 'source': 'external', ...meta},
);

const _folder = WorkspaceKnowledgeDirectory(
  id: 'dir-1',
  knowledgeId: 'kb-1',
  name: 'Maps',
  userId: 'owner',
);

const _file = WorkspaceKnowledgeFile(
  id: 'file-1',
  filename: 'route.txt',
  size: 2048,
);

FileInfo _serverFile(String id, String name) => FileInfo(
  id: id,
  filename: name,
  originalFilename: name,
  size: 12,
  mimeType: 'text/plain',
  createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
);

final class _Knowledge extends WorkspaceKnowledge {
  _Knowledge([this.items = const []]);

  final List<WorkspaceKnowledgeSummary> items;
  final created = <WorkspaceKnowledgeForm>[];
  final updated = <WorkspaceKnowledgeForm>[];
  final resetIds = <String>[];
  final deleted = <String>[];
  final views = <String>[];
  final sources = <String>[];
  Completer<void>? saveGate;

  @override
  Future<WorkspaceCollectionState<WorkspaceKnowledgeSummary>> build() async =>
      WorkspaceCollectionState(items: items, total: items.length);

  @override
  Future<WorkspaceKnowledgeDetail> create(WorkspaceKnowledgeForm form) async {
    created.add(form);
    await saveGate?.future;
    // As Open WebUI answers a create: without what the account may do.
    return WorkspaceKnowledgeDetail(
      summary: WorkspaceKnowledgeSummary(
        id: 'kb-new',
        name: form.name,
        userId: 'owner',
      ),
    );
  }

  @override
  Future<WorkspaceKnowledgeDetail> updateItem(
    String id,
    WorkspaceKnowledgeForm form,
  ) async {
    updated.add(form);
    return WorkspaceKnowledgeDetail(summary: _summary());
  }

  @override
  Future<WorkspaceKnowledgeDetail> reset(
    String id, {
    bool includeDirectories = true,
  }) async {
    resetIds.add(id);
    return WorkspaceKnowledgeDetail(summary: _summary());
  }

  @override
  Future<void> delete(String id) async => deleted.add(id);

  @override
  Future<List<int>> export(String id) async => [1, 2, 3];

  @override
  Future<void> setView(String view) async => views.add(view);

  @override
  Future<void> setSource(String source) async => sources.add(source);

  @override
  Future<void> refresh() async {}
}

/// A base's files: [folders] and [files] at the top level, and the
/// contents of each folder by id.
final class _Files extends WorkspaceKnowledgeFiles {
  _Files({
    this.folders = const [_folder],
    this.files = const [_file],
    this.inside = const {},
    this.more = false,
  });

  /// Whether the server holds more files than the first page.
  final bool more;
  int loadedMore = 0;

  /// Thrown by the first read while set.
  Object? buildError;

  final List<WorkspaceKnowledgeDirectory> folders;
  final List<WorkspaceKnowledgeFile> files;
  final Map<String, List<WorkspaceKnowledgeFile>> inside;
  final opened = <String>[];
  final uploaded = <List<String>>[];
  final detached = <(String, bool)>[];
  final made = <String>[];
  final renamed = <(String, String)>[];
  final moved = <(String, String?)>[];
  final attached = <String>[];
  final texts = <(String, String)>[];
  Object? failure;

  WorkspaceKnowledgeBrowserState _at(String directoryId) {
    final listed = directoryId.isEmpty
        ? files
        : inside[directoryId] ?? const <WorkspaceKnowledgeFile>[];
    return WorkspaceKnowledgeBrowserState(
      directoryId: directoryId,
      directories: directoryId.isEmpty ? folders : const [],
      files: listed,
      breadcrumbs: directoryId.isEmpty ? const [] : const [_folder],
      total: more ? listed.length + 1 : listed.length,
    );
  }

  @override
  Future<WorkspaceKnowledgeBrowserState> build(String knowledgeId) async {
    final error = buildError;
    if (error != null) throw error;
    return _at('');
  }

  @override
  Future<void> loadMore() async => loadedMore++;

  @override
  Future<void> openDirectory(String directoryId) async {
    opened.add(directoryId);
    final error = openError;
    if (error != null) {
      // As the provider keeps the last folder's entries on a failed read.
      state = AsyncData(
        state.requireValue.copyWith(directoryId: directoryId, error: error),
      );
      throw error;
    }
    state = AsyncData(_at(directoryId));
  }

  /// Thrown by [openDirectory] while set.
  Object? openError;

  void _maybeFail() {
    final error = failure;
    if (error != null) throw error;
  }

  @override
  Future<void> uploadMany(List<WorkspaceUploadSource> picked) async {
    _maybeFail();
    uploaded.add([for (final file in picked) file.name]);
  }

  @override
  Future<void> detach(String fileId, {required bool deleteUnderlying}) async =>
      detached.add((fileId, deleteUnderlying));

  @override
  Future<void> createDirectory(String name) async {
    _maybeFail();
    made.add(name);
  }

  @override
  Future<void> rename(String fileId, String filename) async =>
      renamed.add((fileId, filename));

  @override
  Future<void> move(String fileId, String? directoryId) async =>
      moved.add((fileId, directoryId));

  @override
  Future<void> attachExisting(String fileId) async {
    _maybeFail();
    attached.add(fileId);
  }

  @override
  Future<void> addTextFile(String filename, String content) async =>
      texts.add((filename, content));

  @override
  Future<void> refresh() async {}

  @override
  Future<void> refreshPending() async {}
}

/// Who is signed in, when a test switches to another account.
final class _SignedIn extends Notifier<User?> {
  @override
  User? build() => null;

  void use(User user) => state = user;
}

final _signedInProvider = NotifierProvider<_SignedIn, User?>(_SignedIn.new);

final class _UserFiles extends UserFiles {
  _UserFiles(this.files);

  final List<FileInfo> files;

  @override
  Future<List<FileInfo>> build() async {
    // Another account's files cannot be read here.
    if (ref.watch(currentUserProvider2)?.id == 'user-2') {
      throw StateError('offline');
    }
    return files;
  }
}

/// Settings as the pages see it: each question is answered with [answer].
final class _Surface extends SettingsSurface {
  _Surface(super.ref);

  final asked = <List<String>>[];
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
    asked.add([for (final action in actions) action.id]);
    return answer;
  }
}

final class _Export extends WorkspaceExportController {
  final shared = <String>[];

  @override
  Future<ShareResult> shareBytes({
    required String filename,
    required List<int> bytes,
    String? mimeType,
    String? subject,
    Rect? sharePositionOrigin,
  }) async {
    shared.add(filename);
    return const ShareResult('ok', ShareResultStatus.success);
  }
}

final class _Rig {
  _Rig(this.tester, this.container, this.surface, this.export);

  final WidgetTester tester;
  final ProviderContainer container;
  final _Surface surface;
  final _Export export;

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

  List<String> titles(String pageId) =>
      rows(pageId).map((r) => r.title).toList();

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

  /// A row change handed to the modules without waiting for it.
  Future<void> send(String id, [Object? value = true]) async {
    for (final module in container.read(settingsPageModulesProvider)) {
      if (await module.handleChange(id, value, _l10n)) return;
    }
  }

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

String _row(String field, [String? key, String? extra]) =>
    workspaceRowId('knowledge-$field', key ?? workspaceNewKey, extra);

String _form(String kind, String target) =>
    workspaceKnowledgeFormPageId(kind, _key, target);

String _formRow(String field, String kind, String target) =>
    _row('form-$field', _key, '$kind|$target');

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
    _Knowledge? knowledge,
    _Files? files,
    WorkspaceKnowledgeSummary? base,
    User? user,
    bool limits = true,
    WorkspaceCapabilities capabilities = WorkspaceCapabilities.all,
    List<WorkspaceUploadSource> picked = const [],
    List<FileInfo> userFiles = const [],
    bool newBaseReadable = true,
  }) async {
    late final _Surface surface;
    final export = _Export();
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        currentUserProvider2.overrideWith(
          (ref) => ref.watch(_signedInProvider) ?? user ?? _user(),
        ),
        apiServiceProvider.overrideWithValue(api),
        authTokenProvider3.overrideWithValue('token-a'),
        activeServerProvider.overrideWith((ref) async => _server),
        knowledgeLimitsSupportedProvider.overrideWithValue(limits),
        workspaceCapabilitiesProvider.overrideWith((ref) async => capabilities),
        workspaceKnowledgeProvider.overrideWith(
          () => knowledge ?? _Knowledge(),
        ),
        workspaceKnowledgeDetailProvider('kb-1').overrideWith(
          (ref) async => WorkspaceKnowledgeDetail(summary: base ?? _summary()),
        ),
        workspaceKnowledgeDetailProvider('kb-new').overrideWith(
          (ref) async => newBaseReadable
              ? WorkspaceKnowledgeDetail(
                  summary: _summary(id: 'kb-new', userId: 'owner'),
                )
              : throw StateError('offline'),
        ),
        workspaceKnowledgeFilesProvider('kb-1')
            .overrideWith(() => files ?? _Files()),
        workspaceKnowledgeFilesProvider('kb-new')
            .overrideWith(() => _Files(folders: const [], files: const [])),
        userFilesProvider.overrideWith(() => _UserFiles(userFiles)),
        workspaceKnowledgeFilePickerProvider.overrideWithValue(
          () async => picked,
        ),
        settingsSurfaceProvider.overrideWith((ref) => surface = _Surface(ref)),
        workspaceExportControllerProvider.overrideWithValue(export),
      ],
    );
    addTearDown(container.dispose);
    container.read(settingsSurfaceProvider);
    container.listen(workspaceCapabilitiesProvider, (_, _) {});
    container.listen(activeServerProvider, (_, _) {});
    final rig = _Rig(tester, container, surface, export);
    await rig.settle(Future<void>.value());
    return rig;
  }

  group('the Knowledge list', () {
    final list = workspaceSectionPageId(WorkspaceSection.knowledge);

    testWidgets('filters by whose bases and where they come from', (
      tester,
    ) async {
      final knowledge = _Knowledge([_summary()]);
      final rig = await pump(tester, knowledge: knowledge);
      await rig.open(list);

      final view = rig.row(list, workspaceRowId('list-view', 'knowledge'))!;
      check(view.kind).equals(NativeSheetItemKind.segment);
      check(view.options.map((option) => option.id))
          .deepEquals(['', 'created', 'shared']);
      final base = rig.row(list, _base1)!;
      check(base.subtitle!).contains(_l10n.workspaceKnowledgeSourceLocal);

      await rig.change(workspaceRowId('list-view', 'knowledge'), 'shared');
      await rig.change(workspaceRowId('list-source', 'knowledge'), 'external');
      check(knowledge.views).deepEquals(['shared']);
      check(knowledge.sources).deepEquals(['external']);
    });

    testWidgets('a base offers Delete from its menu, and nothing to switch '
        'off; a connected one offers neither', (tester) async {
      final knowledge = _Knowledge([
        _summary(),
        _summary(id: 'kb-2', external: true),
      ]);
      final rig = await pump(tester, knowledge: knowledge);
      await rig.open(list);

      check(rig.row(list, _base1)!.rowActions.map((action) => action.id))
          .deepEquals([workspaceRowId('list-delete', 'knowledge', 'kb-1')]);
      check(rig.row(list, workspaceKnowledgePageId('kb-2'))!.rowActions)
          .isEmpty();

      await rig.change(workspaceRowId('list-delete', 'knowledge', 'kb-1'));
      check(knowledge.deleted).deepEquals(['kb-1']);
    });

    testWidgets('a delete is not sent once another account signed in while '
        'its row was drawn busy', (tester) async {
      final knowledge = _Knowledge([_summary()]);
      final rig = await pump(tester, knowledge: knowledge);
      await rig.open(list);
      final gate = rig.surface.gate = Completer<void>();

      final deleting = rig.container
          .read(settingsPageModulesProvider)
          .whereType<WorkspaceSettingsPages>()
          .single
          .handleChange(
            workspaceRowId('list-delete', 'knowledge', 'kb-1'),
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
      await rig.settle(deleting);

      check(knowledge.deleted).isEmpty();
    });
  });

  group("a base's editor", () {
    testWidgets('makes a base, then stays as its page with its files', (
      tester,
    ) async {
      final knowledge = _Knowledge();
      final rig = await pump(tester, knowledge: knowledge);
      await rig.open(_newBase);
      check(rig.page(_newBase).confirmActionLabel)
          .equals(_l10n.workspaceCreate);
      check(rig.titles(_newBase))
          .not((it) => it.contains(_l10n.workspaceKnowledgeFilesTitle));

      await rig.change(_row('name'), 'Trail Notes');
      await rig.change(_row('description'), 'Hiking guides');
      await rig.change(_row('save'));

      check(knowledge.created.single.name).equals('Trail Notes');
      check(knowledge.created.single.description).equals('Hiking guides');
      check(rig.closed).isEmpty();
      check(rig.titles(_newBase)).contains(_l10n.workspaceKnowledgeFilesTitle);
      check(rig.page(_newBase).announcement)
          .equals(_l10n.workspaceKnowledgeSaved);
      // Read again, the new base is one its maker may change.
      check(rig.row(_newBase, _row('name'))!.kind)
          .equals(NativeSheetItemKind.textField);
    });

    testWidgets('a new base that cannot be read again is still its '
        "maker's to change", (tester) async {
      final rig = await pump(tester, newBaseReadable: false);
      await rig.open(_newBase);

      await rig.change(_row('name'), 'Trail Notes');
      await rig.change(_row('save'));

      check(rig.row(_newBase, _row('name'))!.kind)
          .equals(NativeSheetItemKind.textField);
      check(rig.page(_newBase).confirmActionId).isNotNull();
    });

    testWidgets('saves nothing without a name', (tester) async {
      final knowledge = _Knowledge();
      final rig = await pump(tester, knowledge: knowledge);
      await rig.open(_newBase);

      await rig.change(_row('save'));

      check(knowledge.created).isEmpty();
      check(rig.page(_newBase).announcement)
          .equals(_l10n.workspaceKnowledgeNameRequired);
    });

    group('its file limits', () {
      testWidgets('a new base is made with the limits typed', (tester) async {
        final knowledge = _Knowledge();
        final rig = await pump(tester, knowledge: knowledge);
        await rig.open(_newBase);

        await rig.change(_row('name'), 'Trail Notes');
        await rig.change(_row('max-count'), '25');
        await rig.change(_row('save'));

        check(knowledge.created.single.limits)
            .equals((maxFileCount: 25, maxFileSize: null));
      });

      testWidgets('a limit that is not a whole number above zero is refused', (
        tester,
      ) async {
        final knowledge = _Knowledge();
        final rig = await pump(tester, knowledge: knowledge);
        await rig.open(_newBase);

        await rig.change(_row('name'), 'Trail Notes');
        await rig.change(_row('max-size'), '0');
        await rig.change(_row('save'));

        check(knowledge.created).isEmpty();
        check(rig.page(_newBase).announcement)
            .equals(_l10n.workspaceKnowledgeLimitInvalid);
      });

      testWidgets("the owner edits the base's limits, then goes back", (
        tester,
      ) async {
        final knowledge = _Knowledge();
        final rig = await pump(
          tester,
          knowledge: knowledge,
          base: _summary(meta: {'max_file_count': 10}),
        );
        await rig.open(_base1);
        check(rig.row(_base1, _row('max-count', _key))!.value).equals('10');

        await rig.change(_row('max-count', _key), '');
        await rig.change(_row('max-size', _key), '50');
        await rig.change(_row('save', _key));

        check(knowledge.updated.single.limits)
            .equals((maxFileCount: null, maxFileSize: 50));
        check(rig.closed).deepEquals([_base1]);
      });

      testWidgets('only the owner or an admin, on a server that has them, '
          'sees them', (tester) async {
        final someone = await pump(tester, user: _user(id: 'someone-else'));
        await someone.open(_base1);
        check(someone.row(_base1, _row('max-count', _key))).isNull();

        final admin = await pump(
          tester,
          user: _user(id: 'someone-else', role: 'admin'),
        );
        await admin.open(_base1);
        check(admin.row(_base1, _row('max-count', _key))).isNotNull();

        final older = await pump(tester, limits: false);
        await older.open(_base1);
        check(older.row(_base1, _row('max-count', _key))).isNull();
      });
    });

    testWidgets('resets and deletes the base once agreed', (tester) async {
      final knowledge = _Knowledge();
      final rig = await pump(tester, knowledge: knowledge);
      await rig.open(_base1);
      final reset = rig.row(_base1, _row('reset', _key))!;
      check(reset.confirmMessage)
          .equals(_l10n.workspaceKnowledgeResetConfirmMessage('Trail Notes'));

      await rig.change(_row('reset', _key));
      check(knowledge.resetIds).deepEquals(['kb-1']);
      check(rig.page(_base1).announcement)
          .equals(_l10n.workspaceKnowledgeResetDone);

      await rig.change(_row('delete', _key));
      check(knowledge.deleted).deepEquals(['kb-1']);
      check(rig.closed).deepEquals([_base1]);
    });

    testWidgets('exports the base through the share sheet', (tester) async {
      final rig = await pump(tester);
      await rig.open(_base1);

      await rig.change(_row('export', _key));

      // A ZIP, as Open WebUI exports a base.
      check(rig.export.shared).deepEquals(['Trail Notes.zip']);
    });

    testWidgets("an editor kept from another account is not shown to the "
        'next', (tester) async {
      final rig = await pump(tester);
      await rig.open(_base1);
      await rig.change(_row('name', _key), 'Private Trail');

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
      await rig.open(_base1);

      check(rig.row(_base1, _row('name', _key))?.value)
          .not((it) => it.equals('Private Trail'));
    });

    testWidgets('a connected base reads without fields or file changes', (
      tester,
    ) async {
      final rig = await pump(tester, base: _summary(external: true));
      await rig.open(_base1);

      check(rig.page(_base1).confirmActionId).isNull();
      check(rig.row(_base1, _row('name', _key))!.kind)
          .equals(NativeSheetItemKind.readOnlyText);
      check(rig.row(_base1, _row('delete', _key))).isNull();

      await rig.open(_root);
      check(rig.row(_root, _row('upload', _key, ''))).isNull();
      check(rig.row(_root, '$_root-file-file-1')!.rowActions).isEmpty();
    });

    testWidgets('a save that lands after the editor was left changes '
        'nothing', (tester) async {
      final knowledge = _Knowledge()..saveGate = Completer<void>();
      final rig = await pump(tester, knowledge: knowledge);
      await rig.open(_newBase);
      await rig.change(_row('name'), 'Trail Notes');
      final saving = rig.send(_row('save'));
      await rig.settle(Future<void>.value());

      rig.leave(_newBase);
      knowledge.saveGate!.complete();
      await rig.settle(saving);

      check(knowledge.created).length.equals(1);
      check(rig.titles(_newBase))
          .not((it) => it.contains(_l10n.workspaceKnowledgeFilesTitle));
    });
  });

  group("a base's files", () {
    Future<_Rig> files(
      WidgetTester tester, {
      _Files? browser,
      User? user,
      List<WorkspaceUploadSource> picked = const [],
      List<FileInfo> userFiles = const [],
    }) async {
      final rig = await pump(
        tester,
        files: browser,
        user: user,
        picked: picked,
        userFiles: userFiles,
      );
      await rig.open(_base1);
      await rig.open(_root);
      return rig;
    }

    testWidgets('list the folders, each a page of its own, and the files', (
      tester,
    ) async {
      final browser = _Files(
        inside: const {
          'dir-1': [WorkspaceKnowledgeFile(id: 'file-2', filename: 'peak.txt')],
        },
      );
      final rig = await files(tester, browser: browser);

      check(rig.titles(_root)).deepEquals([
        'Maps',
        'route.txt',
        _l10n.workspaceKnowledgeUploadFiles,
        _l10n.workspaceKnowledgeAttachExisting,
        _l10n.workspaceKnowledgeAddText,
        _l10n.workspaceKnowledgeNewFolder,
      ]);
      check(rig.row(_root, '$_root-file-file-1')!.subtitle).equals('2.0 KB');

      // Every page its rows open is known, with a title, which the native
      // sheet needs to open it.
      for (final kind in [
        WorkspaceKnowledgeForms.attach,
        WorkspaceKnowledgeForms.text,
        WorkspaceKnowledgeForms.folder,
      ]) {
        check(rig.container.read(settingsPagesProvider)[_form(kind, '')])
            .isNotNull()
            .has((page) => page.title, 'title')
            .isNotEmpty();
      }

      final maps = workspaceKnowledgeFolderPageId(_key, 'dir-1');
      await rig.open(maps);
      check(browser.opened).deepEquals(['dir-1']);
      check(rig.page(maps).title).equals('Maps');
      check(rig.titles(maps)).contains('peak.txt');
    });

    testWidgets('an empty folder says so', (tester) async {
      final rig = await files(
        tester,
        browser: _Files(folders: const [], files: const []),
      );

      check(rig.titles(_root).first).equals(_l10n.workspaceKnowledgeFilesEmpty);
    });

    testWidgets('uploads the files picked, and says why the base refused', (
      tester,
    ) async {
      final browser = _Files();
      final picked = <WorkspaceUploadSource>[
        (name: 'one.txt', size: 3, read: () async => [1, 2, 3]),
        (name: 'two.txt', size: 2, read: () async => [4, 5]),
      ];
      final rig = await files(tester, browser: browser, picked: picked);

      await rig.change(_row('upload', _key, ''));
      check(browser.uploaded).deepEquals([
        ['one.txt', 'two.txt'],
      ]);

      browser.failure = const KnowledgeUploadRefused('Too many files.');
      await rig.change(_row('upload', _key, ''));
      final notice = rig.row(_root, '$_root-notice')!;
      check(notice.title).equals('Too many files.');
      check(notice.sfSymbol).equals('exclamationmark.triangle');
    });

    testWidgets('the owner may also delete a file it removes; another may '
        'not', (tester) async {
      final browser = _Files();
      final rig = await files(tester, browser: browser);
      rig.surface.answer = 'delete';

      await rig.change(_row('detach', _key, 'file-1'));

      check(rig.surface.asked.single)
          .deepEquals(['cancel', 'detach', 'delete']);
      check(browser.detached).deepEquals([('file-1', true)]);

      final other = _Files();
      final shared = await files(
        tester,
        browser: other,
        user: _user(id: 'someone-else'),
      );
      shared.surface.answer = 'detach';
      await shared.change(_row('detach', _key, 'file-1'));
      check(shared.surface.asked.single).deepEquals(['cancel', 'detach']);
      check(other.detached).deepEquals([('file-1', false)]);
    });

    testWidgets('a folder is made from its form, which then closes', (
      tester,
    ) async {
      final browser = _Files();
      final rig = await files(tester, browser: browser);
      final form = _form(WorkspaceKnowledgeForms.folder, '');
      await rig.open(form);

      await rig.change(_formRow('done', WorkspaceKnowledgeForms.folder, ''));
      check(browser.made).isEmpty();
      check(rig.page(form).announcement)
          .equals(_l10n.workspaceKnowledgeNameRequired);

      await rig.change(
        _formRow('name', WorkspaceKnowledgeForms.folder, ''),
        'Summits',
      );
      check(rig.page(form).edited).isTrue();
      await rig.change(_formRow('done', WorkspaceKnowledgeForms.folder, ''));
      check(browser.made).deepEquals(['Summits']);
      check(rig.closed).deepEquals([form]);
    });

    testWidgets('a folder that cannot be made keeps its form with why', (
      tester,
    ) async {
      final browser = _Files()..failure = StateError('refused');
      final rig = await files(tester, browser: browser);
      final form = _form(WorkspaceKnowledgeForms.folder, '');
      await rig.open(form);

      await rig.change(
        _formRow('name', WorkspaceKnowledgeForms.folder, ''),
        'Summits',
      );
      await rig.change(_formRow('done', WorkspaceKnowledgeForms.folder, ''));

      check(rig.closed).isEmpty();
      check(rig.page(form).announcement)
          .equals(_l10n.workspaceKnowledgeFolderCreateFailed);
    });

    testWidgets('a file is renamed from a form that starts from its name', (
      tester,
    ) async {
      final browser = _Files();
      final rig = await files(tester, browser: browser);
      final form = _form(WorkspaceKnowledgeForms.renameFile, 'file-1');
      // The file's menu opens the form.
      check(rig.row(_root, '$_root-file-file-1')!.rowActions.map((a) => a.id))
          .contains(form);
      await rig.open(form);
      final name = _formRow(
        'name',
        WorkspaceKnowledgeForms.renameFile,
        'file-1',
      );
      check(rig.row(form, name)!.value).equals('route.txt');
      // Untouched, the name it opened with is no change to ask about.
      check(rig.page(form).edited).isFalse();

      // Typed into, it keeps the text through the folder drawn again.
      await rig.change(name, 'trail.txt');
      await rig.open(_root);
      check(rig.row(form, name)!.value).equals('trail.txt');

      await rig.change(name, 'trail.txt');
      await rig.change(
        _formRow('done', WorkspaceKnowledgeForms.renameFile, 'file-1'),
      );

      check(browser.renamed).deepEquals([('file-1', 'trail.txt')]);
    });

    testWidgets('a connected base pages through its files too', (tester) async {
      final browser = _Files(more: true);
      final rig = await pump(
        tester,
        base: _summary(external: true),
        files: browser,
      );
      await rig.open(_base1);
      await rig.open(_root);

      await rig.change(_row('files-more', _key, ''));

      check(browser.loadedMore).equals(1);
    });

    testWidgets('Retry reads a folder that failed once', (tester) async {
      final browser = _Files()..buildError = StateError('offline');
      final rig = await files(tester, browser: browser);
      check(rig.row(_root, _row('files-retry', _key, ''))).isNotNull();

      browser.buildError = null;
      await rig.change(_row('files-retry', _key, ''), true);

      check(rig.row(_root, '$_root-file-file-1')).isNotNull();
    });

    testWidgets('a file moves to the folder picked', (tester) async {
      final browser = _Files();
      final rig = await files(tester, browser: browser);
      final form = _form(WorkspaceKnowledgeForms.move, 'file-1');
      await rig.open(form);

      check(rig.titles(form))
          .deepEquals([_l10n.workspaceKnowledgeMoveRoot, 'Maps']);
      await rig.change(_row('move-to', _key, 'file-1|dir-1'));

      check(browser.moved).deepEquals([('file-1', 'dir-1')]);
      check(rig.closed).deepEquals([form]);
    });

    testWidgets("adds a text file, and attaches one of the account's", (
      tester,
    ) async {
      final browser = _Files();
      final rig = await files(
        tester,
        browser: browser,
        userFiles: [_serverFile('srv-1', 'gear.md')],
      );
      final text = _form(WorkspaceKnowledgeForms.text, '');
      await rig.open(text);
      await rig.change(
        _formRow('name', WorkspaceKnowledgeForms.text, ''),
        'notes.txt',
      );
      await rig.change(
        _formRow('content', WorkspaceKnowledgeForms.text, ''),
        'Bring water.',
      );
      await rig.change(_formRow('done', WorkspaceKnowledgeForms.text, ''));
      check(browser.texts).deepEquals([('notes.txt', 'Bring water.')]);

      final attach = _form(WorkspaceKnowledgeForms.attach, '');
      await rig.open(attach);
      check(rig.titles(attach)).deepEquals(['gear.md']);
      await rig.change(_row('attach-pick', _key, '|srv-1'));
      check(browser.attached).deepEquals(['srv-1']);
      check(rig.closed).deepEquals([text, attach]);
    });

    testWidgets('a folder that cannot be read offers Retry, not the last '
        "folder's files", (tester) async {
      final browser = _Files()..openError = StateError('offline');
      final rig = await files(tester, browser: browser);
      final maps = workspaceKnowledgeFolderPageId(_key, 'dir-1');

      await rig.open(maps);

      check(rig.row(maps, _row('files-retry', _key, 'dir-1'))).isNotNull();
      check(rig.row(maps, '$maps-file-file-1')).isNull();
    });

    testWidgets("another account's Attach form shows none of the last one's "
        'files', (tester) async {
      final rig = await files(
        tester,
        userFiles: [_serverFile('srv-1', 'gear.md')],
      );
      final attach = _form(WorkspaceKnowledgeForms.attach, '');
      await rig.open(attach);
      check(rig.titles(attach)).deepEquals(['gear.md']);
      rig.leave(attach);

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
      await rig.open(attach);

      check(rig.titles(attach)).not((it) => it.contains('gear.md'));
    });

    testWidgets('a form left keeps nothing typed into it', (tester) async {
      final rig = await files(tester);
      final form = _form(WorkspaceKnowledgeForms.folder, '');
      await rig.open(form);
      final name = _formRow('name', WorkspaceKnowledgeForms.folder, '');
      await rig.change(name, 'Summits');

      rig.leave(form);
      await rig.open(form);

      check(rig.row(form, name)!.value).equals('');
    });
  });
}
