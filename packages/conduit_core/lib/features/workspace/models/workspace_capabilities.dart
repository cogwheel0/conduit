import 'package:meta/meta.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';

@immutable
class WorkspaceSectionCapabilities {
  const WorkspaceSectionCapabilities({
    this.manage = false,
    this.importItems = false,
    this.exportItems = false,
    this.share = false,
    this.sharePublicly = false,
  });

  final bool manage;
  final bool importItems;
  final bool exportItems;
  final bool share;
  final bool sharePublicly;

  static const none = WorkspaceSectionCapabilities();
  static const all = WorkspaceSectionCapabilities(
    manage: true,
    importItems: true,
    exportItems: true,
    share: true,
    sharePublicly: true,
  );
}

/// What the account may do when it edits who can see one chat, folder or
/// note. Each resource has its own caller in Open WebUI, so each carries its
/// own answers for the grant kinds rather than sharing the workspace pair.
@immutable
class ResourceSharingCapabilities {
  const ResourceSharingCapabilities({
    this.section = WorkspaceSectionCapabilities.none,
    this.allowUserGrants = false,
    this.allowGroupGrants = false,
    this.shareOpenly = false,
  });

  /// [WorkspaceSectionCapabilities.share] is whether access may be edited at
  /// all; [WorkspaceSectionCapabilities.sharePublicly] whether everyone on the
  /// server may be granted read.
  final WorkspaceSectionCapabilities section;
  final bool allowUserGrants;
  final bool allowGroupGrants;

  /// Whether the account may open the resource to anyone with the link
  /// (`sharing.open_chats`). Only chats have this audience.
  final bool shareOpenly;

  static const none = ResourceSharingCapabilities();
  static const all = ResourceSharingCapabilities(
    section: WorkspaceSectionCapabilities.all,
    allowUserGrants: true,
    allowGroupGrants: true,
    shareOpenly: true,
  );
}

@immutable
class WorkspaceCapabilities {
  const WorkspaceCapabilities({
    this.models = WorkspaceSectionCapabilities.none,
    this.knowledge = WorkspaceSectionCapabilities.none,
    this.prompts = WorkspaceSectionCapabilities.none,
    this.skills = WorkspaceSectionCapabilities.none,
    this.tools = WorkspaceSectionCapabilities.none,
    this.allowUserGrants = false,
    this.allowGroupGrants = false,
    this.notes = ResourceSharingCapabilities.none,
    this.folders = ResourceSharingCapabilities.none,
    this.chats = ResourceSharingCapabilities.none,
  });

  final WorkspaceSectionCapabilities models;
  final WorkspaceSectionCapabilities knowledge;
  final WorkspaceSectionCapabilities prompts;
  final WorkspaceSectionCapabilities skills;
  final WorkspaceSectionCapabilities tools;

  /// Whether access grants may name individual users
  /// (`access_grants.allow_users`).
  final bool allowUserGrants;

  /// Whether access grants may name groups (`access_grants.allow_groups`).
  /// Independent of [allowUserGrants].
  final bool allowGroupGrants;

  /// Sharing of the account's own notes, folders and chats. These are not
  /// workspace sections; they ride on the same permission read so there is one
  /// account-scoped source for what the user may grant.
  final ResourceSharingCapabilities notes;
  final ResourceSharingCapabilities folders;
  final ResourceSharingCapabilities chats;

  static const none = WorkspaceCapabilities();
  static const all = WorkspaceCapabilities(
    models: WorkspaceSectionCapabilities.all,
    knowledge: WorkspaceSectionCapabilities.all,
    prompts: WorkspaceSectionCapabilities.all,
    skills: WorkspaceSectionCapabilities.all,
    tools: WorkspaceSectionCapabilities.all,
    allowUserGrants: true,
    allowGroupGrants: true,
    notes: ResourceSharingCapabilities.all,
    folders: ResourceSharingCapabilities(
      section: WorkspaceSectionCapabilities(share: true),
      allowUserGrants: true,
      allowGroupGrants: true,
    ),
    chats: ResourceSharingCapabilities.all,
  );

  factory WorkspaceCapabilities.fromPermissions(Map<String, dynamic> json) {
    final workspace = workspaceJsonMap(json['workspace']);
    final sharing = workspaceJsonMap(json['sharing']);
    final accessGrants = workspaceJsonMap(json['access_grants']);
    final chat = workspaceJsonMap(json['chat']);

    WorkspaceSectionCapabilities section(String key) =>
        WorkspaceSectionCapabilities(
          manage: workspaceBool(workspace[key]),
          importItems: workspaceBool(workspace['${key}_import']),
          exportItems: workspaceBool(workspace['${key}_export']),
          share: workspaceBool(sharing[key]),
          sharePublicly: workspaceBool(sharing['public_$key']),
        );

    return WorkspaceCapabilities(
      models: section('models'),
      knowledge: section('knowledge'),
      prompts: section('prompts'),
      skills: section('skills'),
      tools: section('tools'),
      // Every pinned Open WebUI workspace editor (models, tools, prompts,
      // skills, knowledge) treats a missing grant permission as allowed
      // (`allow_* ?? true`); the server strips what the account may not grant.
      allowUserGrants: workspaceBool(accessGrants['allow_users'], true),
      allowGroupGrants: workspaceBool(accessGrants['allow_groups'], true),
      // Pinned callers: the note editor and chat share modal treat a missing
      // grant permission as allowed, the folder modal only does so for groups.
      notes: ResourceSharingCapabilities(
        section: WorkspaceSectionCapabilities(
          share: workspaceBool(sharing['notes']),
          sharePublicly: workspaceBool(sharing['public_notes']),
        ),
        allowUserGrants: workspaceBool(accessGrants['allow_users'], true),
        allowGroupGrants: workspaceBool(accessGrants['allow_groups'], true),
      ),
      folders: ResourceSharingCapabilities(
        section: WorkspaceSectionCapabilities(
          share: workspaceBool(sharing['folders']),
        ),
        allowUserGrants: workspaceBool(accessGrants['allow_users']),
        allowGroupGrants: workspaceBool(accessGrants['allow_groups'], true),
      ),
      // Editing chat access is part of the share flow, which `chat.share`
      // governs; only the audiences are separate permissions.
      chats: ResourceSharingCapabilities(
        section: WorkspaceSectionCapabilities(
          share: workspaceBool(chat['share'], true),
          sharePublicly: workspaceBool(sharing['public_chats']),
        ),
        allowUserGrants: workspaceBool(accessGrants['allow_users'], true),
        allowGroupGrants: workspaceBool(accessGrants['allow_groups'], true),
        shareOpenly: workspaceBool(sharing['open_chats']),
      ),
    );
  }
}
