import 'dart:async';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/sharing/providers/principal_lookup.dart';
import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/features/workspace/providers/workspace_session.dart';
import 'package:conduit_core/navigation/routes.dart' show WorkspaceSection;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/utils/native_sheet_utils.dart';
import '../../workspace/widgets/workspace_access_grants.dart';
import '../settings_pages.dart';
import 'workspace_page_ids.dart';

/// The key a resource's access rows carry: its section and its editor's
/// key. `|` is escaped in every encoded id, so the two stay apart.
String workspaceAccessKey(WorkspaceSection section, String editorKey) =>
    '${section.name}|$editorKey';

/// Who can open one Workspace resource, as its Access page edits it.
///
/// [saveOnDone] says whether Done saves the list to the server (a saved
/// resource) or hands it back for the resource's first save (a new one).
final class WorkspaceAccessDraft {
  WorkspaceAccessDraft({
    required this.section,
    required this.editorKey,
    required List<WorkspaceAccessGrantInput> grants,
    required this.readOnly,
    required this.saveOnDone,
    this.resourceName,
    this.session,
  }) : baseline = normalizeWorkspaceGrants(grants),
       grants = normalizeWorkspaceGrants(grants);

  final WorkspaceSection section;
  final String editorKey;

  /// The account the list was opened for: once another one signs in, the
  /// list is neither drawn nor sent for it.
  final WorkspaceSessionIdentity? session;
  final String? resourceName;
  final bool readOnly;
  final bool saveOnDone;
  List<WorkspaceAccessGrantInput> baseline;
  List<WorkspaceAccessGrantInput> grants;
  bool saving = false;
  String? notice;

  /// What the server kept of the list [WorkspaceAccessPages.onSave] sent, when
  /// it says: it drops grants the account may not give, so what stands can be
  /// less than what was sent.
  List<WorkspaceAccessGrantInput>? kept;

  /// The people found for the search typed on the Add People page.
  String userQuery = '';
  int userSearch = 0;
  List<WorkspacePrincipalPreview>? users;
  bool usersLoading = false;
  bool usersFailed = false;

  /// The server's groups, for the Add Groups page, and the filter typed.
  String groupQuery = '';
  List<WorkspacePrincipalPreview>? groups;
  bool groupsLoading = false;
  bool groupsFailed = false;

  String get key => workspaceAccessKey(section, editorKey);

  bool get edited {
    final now = workspaceGrantKeys(grants);
    final then = workspaceGrantKeys(baseline);
    return now.length != then.length || !now.containsAll(then);
  }
}

String _principalName(
  AppLocalizations l10n,
  WorkspacePrincipalLookup? lookup,
  WorkspacePrincipalType type,
  String id,
) {
  final name = lookup?.cached(type, id)?.name.trim();
  if (name != null && name.isNotEmpty) return name;
  return type == WorkspacePrincipalType.group
      ? l10n.libraryAccessUnknownGroup
      : l10n.libraryAccessUnknownPerson;
}

/// A resource's Access page: who beyond its owner can open it, each
/// person or group with what they may do, and rows adding more. Done saves
/// the list (or keeps it for a new resource's first save); leaving with
/// changes asks first.
@visibleForTesting
NativeSheetDetailConfig buildWorkspaceAccessPage(
  AppLocalizations l10n, {
  required WorkspaceAccessDraft draft,
  required WorkspaceSectionCapabilities capabilities,
  required bool allowUserGrants,
  required bool allowGroupGrants,
  WorkspacePrincipalLookup? lookup,
}) {
  final pageId = workspaceAccessPageId(draft.section, draft.editorKey);
  final key = draft.key;
  final canEdit = !draft.readOnly && capabilities.share && !draft.saving;
  final isPublic = workspaceGrantsArePublic(draft.grants);
  final principals = workspaceSharedPrincipals(draft.grants);
  final canGrantAny = allowUserGrants || allowGroupGrants;
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.workspaceModelManageAccess,
    subtitle: draft.resourceName,
    confirmActionId: draft.readOnly || !capabilities.share
        ? null
        : workspaceRowId('access-done', key),
    confirmActionLabel: l10n.libraryAccessDone,
    discardPrompt: nativeDiscardPrompt(l10n),
    edited: draft.edited,
    busy: draft.saving,
    announcement: draft.notice,
    sections: [
      if (draft.notice != null)
        NativeSheetSectionConfig(
          items: [workspaceWarning('$pageId-notice', draft.notice!)],
        ),
      if (draft.readOnly || !capabilities.share)
        NativeSheetSectionConfig(
          items: [
            workspaceNote(
              '$pageId-read-only',
              draft.readOnly
                  ? l10n.libraryAccessOwnerOnlyNotice
                  : l10n.libraryAccessAccountCantShare,
              'lock',
            ),
          ],
        ),
      NativeSheetSectionConfig(
        footer: isPublic
            ? l10n.libraryAccessEveryoneHint
            : (!capabilities.sharePublicly && canEdit
                  ? l10n.workspaceAccessPublicDisabled
                  : null),
        items: [
          NativeSheetItemConfig(
            id: workspaceRowId('access-general', key),
            title: l10n.libraryGeneralAccess,
            sfSymbol: isPublic ? 'globe' : 'lock',
            kind: NativeSheetItemKind.segment,
            value: isPublic ? 'server' : 'restricted',
            // Public stays shown when the account may not choose it, so a
            // resource already public reads as such.
            disabled: !canEdit || (!capabilities.sharePublicly && !isPublic),
            options: [
              NativeSheetOptionConfig(
                id: 'restricted',
                label: l10n.libraryAccessOnlyPeopleAdded,
              ),
              NativeSheetOptionConfig(
                id: 'server',
                label: l10n.libraryAccessEveryoneOnServer,
                enabled: capabilities.sharePublicly,
              ),
            ],
          ),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.workspaceAccessPeopleHeading,
        footer: !canEdit
            ? null
            : !canGrantAny
            ? l10n.workspaceAccessGrantsDisabled
            : !allowUserGrants
            ? l10n.workspaceAccessUsersDisabled
            : !allowGroupGrants
            ? l10n.workspaceAccessGroupsDisabled
            : null,
        items: [
          if (principals.isEmpty)
            workspaceNote(
              '$pageId-empty',
              l10n.workspaceAccessEmpty,
              'person.crop.circle.badge.questionmark',
            ),
          for (final principal in principals)
            _principalRow(l10n, key, principal, lookup, canEdit: canEdit),
          if (canEdit && allowUserGrants)
            NativeSheetItemConfig(
              id: workspaceAccessAddPageId(
                draft.section,
                draft.editorKey,
                groups: false,
              ),
              title: l10n.workspaceAccessAddUsers,
              sfSymbol: 'person.badge.plus',
              accent: true,
            ),
          if (canEdit && allowGroupGrants)
            NativeSheetItemConfig(
              id: workspaceAccessAddPageId(
                draft.section,
                draft.editorKey,
                groups: true,
              ),
              title: l10n.workspaceAccessAddGroups,
              sfSymbol: 'person.2.badge.plus',
              accent: true,
            ),
        ],
      ),
    ],
  );
}

NativeSheetItemConfig _principalRow(
  AppLocalizations l10n,
  String key,
  WorkspaceSharedPrincipal principal,
  WorkspacePrincipalLookup? lookup, {
  required bool canEdit,
}) {
  final group = principal.type == WorkspacePrincipalType.group;
  final name = _principalName(l10n, lookup, principal.type, principal.id);
  final extra = '${principal.type.name}|${principal.id}';
  return NativeSheetItemConfig(
    id: workspaceRowId('access-principal', key, extra),
    title: name,
    subtitle: [
      group ? l10n.workspaceAccessGroupBadge : l10n.workspaceAccessUserBadge,
      principal.canWrite
          ? l10n.workspaceAccessCanEdit
          : l10n.libraryAccessCanView,
    ].join(' · '),
    sfSymbol: group ? 'person.2' : 'person',
    avatarName: group ? null : name,
    showsDisclosure: false,
    rowActions: [
      if (canEdit && principal.canWrite)
        NativeSheetRowAction(
          id: workspaceRowId('access-view', key, extra),
          label: l10n.libraryAccessCanView,
          sfSymbol: 'eye',
        ),
      if (canEdit && !principal.canWrite)
        NativeSheetRowAction(
          id: workspaceRowId('access-edit', key, extra),
          label: l10n.workspaceAccessCanEdit,
          sfSymbol: 'pencil',
        ),
      if (canEdit)
        NativeSheetRowAction(
          id: workspaceRowId('access-remove', key, extra),
          label: l10n.workspaceAccessRemoveGrant,
          sfSymbol: 'person.badge.minus',
          destructive: true,
        ),
    ],
  );
}

/// The page adding people ([groups] false) or groups to a resource's
/// access: a search, then each match; one already given access says so.
@visibleForTesting
NativeSheetDetailConfig buildWorkspaceAccessAddPage(
  AppLocalizations l10n, {
  required WorkspaceAccessDraft draft,
  required bool groups,
}) {
  final pageId = workspaceAccessAddPageId(
    draft.section,
    draft.editorKey,
    groups: groups,
  );
  final key = draft.key;
  final granted = {
    for (final principal in workspaceSharedPrincipals(draft.grants))
      '${principal.type.name}|${principal.id}',
  };
  final query = groups ? draft.groupQuery : draft.userQuery;
  final List<WorkspacePrincipalPreview>? found;
  if (groups) {
    final needle = query.trim().toLowerCase();
    found = draft.groups
        ?.where(
          (group) =>
              needle.isEmpty || group.name.toLowerCase().contains(needle),
        )
        .toList();
  } else {
    found = draft.users;
  }
  final loading = groups ? draft.groupsLoading : draft.usersLoading;
  final failed = groups ? draft.groupsFailed : draft.usersFailed;
  return NativeSheetDetailConfig(
    id: pageId,
    title: groups
        ? l10n.workspaceAccessAddGroups
        : l10n.workspaceAccessAddUsers,
    search: NativeSheetSearchConfig(
      id: workspaceRowId(
        groups ? 'access-group-search' : 'access-user-search',
        key,
      ),
      placeholder: groups
          ? l10n.libraryPickerSearchGroups
          : l10n.workspacePrincipalSearchHint,
      value: query,
    ),
    items: [
      if (failed)
        NativeSheetItemConfig(
          id: workspaceRowId(
            groups ? 'access-groups-retry' : 'access-users-retry',
            key,
          ),
          title: l10n.workspacePrincipalLoadFailed,
          subtitle: l10n.retry,
          sfSymbol: 'exclamationmark.triangle',
          showsDisclosure: false,
        )
      else if (loading && (found == null || found.isEmpty))
        buildNativeLoadingItem(l10n, id: '$pageId-loading')
      else if (!groups && query.trim().isEmpty)
        workspaceNote(
          '$pageId-prompt',
          l10n.workspacePrincipalSearchPrompt,
          'magnifyingglass',
        )
      else if (found == null || found.isEmpty)
        workspaceNote('$pageId-none', l10n.workspacePrincipalNoResults)
      else
        for (final principal in found)
          _candidateRow(
            l10n,
            key,
            principal,
            granted: granted.contains('${principal.type.name}|${principal.id}'),
          ),
    ],
  );
}

NativeSheetItemConfig _candidateRow(
  AppLocalizations l10n,
  String key,
  WorkspacePrincipalPreview principal, {
  required bool granted,
}) {
  final group = principal.type == WorkspacePrincipalType.group;
  return NativeSheetItemConfig(
    id: workspaceRowId(
      'access-add',
      key,
      '${principal.type.name}|${principal.id}',
    ),
    title: principal.name.trim().isEmpty
        ? (group
              ? l10n.libraryAccessUnknownGroup
              : l10n.libraryAccessUnknownPerson)
        : principal.name,
    subtitle: granted
        ? l10n.libraryPickerHasAccess
        : (principal.email?.trim().isEmpty ?? true ? null : principal.email),
    sfSymbol: group ? 'person.2' : 'person',
    avatarName: group ? null : principal.name,
    showsDisclosure: false,
    disabled: granted,
  );
}

/// Draws and runs the Access pages of one kind of Workspace resource. The
/// editor that owns a resource opens its access with [open] as the page
/// appears; Done hands the list back through [onDone], after saving it with
/// [onSave] when the resource is saved already.
final class WorkspaceAccessPages {
  WorkspaceAccessPages(
    this._ref, {
    required this.section,
    required this.onSave,
    required this.onDone,
  });

  final Ref _ref;
  final WorkspaceSection section;

  /// Saves [grants] for the resource behind [draft]. Returns why it could
  /// not, or null once saved.
  final Future<String?> Function(
    WorkspaceAccessDraft draft,
    List<WorkspaceAccessGrantInput> grants,
  )
  onSave;

  /// The list is final: saved already when [saved], else kept for the
  /// resource's first save.
  final Future<void> Function(
    WorkspaceAccessDraft draft,
    List<WorkspaceAccessGrantInput> grants, {
    required bool saved,
  })
  onDone;

  final Map<String, WorkspaceAccessDraft> _drafts = {};
  AppLocalizations? _l10n;

  /// The lookup naming people and groups, as long as it is the account's.
  WorkspacePrincipalLookup? _lookup;

  SettingsSurface get _surface => _ref.read(settingsSurfaceProvider);

  WorkspaceCapabilities? get _capabilities =>
      _ref.read(workspaceCapabilitiesProvider).value;

  WorkspaceSectionCapabilities _sectionCapabilities(
    WorkspaceCapabilities? capabilities,
  ) {
    if (capabilities == null) return const WorkspaceSectionCapabilities();
    return switch (section) {
      WorkspaceSection.models => capabilities.models,
      WorkspaceSection.knowledge => capabilities.knowledge,
      WorkspaceSection.prompts => capabilities.prompts,
      WorkspaceSection.tools => capabilities.tools,
      WorkspaceSection.skills => capabilities.skills,
    };
  }

  bool ownsPage(String detailId) {
    if (detailId.startsWith(workspaceAccessPagePrefix)) {
      return detailId
          .substring(workspaceAccessPagePrefix.length)
          .startsWith('${section.name}:');
    }
    if (detailId.startsWith(workspaceAccessAddPagePrefix)) {
      final rest = detailId.substring(workspaceAccessAddPagePrefix.length);
      final colon = rest.indexOf(':');
      return colon > 0 &&
          rest.substring(colon + 1).startsWith('${section.name}:');
    }
    return false;
  }

  /// The editor key of Access page [detailId], or null.
  String? editorKeyOf(String detailId) {
    if (detailId.startsWith(workspaceAccessPagePrefix)) {
      final rest = detailId.substring(workspaceAccessPagePrefix.length);
      return rest.substring(section.name.length + 1);
    }
    if (detailId.startsWith(workspaceAccessAddPagePrefix)) {
      final rest = detailId.substring(workspaceAccessAddPagePrefix.length);
      final colon = rest.indexOf(':');
      return rest.substring(colon + 1 + section.name.length + 1);
    }
    return null;
  }

  WorkspaceAccessDraft? draftFor(String editorKey) =>
      _drafts[workspaceAccessKey(section, editorKey)];

  /// Opens the access of the resource behind [editorKey] as its Access page
  /// appears, for the account of [session] (the one signed in when null). A
  /// list being edited stays as it is; one opened for an account since gone
  /// is replaced.
  WorkspaceAccessDraft open({
    required String editorKey,
    required List<WorkspaceAccessGrantInput> grants,
    required bool readOnly,
    required bool saveOnDone,
    String? resourceName,
    WorkspaceSessionIdentity? session,
  }) {
    final key = workspaceAccessKey(section, editorKey);
    final existing = _drafts[key];
    if (existing != null && _current(existing)) return existing;
    return _drafts[key] = WorkspaceAccessDraft(
      section: section,
      editorKey: editorKey,
      grants: grants,
      readOnly: readOnly,
      saveOnDone: saveOnDone,
      resourceName: resourceName,
      session: session ?? _session(),
    );
  }

  WorkspaceSessionIdentity? _session() {
    try {
      return WorkspaceSessionIdentity.read(_ref);
    } on StateError {
      return null;
    }
  }

  Future<void> hydrate(String detailId, AppLocalizations l10n) async {
    _l10n = l10n;
    final editorKey = editorKeyOf(detailId);
    if (editorKey == null) return;
    final draft = draftFor(editorKey);
    if (draft == null || !_current(draft)) {
      // The editor that owns it is gone, or was another account's: nothing
      // to show access for.
      await _surface.closeDetail(detailId);
      return;
    }
    if (detailId.startsWith(workspaceAccessAddPagePrefix)) {
      final groups = detailId
          .substring(workspaceAccessAddPagePrefix.length)
          .startsWith('groups:');
      if (groups) {
        draft.groupQuery = '';
        await _applyAdd(l10n, draft, groups: true);
        if (draft.groups == null) unawaited(_loadGroups(draft));
      } else {
        draft
          ..userQuery = ''
          ..users = null
          ..usersFailed = false;
        await _applyAdd(l10n, draft, groups: false);
      }
      return;
    }
    await apply(l10n, draft);
    unawaited(_resolveNames(draft));
  }

  Future<void> apply(AppLocalizations l10n, WorkspaceAccessDraft draft) {
    final capabilities = _capabilities;
    final known = _ref.read(settingsPagesProvider);
    return _surface.applyDetail(
      buildWorkspaceAccessPage(
        l10n,
        draft: draft,
        capabilities: _sectionCapabilities(capabilities),
        allowUserGrants: capabilities?.allowUserGrants ?? false,
        allowGroupGrants: capabilities?.allowGroupGrants ?? false,
        lookup: _currentLookup(),
      ),
      // The pages its Add rows open, so a tap pushes them; one already
      // open keeps what it shows.
      detailSheets: [
        for (final groups in const [false, true])
          if (!known.contains(
            workspaceAccessAddPageId(
              draft.section,
              draft.editorKey,
              groups: groups,
            ),
          ))
            buildNativeLoadingDetail(
              l10n: l10n,
              id: workspaceAccessAddPageId(
                draft.section,
                draft.editorKey,
                groups: groups,
              ),
              title: groups
                  ? l10n.workspaceAccessAddGroups
                  : l10n.workspaceAccessAddUsers,
            ),
      ],
    );
  }

  Future<void> _applyAdd(
    AppLocalizations l10n,
    WorkspaceAccessDraft draft, {
    required bool groups,
  }) => _surface.applyDetail(
    buildWorkspaceAccessAddPage(l10n, draft: draft, groups: groups),
  );

  WorkspacePrincipalLookup? _currentLookup() {
    final lookup = _ref.read(workspacePrincipalLookupProvider);
    if (!identical(lookup, _lookup)) _lookup = lookup;
    return lookup;
  }

  /// Whether [draft] is still the page's list, for the account signed in.
  bool _current(WorkspaceAccessDraft draft) =>
      identical(_drafts[draft.key], draft) &&
      (draft.session?.isCurrent(_ref) ?? false);

  Future<void> _resolveNames(WorkspaceAccessDraft draft) async {
    final lookup = _currentLookup();
    if (lookup == null) return;
    final wanted = [
      for (final principal in workspaceSharedPrincipals(draft.grants))
        if (lookup.resolutionOf(principal.type, principal.id) ==
            WorkspacePrincipalResolution.unknown)
          (type: principal.type, id: principal.id),
    ];
    if (wanted.isEmpty) return;
    try {
      await lookup.resolve(wanted);
    } catch (_) {
      // Unnamed principals read as unknown; the access list still works.
    }
    final l10n = _l10n;
    if (l10n == null ||
        !_current(draft) ||
        !identical(_ref.read(workspacePrincipalLookupProvider), lookup)) {
      return;
    }
    await apply(l10n, draft);
  }

  Future<void> _loadGroups(WorkspaceAccessDraft draft) async {
    final directory = _ref.read(workspacePrincipalDirectoryProvider);
    final l10n = _l10n;
    if (directory == null || l10n == null) return;
    draft
      ..groupsLoading = true
      ..groupsFailed = false;
    await _applyAdd(l10n, draft, groups: true);
    try {
      final groups = await directory.loadGroups();
      if (!_current(draft) ||
          !identical(
            _ref.read(workspacePrincipalDirectoryProvider),
            directory,
          )) {
        return;
      }
      _currentLookup()?.remember(groups);
      draft.groups = groups;
    } catch (_) {
      if (!_current(draft)) return;
      draft.groupsFailed = true;
    }
    draft.groupsLoading = false;
    await _applyAdd(l10n, draft, groups: true);
  }

  Future<void> _searchUsers(WorkspaceAccessDraft draft, String query) async {
    final l10n = _l10n;
    if (l10n == null) return;
    final search = ++draft.userSearch;
    draft
      ..userQuery = query
      ..usersFailed = false;
    if (query.trim().isEmpty) {
      draft
        ..users = null
        ..usersLoading = false;
      await _applyAdd(l10n, draft, groups: false);
      return;
    }
    final directory = _ref.read(workspacePrincipalDirectoryProvider);
    if (directory == null) return;
    draft.usersLoading = true;
    await _applyAdd(l10n, draft, groups: false);
    try {
      final users = await directory.searchUsers(query.trim());
      // An answer to a search typed over since, or for another account,
      // is not shown.
      if (!_current(draft) ||
          draft.userSearch != search ||
          !identical(
            _ref.read(workspacePrincipalDirectoryProvider),
            directory,
          )) {
        return;
      }
      _currentLookup()?.remember(users);
      draft.users = users;
    } catch (_) {
      if (!_current(draft) || draft.userSearch != search) return;
      draft.usersFailed = true;
    }
    draft.usersLoading = false;
    await _applyAdd(l10n, draft, groups: false);
  }

  /// Handles a row of an Access page of this section. Returns false for any
  /// other row.
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    _l10n = l10n;
    final row = parseWorkspaceRowId(id);
    if (row == null || !row.field.startsWith('access-')) return false;
    final bar = row.key.indexOf('|');
    if (bar < 0 || row.key.substring(0, bar) != section.name) return false;
    final draft = _drafts[row.key];
    // A list opened for an account since gone is not changed or drawn.
    if (draft == null || !_current(draft)) return true;
    // What the account may grant now, as the page draws it: a change from a
    // page drawn before the server said otherwise is refused, and the page
    // drawn again as it stands.
    final capabilities = _capabilities;
    final rights = _sectionCapabilities(capabilities);
    final canEdit = !draft.readOnly && !draft.saving && rights.share;
    bool mayGrant(WorkspacePrincipalType type) => switch (type) {
      WorkspacePrincipalType.user => capabilities?.allowUserGrants ?? false,
      WorkspacePrincipalType.group => capabilities?.allowGroupGrants ?? false,
    };
    switch (row.field) {
      case 'access-general'
          when value is String &&
              canEdit &&
              (value != 'server' || rights.sharePublicly):
        draft
          ..grants = setWorkspacePublicGrant(draft.grants, value == 'server')
          ..notice = null;
        await apply(l10n, draft);
      case 'access-general' when value is String:
        await apply(l10n, draft);
      case 'access-view' || 'access-edit' || 'access-remove'
          when row.extra != null && canEdit:
        final principal = _principalOf(row.extra!);
        if (principal == null) return true;
        draft
          ..grants = switch (row.field) {
            'access-remove' => removeWorkspacePrincipal(
              draft.grants,
              principal.type,
              principal.id,
            ),
            _ => setWorkspacePrincipalWrite(
              draft.grants,
              principal.type,
              principal.id,
              row.field == 'access-edit',
            ),
          }
          ..notice = null;
        await apply(l10n, draft);
      case 'access-add' when row.extra != null && canEdit:
        final principal = _principalOf(row.extra!);
        if (principal == null || !mayGrant(principal.type)) return true;
        draft
          ..grants = upsertWorkspacePrincipalGrant(
            draft.grants,
            principal.type,
            principal.id,
          )
          ..notice = null;
        await _surface.closeDetail(
          workspaceAccessAddPageId(
            section,
            draft.editorKey,
            groups: principal.type == WorkspacePrincipalType.group,
          ),
        );
        await apply(l10n, draft);
      case 'access-user-search' when value is String:
        await _searchUsers(draft, value);
      case 'access-users-retry':
        await _searchUsers(draft, draft.userQuery);
      case 'access-group-search' when value is String:
        draft.groupQuery = value;
        await _applyAdd(l10n, draft, groups: true);
      case 'access-groups-retry':
        await _loadGroups(draft);
      case 'access-done':
        await _done(l10n, draft);
    }
    return true;
  }

  ({WorkspacePrincipalType type, String id})? _principalOf(String extra) {
    final bar = extra.indexOf('|');
    if (bar < 0) return null;
    final type = WorkspacePrincipalType.values
        .where((value) => value.name == extra.substring(0, bar))
        .firstOrNull;
    if (type == null) return null;
    return (type: type, id: extra.substring(bar + 1));
  }

  Future<void> _done(AppLocalizations l10n, WorkspaceAccessDraft draft) async {
    if (draft.readOnly || draft.saving) return;
    // Sharing taken away while the page was open: nothing is sent.
    if (!_sectionCapabilities(_capabilities).share) {
      await apply(l10n, draft);
      return;
    }
    final grants = draft.grants;
    final pageId = workspaceAccessPageId(section, draft.editorKey);
    if (!draft.saveOnDone) {
      draft.baseline = grants;
      await onDone(draft, grants, saved: false);
      if (!_current(draft)) return;
      await _surface.closeDetail(pageId);
      return;
    }
    if (!draft.edited) {
      await _surface.closeDetail(pageId);
      return;
    }
    draft
      ..saving = true
      ..notice = null
      ..kept = null;
    await apply(l10n, draft);
    final problem = await onSave(draft, grants);
    if (!_current(draft)) return;
    draft.saving = false;
    if (problem != null) {
      draft.notice = problem;
      await apply(l10n, draft);
      return;
    }
    // The list as saved is the server's, not the one sent: it drops grants
    // the account may not give.
    final saved = normalizeWorkspaceGrants(draft.kept ?? grants);
    draft
      ..grants = saved
      ..baseline = saved;
    final keptAll = workspaceGrantKeys(saved)
        .containsAll(workspaceGrantKeys(grants));
    if (keptAll) {
      await apply(l10n, draft);
      if (!_current(draft)) return;
    }
    await onDone(draft, saved, saved: true);
    // The editor drawn again waits on the sheet: an account that signed in
    // meanwhile, or a page left, is shown nothing more of this list.
    if (!_current(draft)) return;
    if (keptAll) {
      await _surface.closeDetail(pageId);
      return;
    }
    // Saved, but not all of it: as the access sheet does, the page stays on
    // the server's answer and names the people and groups it dropped.
    final dropped = [
      for (final principal in workspaceDroppedPrincipals(grants, saved))
        _principalName(l10n, _lookup, principal.type, principal.id),
    ];
    draft.notice = dropped.isEmpty
        ? l10n.resourceSharingFiltered
        : l10n.libraryAccessPartialSave(dropped.join(', '));
    await apply(l10n, draft);
  }

  /// An Access page or its Add page was left.
  void pageLeft(String detailId) {
    if (!detailId.startsWith(workspaceAccessPagePrefix)) return;
    final editorKey = editorKeyOf(detailId);
    if (editorKey == null) return;
    // Left without Done, the edit is dropped; the editor's list stands.
    _drafts.remove(workspaceAccessKey(section, editorKey));
  }

  /// The editor behind [editorKey] is gone, and its access with it.
  void forget(String editorKey) =>
      _drafts.remove(workspaceAccessKey(section, editorKey));

  void clear() {
    _drafts.clear();
    _lookup = null;
  }
}
