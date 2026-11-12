import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher, Offset, Rect;

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/models/workspace_collection_view.dart';
import 'package:conduit_core/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit_core/features/workspace/models/workspace_prompt_command.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/features/workspace/models/workspace_transfer.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/features/workspace/providers/workspace_providers.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/utils/native_sheet_utils.dart';
import '../../../shared/services/navigation_service.dart';
import '../../workspace/widgets/workspace_export_controller.dart';
import '../../workspace/workspace_navigation.dart'
    show workspaceSectionsInFlutter, workspaceSectionsInSettings;
import '../../workspace/widgets/workspace_import_sheet.dart'
    show runWorkspaceImport, WorkspaceImportReport;
import '../settings_page_module.dart';
import '../settings_pages.dart';
import 'workspace_page_ids.dart';

String workspaceSectionTitle(AppLocalizations l10n, WorkspaceSection section) =>
    switch (section) {
      WorkspaceSection.models => l10n.workspaceModels,
      WorkspaceSection.knowledge => l10n.workspaceKnowledge,
      WorkspaceSection.prompts => l10n.workspacePrompts,
      WorkspaceSection.tools => l10n.workspaceTools,
      WorkspaceSection.skills => l10n.workspaceSkills,
    };

String workspaceSectionSymbol(WorkspaceSection section) => switch (section) {
  WorkspaceSection.models => 'cube',
  WorkspaceSection.knowledge => 'books.vertical',
  WorkspaceSection.prompts => 'text.quote',
  WorkspaceSection.tools => 'wrench.and.screwdriver',
  WorkspaceSection.skills => 'graduationcap',
};

/// The editor page of resource [id] of [section], or of a new one when [id]
/// is null.
String workspaceEditorPageId(WorkspaceSection section, String? id) =>
    switch (section) {
      WorkspaceSection.models => workspaceModelPageId(id),
      WorkspaceSection.knowledge => workspaceKnowledgePageId(id),
      WorkspaceSection.prompts => workspacePromptPageId(id),
      // Still opened over the app; never a page of Settings yet.
      WorkspaceSection.tools || WorkspaceSection.skills => '',
    };

/// The title of the editor making a new resource of [section].
String workspaceNewTitle(AppLocalizations l10n, WorkspaceSection section) =>
    switch (section) {
      WorkspaceSection.models => l10n.workspaceModelNewTitle,
      WorkspaceSection.knowledge => l10n.workspaceKnowledgeCreateTitle,
      WorkspaceSection.prompts => l10n.workspacePromptCreateTitle,
      WorkspaceSection.tools || WorkspaceSection.skills => l10n.workspaceCreate,
    };

WorkspaceSectionCapabilities workspaceSectionCapabilities(
  WorkspaceCapabilities? capabilities,
  WorkspaceSection section,
) {
  if (capabilities == null) return WorkspaceSectionCapabilities.none;
  return switch (section) {
    WorkspaceSection.models => capabilities.models,
    WorkspaceSection.knowledge => capabilities.knowledge,
    WorkspaceSection.prompts => capabilities.prompts,
    WorkspaceSection.tools => capabilities.tools,
    WorkspaceSection.skills => capabilities.skills,
  };
}

// -- The hub ------------------------------------------------------------------

/// What the Workspace page shows: the sections the account may manage, or
/// why there are none.
@immutable
@visibleForTesting
final class WorkspaceHubState {
  const WorkspaceHubState({required this.gate, this.permitted = const []});

  /// [WorkspaceGateStatus.ready] once the capabilities say which sections
  /// the account may manage.
  final WorkspaceGateStatus gate;
  final List<WorkspaceSection> permitted;
}

/// Reads the hub's state: denied in reviewer mode, and fail-closed while the
/// capabilities load or after they fail.
WorkspaceHubState readWorkspaceHubState(Ref ref) {
  if (ref.read(reviewerModeProvider)) {
    return const WorkspaceHubState(gate: WorkspaceGateStatus.denied);
  }
  return ref
      .read(workspaceCapabilitiesProvider)
      .when(
        loading: () =>
            const WorkspaceHubState(gate: WorkspaceGateStatus.loading),
        error: (error, _) => WorkspaceHubState(
          gate: isWorkspaceUnsupportedError(error)
              ? WorkspaceGateStatus.unsupported
              : WorkspaceGateStatus.error,
        ),
        data: (value) {
          final permitted = permittedWorkspaceSections(value);
          return WorkspaceHubState(
            gate: permitted.isEmpty
                ? WorkspaceGateStatus.denied
                : WorkspaceGateStatus.ready,
            permitted: permitted,
          );
        },
      );
}

/// The rows standing for why the Workspace cannot be shown, with Retry
/// where reading again could help; empty once it can.
List<NativeSheetItemConfig> _gateRows(
  AppLocalizations l10n,
  String pageId,
  WorkspaceGateStatus gate,
) => switch (gate) {
  WorkspaceGateStatus.ready => const [],
  WorkspaceGateStatus.loading => [
    buildNativeLoadingItem(l10n, id: '$pageId-loading'),
  ],
  WorkspaceGateStatus.denied => [
    workspaceNote('$pageId-denied', l10n.workspaceDenied, 'lock'),
  ],
  WorkspaceGateStatus.unsupported => [
    workspaceNote(
      '$pageId-unsupported',
      l10n.workspaceUnsupported,
      'icloud.slash',
    ),
  ],
  WorkspaceGateStatus.error => [
    NativeSheetItemConfig(
      id: workspaceRowId('gate-retry', 'hub'),
      title: l10n.workspaceLoadFailed,
      subtitle: l10n.workspaceRetry,
      sfSymbol: 'exclamationmark.triangle',
      showsDisclosure: false,
    ),
  ],
};

/// The Workspace's page of Settings: a row per section the account may
/// manage. Models and Prompts open pages of Settings's own; the others
/// open the Workspace's pages over the app.
@visibleForTesting
NativeSheetDetailConfig buildWorkspaceHubPage(
  AppLocalizations l10n,
  WorkspaceHubState state,
) {
  const pageId = workspaceHubPageId;
  final gate = _gateRows(l10n, pageId, state.gate);
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.workspaceTitle,
    subtitle: l10n.workspaceSubtitle,
    sections: [
      if (gate.isNotEmpty)
        NativeSheetSectionConfig(items: gate)
      else
        NativeSheetSectionConfig(
          items: [
            for (final section in state.permitted)
              if (workspaceSectionsInSettings.contains(section))
                NativeSheetItemConfig(
                  id: workspaceSectionPageId(section),
                  title: workspaceSectionTitle(l10n, section),
                  sfSymbol: workspaceSectionSymbol(section),
                )
              else
                NativeSheetItemConfig(
                  id: workspaceRowId('open', 'hub', section.name),
                  title: workspaceSectionTitle(l10n, section),
                  sfSymbol: workspaceSectionSymbol(section),
                  // Opens over the app, as Settings closes.
                  showsDisclosure: true,
                ),
          ],
        ),
    ],
  );
}

// -- A section's list ----------------------------------------------------------

/// One resource as a list row shows it.
@immutable
@visibleForTesting
final class WorkspaceListItem {
  const WorkspaceListItem({
    required this.id,
    required this.title,
    this.subtitle,
    required this.isActive,
    required this.writeAccess,
    this.avatarBytes,
    this.toggleable = true,
    this.external = false,
  });

  final String id;
  final String title;
  final String? subtitle;
  final bool isActive;
  final bool writeAccess;
  final Uint8List? avatarBytes;

  /// Whether it can be switched on and off; a knowledge base cannot.
  final bool toggleable;

  /// A knowledge base another service keeps, which this app only reads.
  final bool external;

  factory WorkspaceListItem.model(WorkspaceModelSummary model) {
    final row = workspaceCollectionRowText(model);
    return WorkspaceListItem(
      id: model.id,
      title: row.title.trim().isEmpty ? model.id : row.title,
      subtitle: row.subtitle,
      isActive: model.isActive,
      writeAccess: model.writeAccess,
      avatarBytes: workspaceDataUrlBytes(
        model.meta['profile_image_url']?.toString(),
      ),
    );
  }

  factory WorkspaceListItem.knowledge(WorkspaceKnowledgeSummary base) =>
      WorkspaceListItem(
        id: base.id,
        title: base.name.trim().isEmpty ? base.id : base.name,
        subtitle: base.description.trim().isEmpty ? null : base.description,
        isActive: true,
        writeAccess: base.writeAccess,
        toggleable: false,
        external: base.isExternal,
      );

  factory WorkspaceListItem.prompt(WorkspacePromptSummary prompt) =>
      WorkspaceListItem(
        id: prompt.id,
        title: prompt.name.trim().isEmpty
            ? WorkspacePromptCommand.display(prompt.command)
            : prompt.name,
        subtitle: prompt.command.isEmpty
            ? null
            : WorkspacePromptCommand.display(prompt.command),
        isActive: prompt.isActive,
        writeAccess: prompt.writeAccess,
      );
}

/// What a section's list shows.
@immutable
@visibleForTesting
final class WorkspaceListState {
  const WorkspaceListState({
    required this.section,
    this.gate = WorkspaceGateStatus.ready,
    this.items,
    this.loading = false,
    this.loadFailed = false,
    this.query = '',
    this.view = '',
    this.source = '',
    this.hasMore = false,
    this.loadingMore = false,
    this.capabilities = WorkspaceSectionCapabilities.none,
    this.busy = const {},
    this.running,
    this.notice,
    this.noticeIsError = false,
  });

  final WorkspaceSection section;
  final WorkspaceGateStatus gate;

  /// The resources read, or null before any could be.
  final List<WorkspaceListItem>? items;
  final bool loading;
  final bool loadFailed;
  final String query;

  /// Knowledge's filters: whose bases (`''`, `created`, `shared`) and from
  /// where (`''`, `local`, `external`).
  final String view;
  final String source;
  final bool hasMore;
  final bool loadingMore;
  final WorkspaceSectionCapabilities capabilities;

  /// Resources whose change from a row's menu is on its way.
  final Set<String> busy;

  /// The list-wide action under way: `import` or `export`.
  final String? running;
  final String? notice;
  final bool noticeIsError;
}

/// A Workspace section's list of resources: a search, the resources, and
/// rows adding, importing and exporting them as the account may.
@visibleForTesting
NativeSheetDetailConfig buildWorkspaceListPage(
  AppLocalizations l10n,
  WorkspaceListState state,
) {
  final section = state.section;
  final pageId = workspaceSectionPageId(section);
  final key = section.name;
  final title = workspaceSectionTitle(l10n, section);
  final gate = _gateRows(l10n, pageId, state.gate);
  if (gate.isNotEmpty) {
    return NativeSheetDetailConfig(id: pageId, title: title, items: gate);
  }
  final items = state.items;
  final caps = state.capabilities;
  final editorPageId = workspaceEditorPageId(section, null);
  final running = state.running;
  // Import and export of a whole section are for models and prompts.
  final transfers =
      section == WorkspaceSection.models || section == WorkspaceSection.prompts;
  return NativeSheetDetailConfig(
    id: pageId,
    title: title,
    announcement: state.notice,
    search: NativeSheetSearchConfig(
      id: workspaceRowId('list-search', key),
      placeholder: l10n.workspaceSearchHint,
      value: state.query,
    ),
    sections: [
      if (state.notice != null)
        NativeSheetSectionConfig(
          items: [
            state.noticeIsError
                ? workspaceWarning('$pageId-notice', state.notice!)
                : workspaceNote(
                    '$pageId-notice',
                    state.notice!,
                    'checkmark.circle',
                  ),
          ],
        ),
      if (section == WorkspaceSection.knowledge)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: workspaceRowId('list-view', key),
              title: l10n.scheduledTasksFilterLabel,
              sfSymbol: 'person.2',
              kind: NativeSheetItemKind.segment,
              value: state.view,
              options: [
                NativeSheetOptionConfig(
                  id: '',
                  label: l10n.workspaceKnowledgeViewAll,
                ),
                NativeSheetOptionConfig(
                  id: 'created',
                  label: l10n.workspaceKnowledgeViewCreated,
                ),
                NativeSheetOptionConfig(
                  id: 'shared',
                  label: l10n.workspaceKnowledgeViewShared,
                ),
              ],
            ),
            NativeSheetItemConfig(
              id: workspaceRowId('list-source', key),
              title: l10n.workspaceKnowledgeSourceLabel,
              sfSymbol: 'externaldrive',
              kind: NativeSheetItemKind.segment,
              value: state.source,
              options: [
                NativeSheetOptionConfig(
                  id: '',
                  label: l10n.workspaceKnowledgeSourceAll,
                ),
                NativeSheetOptionConfig(
                  id: 'local',
                  label: l10n.workspaceKnowledgeSourceLocal,
                ),
                NativeSheetOptionConfig(
                  id: 'external',
                  label: l10n.workspaceKnowledgeSourceExternal,
                ),
              ],
            ),
          ],
        ),
      NativeSheetSectionConfig(
        items: [
          // A list that could not be read, or read again while empty.
          if ((items == null || items.isEmpty) && state.loadFailed)
            NativeSheetItemConfig(
              id: workspaceRowId('list-retry', key),
              title: l10n.workspaceLoadFailed,
              subtitle: l10n.workspaceRetry,
              sfSymbol: 'exclamationmark.triangle',
              showsDisclosure: false,
            )
          else if (items == null || (state.loading && items.isEmpty))
            buildNativeLoadingItem(l10n, id: '$pageId-loading')
          else if (items.isEmpty)
            workspaceNote(
              '$pageId-empty',
              l10n.workspaceEmpty,
              workspaceSectionSymbol(section),
            )
          else
            for (final item in items)
              _listRow(l10n, section, item, busy: state.busy.contains(item.id)),
          if (items != null && state.hasMore)
            NativeSheetItemConfig(
              id: workspaceRowId('list-more', key),
              title: l10n.workspaceLoadMore,
              sfSymbol: 'arrow.down.circle',
              accent: true,
              showsDisclosure: false,
              pending: state.loadingMore ? true : null,
              disabled: state.loadingMore,
            ),
          if (items != null && items.isNotEmpty && state.loadFailed)
            workspaceWarning('$pageId-failed', l10n.workspaceLoadFailed),
        ],
      ),
      if (caps.manage || (transfers && (caps.importItems || caps.exportItems)))
        NativeSheetSectionConfig(
          items: [
            if (caps.manage)
              NativeSheetItemConfig(
                id: editorPageId,
                title: l10n.workspaceCreate,
                sfSymbol: 'plus.circle',
                accent: true,
              ),
            if (transfers && caps.importItems)
              NativeSheetItemConfig(
                id: workspaceRowId('list-import', key),
                title: section == WorkspaceSection.models
                    ? l10n.workspaceModelImport
                    : l10n.workspacePromptImport,
                sfSymbol: 'square.and.arrow.down',
                showsDisclosure: false,
                pending: running == 'import' ? true : null,
                disabled: running != null,
              ),
            if (transfers && caps.exportItems)
              NativeSheetItemConfig(
                id: workspaceRowId('list-export', key),
                title: section == WorkspaceSection.models
                    ? l10n.workspaceModelExportAll
                    : l10n.workspacePromptExport,
                sfSymbol: 'square.and.arrow.up',
                showsDisclosure: false,
                pending: running == 'export' ? true : null,
                disabled: running != null,
              ),
          ],
        ),
    ],
  );
}

NativeSheetItemConfig _listRow(
  AppLocalizations l10n,
  WorkspaceSection section,
  WorkspaceListItem item, {
  required bool busy,
}) {
  final key = section.name;
  final models = section == WorkspaceSection.models;
  final knowledge = section == WorkspaceSection.knowledge;
  return NativeSheetItemConfig(
    id: workspaceEditorPageId(section, item.id),
    title: item.title,
    subtitle: [
      if (item.subtitle != null && item.subtitle!.trim().isNotEmpty)
        item.subtitle!,
      if (knowledge)
        item.external
            ? l10n.workspaceKnowledgeExternalBadge
            : l10n.workspaceKnowledgeSourceLocal
      else
        item.isActive ? l10n.activeStatus : l10n.inactiveStatus,
      if (!item.writeAccess) l10n.workspaceReadOnlyBadge,
    ].join(' · '),
    sfSymbol: knowledge && item.external
        ? 'link'
        : item.isActive
        ? workspaceSectionSymbol(section)
        : 'pause.circle',
    avatarBytes: item.avatarBytes,
    pending: busy ? true : null,
    rowActions: [
      if (item.writeAccess && item.toggleable && !busy)
        NativeSheetRowAction(
          id: workspaceRowId('list-active', key, item.id),
          label: item.isActive
              ? (models
                    ? l10n.workspaceModelDeactivate
                    : l10n.workspacePromptDeactivate)
              : (models
                    ? l10n.workspaceModelActivate
                    : l10n.workspacePromptActivate),
          sfSymbol: item.isActive ? 'pause.circle' : 'play.circle',
        ),
      if (item.writeAccess && !item.external && !busy)
        NativeSheetRowAction(
          id: workspaceRowId('list-delete', key, item.id),
          label: models
              ? l10n.workspaceModelDelete
              : knowledge
              ? l10n.workspaceKnowledgeDelete
              : l10n.workspacePromptDelete,
          sfSymbol: 'trash',
          destructive: true,
          confirmMessage: models
              ? l10n.workspaceModelDeleteConfirmMessage(item.title)
              : knowledge
              ? l10n.workspaceKnowledgeDeleteConfirmMessage(item.title)
              : l10n.workspacePromptDeleteConfirmMessage(item.title),
        ),
    ],
  );
}

/// The Workspace's page and its sections' lists in Settings.
class WorkspaceSettingsPages extends SettingsPageModule {
  WorkspaceSettingsPages(this._ref);

  final Ref _ref;
  AppLocalizations? _l10n;

  bool _hubShown = false;
  final Set<WorkspaceSection> _listsShown = {};
  final Map<WorkspaceSection, Set<String>> _busy = {};
  final Map<WorkspaceSection, String> _running = {};
  final Map<WorkspaceSection, ({String text, bool error})> _notices = {};
  final List<ProviderSubscription<Object?>> _following = [];
  bool _redrawQueued = false;

  SettingsSurface get _surface => _ref.read(settingsSurfaceProvider);

  @override
  bool ownsPage(String detailId) =>
      detailId == workspaceHubPageId ||
      detailId.startsWith(workspaceSectionPagePrefix);

  @override
  Future<void> hydrate(String detailId, AppLocalizations l10n) async {
    _l10n = l10n;
    _follow();
    if (detailId == workspaceHubPageId) {
      _hubShown = true;
      await _applyHub(l10n);
      return;
    }
    final section = workspaceSectionNamed(
      detailId.substring(workspaceSectionPagePrefix.length),
    );
    if (section == null || !workspaceSectionsInSettings.contains(section)) {
      return;
    }
    // Opened again, the list says nothing about an earlier visit.
    if (!_listsShown.contains(section)) _notices.remove(section);
    final reopened = _listsShown.contains(section) || _listExists(section);
    _listsShown.add(section);
    await _applyList(l10n, section);
    // Coming back from an editor, or opened again, the list shows what the
    // server has now.
    if (reopened && _gateOpen(section)) unawaited(_refresh(section));
  }

  @override
  void pageLeft(String detailId) {
    if (detailId == workspaceHubPageId) {
      _hubShown = false;
    } else if (detailId.startsWith(workspaceSectionPagePrefix)) {
      final section = workspaceSectionNamed(
        detailId.substring(workspaceSectionPagePrefix.length),
      );
      if (section != null) {
        _listsShown.remove(section);
        _notices.remove(section);
      }
    }
    _stopFollowingWhenIdle();
  }

  @override
  void settingsClosed() {
    _hubShown = false;
    _listsShown.clear();
    _notices.clear();
    _stopFollowingWhenIdle();
  }

  // -- Following -------------------------------------------------------------

  void _follow() {
    if (_following.isNotEmpty) return;
    void redraw(Object? _, Object? _) => _queueRedraw();
    _following.addAll([
      _ref.listen(workspaceCapabilitiesProvider, redraw),
      _ref.listen(reviewerModeProvider, redraw),
      _ref.listen(workspaceModelsProvider, redraw),
      _ref.listen(workspaceKnowledgeProvider, redraw),
      _ref.listen(workspacePromptsProvider, redraw),
    ]);
  }

  void _stopFollowingWhenIdle() {
    if (_hubShown || _listsShown.isNotEmpty) return;
    for (final subscription in _following) {
      subscription.close();
    }
    _following.clear();
  }

  void _queueRedraw() {
    if (_redrawQueued) return;
    _redrawQueued = true;
    scheduleMicrotask(() async {
      _redrawQueued = false;
      final l10n = _l10n;
      if (l10n == null) return;
      if (_hubShown) await _applyHub(l10n);
      for (final section in _listsShown.toList()) {
        await _applyList(l10n, section);
      }
    });
  }

  // -- The hub -----------------------------------------------------------------

  Future<void> _applyHub(AppLocalizations l10n) {
    final state = readWorkspaceHubState(_ref);
    // Stand-ins only for pages not drawn yet: an open one keeps its rows.
    final known = _ref.read(settingsPagesProvider);
    return _surface.applyDetail(
      buildWorkspaceHubPage(l10n, state),
      detailSheets: [
        for (final section in state.permitted)
          if (workspaceSectionsInSettings.contains(section) &&
              !known.contains(workspaceSectionPageId(section)))
            buildNativeLoadingDetail(
              l10n: l10n,
              id: workspaceSectionPageId(section),
              title: workspaceSectionTitle(l10n, section),
            ),
      ],
    );
  }

  /// Opens [section]'s Workspace pages over the app. Settings closes first
  /// when it is the native sheet; the Flutter Settings pages stay under it.
  Future<void> _openInFlutter(WorkspaceSection section) async {
    final bridge = NativeSheetBridge.instance;
    final fromSheet = bridge.settingsSheetOpen;
    if (fromSheet) await bridge.dismiss();
    unawaited(
      NavigationService.router.push<void>(
        section.path,
        extra: fromSheet ? const NativeSheetNavigationOrigin() : null,
      ),
    );
  }

  // -- The lists ---------------------------------------------------------------

  bool _gateOpen(WorkspaceSection section) {
    final hub = readWorkspaceHubState(_ref);
    return hub.gate == WorkspaceGateStatus.ready &&
        hub.permitted.contains(section);
  }

  bool _listExists(WorkspaceSection section) => switch (section) {
    WorkspaceSection.models => _ref.read(workspaceModelsProvider.exists),
    WorkspaceSection.knowledge => _ref.read(workspaceKnowledgeProvider.exists),
    WorkspaceSection.prompts => _ref.read(workspacePromptsProvider.exists),
    _ => false,
  };

  WorkspaceListState _listState(WorkspaceSection section) {
    final hub = readWorkspaceHubState(_ref);
    final gate = hub.gate != WorkspaceGateStatus.ready
        ? hub.gate
        : hub.permitted.contains(section)
        ? WorkspaceGateStatus.ready
        : WorkspaceGateStatus.denied;
    final notice = _notices[section];
    final capabilities = workspaceSectionCapabilities(
      _ref.read(workspaceCapabilitiesProvider).value,
      section,
    );
    if (gate != WorkspaceGateStatus.ready) {
      return WorkspaceListState(section: section, gate: gate);
    }
    final ({
      List<WorkspaceListItem>? items,
      bool loading,
      bool failed,
      String query,
      String view,
      String source,
      bool hasMore,
      bool loadingMore,
    })
    list;
    switch (section) {
      case WorkspaceSection.models:
        final value = _ref.read(workspaceModelsProvider);
        final data = value.value;
        list = (
          items: data?.items.map(WorkspaceListItem.model).toList(),
          loading: value.isLoading || (data?.isLoading ?? false),
          failed: value.hasError || data?.error != null,
          query: data?.query ?? '',
          view: '',
          source: '',
          hasMore: data?.hasMore ?? false,
          loadingMore: data?.isLoadingMore ?? false,
        );
      case WorkspaceSection.knowledge:
        final value = _ref.read(workspaceKnowledgeProvider);
        final data = value.value;
        list = (
          items: data?.items.map(WorkspaceListItem.knowledge).toList(),
          loading: value.isLoading || (data?.isLoading ?? false),
          failed: value.hasError || data?.error != null,
          query: data?.query ?? '',
          view: data?.view ?? '',
          source: data?.source ?? '',
          hasMore: data?.hasMore ?? false,
          loadingMore: data?.isLoadingMore ?? false,
        );
      case WorkspaceSection.prompts:
        final value = _ref.read(workspacePromptsProvider);
        final data = value.value;
        list = (
          items: data?.items.map(WorkspaceListItem.prompt).toList(),
          loading: value.isLoading || (data?.isLoading ?? false),
          failed: value.hasError || data?.error != null,
          query: data?.query ?? '',
          view: '',
          source: '',
          hasMore: data?.hasMore ?? false,
          loadingMore: data?.isLoadingMore ?? false,
        );
      default:
        return WorkspaceListState(section: section, gate: gate);
    }
    return WorkspaceListState(
      section: section,
      items: list.items,
      loading: list.loading,
      loadFailed: list.failed,
      query: list.query,
      view: list.view,
      source: list.source,
      hasMore: list.hasMore,
      loadingMore: list.loadingMore,
      capabilities: capabilities,
      busy: _busy[section] ?? const {},
      running: _running[section],
      notice: notice?.text,
      noticeIsError: notice?.error ?? false,
    );
  }

  Future<void> _applyList(AppLocalizations l10n, WorkspaceSection section) {
    final state = _listState(section);
    if (state.gate == WorkspaceGateStatus.ready && state.items == null) {
      // The first read: reading the provider below is what loads it.
      _readList(section);
    }
    String editorId(String? id) => workspaceEditorPageId(section, id);
    // Stand-ins only for editors not drawn yet: one open over the list
    // keeps its rows through the list's redraws.
    final known = _ref.read(settingsPagesProvider);
    return _surface.applyDetail(
      buildWorkspaceListPage(l10n, state),
      detailSheets: [
        for (final item in state.items ?? const <WorkspaceListItem>[])
          if (!known.contains(editorId(item.id)))
            buildNativeLoadingDetail(
              l10n: l10n,
              id: editorId(item.id),
              title: item.title,
            ),
        if (state.capabilities.manage && !known.contains(editorId(null)))
          buildNativeLoadingDetail(
            l10n: l10n,
            id: editorId(null),
            title: workspaceNewTitle(l10n, section),
          ),
      ],
    );
  }

  void _readList(WorkspaceSection section) {
    switch (section) {
      case WorkspaceSection.models:
        _ref.read(workspaceModelsProvider);
      case WorkspaceSection.knowledge:
        _ref.read(workspaceKnowledgeProvider);
      case WorkspaceSection.prompts:
        _ref.read(workspacePromptsProvider);
      default:
        break;
    }
  }

  Future<void> _listAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (error, stackTrace) {
      // The notifier keeps the failure in its state, which the list shows.
      DebugLogger.error(
        'workspace-list-action-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _refresh(WorkspaceSection section) => _listAction(
    () => switch (section) {
      WorkspaceSection.models =>
        _ref.read(workspaceModelsProvider.notifier).refresh(),
      WorkspaceSection.knowledge =>
        _ref.read(workspaceKnowledgeProvider.notifier).refresh(),
      WorkspaceSection.prompts =>
        _ref.read(workspacePromptsProvider.notifier).refresh(),
      _ => Future<void>.value(),
    },
  );

  @override
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    final row = parseWorkspaceRowId(id);
    if (row == null) return false;
    _l10n = l10n;
    if (row.key == 'hub') {
      switch (row.field) {
        case 'open':
          final section = workspaceSectionNamed(row.extra ?? '');
          if (section != null && workspaceSectionsInFlutter.contains(section)) {
            await _openInFlutter(section);
          }
          return true;
        case 'gate-retry':
          _ref.invalidate(workspaceCapabilitiesProvider);
          return true;
      }
      return false;
    }
    if (!row.field.startsWith('list-')) return false;
    final section = workspaceSectionNamed(row.key);
    if (section == null || !workspaceSectionsInSettings.contains(section)) {
      return false;
    }
    switch (row.field) {
      case 'list-search' when value is String:
        await _listAction(
          () => switch (section) {
            WorkspaceSection.models =>
              _ref.read(workspaceModelsProvider.notifier).setQuery(value),
            WorkspaceSection.knowledge =>
              _ref.read(workspaceKnowledgeProvider.notifier).setQuery(value),
            _ => _ref.read(workspacePromptsProvider.notifier).setQuery(value),
          },
        );
      case 'list-more':
        await _listAction(
          () => switch (section) {
            WorkspaceSection.models =>
              _ref.read(workspaceModelsProvider.notifier).loadMore(),
            WorkspaceSection.knowledge =>
              _ref.read(workspaceKnowledgeProvider.notifier).loadMore(),
            _ => _ref.read(workspacePromptsProvider.notifier).loadMore(),
          },
        );
      case 'list-view'
          when value is String && section == WorkspaceSection.knowledge:
        await _listAction(
          () => _ref.read(workspaceKnowledgeProvider.notifier).setView(value),
        );
      case 'list-source'
          when value is String && section == WorkspaceSection.knowledge:
        await _listAction(
          () => _ref.read(workspaceKnowledgeProvider.notifier).setSource(value),
        );
      case 'list-retry':
        await _refresh(section);
      case 'list-active' when row.extra != null:
        await _toggle(l10n, section, row.extra!);
      case 'list-delete' when row.extra != null:
        await _delete(l10n, section, row.extra!);
      case 'list-import':
        await _import(l10n, section);
      case 'list-export':
        await _export(l10n, section);
    }
    return true;
  }

  Future<void> _withBusy(
    AppLocalizations l10n,
    WorkspaceSection section,
    String itemId,
    Future<void> Function() action, {
    required String failure,
  }) async {
    final busy = _busy.putIfAbsent(section, () => {});
    if (!busy.add(itemId)) return;
    // The account the row was drawn for: the change goes to it or nowhere.
    final account = _account();
    _notices.remove(section);
    await _applyList(l10n, section);
    // Checked with nothing awaited before the request: another account may
    // have signed in while the row was drawn busy, and may hold an item by
    // the same id.
    if (_account() != account) {
      // The row was drawn busy; draw it ready again.
      busy.remove(itemId);
      if (_listsShown.contains(section)) await _applyList(l10n, section);
      return;
    }
    try {
      await action();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-row-action-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      _notices[section] = (text: failure, error: true);
    } finally {
      busy.remove(itemId);
    }
    if (_listsShown.contains(section)) await _applyList(l10n, section);
  }

  Future<void> _toggle(
    AppLocalizations l10n,
    WorkspaceSection section,
    String itemId,
  ) => _withBusy(
    l10n,
    section,
    itemId,
    () async {
      switch (section) {
        case WorkspaceSection.models:
          await _ref.read(workspaceModelsProvider.notifier).toggle(itemId);
          _ref.invalidate(workspaceModelDetailProvider(itemId));
        default:
          await _ref.read(workspacePromptsProvider.notifier).toggle(itemId);
          _ref.invalidate(workspacePromptDetailProvider(itemId));
      }
    },
    failure: section == WorkspaceSection.models
        ? l10n.workspaceModelSaveFailed
        : l10n.workspacePromptSaveFailed,
  );

  Future<void> _delete(
    AppLocalizations l10n,
    WorkspaceSection section,
    String itemId,
  ) => _withBusy(
    l10n,
    section,
    itemId,
    () async {
      switch (section) {
        case WorkspaceSection.models:
          await _ref.read(workspaceModelsProvider.notifier).delete(itemId);
          _notices[section] = (text: l10n.workspaceModelDeleted, error: false);
        case WorkspaceSection.knowledge:
          await _ref.read(workspaceKnowledgeProvider.notifier).delete(itemId);
          _notices[section] = (
            text: l10n.workspaceKnowledgeDeleted,
            error: false,
          );
        default:
          await _ref.read(workspacePromptsProvider.notifier).delete(itemId);
          _notices[section] = (text: l10n.workspacePromptDeleted, error: false);
      }
    },
    failure: switch (section) {
      WorkspaceSection.models => l10n.workspaceModelSaveFailed,
      WorkspaceSection.knowledge => l10n.workspaceKnowledgeSaveFailed,
      _ => l10n.workspacePromptSaveFailed,
    },
  );

  /// Where the share sheet opens from: the middle of the screen, as iPad
  /// asks for an origin.
  Rect? _shareOrigin() {
    final view = PlatformDispatcher.instance.views.firstOrNull;
    if (view == null) return null;
    final size = view.physicalSize / view.devicePixelRatio;
    return Rect.fromCenter(
      center: size.center(Offset.zero),
      width: 1,
      height: 1,
    );
  }

  Future<void> _export(AppLocalizations l10n, WorkspaceSection section) async {
    if (_running.containsKey(section)) return;
    _running[section] = 'export';
    _notices.remove(section);
    // The library shared is the account's that asked for it.
    final account = _account();
    await _applyList(l10n, section);
    if (_account() != account) {
      // The row was drawn busy; draw it ready again.
      _running.remove(section);
      if (_listsShown.contains(section)) await _applyList(l10n, section);
      return;
    }
    try {
      final List<Map<String, dynamic>> payload;
      final String filename;
      switch (section) {
        case WorkspaceSection.models:
          final models = await _ref
              .read(workspaceModelsProvider.notifier)
              .exportAll();
          payload = models.map(workspaceModelExportMap).toList();
          filename = 'models';
        default:
          final prompts = await _ref
              .read(workspacePromptsProvider.notifier)
              .loadAllForExport();
          payload = prompts.map(workspacePromptExportMap).toList();
          filename = 'prompts';
      }
      // Left meanwhile, nobody is there to share it with; read for an
      // account since gone, it is not this one's to share.
      if (_listsShown.contains(section) && _account() == account) {
        await _ref
            .read(workspaceExportControllerProvider)
            .shareJson(
              filename: filename,
              data: payload,
              sharePositionOrigin: _shareOrigin(),
            );
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-export-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      _notices[section] = (
        text: section == WorkspaceSection.models
            ? l10n.workspaceModelExportFailed
            : l10n.workspacePromptExportFailed,
        error: true,
      );
    } finally {
      _running.remove(section);
    }
    if (_listsShown.contains(section)) await _applyList(l10n, section);
  }

  /// The account the pages act for, by server and user.
  (String?, String?) _account() => (
    _ref.read(activeServerProvider).asData?.value?.id,
    _ref.read(currentUserProvider2)?.id,
  );

  Future<void> _import(AppLocalizations l10n, WorkspaceSection section) async {
    if (_running.containsKey(section)) return;
    // A file chosen under one account is never imported into another.
    final account = _account();
    final String? text;
    try {
      // Over the Settings sheet, as a picker opened from one of its rows.
      text = await _ref.read(workspaceImportFilePickerProvider)();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-import-read-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
      _notices[section] = (text: l10n.workspaceImportReadFailed, error: true);
      if (_listsShown.contains(section)) await _applyList(l10n, section);
      return;
    }
    if (text == null ||
        !_listsShown.contains(section) ||
        _account() != account) {
      return;
    }
    final List<Map<String, dynamic>> items;
    try {
      items = workspaceImportItemsFromJson(jsonDecode(text));
    } on FormatException {
      _notices[section] = (text: l10n.workspaceImportInvalidJson, error: true);
      await _applyList(l10n, section);
      return;
    }
    if (items.isEmpty) {
      _notices[section] = (text: l10n.workspaceImportEmpty, error: true);
      await _applyList(l10n, section);
      return;
    }
    _running[section] = 'import';
    _notices.remove(section);
    await _applyList(l10n, section);
    // Once another account signs in, the rest of the batch is not this
    // account's to import, even if it signs in again before the end.
    var cancelled = false;
    void follow() {
      if (_account() != account) cancelled = true;
    }

    final following = [
      _ref.listen(activeServerProvider, (_, _) => follow()),
      _ref.listen(currentUserProvider2, (_, _) => follow()),
    ];
    WorkspaceImportReport? report;
    try {
      report = await runWorkspaceImport(
        items,
        importItem: (item) async {
          if (cancelled || _account() != account) {
            cancelled = true;
            throw StateError('account changed');
          }
          switch (section) {
            case WorkspaceSection.models:
              final ok = await _ref
                  .read(workspaceModelsProvider.notifier)
                  .importItems([item]);
              if (!ok) throw StateError('import rejected');
            default:
              await _ref
                  .read(workspacePromptsProvider.notifier)
                  .importPrompt(workspacePromptFormFromImport(item));
          }
        },
        labelOf: (item) => section == WorkspaceSection.models
            ? item['name']?.toString() ?? item['id']?.toString() ?? ''
            : item['name']?.toString() ?? item['command']?.toString() ?? '',
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'workspace-import-failed',
        scope: 'settings/workspace',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      for (final subscription in following) {
        subscription.close();
      }
      _running.remove(section);
    }
    if (_account() != account) {
      // Another account's list, shown meanwhile, no longer waits on this
      // import; it says nothing of it.
      if (_listsShown.contains(section)) await _applyList(l10n, section);
      return;
    }
    if (cancelled) {
      // Stopped by an account change, and back on this account: the list
      // no longer waits on the import, which says nothing more.
      if (_listsShown.contains(section)) await _applyList(l10n, section);
      return;
    }
    _notices[section] = report == null
        ? (text: l10n.workspaceImportBatchFailed, error: true)
        : (
            text: [
              l10n.workspaceImportSummary(report.successCount, report.total),
              for (final failure in report.failures)
                '${failure.label}: ${l10n.workspaceImportItemFailed}',
            ].join('\n'),
            error: report.hasFailures,
          );
    await _refresh(section);
    if (_listsShown.contains(section)) await _applyList(l10n, section);
  }
}

/// Shares workspace exports; replaced in tests.
final workspaceExportControllerProvider = Provider<WorkspaceExportController>(
  (ref) => WorkspaceExportController(),
);

/// Reads a JSON file the user picks, over Settings, or null when they
/// cancel; replaced in tests.
final workspaceImportFilePickerProvider = Provider<Future<String?> Function()>(
  (ref) => () async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (file == null) return null;
    final bytes = file.path != null
        ? await File(file.path!).readAsBytes()
        : await file.readAsBytes();
    return utf8.decode(bytes);
  },
);
