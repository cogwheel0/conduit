import 'dart:async';
import 'dart:math' as math;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit_core/features/sharing/models/resource_access.dart';
import 'package:conduit_core/features/sharing/providers/principal_lookup.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit/features/workspace/providers/workspace_session.dart';
import 'package:conduit/features/profile/widgets/adaptive_segmented_selector.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_fields.dart';
import 'package:conduit/features/workspace/widgets/workspace_tiles.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/services/brand_service.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/utils/ui_utils.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/conduit_loading.dart';
import 'package:conduit/shared/widgets/discard_changes.dart';
import 'package:conduit/shared/widgets/middle_ellipsis_text.dart';
import 'package:conduit/shared/widgets/sheet_handle.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:conduit/shared/widgets/user_avatar.dart';

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

String _principalKey(WorkspacePrincipalType type, String id) =>
    '${type.name}:$id';

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

/// The grants as `type:id:permission` keys, for comparing two grant lists
/// whatever their order or duplicates.
Set<String> workspaceGrantKeys(Iterable<WorkspaceAccessGrantInput> grants) => {
  for (final grant in grants)
    if (grant.principalId.isNotEmpty)
      _grantKey(grant.principalType, grant.principalId, grant.permission),
};

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
    final key = _principalKey(grant.principalType, grant.principalId);
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

/// The people and groups [submitted] gave access to that [kept] no longer
/// names: what a save asked for and the server did not keep.
List<WorkspaceSharedPrincipal> workspaceDroppedPrincipals(
  Iterable<WorkspaceAccessGrantInput> submitted,
  Iterable<WorkspaceAccessGrantInput> kept,
) {
  final keptKeys = {
    for (final principal in workspaceSharedPrincipals(kept))
      _principalKey(principal.type, principal.id),
  };
  return [
    for (final principal in workspaceSharedPrincipals(submitted))
      if (!keptKeys.contains(_principalKey(principal.type, principal.id)))
        principal,
  ];
}

/// Who beyond the people and groups added can open a resource, as the
/// General access row offers it.
enum WorkspaceGeneralAccess {
  /// Only the owner and the people and groups added.
  restricted,

  /// Everyone with an account on the server (a `user` grant for `*`).
  server,

  /// Anyone with the link (a chat's `anyone` grant for `*`).
  link,
}

/// One line describing who can open a resource, for the access row of a
/// workspace editor: only the owner, a count of people and groups, or
/// everyone on the server.
String workspaceAccessSummary(
  AppLocalizations l10n,
  Iterable<WorkspaceAccessGrantInput> grants,
) {
  if (workspaceGrantsArePublic(grants)) {
    return l10n.libraryAccessEveryoneOnServer;
  }
  final count = workspaceSharedPrincipals(grants).length;
  return count == 0
      ? l10n.libraryAccessSummaryOnlyYou
      : l10n.libraryAccessSummaryShared(count);
}

/// The glyph that goes with [workspaceAccessSummary].
IconData workspaceAccessSummaryIcon(
  Iterable<WorkspaceAccessGrantInput> grants,
) {
  if (workspaceGrantsArePublic(grants)) return Icons.public;
  return workspaceSharedPrincipals(grants).isEmpty
      ? Icons.lock_outline
      : Icons.group_outlined;
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

  /// Searches and lists through [api] as the account signed in when this was
  /// made. People found carry their profile picture from the server.
  factory WorkspacePrincipalDirectory.fromApi(ApiService api) {
    final authSnapshot = api.captureAuthSnapshot();
    return WorkspacePrincipalDirectory(
      searchUsers: (query) async {
        final response = await api.searchWorkspaceUsers(
          query,
          authSnapshot: authSnapshot,
        );
        return [
          for (final user in response.items)
            withWorkspaceUserPicture(api, user),
        ];
      },
      loadGroups: () => api.getWorkspaceGroups(authSnapshot: authSnapshot),
    );
  }
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

/// The Private / Public / Open choice a chat offers in place of the single
/// public switch.
///
/// [initial] is what the loaded grants say, shown even when the account may
/// not choose it. [canChooseOpen] is `sharing.open_chats`; Public follows the
/// sheet's [WorkspaceSectionCapabilities.sharePublicly].
class WorkspaceAudienceChoice {
  const WorkspaceAudienceChoice({
    required this.initial,
    required this.canChooseOpen,
  });

  final ResourceAudience initial;
  final bool canChooseOpen;
}

/// Who owns the resource, shown as the first row of the access list. Leave it
/// out when the owner is not known.
@immutable
class WorkspaceAccessOwner {
  const WorkspaceAccessOwner({
    this.name,
    this.email,
    this.imageUrl,
    this.isYou = false,
  });

  final String? name;
  final String? email;
  final String? imageUrl;

  /// The signed-in account owns it; the row reads "You".
  final bool isYou;

  bool get isShown => isYou || (name?.trim().isNotEmpty ?? false);
}

/// How a save through [WorkspaceAccessGrantSheet.onSave] went.
@immutable
class WorkspaceAccessSaveOutcome {
  /// Saved as submitted. The sheet closes with the submitted grants.
  const WorkspaceAccessSaveOutcome.saved()
    : message = null,
      keptGrants = null,
      keptAudience = null;

  /// Not saved. The sheet keeps the edited form and shows [message].
  const WorkspaceAccessSaveOutcome.failed(String this.message)
    : keptGrants = null,
      keptAudience = null;

  /// Saved, but the server kept less than was submitted. The sheet stays open
  /// on [keptGrants], the server's answer, and names the people and groups it
  /// dropped; [message] is shown when none was dropped (only a wildcard).
  const WorkspaceAccessSaveOutcome.partial({
    required List<WorkspaceAccessGrantInput> this.keptGrants,
    this.keptAudience,
    required String this.message,
  });

  final String? message;
  final List<WorkspaceAccessGrantInput>? keptGrants;
  final ResourceAudience? keptAudience;

  bool get isSaved => message == null && keptGrants == null;
}

/// The title row shared by the access sheet and its loading and error states,
/// so the sheet's header does not jump while it loads.
class WorkspaceAccessSheetHeader extends StatelessWidget {
  const WorkspaceAccessSheetHeader({
    super.key,
    this.subtitle,
    this.readOnly = false,
    required this.onClose,
  });

  /// The resource's name, under the title, when known.
  final String? subtitle;
  final bool readOnly;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final name = subtitle?.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    l10n.libraryShareTitle,
                    style: theme.headingSmall,
                  ),
                ),
                if (name != null && name.isNotEmpty)
                  Text(
                    name,
                    key: const Key('workspace-access-resource-name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.bodySmall?.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          if (readOnly)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
              child: Icon(
                UiUtils.platformIcon(
                  ios: CupertinoIcons.lock,
                  android: Icons.lock_outline,
                ),
                size: IconSize.small,
                color: theme.iconSecondary,
                semanticLabel: l10n.readOnly,
              ),
            ),
          SheetCloseButton(tooltip: l10n.close, onPressed: onClose),
        ],
      ),
    );
  }
}

/// Bottom sheet that edits the access grants for a workspace resource, a
/// chat, a folder or a note.
///
/// Capability gating:
/// * [WorkspaceSectionCapabilities.share] — when false the sheet is read-only.
/// * [WorkspaceSectionCapabilities.sharePublicly] — gates "Everyone on this
///   server".
/// * [allowUserGrants] / [allowGroupGrants] — independently gate adding
///   individual users and groups. Grants the resource already has are kept and
///   stay editable whichever kinds may be added.
/// * [allowWriteGrants] — whether a recipient can be given Can edit. Without
///   it a person is added with read access only, and a write grant the
///   resource already has is sent back unchanged.
///
/// People and groups are named through [workspacePrincipalLookupProvider], the
/// lookup of the account that opened the sheet; a name it cannot find reads
/// "Unknown person" (or group), never an id.
///
/// Returns the normalized grants on Done, or null if dismissed or unchanged.
///
/// With [onSave] the sheet saves before it closes: Save waits for the callback
/// and closes only when it reports [WorkspaceAccessSaveOutcome.saved]. A
/// failure keeps the sheet open with the edited grants and shows the message,
/// so a refused save does not cost the user their changes.
///
/// With [audience] the general access row also offers "Anyone with the link".
/// [onSave] then also receives the audience, but only if the user picked one:
/// an untouched audience is null, so wildcard grants the account may not
/// author are never rewritten by an unrelated edit.
///
/// Edits are guarded: closing, swiping the sheet down, tapping the barrier or
/// going back with unsaved changes asks before discarding them.
class WorkspaceAccessGrantSheet extends ConsumerStatefulWidget {
  const WorkspaceAccessGrantSheet({
    super.key,
    required this.initialGrants,
    required this.capabilities,
    required this.allowUserGrants,
    required this.allowGroupGrants,
    this.allowWriteGrants = true,
    this.readOnly = false,
    this.principalNames = const {},
    this.audience,
    this.showVisibility = true,
    this.resourceName,
    this.owner,
    this.onSave,
  });

  final List<WorkspaceAccessGrantInput> initialGrants;
  final WorkspaceSectionCapabilities capabilities;
  final bool allowUserGrants;
  final bool allowGroupGrants;

  /// Whether a recipient can be given edit access. A shared chat's audience is
  /// read-only in Open WebUI, so its sheet turns this off.
  final bool allowWriteGrants;

  /// The account may see but not change who has access: it is neither the
  /// owner nor someone who can edit.
  final bool readOnly;

  /// Optional pre-resolved display names keyed by `type:id`, used when the
  /// lookup has no answer.
  final Map<String, String> principalNames;

  /// Adds "Anyone with the link" to the general access choices when set.
  final WorkspaceAudienceChoice? audience;

  /// Whether to offer general access at all. A folder does not: the web
  /// folder modal has no such choice.
  final bool showVisibility;

  /// Shown under the title when known.
  final String? resourceName;

  /// Shown as the first row of the access list when set.
  final WorkspaceAccessOwner? owner;

  /// Saves the edited grants and reports how it went. The audience is the
  /// one the user picked, or null when [audience] is unset or untouched.
  final Future<WorkspaceAccessSaveOutcome> Function(
    List<WorkspaceAccessGrantInput> grants,
    ResourceAudience? audience,
  )?
  onSave;

  static Future<List<WorkspaceAccessGrantInput>?> show(
    BuildContext context, {
    required List<WorkspaceAccessGrantInput> initialGrants,
    required WorkspaceSectionCapabilities capabilities,
    required bool allowUserGrants,
    required bool allowGroupGrants,
    bool readOnly = false,
    Map<String, String> principalNames = const {},
    String? resourceName,
    Future<WorkspaceAccessSaveOutcome> Function(
      List<WorkspaceAccessGrantInput> grants,
      ResourceAudience? audience,
    )?
    onSave,
  }) {
    return ThemedSheets.showCustom<List<WorkspaceAccessGrantInput>>(
      context: context,
      builder: (_) => WorkspaceAccessGrantSheet(
        initialGrants: initialGrants,
        capabilities: capabilities,
        allowUserGrants: allowUserGrants,
        allowGroupGrants: allowGroupGrants,
        readOnly: readOnly,
        principalNames: principalNames,
        resourceName: resourceName,
        onSave: onSave,
      ),
    );
  }

  @override
  ConsumerState<WorkspaceAccessGrantSheet> createState() =>
      _WorkspaceAccessGrantSheetState();
}

enum _AccessLevelAction { view, edit, keep, remove }

/// What one access row shows for a principal.
class _PrincipalView {
  const _PrincipalView({
    required this.principal,
    required this.title,
    required this.subtitle,
    required this.known,
    this.imageUrl,
  });

  final WorkspaceSharedPrincipal principal;
  final String title;
  final String subtitle;

  /// The title is a real name rather than a placeholder.
  final bool known;
  final String? imageUrl;
}

class _WorkspaceAccessGrantSheetState
    extends ConsumerState<WorkspaceAccessGrantSheet> {
  late List<WorkspaceAccessGrantInput> _grants;
  late Set<String> _baselineKeys;
  ResourceAudience? _baselineAudience;
  ResourceAudience? _pickedAudience;
  bool _saving = false;
  String? _saveError;

  /// The lookup of the account that opened the sheet. Its answers are shown
  /// only while it is still the provider's current lookup.
  WorkspacePrincipalLookup? _lookup;
  int _resolving = 0;

  /// People and groups picked in this sheet, by `type:id`.
  final Map<String, WorkspacePrincipalPreview> _picked = {};

  bool get _isReadOnly => widget.readOnly || !widget.capabilities.share;
  bool get _canGrantAny => widget.allowUserGrants || widget.allowGroupGrants;

  @override
  void initState() {
    super.initState();
    _adoptBaseline(
      normalizeWorkspaceGrants(widget.initialGrants),
      widget.audience?.initial,
    );
    _lookup = ref.read(workspacePrincipalLookupProvider);
    unawaited(_resolveNames(initial: true));
  }

  void _adoptBaseline(
    List<WorkspaceAccessGrantInput> grants,
    ResourceAudience? audience,
  ) {
    _grants = grants;
    _baselineKeys = workspaceGrantKeys(grants);
    _baselineAudience = audience;
    _pickedAudience = null;
  }

  /// Whether anything differs from what the sheet opened with, or from the
  /// server's answer after a partial save.
  bool get _dirty {
    final keys = workspaceGrantKeys(_grants);
    final grantsChanged =
        keys.length != _baselineKeys.length || !keys.containsAll(_baselineKeys);
    return grantsChanged ||
        (_pickedAudience != null && _pickedAudience != _baselineAudience);
  }

  /// The audience on screen: the user's pick, else what was loaded.
  ResourceAudience get _audience =>
      _pickedAudience ?? _baselineAudience ?? ResourceAudience.private;

  WorkspaceGeneralAccess get _generalAccess {
    if (widget.audience != null) {
      return switch (_audience) {
        ResourceAudience.private => WorkspaceGeneralAccess.restricted,
        ResourceAudience.public => WorkspaceGeneralAccess.server,
        ResourceAudience.open => WorkspaceGeneralAccess.link,
      };
    }
    return workspaceGrantsArePublic(_grants)
        ? WorkspaceGeneralAccess.server
        : WorkspaceGeneralAccess.restricted;
  }

  bool get _lookupIsCurrent {
    final lookup = _lookup;
    return lookup != null &&
        identical(ref.read(workspacePrincipalLookupProvider), lookup);
  }

  /// Asks the lookup for every principal it cannot name yet.
  Future<void> _resolveNames({bool initial = false}) async {
    final lookup = _lookup;
    if (lookup == null) return;
    final wanted = [
      for (final principal in workspaceSharedPrincipals(_grants))
        if (lookup.resolutionOf(principal.type, principal.id) ==
            WorkspacePrincipalResolution.unknown)
          (type: principal.type, id: principal.id),
    ];
    if (wanted.isEmpty) return;
    if (initial) {
      _resolving++;
    } else {
      setState(() => _resolving++);
    }
    await lookup.resolve(wanted);
    if (!mounted) return;
    setState(() => _resolving--);
  }

  /// Mirrors the web editor's `setVisibility`: an explicit pick drops every
  /// wildcard row first, then Public adds its read row. The `anyone` rows
  /// live outside these grants and are replaced when the audience is saved.
  void _pickAudience(ResourceAudience next) {
    final grants = setWorkspacePublicGrant(
      _grants,
      next == ResourceAudience.public,
    );
    setState(() {
      _pickedAudience = next;
      _grants = grants;
      _saveError = null;
    });
  }

  void _pickGeneralAccess(WorkspaceGeneralAccess next) {
    if (next == _generalAccess) return;
    if (widget.audience != null) {
      _pickAudience(switch (next) {
        WorkspaceGeneralAccess.restricted => ResourceAudience.private,
        WorkspaceGeneralAccess.server => ResourceAudience.public,
        WorkspaceGeneralAccess.link => ResourceAudience.open,
      });
      return;
    }
    _update(
      setWorkspacePublicGrant(_grants, next == WorkspaceGeneralAccess.server),
    );
  }

  void _update(List<WorkspaceAccessGrantInput> next) {
    setState(() {
      _grants = next;
      _saveError = null;
    });
  }

  void _close() => Navigator.of(context).maybePop();

  Future<void> _confirmDiscard() async {
    final navigator = Navigator.of(context);
    if (await confirmDiscardChanges(context) && mounted) navigator.pop();
  }

  Future<void> _save() async {
    if (_saving) return;
    final onSave = widget.onSave;
    if (onSave == null) {
      Navigator.of(context).pop(_dirty ? _grants : null);
      return;
    }
    // What is submitted is what closes the sheet, whatever the form shows by
    // the time the owner answers.
    final submitted = _grants;
    final audience = _pickedAudience;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final outcome = await onSave(submitted, audience);
    if (!mounted) return;
    if (outcome.isSaved) {
      unawaited(ConduitHaptics.success());
      Navigator.of(context).pop(submitted);
      return;
    }
    final kept = outcome.keptGrants;
    if (kept == null) {
      setState(() {
        _saving = false;
        _saveError = outcome.message;
      });
      return;
    }
    // Saved, but not all of it: the form becomes the server's answer, and
    // the people and groups it dropped are named.
    final l10n = AppLocalizations.of(context)!;
    final lookupCurrent = _lookupIsCurrent;
    final dropped = [
      for (final principal in workspaceDroppedPrincipals(submitted, kept))
        _view(l10n, principal, lookupCurrent).title,
    ];
    setState(() {
      _saving = false;
      _adoptBaseline(
        normalizeWorkspaceGrants(kept),
        outcome.keptAudience ?? _baselineAudience,
      );
      _saveError = dropped.isEmpty
          ? outcome.message
          : l10n.libraryAccessPartialSave(dropped.join(', '));
    });
  }

  Future<void> _addPrincipals() async {
    final directory = ref.read(workspacePrincipalDirectoryProvider);
    if (directory == null) return;
    final l10n = AppLocalizations.of(context)!;
    final picked = await WorkspacePrincipalPicker.showMany(
      context,
      directory: directory,
      allowUsers: widget.allowUserGrants,
      allowGroups: widget.allowGroupGrants,
      existing: {
        for (final principal in workspaceSharedPrincipals(_grants))
          _principalKey(principal.type, principal.id),
      },
      existingLabel: l10n.libraryPickerHasAccess,
    );
    // A picker opened before Save can still answer while the save is in
    // flight, when the form no longer takes changes.
    if (picked == null || picked.isEmpty || !mounted || _saving) return;
    // Only the account the sheet belongs to keeps what it picked.
    if (_lookupIsCurrent) _lookup!.remember(picked);
    var next = _grants;
    for (final principal in picked) {
      _picked[_principalKey(principal.type, principal.id)] = principal;
      next = upsertWorkspacePrincipalGrant(next, principal.type, principal.id);
    }
    _update(next);
    DebugLogger.log(
      'access grants added',
      scope: 'workspace/access',
      data: {'count': picked.length},
    );
  }

  _PrincipalView _view(
    AppLocalizations l10n,
    WorkspaceSharedPrincipal principal,
    bool lookupCurrent,
  ) {
    final isGroup = principal.type == WorkspacePrincipalType.group;
    final key = _principalKey(principal.type, principal.id);
    final lookup = lookupCurrent ? _lookup : null;
    final preview =
        lookup?.cached(principal.type, principal.id) ?? _picked[key];
    final name = switch (preview?.name.trim()) {
      final String found when found.isNotEmpty => found,
      _ => widget.principalNames[key]?.trim(),
    };
    final badge = isGroup
        ? l10n.workspaceAccessGroupBadge
        : l10n.workspaceAccessUserBadge;
    if (name != null && name.isNotEmpty) {
      final email = preview?.email?.trim();
      return _PrincipalView(
        principal: principal,
        title: name,
        subtitle: !isGroup && email != null && email.isNotEmpty ? email : badge,
        known: true,
        imageUrl: preview?.profileImageUrl,
      );
    }
    final resolution = lookup?.resolutionOf(principal.type, principal.id);
    final waiting =
        _resolving > 0 &&
        (resolution == WorkspacePrincipalResolution.pending ||
            resolution == WorkspacePrincipalResolution.unknown);
    return _PrincipalView(
      principal: principal,
      // Still being looked up: a quiet placeholder rather than a raw id.
      title: waiting
          ? '…'
          : isGroup
          ? l10n.libraryAccessUnknownGroup
          : l10n.libraryAccessUnknownPerson,
      subtitle: badge,
      known: false,
    );
  }

  /// People first, then groups; named ones by name, unnamed ones last.
  List<_PrincipalView> _sortedViews(AppLocalizations l10n, bool lookupCurrent) {
    final views = [
      for (final principal in workspaceSharedPrincipals(_grants))
        _view(l10n, principal, lookupCurrent),
    ];
    int rank(WorkspacePrincipalType type) =>
        type == WorkspacePrincipalType.user ? 0 : 1;
    views.sort((a, b) {
      final byType = rank(
        a.principal.type,
      ).compareTo(rank(b.principal.type));
      if (byType != 0) return byType;
      if (a.known != b.known) return a.known ? -1 : 1;
      final byName = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      if (byName != 0) return byName;
      return a.principal.id.compareTo(b.principal.id);
    });
    return views;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    // Rebuilds when the account changes, which hides the old account's names.
    final currentLookup = ref.watch(workspacePrincipalLookupProvider);
    // The provider also rebuilds while the account stays the same (a server
    // refresh, a lookup that was not ready when the sheet opened). Move to the
    // new lookup then, so names keep resolving instead of going unknown.
    final previous = _lookup;
    if (currentLookup != null &&
        !identical(currentLookup, previous) &&
        (previous == null ||
            (previous.owner != null && currentLookup.owner == previous.owner))) {
      _lookup = currentLookup;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_resolveNames());
      });
    }
    final lookupCurrent = _lookup != null && identical(currentLookup, _lookup);
    final views = _sortedViews(l10n, lookupCurrent);
    final owner = widget.owner;
    final showOwner = owner != null && owner.isShown;
    final canAdd = !_isReadOnly && _canGrantAny;
    final grantKindsNotice = _isReadOnly ? null : _grantKindsNotice(l10n);
    final readOnlyNotice = _readOnlyNotice(l10n);
    final dirty = _dirty;

    final rows = <Widget>[
      if (showOwner) _ownerRow(context, l10n, owner),
      for (final view in views) _principalRow(context, l10n, view),
    ];

    return PopScope<Object?>(
      canPop: !dirty && !_saving,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _saving) return;
        unawaited(_confirmDiscard());
      },
      child: SheetDismissGuard(
        guarded: dirty || _saving,
        child: _BoundedSheetSurface(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHandle(),
              WorkspaceAccessSheetHeader(
                subtitle: widget.resourceName,
                readOnly: _isReadOnly,
                onClose: _saving ? null : _close,
              ),
              if (readOnlyNotice != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.sm),
                  child: _AccessNotice(
                    key: const Key('workspace-access-read-only'),
                    message: readOnlyNotice,
                  ),
                ),
              Flexible(
                child: ListView(
                  key: const Key('workspace-access-list'),
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: Spacing.sm),
                  children: [
                    if (widget.showVisibility) ...[
                      _SectionLabel(l10n.libraryGeneralAccess),
                      WorkspaceEditorFieldGroup(
                        children: [_generalAccessRow(context, l10n)],
                      ),
                      for (final notice in _restrictedNotices(l10n))
                        Padding(
                          padding: const EdgeInsets.only(top: Spacing.xs),
                          child: _AccessNotice(message: notice),
                        ),
                      const SizedBox(height: Spacing.lg),
                    ],
                    _SectionLabel(l10n.workspaceAccessPeopleHeading),
                    if (grantKindsNotice != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: Spacing.xs),
                        child: _AccessNotice(message: grantKindsNotice),
                      ),
                    if (rows.isNotEmpty)
                      WorkspaceEditorFieldGroup(children: rows),
                    if (views.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(Spacing.md),
                        child: Text(
                          l10n.workspaceAccessEmpty,
                          key: const Key('workspace-access-empty'),
                          style: theme.bodySmall?.copyWith(
                            color: theme.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (canAdd)
                Padding(
                  padding: const EdgeInsets.only(top: Spacing.xs),
                  child: ConduitButton(
                    key: const Key('workspace-access-add'),
                    text: switch ((
                      widget.allowUserGrants,
                      widget.allowGroupGrants,
                    )) {
                      (true, true) => l10n.workspaceAccessAddPeople,
                      (true, false) => l10n.workspaceAccessAddUsers,
                      _ => l10n.workspaceAccessAddGroups,
                    },
                    icon: UiUtils.platformIcon(
                      ios: CupertinoIcons.person_badge_plus,
                      android: Icons.person_add_alt_1_outlined,
                    ),
                    isSecondary: true,
                    isFullWidth: true,
                    onPressed: _saving ? null : _addPrincipals,
                  ),
                ),
              const SizedBox(height: Spacing.sm),
              if (_saveError case final error?)
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.sm),
                  child: Container(
                    key: const Key('workspace-access-save-error'),
                    padding: const EdgeInsets.all(Spacing.sm),
                    decoration: BoxDecoration(
                      color: theme.surfaceContainer,
                      borderRadius: BorderRadius.circular(
                        AppBorderRadius.small,
                      ),
                    ),
                    child: Text(
                      error,
                      style: theme.bodySmall?.copyWith(color: theme.error),
                    ),
                  ),
                ),
              if (!_isReadOnly)
                ConduitButton(
                  key: const Key('workspace-access-save'),
                  text: widget.onSave == null
                      ? l10n.libraryAccessDone
                      : l10n.save,
                  isFullWidth: true,
                  isLoading: _saving,
                  // Done also closes an untouched sheet; Save needs a change.
                  onPressed: _saving || (widget.onSave != null && !dirty)
                      ? null
                      : _save,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Why the access cannot be changed here, or null when it can.
  String? _readOnlyNotice(AppLocalizations l10n) {
    if (widget.readOnly) return l10n.libraryAccessOwnerOnlyNotice;
    if (!widget.capabilities.share) return l10n.libraryAccessAccountCantShare;
    return null;
  }

  /// Why some principal kinds cannot be added, or null when both can.
  String? _grantKindsNotice(AppLocalizations l10n) {
    return switch ((widget.allowUserGrants, widget.allowGroupGrants)) {
      (true, true) => null,
      (true, false) => l10n.workspaceAccessGroupsDisabled,
      (false, true) => l10n.workspaceAccessUsersDisabled,
      (false, false) => l10n.workspaceAccessGrantsDisabled,
    };
  }

  bool get _canChooseServer =>
      !_isReadOnly && widget.capabilities.sharePublicly;

  bool get _canChooseLink =>
      !_isReadOnly && (widget.audience?.canChooseOpen ?? false);

  /// The general access choices on offer. One the resource already has stays
  /// selectable, as in the web editor, so a restricted account still sees
  /// where it stands.
  List<(WorkspaceGeneralAccess, bool)> _generalOptions() {
    final current = _generalAccess;
    return [
      (WorkspaceGeneralAccess.restricted, true),
      (
        WorkspaceGeneralAccess.server,
        _canChooseServer || current == WorkspaceGeneralAccess.server,
      ),
      if (widget.audience != null)
        (
          WorkspaceGeneralAccess.link,
          _canChooseLink || current == WorkspaceGeneralAccess.link,
        ),
    ];
  }

  /// One notice per choice the account may not make, unless the resource
  /// already has that choice.
  List<String> _restrictedNotices(AppLocalizations l10n) {
    if (_isReadOnly) return const [];
    final current = _generalAccess;
    return [
      if (!_canChooseServer && current != WorkspaceGeneralAccess.server)
        l10n.workspaceAccessPublicDisabled,
      if (widget.audience != null &&
          !_canChooseLink &&
          current != WorkspaceGeneralAccess.link)
        l10n.libraryAccessLinkNotAllowed,
    ];
  }

  String _generalLabel(AppLocalizations l10n, WorkspaceGeneralAccess access) {
    return switch (access) {
      WorkspaceGeneralAccess.restricted => l10n.libraryAccessOnlyPeopleAdded,
      WorkspaceGeneralAccess.server => l10n.libraryAccessEveryoneOnServer,
      WorkspaceGeneralAccess.link => l10n.libraryAccessAnyoneWithLink,
    };
  }

  String _generalHint(AppLocalizations l10n, WorkspaceGeneralAccess access) {
    return switch (access) {
      WorkspaceGeneralAccess.restricted => l10n.resourceAudiencePrivateHint,
      WorkspaceGeneralAccess.server => l10n.libraryAccessEveryoneHint,
      WorkspaceGeneralAccess.link => l10n.resourceAudienceOpenHint,
    };
  }

  IconData _generalIcon(WorkspaceGeneralAccess access) {
    return switch (access) {
      WorkspaceGeneralAccess.restricted => UiUtils.platformIcon(
        ios: CupertinoIcons.lock,
        android: Icons.lock_outline,
      ),
      WorkspaceGeneralAccess.server => UiUtils.platformIcon(
        ios: CupertinoIcons.globe,
        android: Icons.public,
      ),
      WorkspaceGeneralAccess.link => UiUtils.platformIcon(
        ios: CupertinoIcons.link,
        android: Icons.link,
      ),
    };
  }

  Widget _generalAccessRow(BuildContext context, AppLocalizations l10n) {
    final theme = context.conduitTheme;
    final current = _generalAccess;
    final label = _generalLabel(l10n, current);
    final editable = !_isReadOnly && !_saving;
    final tile = WorkspaceResourceTile(
      grouped: true,
      icon: _generalIcon(current),
      iconColor: current == WorkspaceGeneralAccess.restricted
          ? theme.iconSecondary
          : theme.buttonPrimary,
      title: label,
      subtitle: _generalHint(l10n, current),
      showChevron: false,
      trailing: editable
          ? Icon(
              UiUtils.platformIcon(
                ios: CupertinoIcons.chevron_up_chevron_down,
                android: Icons.arrow_drop_down,
              ),
              size: IconSize.small,
              color: theme.iconSecondary,
            )
          : null,
    );
    final semanticLabel = '${l10n.libraryGeneralAccess}: $label';
    if (!editable) {
      return Semantics(
        key: const Key('workspace-access-general'),
        label: semanticLabel,
        excludeSemantics: true,
        child: tile,
      );
    }
    // The tile's own text is left out for the one label above, but the menu
    // button's tap stays: excluding everything below would drop it too.
    return Semantics(
      key: const Key('workspace-access-general'),
      container: true,
      button: true,
      label: semanticLabel,
      child: AdaptivePopupMenuButton.widget<WorkspaceGeneralAccess>(
        items: [
          for (final (option, enabled) in _generalOptions())
            AdaptivePopupMenuItem<WorkspaceGeneralAccess>(
              key: Key('workspace-access-general-${option.name}'),
              value: option,
              label: _generalLabel(l10n, option),
              icon: _generalIcon(option),
              checked: option == current,
              enabled: enabled,
            ),
        ],
        onSelected: (_, entry) {
          final value = entry.value;
          if (value != null) _pickGeneralAccess(value);
        },
        child: ExcludeSemantics(child: tile),
      ),
    );
  }

  Widget _ownerRow(
    BuildContext context,
    AppLocalizations l10n,
    WorkspaceAccessOwner owner,
  ) {
    final theme = context.conduitTheme;
    final title = owner.isYou ? l10n.you : owner.name!.trim();
    final email = owner.email?.trim();
    return WorkspaceResourceTile(
      key: const Key('workspace-access-owner'),
      grouped: true,
      leading: _PrincipalAvatar(
        title: title,
        imageUrl: owner.imageUrl,
        isGroup: false,
        known: true,
      ),
      title: title,
      subtitle: owner.isYou || email == null || email.isEmpty ? null : email,
      showChevron: false,
      trailing: Text(
        l10n.libraryAccessOwner,
        style: theme.bodySmall?.copyWith(color: theme.textSecondary),
      ),
    );
  }

  void _setLevel(WorkspaceSharedPrincipal principal, _AccessLevelAction act) {
    switch (act) {
      case _AccessLevelAction.view || _AccessLevelAction.edit:
        final canWrite = act == _AccessLevelAction.edit;
        if (canWrite == principal.canWrite) return;
        _update(
          setWorkspacePrincipalWrite(
            _grants,
            principal.type,
            principal.id,
            canWrite,
          ),
        );
      case _AccessLevelAction.keep:
        return;
      case _AccessLevelAction.remove:
        _update(
          removeWorkspacePrincipal(_grants, principal.type, principal.id),
        );
    }
  }

  Widget _principalRow(
    BuildContext context,
    AppLocalizations l10n,
    _PrincipalView view,
  ) {
    final theme = context.conduitTheme;
    final principal = view.principal;
    final suffix = '${principal.type.name}-${principal.id}';
    final level = principal.canWrite
        ? l10n.workspaceAccessCanEdit
        : l10n.libraryAccessCanView;
    final editable = !_isReadOnly;
    final Widget trailing;
    if (!editable) {
      trailing = Text(
        level,
        key: Key('workspace-access-level-$suffix'),
        style: theme.bodySmall?.copyWith(color: theme.textSecondary),
      );
    } else {
      trailing = Semantics(
        container: true,
        label: l10n.libraryAccessLevelFor(view.title),
        button: true,
        child: IgnorePointer(
          ignoring: _saving,
          child: AdaptivePopupMenuButton.text<_AccessLevelAction>(
            key: Key('workspace-access-level-$suffix'),
            label: '$level ▾',
            height: TouchTarget.minimum,
            tint: theme.textSecondary,
            items: [
              if (widget.allowWriteGrants) ...[
                AdaptivePopupMenuItem<_AccessLevelAction>(
                  key: Key('workspace-access-view-$suffix'),
                  value: _AccessLevelAction.view,
                  label: l10n.libraryAccessCanView,
                  checked: !principal.canWrite,
                ),
                AdaptivePopupMenuItem<_AccessLevelAction>(
                  key: Key('workspace-access-edit-$suffix'),
                  value: _AccessLevelAction.edit,
                  label: l10n.workspaceAccessCanEdit,
                  checked: principal.canWrite,
                ),
              ] else
                AdaptivePopupMenuItem<_AccessLevelAction>(
                  value: _AccessLevelAction.keep,
                  label: level,
                  checked: true,
                ),
              const AdaptivePopupMenuDivider(),
              AdaptivePopupMenuItem<_AccessLevelAction>(
                key: Key('workspace-access-remove-$suffix'),
                value: _AccessLevelAction.remove,
                label: l10n.workspaceAccessRemoveGrant,
                isDestructive: true,
              ),
            ],
            onSelected: (_, entry) {
              final action = entry.value;
              if (action != null && !_saving) _setLevel(principal, action);
            },
          ),
        ),
      );
    }
    return Semantics(
      key: Key('workspace-access-principal-$suffix'),
      container: true,
      customSemanticsActions: editable && !_saving
          ? {
              CustomSemanticsAction(
                label: l10n.libraryAccessRemovePrincipal(view.title),
              ): () =>
                  _setLevel(principal, _AccessLevelAction.remove),
            }
          : null,
      child: WorkspaceResourceTile(
        grouped: true,
        leading: _PrincipalAvatar(
          title: view.title,
          imageUrl: view.imageUrl,
          isGroup: principal.type == WorkspacePrincipalType.group,
          known: view.known,
        ),
        title: view.title,
        subtitle: view.subtitle,
        showChevron: false,
        trailing: trailing,
      ),
    );
  }
}

/// The sheet surface, capped between the status bar and the bottom of the
/// screen so a long access list scrolls instead of overflowing. The handle is
/// part of the child: the surface's own handle column would hand the content
/// unbounded height.
class _BoundedSheetSurface extends StatelessWidget {
  const _BoundedSheetSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The sheet route strips the top padding from its MediaQuery, so the
    // status bar height comes from the view itself.
    final view = View.of(context);
    final statusBar = view.padding.top / view.devicePixelRatio;
    final maxHeight = math.max(
      0.0,
      MediaQuery.sizeOf(context).height - statusBar - Spacing.sm,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: ConduitModalSheetSurface(showHandle: false, child: child),
    );
  }
}

/// A person's picture (or initial), or a group glyph.
class _PrincipalAvatar extends StatelessWidget {
  const _PrincipalAvatar({
    required this.title,
    required this.imageUrl,
    required this.isGroup,
    required this.known,
  });

  final String title;
  final String? imageUrl;
  final bool isGroup;
  final bool known;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    if (isGroup || !known) {
      return WorkspaceIconBadge(
        icon: isGroup
            ? UiUtils.platformIcon(
                ios: CupertinoIcons.person_3,
                android: Icons.groups_outlined,
              )
            : UiUtils.platformIcon(
                ios: CupertinoIcons.person,
                android: Icons.person_outline,
              ),
        color: theme.iconSecondary,
      );
    }
    return WorkspacePersonAvatar(name: title, imageUrl: imageUrl);
  }
}

/// A person's picture, showing their initial until it loads and if it
/// cannot. Unlike a bare [UserAvatar] it shows no spinner while loading, so a
/// list of people stays calm as their pictures arrive.
class WorkspacePersonAvatar extends StatelessWidget {
  const WorkspacePersonAvatar({
    super.key,
    required this.name,
    this.imageUrl,
    this.size = IconSize.xl,
  });

  final String name;
  final String? imageUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    final initial = trimmed.isEmpty
        ? null
        : String.fromCharCode(trimmed.runes.first).toUpperCase();
    Widget fallback(BuildContext context, double size) =>
        BrandService.createBrandAvatar(
          size: size,
          fallbackText: initial,
          context: context,
        );
    return AvatarImage(
      size: size,
      imageUrl: imageUrl,
      fallbackBuilder: fallback,
      placeholderBuilder: fallback,
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.xs,
        Spacing.xs,
        Spacing.xs,
        Spacing.sm,
      ),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: theme.label?.copyWith(color: theme.textSecondary),
        ),
      ),
    );
  }
}

class _AccessNotice extends StatelessWidget {
  const _AccessNotice({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
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
            UiUtils.platformIcon(
              ios: CupertinoIcons.info,
              android: Icons.info_outline,
            ),
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
}

// ---------------------------------------------------------------------------
// Principal picker (users + groups).
// ---------------------------------------------------------------------------

enum _PrincipalTab { people, groups }

/// Sheet that searches people and lists groups.
///
/// [show] returns the one principal tapped. [showMany] lets several be
/// checked across searches and both tabs and returns them when "Add (n)" is
/// pressed. Principals in [existing] (`type:id`) already have access: they are
/// shown checked and cannot be picked again.
///
/// Only the kinds the account may grant are offered, and only those are
/// requested: with neither allowed, nothing is fetched. Groups are listed once
/// and narrowed by the same search field.
class WorkspacePrincipalPicker extends StatefulWidget {
  const WorkspacePrincipalPicker({
    super.key,
    required this.directory,
    required this.allowUsers,
    required this.allowGroups,
    this.multiple = false,
    this.existing = const {},
    this.existingLabel,
  });

  final WorkspacePrincipalDirectory directory;
  final bool allowUsers;
  final bool allowGroups;

  /// Check several and add them together, instead of picking one by tapping.
  final bool multiple;

  /// `type:id` of principals that already have access.
  final Set<String> existing;

  /// Subtitle of an [existing] row, such as "Has access".
  final String? existingLabel;

  static Future<WorkspacePrincipalPreview?> show(
    BuildContext context, {
    required WorkspacePrincipalDirectory directory,
    required bool allowUsers,
    required bool allowGroups,
    Set<String> existing = const {},
    String? existingLabel,
  }) {
    return ThemedSheets.showCustom<WorkspacePrincipalPreview>(
      context: context,
      builder: (_) => WorkspacePrincipalPicker(
        directory: directory,
        allowUsers: allowUsers,
        allowGroups: allowGroups,
        existing: existing,
        existingLabel: existingLabel,
      ),
    );
  }

  static Future<List<WorkspacePrincipalPreview>?> showMany(
    BuildContext context, {
    required WorkspacePrincipalDirectory directory,
    required bool allowUsers,
    required bool allowGroups,
    Set<String> existing = const {},
    String? existingLabel,
  }) {
    return ThemedSheets.showCustom<List<WorkspacePrincipalPreview>>(
      context: context,
      builder: (_) => WorkspacePrincipalPicker(
        directory: directory,
        allowUsers: allowUsers,
        allowGroups: allowGroups,
        multiple: true,
        existing: existing,
        existingLabel: existingLabel,
      ),
    );
  }

  @override
  State<WorkspacePrincipalPicker> createState() =>
      _WorkspacePrincipalPickerState();
}

class _WorkspacePrincipalPickerState extends State<WorkspacePrincipalPicker> {
  static const _searchDebounce = Duration(milliseconds: 300);

  final _controller = TextEditingController();
  Timer? _debounce;
  bool _showingGroups = false;
  bool _loading = false;
  Object? _error;
  List<WorkspacePrincipalPreview> _people = const [];
  List<WorkspacePrincipalPreview>? _groups;
  int _requestGeneration = 0;

  /// What is checked, by `type:id`, in the order it was checked.
  final Map<String, WorkspacePrincipalPreview> _selected = {};

  @override
  void initState() {
    super.initState();
    // Default to the only permitted kind when user grants are disallowed.
    _showingGroups = !widget.allowUsers && widget.allowGroups;
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

  static String _keyOf(WorkspacePrincipalPreview principal) =>
      _principalKey(principal.type, principal.id);

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    if (_showingGroups) {
      // Groups are narrowed here, as the person types.
      setState(() {});
      return;
    }
    final generation = ++_requestGeneration;
    final query = value.trim();
    if (query.isEmpty) {
      setState(() {
        _people = const [];
        _error = null;
        _loading = false;
      });
      return;
    }
    setState(() {});
    _debounce = Timer(_searchDebounce, () {
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
        _people = results;
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
        _groups = results;
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

  void _retry() {
    final generation = ++_requestGeneration;
    if (_showingGroups) {
      _loadGroups(generation);
      return;
    }
    final query = _controller.text.trim();
    if (query.isNotEmpty) _searchUsers(query, generation);
  }

  void _selectTab(_PrincipalTab tab) {
    final groups = tab == _PrincipalTab.groups;
    if (_showingGroups == groups) return;
    _debounce?.cancel();
    final generation = ++_requestGeneration;
    setState(() {
      _showingGroups = groups;
      _people = const [];
      _error = null;
      _loading = false;
    });
    if (groups) {
      // The list is read once; switching back and forth only narrows it.
      if (_groups == null) _loadGroups(generation);
    } else {
      final query = _controller.text.trim();
      if (query.isNotEmpty) _searchUsers(query, generation);
    }
  }

  void _toggle(WorkspacePrincipalPreview principal) {
    final key = _keyOf(principal);
    setState(() {
      if (_selected.remove(key) == null) _selected[key] = principal;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final media = MediaQuery.of(context);
    final keyboardInset = media.viewInsets.bottom;
    // The sheet route strips the top padding from its MediaQuery, so the status
    // bar height comes from the view itself.
    final view = View.of(context);
    final statusBar = view.padding.top / view.devicePixelRatio;
    // The route does not move the sheet above the keyboard, so the picker lifts
    // itself by the inset and caps its surface between the status bar and the
    // keyboard. The handle sits in this column rather than in the surface's own
    // handle column, which would hand the content unbounded height.
    final availableHeight = math.max(
      0.0,
      media.size.height - keyboardInset - statusBar - Spacing.sm,
    );

    return AnimatedPadding(
      duration: context.motionDuration(AnimationDuration.fast),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: availableHeight),
        child: _surface(context, l10n, theme),
      ),
    );
  }

  Widget _surface(
    BuildContext context,
    AppLocalizations l10n,
    ConduitThemeExtension theme,
  ) {
    final canSearch = widget.allowUsers || widget.allowGroups;
    return ConduitModalSheetSurface(
      showHandle: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHandle(),
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(switch ((widget.allowUsers, widget.allowGroups)) {
                    (true, false) => l10n.workspaceAccessAddUsers,
                    (false, true) => l10n.workspaceAccessAddGroups,
                    _ => l10n.workspacePrincipalTitle,
                  }, style: theme.headingSmall),
                ),
              ),
              SheetCloseButton(
                tooltip: l10n.close,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          if (widget.allowUsers && widget.allowGroups) ...[
            AdaptiveSegmentedSelector<_PrincipalTab>(
              key: const Key('workspace-principal-tabs'),
              value: _showingGroups
                  ? _PrincipalTab.groups
                  : _PrincipalTab.people,
              onChanged: _selectTab,
              showIcons: false,
              options: [
                (
                  value: _PrincipalTab.people,
                  label: l10n.workspacePrincipalUsersTab,
                  cupertinoIcon: CupertinoIcons.person,
                  materialIcon: Icons.person_outline,
                  enabled: true,
                ),
                (
                  value: _PrincipalTab.groups,
                  label: l10n.workspacePrincipalGroupsTab,
                  cupertinoIcon: CupertinoIcons.person_3,
                  materialIcon: Icons.groups_outlined,
                  enabled: true,
                ),
              ],
            ),
            const SizedBox(height: Spacing.sm),
          ],
          if (canSearch) ...[
            ConduitGlassSearchField(
              controller: _controller,
              hintText: _showingGroups
                  ? l10n.libraryPickerSearchGroups
                  : l10n.workspacePrincipalSearchHint,
              query: _controller.text,
              onChanged: _onQueryChanged,
              onClear: () {
                _controller.clear();
                _onQueryChanged('');
              },
            ),
            const SizedBox(height: Spacing.sm),
          ],
          Flexible(child: _body(context, l10n)),
          if (widget.multiple && canSearch) ...[
            const SizedBox(height: Spacing.sm),
            ConduitButton(
              key: const Key('workspace-principal-add'),
              text: l10n.libraryPickerAddCount(_selected.length),
              isFullWidth: true,
              onPressed: _selected.isEmpty
                  ? null
                  : () => Navigator.of(
                      context,
                    ).pop(List<WorkspacePrincipalPreview>.of(_selected.values)),
            ),
          ],
        ],
      ),
    );
  }

  List<WorkspacePrincipalPreview> get _visibleGroups {
    final needle = _controller.text.trim().toLowerCase();
    final groups = _groups ?? const <WorkspacePrincipalPreview>[];
    if (needle.isEmpty) return groups;
    return [
      for (final group in groups)
        if (group.name.toLowerCase().contains(needle)) group,
    ];
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    if (!widget.allowUsers && !widget.allowGroups) {
      return _emptyMessage(
        context,
        key: const Key('workspace-principal-none-allowed'),
        icon: Icons.lock_outline,
        message: l10n.workspaceAccessGrantsDisabled,
      );
    }
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
        action: ConduitButton(
          key: const Key('workspace-principal-retry'),
          text: l10n.retry,
          isSecondary: true,
          isCompact: true,
          onPressed: _retry,
        ),
      );
    }
    if (!_showingGroups && _controller.text.trim().isEmpty) {
      return _emptyMessage(
        context,
        icon: Icons.search,
        message: l10n.workspacePrincipalSearchPrompt,
      );
    }
    final results = _showingGroups ? _visibleGroups : _people;
    if (results.isEmpty) {
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
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: results.length,
      itemBuilder: (context, index) => _row(context, l10n, results[index]),
    );
  }

  Widget _row(
    BuildContext context,
    AppLocalizations l10n,
    WorkspacePrincipalPreview principal,
  ) {
    final theme = context.conduitTheme;
    final isGroup = principal.type == WorkspacePrincipalType.group;
    final key = _keyOf(principal);
    final hasAccess = widget.existing.contains(key);
    final checked = hasAccess || _selected.containsKey(key);
    final email = principal.email?.trim();
    final name = principal.name.trim().isNotEmpty
        ? principal.name.trim()
        : (email != null && email.isNotEmpty
              ? email
              : isGroup
              ? l10n.libraryAccessUnknownGroup
              : l10n.libraryAccessUnknownPerson);
    final subtitle = hasAccess
        ? widget.existingLabel
        : (!isGroup && email != null && email.isNotEmpty && email != name
              ? email
              : null);
    VoidCallback? onTap;
    if (!hasAccess) {
      onTap = widget.multiple
          ? () {
              ConduitHaptics.selectionClick();
              _toggle(principal);
            }
          : () => Navigator.of(context).pop(principal);
    }
    return Material(
      color: Colors.transparent,
      child: AdaptiveListTile(
        key: Key('workspace-principal-${principal.type.name}-${principal.id}'),
        enabled: !hasAccess,
        selected: widget.multiple && checked && !hasAccess,
        leading: isGroup
            ? Icon(
                UiUtils.platformIcon(
                  ios: CupertinoIcons.person_3,
                  android: Icons.groups_outlined,
                ),
                color: theme.iconSecondary,
              )
            : WorkspacePersonAvatar(
                name: name,
                imageUrl: principal.profileImageUrl,
              ),
        title: MiddleEllipsisText(name),
        subtitle: subtitle == null
            ? null
            : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: widget.multiple
            ? AdaptiveCheckbox(
                key: Key(
                  'workspace-principal-check-${principal.type.name}-'
                  '${principal.id}',
                ),
                value: checked,
                onChanged: hasAccess ? null : (_) => _toggle(principal),
              )
            : null,
        onTap: onTap,
      ),
    );
  }

  Widget _emptyMessage(
    BuildContext context, {
    required IconData icon,
    required String message,
    Widget? action,
    Key? key,
  }) {
    final theme = context.conduitTheme;
    return Padding(
      key: key,
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: IconSize.extraLarge, color: theme.iconSecondary),
          const SizedBox(height: Spacing.sm),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.bodySmall?.copyWith(color: theme.textSecondary),
          ),
          if (action != null) ...[
            const SizedBox(height: Spacing.sm),
            action,
          ],
        ],
      ),
    );
  }
}
