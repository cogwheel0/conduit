import 'dart:async';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart'
    show currentUserProvider2;
import 'package:conduit_core/features/sharing/models/resource_access.dart';
import 'package:conduit_core/features/sharing/providers/principal_lookup.dart';
import 'package:conduit_core/features/sharing/providers/resource_access_controller.dart';
import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'settled.dart';
import 'workspace_service.dart';

/// Implements `access.*`: who may read or write one chat, folder or note,
/// or one of the workspace's models, knowledge bases, prompts, tools and
/// skills, as mobile's sharing sheets edit them.
///
/// The core's [ResourceAccessController] owns the reads and the write (the
/// grants the sheet cannot show are carried back untouched, the server's
/// answer is read back after a save), [ResourceAccessSnapshot] the shape of
/// the body, and [WorkspacePrincipalLookup] the names. The window holds one
/// row per person or group; a write grant carries its read row with it, as
/// mobile writes them.
///
/// A workspace item's grants are read and written through the
/// [WorkspaceService] (its section's notifier), which tells every window
/// with `workspace.changed`.
final class AccessService {
  AccessService(this._container, {WorkspaceService? workspace})
    : _workspaceService = workspace;

  final ProviderContainer _container;
  final WorkspaceService? _workspaceService;

  WorkspaceService get _workspace =>
      _workspaceService ?? WorkspaceService(_container);

  Future<AccessState> get(AccessRef ref) async {
    final session = _session();
    if (_workspaceKind(ref.kind) case final kind?) {
      final detail = await _workspace.get(WorkspaceRef(kind: kind, id: ref.id));
      return _workspaceState(ref.kind, ref.id, detail, session);
    }
    final controller = _controller(ref.kind, ref.id);
    final snapshot = await _guard(controller.load);
    return _state(ref.kind, ref.id, snapshot, session);
  }

  Future<AccessState> set(AccessEdit edit) async {
    final session = _session();
    if (_workspaceKind(edit.kind) case final kind?) {
      return _setWorkspace(kind, edit, session);
    }
    final controller = _controller(edit.kind, edit.id);
    final base = await _guard(controller.load);
    final sharing = await _sharing(edit.kind);
    if (!base.canEdit || !sharing.section.share) {
      throw _notEditable;
    }
    _refuseBeyondLimits(
      edit,
      base.editableGrants,
      _audienceOf(base.audience),
      sharing,
    );
    final fresh = await _guard(
      () => controller.save(
        base,
        _rows(edit, base.editableGrants),
        audience: switch (edit.audience) {
          null => null,
          AccessAudience.private => ResourceAudience.private,
          AccessAudience.public => ResourceAudience.public,
          AccessAudience.open => ResourceAudience.open,
        },
      ),
    );
    return _state(edit.kind, edit.id, fresh, session);
  }

  static const _notEditable = RpcError(
    code: ConduitErrorCodes.unauthorized,
    args: <String, String>{'reason': 'notEditable'},
    debugMessage: 'this account cannot change who has access',
  );

  /// A workspace item's grants, saved over its section's notifier and read
  /// back.
  Future<AccessState> _setWorkspace(
    WorkspaceKind kind,
    AccessEdit edit,
    Object session,
  ) async {
    final detail = await _workspace.get(WorkspaceRef(kind: kind, id: edit.id));
    final sharing = await _sharing(edit.kind);
    if (!detail.writeAccess || !sharing.section.share) throw _notEditable;
    final loaded = [for (final g in detail.grants) _input(g)];
    _refuseBeyondLimits(edit, loaded, _workspaceAudience(loaded), sharing);
    // Read under another account: nothing is written for this one.
    _sameAccount(session);
    final rows = _rows(edit, loaded);
    final saved = await _workspace.setAccess(
      WorkspaceAccessEdit(
        kind: kind,
        id: edit.id,
        grants: <WorkspaceGrant>[
          for (final row in rows)
            WorkspaceGrant(
              principalType: row.principalType.name,
              principalId: row.principalId,
              write: row.permission == WorkspaceGrantPermission.write,
            ),
        ],
      ),
    );
    return _workspaceState(edit.kind, edit.id, saved, session);
  }

  /// The rows a save writes: one read row per person or group, a write row
  /// beside it for an editor (never for a chat), and the audience row
  /// ("every user") as chosen, or as [loaded] had it when not chosen.
  static List<WorkspaceAccessGrantInput> _rows(
    AccessEdit edit,
    List<WorkspaceAccessGrantInput> loaded,
  ) {
    final audience = edit.audience;
    return <WorkspaceAccessGrantInput>[
      for (final grant in edit.grants)
        if (grant.principalId.isNotEmpty && grant.principalId != '*') ...[
          WorkspaceAccessGrantInput(
            principalType: _principalType(grant.principalType),
            principalId: grant.principalId,
            permission: WorkspaceGrantPermission.read,
          ),
          if (grant.write && edit.kind != AccessResourceKind.chat)
            WorkspaceAccessGrantInput(
              principalType: _principalType(grant.principalType),
              principalId: grant.principalId,
              permission: WorkspaceGrantPermission.write,
            ),
        ],
      // The audience row ("every user"), kept as the server had it unless the
      // user chose one.
      if (audience == null)
        for (final row in loaded)
          if (row.principalId == '*') row,
      if (audience == AccessAudience.public)
        const WorkspaceAccessGrantInput(
          principalType: WorkspacePrincipalType.user,
          principalId: '*',
          permission: WorkspaceGrantPermission.read,
        ),
    ];
  }

  /// What the account may not give, as the sheet hides it: a person or a
  /// group not already granted when such grants are off, and an audience
  /// the item cannot have or the account may not choose. Rows the server
  /// already holds are carried back as they are.
  static void _refuseBeyondLimits(
    AccessEdit edit,
    List<WorkspaceAccessGrantInput> loaded,
    AccessAudience current,
    ResourceSharingCapabilities sharing,
  ) {
    Never refuse(String reason, String message) => throw RpcError(
      code: ConduitErrorCodes.unauthorized,
      args: <String, String>{'reason': reason},
      debugMessage: message,
    );
    final held = <String>{
      for (final row in loaded)
        '${row.principalType.name}:${row.principalId}',
    };
    for (final grant in edit.grants) {
      if (grant.principalId.isEmpty || grant.principalId == '*') continue;
      final type = _principalType(grant.principalType);
      if (held.contains('${type.name}:${grant.principalId}')) continue;
      final allowed = type == WorkspacePrincipalType.group
          ? sharing.allowGroupGrants
          : sharing.allowUserGrants;
      if (!allowed) {
        refuse('${type.name}Grants', 'this account may not add ${type.name}s');
      }
    }
    final audience = edit.audience;
    if (audience == null || audience == current) return;
    final allowed = switch (audience) {
      AccessAudience.private => edit.kind != AccessResourceKind.folder,
      AccessAudience.public =>
        edit.kind != AccessResourceKind.folder && sharing.section.sharePublicly,
      AccessAudience.open =>
        edit.kind == AccessResourceKind.chat && sharing.shareOpenly,
    };
    if (!allowed) refuse('audience', 'this account may not choose $audience');
  }

  static AccessAudience _audienceOf(ResourceAudience audience) =>
      switch (audience) {
        ResourceAudience.private => AccessAudience.private,
        ResourceAudience.public => AccessAudience.public,
        ResourceAudience.open => AccessAudience.open,
      };

  /// A workspace item is public when every user may read it.
  static AccessAudience _workspaceAudience(
    List<WorkspaceAccessGrantInput> rows,
  ) => rows.any((r) => r.principalId == '*' && !_isWrite(r))
      ? AccessAudience.public
      : AccessAudience.private;

  static WorkspaceAccessGrantInput _input(WorkspaceGrant grant) =>
      WorkspaceAccessGrantInput(
        principalType: _principalType(grant.principalType),
        principalId: grant.principalId,
        permission: grant.write
            ? WorkspaceGrantPermission.write
            : WorkspaceGrantPermission.read,
      );

  /// The workspace section [kind] names, when it names one.
  static WorkspaceKind? _workspaceKind(AccessResourceKind kind) =>
      switch (kind) {
        AccessResourceKind.model => WorkspaceKind.models,
        AccessResourceKind.knowledge => WorkspaceKind.knowledge,
        AccessResourceKind.prompt => WorkspaceKind.prompts,
        AccessResourceKind.tool => WorkspaceKind.tools,
        AccessResourceKind.skill => WorkspaceKind.skills,
        AccessResourceKind.chat ||
        AccessResourceKind.folder ||
        AccessResourceKind.note => null,
      };

  Future<AccessState> _workspaceState(
    AccessResourceKind kind,
    String id,
    WorkspaceDetail detail,
    Object session,
  ) {
    final rows = [for (final g in detail.grants) _input(g)];
    return _stateOf(
      kind,
      id,
      rows: rows,
      audience: _workspaceAudience(rows),
      canEdit: detail.writeAccess,
      ownerName: detail.ownerName,
      session: session,
    );
  }

  static bool _isWrite(WorkspaceAccessGrantInput row) =>
      row.permission == WorkspaceGrantPermission.write;

  /// Users matching [query] (a user who may not search users still gets the
  /// groups), and the account's groups.
  ///
  /// Asked and answered under one account: an answer that arrives after a
  /// switch is refused, never shown to the next account.
  Future<AccessPrincipals> principals(AccessPrincipalQuery query) async {
    final session = _container.read(openWebUiAuthSessionEpochProvider);
    final api = _api();
    final text = query.query.trim().toLowerCase();
    final groups = await api.getWorkspaceGroups().catchError(
      (Object _) => <WorkspacePrincipalPreview>[],
    );
    final users = text.isEmpty
        ? const <WorkspacePrincipalPreview>[]
        : await api
              .searchWorkspaceUsers(text)
              .then((page) => page.items)
              .catchError((Object _) => <WorkspacePrincipalPreview>[]);
    if (!identical(
          session,
          _container.read(openWebUiAuthSessionEpochProvider),
        ) ||
        !identical(api, _container.read(apiServiceProvider))) {
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        debugMessage: 'the account changed',
      );
    }
    final me = _container.read(currentUserProvider2)?.id;
    return AccessPrincipals(
      items: <AccessPrincipal>[
        for (final p in groups)
          if (text.isEmpty || p.name.toLowerCase().contains(text))
            AccessPrincipal(type: 'group', id: p.id, name: p.name),
        for (final p in users)
          if (p.id != me)
            AccessPrincipal(
              type: 'user',
              id: p.id,
              name: p.name,
              email: p.email,
            ),
      ],
    );
  }

  Object _session() => _container.read(openWebUiAuthSessionEpochProvider);

  /// Refuses an answer read under [session] once another account is in use.
  void _sameAccount(Object session) {
    if (!identical(session, _session())) {
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        debugMessage: 'the account changed',
      );
    }
  }

  /// [snapshot] as the window shows it, named. Read under [session]: once
  /// another account is in use (while the names are looked up, say), the
  /// grants, names and emails are not shown to it.
  Future<AccessState> _state(
    AccessResourceKind kind,
    String id,
    ResourceAccessSnapshot snapshot,
    Object session,
  ) async => _stateOf(
    kind,
    id,
    rows: snapshot.editableGrants,
    audience: _audienceOf(snapshot.audience),
    canEdit: snapshot.canEdit,
    ownerName: await _ownerName(kind, id),
    session: session,
  );

  Future<AccessState> _stateOf(
    AccessResourceKind kind,
    String id, {
    required List<WorkspaceAccessGrantInput> rows,
    required AccessAudience audience,
    required bool canEdit,
    required String? ownerName,
    required Object session,
  }) async {
    final sharing = await _sharing(kind);
    final byPrincipal = <String, AccessGrantDto>{};
    for (final row in rows) {
      if (row.principalId == '*') continue;
      final key = '${row.principalType.name}:${row.principalId}';
      final known = byPrincipal[key];
      final write = row.permission == WorkspaceGrantPermission.write;
      byPrincipal[key] =
          (known ??
                  AccessGrantDto(
                    principalType: row.principalType.name,
                    principalId: row.principalId,
                  ))
              .copyWith(write: (known?.write ?? false) || write);
    }
    final lookup = _container.read(workspacePrincipalLookupProvider);
    if (lookup != null) {
      try {
        await lookup.resolve(<({WorkspacePrincipalType type, String id})>[
          for (final row in rows)
            (type: row.principalType, id: row.principalId),
        ]);
      } on Object {
        // Unnamed rows read "Unknown person" in the window.
      }
    }
    final grants = <AccessGrantDto>[
      for (final grant in byPrincipal.values)
        () {
          final preview = lookup?.cached(
            _principalType(grant.principalType),
            grant.principalId,
          );
          return grant.copyWith(
            name: preview?.name ?? '',
            email: preview?.email,
          );
        }(),
    ];
    // After every lookup above: none of it is shown to another account.
    _sameAccount(session);
    return AccessState(
      kind: kind,
      id: id,
      grants: grants,
      audience: audience,
      canEdit: canEdit && sharing.section.share,
      allowUsers: sharing.allowUserGrants,
      allowGroups: sharing.allowGroupGrants,
      allowWrite: kind != AccessResourceKind.chat,
      // A folder has no audience of its own (mobile shows none).
      allowPublic:
          kind != AccessResourceKind.folder && sharing.section.sharePublicly,
      // Only a chat has "Anyone with the link" (mobile's audience choice).
      allowOpen: kind == AccessResourceKind.chat && sharing.shareOpenly,
      ownerName: ownerName,
    );
  }

  Future<String?> _ownerName(AccessResourceKind kind, String id) async {
    if (kind != AccessResourceKind.folder) return null;
    try {
      final folders = await readSettled(_container, foldersProvider.future);
      final folder = folders.where((f) => f.id == id).firstOrNull;
      if (folder?.shared == true) return folder!.ownerName;
    } on Object {
      // Fall back to the account's own name.
    }
    return _container.read(currentUserProvider2)?.name;
  }

  Future<ResourceSharingCapabilities> _sharing(AccessResourceKind kind) async {
    try {
      final caps = await readSettled(
        _container,
        workspaceCapabilitiesProvider.future,
      );
      // A workspace section's own permissions, with the server's
      // user and group sharing switches.
      ResourceSharingCapabilities section(WorkspaceSectionCapabilities s) =>
          ResourceSharingCapabilities(
            section: s,
            allowUserGrants: caps.allowUserGrants,
            allowGroupGrants: caps.allowGroupGrants,
          );
      return switch (kind) {
        AccessResourceKind.chat => caps.chats,
        AccessResourceKind.folder => caps.folders,
        AccessResourceKind.note => caps.notes,
        AccessResourceKind.model => section(caps.models),
        AccessResourceKind.knowledge => section(caps.knowledge),
        AccessResourceKind.prompt => section(caps.prompts),
        AccessResourceKind.tool => section(caps.tools),
        AccessResourceKind.skill => section(caps.skills),
      };
    } on Object {
      return ResourceSharingCapabilities.none;
    }
  }

  ResourceAccessController _controller(AccessResourceKind kind, String id) {
    final controller = ResourceAccessController.open(
      _container,
      kind: switch (kind) {
        AccessResourceKind.chat => ResourceKind.chat,
        AccessResourceKind.folder => ResourceKind.folder,
        AccessResourceKind.note => ResourceKind.note,
        // Routed to the workspace before this.
        _ => throw StateError('$kind is a workspace item'),
      },
      resourceId: id,
    );
    if (controller == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'no Open WebUI account is signed in',
      );
    }
    return controller;
  }

  ApiService _api() {
    final api = _container.read(apiServiceProvider);
    if (api == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'no Open WebUI account is signed in',
      );
    }
    return api;
  }

  static WorkspacePrincipalType _principalType(String type) => type == 'group'
      ? WorkspacePrincipalType.group
      : WorkspacePrincipalType.user;

  static Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on ResourceAccessException catch (error) {
      throw RpcError(
        code: switch (error.failure) {
          ResourceAccessFailure.sessionChanged => ConduitErrorCodes.conflict,
          ResourceAccessFailure.denied ||
          ResourceAccessFailure.notEditable => ConduitErrorCodes.unauthorized,
          ResourceAccessFailure.missing => ConduitErrorCodes.notFound,
        },
        args: <String, String>{'reason': error.failure.name},
        debugMessage: 'access: ${error.failure.name}',
      );
    }
  }
}
