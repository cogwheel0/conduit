import 'dart:async';

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/utils/debug_logger.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/models/workspace_common.dart';
import 'package:conduit/features/workspace/providers/workspace_session.dart';
import 'package:conduit/features/workspace/widgets/workspace_tiles.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/conduit_loading.dart';
import 'package:conduit/shared/widgets/middle_ellipsis_text.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';

// ---------------------------------------------------------------------------
// Pure grant algebra (mirrors Open WebUI AccessControl.svelte semantics).
// These are deterministic and side-effect free so they can be unit tested and
// reused by every section editor.
// ---------------------------------------------------------------------------

String _grantKey(
  WorkspacePrincipalType type,
  String id,
  WorkspaceGrantPermission permission,
) => '${type.name}:$id:${permission.name}';

bool _isPublicGrant(WorkspaceAccessGrantInput grant) =>
    grant.principalType == WorkspacePrincipalType.user &&
    grant.principalId == '*';

/// Removes duplicate grants (same principal + permission) while preserving the
/// first-seen order. Empty principal ids are dropped.
List<WorkspaceAccessGrantInput> normalizeWorkspaceGrants(
  Iterable<WorkspaceAccessGrantInput> grants,
) {
  final map = <String, WorkspaceAccessGrantInput>{};
  for (final grant in grants) {
    if (grant.principalId.isEmpty) continue;
    map[_grantKey(
      grant.principalType,
      grant.principalId,
      grant.permission,
    )] = WorkspaceAccessGrantInput(
      principalType: grant.principalType,
      principalId: grant.principalId,
      permission: grant.permission,
    );
  }
  return List<WorkspaceAccessGrantInput>.unmodifiable(map.values);
}

/// Public sharing is represented by a single wildcard user read grant.
bool workspaceGrantsArePublic(Iterable<WorkspaceAccessGrantInput> grants) =>
    grants.any(
      (grant) =>
          _isPublicGrant(grant) &&
          grant.permission == WorkspaceGrantPermission.read,
    );

/// Adds/removes the wildcard user read grant. Toggling on strips any other
/// wildcard grants first so the public flag is expressed by exactly one entry.
List<WorkspaceAccessGrantInput> setWorkspacePublicGrant(
  Iterable<WorkspaceAccessGrantInput> grants,
  bool isPublic,
) {
  final next = grants.where((grant) => !_isPublicGrant(grant)).toList();
  if (isPublic) {
    next.add(
      const WorkspaceAccessGrantInput(
        principalType: WorkspacePrincipalType.user,
        principalId: '*',
        permission: WorkspaceGrantPermission.read,
      ),
    );
  }
  return normalizeWorkspaceGrants(next);
}

/// Ensures a principal has (at minimum) a read grant.
List<WorkspaceAccessGrantInput> upsertWorkspacePrincipalGrant(
  Iterable<WorkspaceAccessGrantInput> grants,
  WorkspacePrincipalType type,
  String id,
) => normalizeWorkspaceGrants([
  ...grants,
  WorkspaceAccessGrantInput(
    principalType: type,
    principalId: id,
    permission: WorkspaceGrantPermission.read,
  ),
]);

/// Drops every grant (read and write) for a principal.
List<WorkspaceAccessGrantInput> removeWorkspacePrincipal(
  Iterable<WorkspaceAccessGrantInput> grants,
  WorkspacePrincipalType type,
  String id,
) => normalizeWorkspaceGrants(
  grants.where(
    (grant) => !(grant.principalType == type && grant.principalId == id),
  ),
);

bool workspacePrincipalCanWrite(
  Iterable<WorkspaceAccessGrantInput> grants,
  WorkspacePrincipalType type,
  String id,
) => grants.any(
  (grant) =>
      grant.principalType == type &&
      grant.principalId == id &&
      grant.permission == WorkspaceGrantPermission.write,
);

/// Sets the write flag for a principal. Enabling write also guarantees a read
/// grant; disabling write leaves the principal with read access.
List<WorkspaceAccessGrantInput> setWorkspacePrincipalWrite(
  Iterable<WorkspaceAccessGrantInput> grants,
  WorkspacePrincipalType type,
  String id,
  bool canWrite,
) {
  final next = grants
      .where(
        (grant) => !(grant.principalType == type && grant.principalId == id),
      )
      .toList();
  next.add(
    WorkspaceAccessGrantInput(
      principalType: type,
      principalId: id,
      permission: WorkspaceGrantPermission.read,
    ),
  );
  if (canWrite) {
    next.add(
      WorkspaceAccessGrantInput(
        principalType: type,
        principalId: id,
        permission: WorkspaceGrantPermission.write,
      ),
    );
  }
  return normalizeWorkspaceGrants(next);
}

/// A distinct principal referenced by the grant set (public wildcard excluded).
@immutable
class WorkspaceSharedPrincipal {
  const WorkspaceSharedPrincipal({
    required this.type,
    required this.id,
    required this.canWrite,
  });

  final WorkspacePrincipalType type;
  final String id;
  final bool canWrite;
}

/// Distinct, non-public principals ordered by id for a stable list.
List<WorkspaceSharedPrincipal> workspaceSharedPrincipals(
  Iterable<WorkspaceAccessGrantInput> grants,
) {
  final seen = <String, WorkspaceSharedPrincipal>{};
  for (final grant in grants) {
    if (_isPublicGrant(grant)) continue;
    final key = '${grant.principalType.name}:${grant.principalId}';
    seen[key] = WorkspaceSharedPrincipal(
      type: grant.principalType,
      id: grant.principalId,
      canWrite:
          seen[key]?.canWrite == true ||
          grant.permission == WorkspaceGrantPermission.write,
    );
  }
  final result = seen.values.toList()
    ..sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
  return List<WorkspaceSharedPrincipal>.unmodifiable(result);
}

// ---------------------------------------------------------------------------
// Principal directory (search users / list groups) injected via provider so
// tests can substitute in-memory fakes.
// ---------------------------------------------------------------------------

typedef WorkspaceUserSearch =
    Future<List<WorkspacePrincipalPreview>> Function(String query);
typedef WorkspaceGroupLoader =
    Future<List<WorkspacePrincipalPreview>> Function();

@immutable
class WorkspacePrincipalDirectory {
  const WorkspacePrincipalDirectory({
    required this.searchUsers,
    required this.loadGroups,
  });

  final WorkspaceUserSearch searchUsers;
  final WorkspaceGroupLoader loadGroups;

  factory WorkspacePrincipalDirectory.fromApi(ApiService api) =>
      WorkspacePrincipalDirectory(
        searchUsers: (query) async {
          final response = await api.searchWorkspaceUsers(query);
          return response.items;
        },
        loadGroups: api.getWorkspaceGroups,
      );
}

/// Resolves a [WorkspacePrincipalDirectory] for the active session, or null
/// when no authenticated server session is available.
final workspacePrincipalDirectoryProvider =
    Provider<WorkspacePrincipalDirectory?>((ref) {
      final session = WorkspaceSessionIdentity.watchNullable(ref);
      if (session == null) return null;
      return WorkspacePrincipalDirectory.fromApi(session.api);
    });

// ---------------------------------------------------------------------------
// Access grant editor sheet.
// ---------------------------------------------------------------------------

/// Bottom sheet that edits the access grants for a workspace resource.
///
/// Capability gating:
/// * [WorkspaceSectionCapabilities.share] — when false the sheet is read-only.
/// * [WorkspaceSectionCapabilities.sharePublicly] — gates the public toggle.
/// * [allowUserGrants] — gates sharing with individual users (vs groups only).
///
/// Returns the normalized grants on save, or null if dismissed.
class WorkspaceAccessGrantSheet extends ConsumerStatefulWidget {
  const WorkspaceAccessGrantSheet({
    super.key,
    required this.initialGrants,
    required this.capabilities,
    required this.allowUserGrants,
    this.readOnly = false,
    this.principalNames = const {},
  });

  final List<WorkspaceAccessGrantInput> initialGrants;
  final WorkspaceSectionCapabilities capabilities;
  final bool allowUserGrants;
  final bool readOnly;

  /// Optional pre-resolved display names keyed by `type:id` so existing grants
  /// render friendly labels without an extra round-trip.
  final Map<String, String> principalNames;

  static Future<List<WorkspaceAccessGrantInput>?> show(
    BuildContext context, {
    required List<WorkspaceAccessGrantInput> initialGrants,
    required WorkspaceSectionCapabilities capabilities,
    required bool allowUserGrants,
    bool readOnly = false,
    Map<String, String> principalNames = const {},
  }) {
    return ThemedSheets.showCustom<List<WorkspaceAccessGrantInput>>(
      context: context,
      builder: (_) => WorkspaceAccessGrantSheet(
        initialGrants: initialGrants,
        capabilities: capabilities,
        allowUserGrants: allowUserGrants,
        readOnly: readOnly,
        principalNames: principalNames,
      ),
    );
  }

  @override
  ConsumerState<WorkspaceAccessGrantSheet> createState() =>
      _WorkspaceAccessGrantSheetState();
}

class _WorkspaceAccessGrantSheetState
    extends ConsumerState<WorkspaceAccessGrantSheet> {
  late List<WorkspaceAccessGrantInput> _grants;
  late final Map<String, String> _names;

  bool get _isReadOnly => widget.readOnly || !widget.capabilities.share;

  @override
  void initState() {
    super.initState();
    _grants = normalizeWorkspaceGrants(widget.initialGrants);
    _names = {...widget.principalNames};
  }

  void _update(List<WorkspaceAccessGrantInput> next) {
    setState(() => _grants = next);
  }

  String _principalName(WorkspaceSharedPrincipal principal) {
    return _names['${principal.type.name}:${principal.id}'] ?? principal.id;
  }

  Future<void> _addPrincipal() async {
    final directory = ref.read(workspacePrincipalDirectoryProvider);
    if (directory == null) return;
    final picked = await WorkspacePrincipalPicker.show(
      context,
      directory: directory,
      allowUsers: widget.allowUserGrants,
    );
    if (picked == null || !mounted) return;
    _names['${picked.type.name}:${picked.id}'] = picked.name;
    _update(upsertWorkspacePrincipalGrant(_grants, picked.type, picked.id));
    DebugLogger.log(
      'access grant added',
      scope: 'workspace/access',
      data: {'type': picked.type.name},
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final isPublic = workspaceGrantsArePublic(_grants);
    final principals = workspaceSharedPrincipals(_grants);
    final canAdd = !_isReadOnly;
    final canTogglePublic = !_isReadOnly && widget.capabilities.sharePublicly;

    return ConduitModalSheetSurface(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, l10n),
          if (_isReadOnly)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.sm),
              child: _notice(context, l10n.workspaceAccessSharingDisabled),
            ),
          Flexible(
            child: ListView(
              key: const Key('workspace-access-list'),
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: Spacing.sm),
              children: [
                _publicTile(context, l10n, isPublic, canTogglePublic),
                if (!canTogglePublic && !_isReadOnly)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
                    child: _notice(context, l10n.workspaceAccessPublicDisabled),
                  ),
                const SizedBox(height: Spacing.sm),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
                  child: Text(
                    l10n.workspaceAccessPeopleHeading,
                    style: theme.label?.copyWith(color: theme.textSecondary),
                  ),
                ),
                if (!widget.allowUserGrants && !_isReadOnly)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
                    child: _notice(context, l10n.workspaceAccessUsersDisabled),
                  ),
                if (principals.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(Spacing.md),
                    child: Text(
                      l10n.workspaceAccessEmpty,
                      key: const Key('workspace-access-empty'),
                      style: theme.bodySmall?.copyWith(
                        color: theme.textSecondary,
                      ),
                    ),
                  )
                else
                  for (final principal in principals)
                    _principalTile(context, l10n, principal),
              ],
            ),
          ),
          if (canAdd)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: ConduitButton(
                key: const Key('workspace-access-add'),
                text: widget.allowUserGrants
                    ? l10n.workspaceAccessAddPeople
                    : l10n.workspaceAccessAddGroups,
                icon: Icons.person_add_alt_1_outlined,
                isSecondary: true,
                isFullWidth: true,
                onPressed: _addPrincipal,
              ),
            ),
          const SizedBox(height: Spacing.sm),
          if (!_isReadOnly)
            ConduitButton(
              key: const Key('workspace-access-save'),
              text: l10n.save,
              isFullWidth: true,
              onPressed: () => Navigator.of(context).pop(_grants),
            ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(l10n.workspaceAccessTitle, style: theme.headingSmall),
          ),
          if (_isReadOnly)
            Padding(
              padding: const EdgeInsets.only(left: Spacing.sm),
              child: Icon(
                Icons.lock_outline,
                size: IconSize.small,
                color: theme.iconSecondary,
              ),
            ),
          SheetCloseButton(
            tooltip: l10n.close,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _notice(BuildContext context, String message) {
    final theme = context.conduitTheme;
    return Container(
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: theme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppBorderRadius.small),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline,
            size: IconSize.small,
            color: theme.iconSecondary,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              message,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _publicTile(
    BuildContext context,
    AppLocalizations l10n,
    bool isPublic,
    bool canToggle,
  ) {
    final theme = context.conduitTheme;
    return WorkspaceResourceTile(
      key: const Key('workspace-access-public'),
      icon: isPublic ? Icons.public : Icons.public_off,
      iconColor: isPublic ? theme.buttonPrimary : theme.iconSecondary,
      title: l10n.workspaceAccessVisibilityLabel,
      subtitle: l10n.workspaceAccessVisibilityDescription,
      trailing: AdaptiveSwitch(
        value: isPublic,
        onChanged: canToggle
            ? (value) => _update(setWorkspacePublicGrant(_grants, value))
            : null,
      ),
    );
  }

  Widget _principalTile(
    BuildContext context,
    AppLocalizations l10n,
    WorkspaceSharedPrincipal principal,
  ) {
    final theme = context.conduitTheme;
    final isGroup = principal.type == WorkspacePrincipalType.group;
    final canEdit = !_isReadOnly;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: WorkspaceResourceTile(
        key: Key(
          'workspace-access-principal-${principal.type.name}-${principal.id}',
        ),
        icon: isGroup ? Icons.groups_outlined : Icons.person_outline,
        iconColor: theme.iconSecondary,
        title: _principalName(principal),
        subtitle: isGroup
            ? l10n.workspaceAccessGroupBadge
            : l10n.workspaceAccessUserBadge,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AdaptiveTooltip(
              message: l10n.workspaceAccessCanEdit,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.workspaceAccessCanEdit,
                    style: theme.caption?.copyWith(color: theme.textSecondary),
                  ),
                  AdaptiveSwitch(
                    key: Key(
                      'workspace-access-write-${principal.type.name}-${principal.id}',
                    ),
                    value: principal.canWrite,
                    onChanged: canEdit
                        ? (value) => _update(
                            setWorkspacePrincipalWrite(
                              _grants,
                              principal.type,
                              principal.id,
                              value,
                            ),
                          )
                        : null,
                  ),
                ],
              ),
            ),
            if (canEdit)
              IconButton(
                key: Key(
                  'workspace-access-remove-${principal.type.name}-${principal.id}',
                ),
                tooltip: l10n.workspaceAccessRemoveGrant,
                icon: const Icon(Icons.close),
                onPressed: () => _update(
                  removeWorkspacePrincipal(
                    _grants,
                    principal.type,
                    principal.id,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Principal picker (users + groups).
// ---------------------------------------------------------------------------

/// Sheet that searches users and lists groups, returning the chosen principal.
class WorkspacePrincipalPicker extends StatefulWidget {
  const WorkspacePrincipalPicker({
    super.key,
    required this.directory,
    required this.allowUsers,
  });

  final WorkspacePrincipalDirectory directory;
  final bool allowUsers;

  static Future<WorkspacePrincipalPreview?> show(
    BuildContext context, {
    required WorkspacePrincipalDirectory directory,
    required bool allowUsers,
  }) {
    return ThemedSheets.showCustom<WorkspacePrincipalPreview>(
      context: context,
      builder: (_) => WorkspacePrincipalPicker(
        directory: directory,
        allowUsers: allowUsers,
      ),
    );
  }

  @override
  State<WorkspacePrincipalPicker> createState() =>
      _WorkspacePrincipalPickerState();
}

class _WorkspacePrincipalPickerState extends State<WorkspacePrincipalPicker> {
  final _controller = TextEditingController();
  Timer? _debounce;
  bool _showingGroups = false;
  bool _loading = false;
  Object? _error;
  List<WorkspacePrincipalPreview> _results = const [];
  int _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    // Default to the only permitted tab when user grants are disallowed.
    _showingGroups = !widget.allowUsers;
    if (_showingGroups) {
      _loadGroups(++_requestGeneration);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final generation = ++_requestGeneration;
    final query = value.trim();
    if (query.isEmpty) {
      setState(() {
        _results = const [];
        _error = null;
        _loading = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _searchUsers(query, generation);
    });
  }

  Future<void> _searchUsers(String query, int generation) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await widget.directory.searchUsers(query);
      if (!mounted ||
          generation != _requestGeneration ||
          _showingGroups ||
          _controller.text.trim() != query) {
        return;
      }
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (error, stackTrace) {
      if (!mounted ||
          generation != _requestGeneration ||
          _showingGroups ||
          _controller.text.trim() != query) {
        return;
      }
      DebugLogger.error(
        'principal user search failed',
        scope: 'workspace/access',
        error: error,
        stackTrace: stackTrace,
      );
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _loadGroups(int generation) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await widget.directory.loadGroups();
      if (!mounted || generation != _requestGeneration || !_showingGroups) {
        return;
      }
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (error, stackTrace) {
      if (!mounted || generation != _requestGeneration || !_showingGroups) {
        return;
      }
      DebugLogger.error(
        'principal group load failed',
        scope: 'workspace/access',
        error: error,
        stackTrace: stackTrace,
      );
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _selectTab({required bool groups}) {
    if (_showingGroups == groups) return;
    _debounce?.cancel();
    final generation = ++_requestGeneration;
    setState(() {
      _showingGroups = groups;
      _results = const [];
      _error = null;
      _loading = false;
    });
    if (groups) {
      _loadGroups(generation);
    } else {
      final query = _controller.text.trim();
      if (query.isNotEmpty) _searchUsers(query, generation);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;

    return ConduitModalSheetSurface(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.workspacePrincipalTitle,
                  style: theme.headingSmall,
                ),
              ),
              SheetCloseButton(
                tooltip: l10n.close,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          if (widget.allowUsers)
            Row(
              children: [
                Expanded(
                  child: ConduitChip(
                    key: const Key('workspace-principal-tab-users'),
                    label: l10n.workspacePrincipalUsersTab,
                    isSelected: !_showingGroups,
                    onTap: () => _selectTab(groups: false),
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: ConduitChip(
                    key: const Key('workspace-principal-tab-groups'),
                    label: l10n.workspacePrincipalGroupsTab,
                    isSelected: _showingGroups,
                    onTap: () => _selectTab(groups: true),
                  ),
                ),
              ],
            ),
          const SizedBox(height: Spacing.sm),
          if (!_showingGroups)
            ConduitGlassSearchField(
              controller: _controller,
              hintText: l10n.workspacePrincipalSearchHint,
              query: _controller.text,
              onChanged: _onQueryChanged,
              onClear: () {
                _controller.clear();
                _onQueryChanged('');
              },
            ),
          const SizedBox(height: Spacing.sm),
          Flexible(child: _body(context, l10n)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    final theme = context.conduitTheme;
    if (_loading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: ConduitLoading.inline(context: context),
        ),
      );
    }
    if (_error != null) {
      return _emptyMessage(
        context,
        key: const Key('workspace-principal-error'),
        icon: Icons.error_outline,
        message: l10n.workspacePrincipalLoadFailed,
      );
    }
    if (!_showingGroups && _controller.text.trim().isEmpty) {
      return _emptyMessage(
        context,
        icon: Icons.search,
        message: l10n.workspacePrincipalSearchPrompt,
      );
    }
    if (_results.isEmpty) {
      return _emptyMessage(
        context,
        key: const Key('workspace-principal-empty'),
        icon: Icons.person_search_outlined,
        message: l10n.workspacePrincipalNoResults,
      );
    }
    return ListView.builder(
      key: const Key('workspace-principal-results'),
      shrinkWrap: true,
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final principal = _results[index];
        final isGroup = principal.type == WorkspacePrincipalType.group;
        return Material(
          color: Colors.transparent,
          child: AdaptiveListTile(
            key: Key(
              'workspace-principal-${principal.type.name}-${principal.id}',
            ),
            leading: Icon(
              isGroup ? Icons.groups_outlined : Icons.person_outline,
              color: theme.iconSecondary,
            ),
            title: MiddleEllipsisText(
              principal.name.isEmpty ? principal.id : principal.name,
            ),
            subtitle: principal.email == null || principal.email!.isEmpty
                ? null
                : Text(
                    principal.email!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            onTap: () => Navigator.of(context).pop(principal),
          ),
        );
      },
    );
  }

  Widget _emptyMessage(
    BuildContext context, {
    required IconData icon,
    required String message,
    Key? key,
  }) {
    final theme = context.conduitTheme;
    return Padding(
      key: key,
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 28, color: theme.iconSecondary),
          const SizedBox(height: Spacing.sm),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.bodySmall?.copyWith(color: theme.textSecondary),
          ),
        ],
      ),
    );
  }
}
