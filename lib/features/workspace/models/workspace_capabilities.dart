import 'package:flutter/foundation.dart';

import 'workspace_common.dart';

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

@immutable
class WorkspaceCapabilities {
  const WorkspaceCapabilities({
    this.models = WorkspaceSectionCapabilities.none,
    this.knowledge = WorkspaceSectionCapabilities.none,
    this.prompts = WorkspaceSectionCapabilities.none,
    this.skills = WorkspaceSectionCapabilities.none,
    this.tools = WorkspaceSectionCapabilities.none,
    this.allowUserGrants = false,
  });

  final WorkspaceSectionCapabilities models;
  final WorkspaceSectionCapabilities knowledge;
  final WorkspaceSectionCapabilities prompts;
  final WorkspaceSectionCapabilities skills;
  final WorkspaceSectionCapabilities tools;
  final bool allowUserGrants;

  static const none = WorkspaceCapabilities();
  static const all = WorkspaceCapabilities(
    models: WorkspaceSectionCapabilities.all,
    knowledge: WorkspaceSectionCapabilities.all,
    prompts: WorkspaceSectionCapabilities.all,
    skills: WorkspaceSectionCapabilities.all,
    tools: WorkspaceSectionCapabilities.all,
    allowUserGrants: true,
  );

  factory WorkspaceCapabilities.fromPermissions(Map<String, dynamic> json) {
    final workspace = workspaceJsonMap(json['workspace']);
    final sharing = workspaceJsonMap(json['sharing']);
    final accessGrants = workspaceJsonMap(json['access_grants']);

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
      allowUserGrants: workspaceBool(accessGrants['allow_users']),
    );
  }
}
