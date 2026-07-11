import 'package:flutter/foundation.dart';

import 'workspace_common.dart';

@immutable
class WorkspaceModelSummary {
  const WorkspaceModelSummary({
    required this.id,
    required this.name,
    required this.userId,
    this.baseModelId,
    this.meta = const {},
    this.params = const {},
    this.accessGrants = const [],
    this.isActive = true,
    this.writeAccess = false,
    this.owner,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  final String id;
  final String name;
  final String userId;
  final String? baseModelId;
  final Map<String, dynamic> meta;
  final Map<String, dynamic> params;
  final List<WorkspaceAccessGrant> accessGrants;
  final bool isActive;
  final bool writeAccess;
  final WorkspaceOwnerPreview? owner;
  final int createdAt;
  final int updatedAt;

  factory WorkspaceModelSummary.fromJson(Map<String, dynamic> json) =>
      WorkspaceModelSummary(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        userId: json['user_id']?.toString() ?? '',
        baseModelId: json['base_model_id']?.toString(),
        meta: workspaceJsonMap(json['meta']),
        params: workspaceJsonMap(json['params']),
        accessGrants: workspaceGrants(json['access_grants']),
        isActive: workspaceBool(json['is_active'], true),
        writeAccess: workspaceBool(json['write_access']),
        owner: json['user'] is Map
            ? WorkspaceOwnerPreview.fromJson(workspaceJsonMap(json['user']))
            : null,
        createdAt: workspaceInt(json['created_at']),
        updatedAt: workspaceInt(json['updated_at']),
      );
}

typedef WorkspaceModelDetail = WorkspaceModelSummary;

@immutable
class WorkspaceModelForm {
  const WorkspaceModelForm({
    required this.id,
    required this.name,
    this.baseModelId,
    this.meta = const {},
    this.params = const {},
    this.accessGrants = const [],
    this.isActive = true,
  });

  final String id;
  final String name;
  final String? baseModelId;
  final Map<String, dynamic> meta;
  final Map<String, dynamic> params;
  final List<WorkspaceAccessGrantInput> accessGrants;
  final bool isActive;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'base_model_id': baseModelId,
    'name': name,
    'meta': meta,
    'params': params,
    'access_grants': workspaceGrantInputs(accessGrants),
    'is_active': isActive,
  };
}

@immutable
class WorkspacePromptSummary {
  const WorkspacePromptSummary({
    required this.id,
    required this.command,
    required this.name,
    required this.content,
    required this.userId,
    this.data,
    this.meta,
    this.tags = const [],
    this.accessGrants = const [],
    this.isActive = true,
    this.versionId,
    this.writeAccess = false,
    this.owner,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  final String id;
  final String command;
  final String name;
  final String content;
  final String userId;
  final Map<String, dynamic>? data;
  final Map<String, dynamic>? meta;
  final List<String> tags;
  final List<WorkspaceAccessGrant> accessGrants;
  final bool isActive;
  final String? versionId;
  final bool writeAccess;
  final WorkspaceOwnerPreview? owner;
  final int createdAt;
  final int updatedAt;

  factory WorkspacePromptSummary.fromJson(Map<String, dynamic> json) =>
      WorkspacePromptSummary(
        id: json['id']?.toString() ?? '',
        command: json['command']?.toString() ?? '',
        name: json['name']?.toString() ?? json['title']?.toString() ?? '',
        content: json['content']?.toString() ?? '',
        userId: json['user_id']?.toString() ?? '',
        data: json['data'] is Map ? workspaceJsonMap(json['data']) : null,
        meta: json['meta'] is Map ? workspaceJsonMap(json['meta']) : null,
        tags: workspaceStringList(json['tags']),
        accessGrants: workspaceGrants(json['access_grants']),
        isActive: workspaceBool(json['is_active'], true),
        versionId: json['version_id']?.toString(),
        writeAccess: workspaceBool(json['write_access']),
        owner: json['user'] is Map
            ? WorkspaceOwnerPreview.fromJson(workspaceJsonMap(json['user']))
            : null,
        createdAt: workspaceInt(json['created_at']),
        updatedAt: workspaceInt(json['updated_at']),
      );
}

typedef WorkspacePromptDetail = WorkspacePromptSummary;

@immutable
class WorkspacePromptForm {
  const WorkspacePromptForm({
    required this.command,
    required this.name,
    required this.content,
    this.data,
    this.meta,
    this.tags = const [],
    this.accessGrants = const [],
    this.versionId,
    this.commitMessage,
    this.isProduction = true,
  });

  final String command;
  final String name;
  final String content;
  final Map<String, dynamic>? data;
  final Map<String, dynamic>? meta;
  final List<String> tags;
  final List<WorkspaceAccessGrantInput> accessGrants;
  final String? versionId;
  final String? commitMessage;
  final bool isProduction;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'command': command,
    'name': name,
    'content': content,
    'data': data,
    'meta': meta,
    'tags': tags,
    'access_grants': workspaceGrantInputs(accessGrants),
    'version_id': versionId,
    'commit_message': commitMessage,
    'is_production': isProduction,
  };
}

@immutable
class WorkspacePromptHistoryEntry {
  const WorkspacePromptHistoryEntry({
    required this.id,
    required this.promptId,
    required this.snapshot,
    required this.userId,
    required this.createdAt,
    this.parentId,
    this.commitMessage,
    this.owner,
  });

  final String id;
  final String promptId;
  final String? parentId;
  final Map<String, dynamic> snapshot;
  final String userId;
  final String? commitMessage;
  final int createdAt;
  final WorkspaceOwnerPreview? owner;

  factory WorkspacePromptHistoryEntry.fromJson(Map<String, dynamic> json) =>
      WorkspacePromptHistoryEntry(
        id: json['id']?.toString() ?? '',
        promptId: json['prompt_id']?.toString() ?? '',
        parentId: json['parent_id']?.toString(),
        snapshot: workspaceJsonMap(json['snapshot']),
        userId: json['user_id']?.toString() ?? '',
        commitMessage: json['commit_message']?.toString(),
        createdAt: workspaceInt(json['created_at']),
        owner: json['user'] is Map
            ? WorkspaceOwnerPreview.fromJson(workspaceJsonMap(json['user']))
            : null,
      );
}

@immutable
class WorkspaceToolSummary {
  const WorkspaceToolSummary({
    required this.id,
    required this.name,
    required this.userId,
    this.content,
    this.specs = const [],
    this.meta = const {},
    this.accessGrants = const [],
    this.writeAccess = false,
    this.owner,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  final String id;
  final String name;
  final String userId;
  final String? content;
  final List<Map<String, dynamic>> specs;
  final Map<String, dynamic> meta;
  final List<WorkspaceAccessGrant> accessGrants;
  final bool writeAccess;
  final WorkspaceOwnerPreview? owner;
  final int createdAt;
  final int updatedAt;

  factory WorkspaceToolSummary.fromJson(Map<String, dynamic> json) =>
      WorkspaceToolSummary(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        userId: json['user_id']?.toString() ?? '',
        content: json['content']?.toString(),
        specs: workspaceJsonList(json['specs'] ?? json['spec']),
        meta: workspaceJsonMap(json['meta']),
        accessGrants: workspaceGrants(json['access_grants']),
        writeAccess: workspaceBool(json['write_access']),
        owner: json['user'] is Map
            ? WorkspaceOwnerPreview.fromJson(workspaceJsonMap(json['user']))
            : null,
        createdAt: workspaceInt(json['created_at']),
        updatedAt: workspaceInt(json['updated_at']),
      );
}

typedef WorkspaceToolDetail = WorkspaceToolSummary;

@immutable
class WorkspaceToolForm {
  const WorkspaceToolForm({
    required this.id,
    required this.name,
    required this.content,
    this.meta = const {},
    this.accessGrants = const [],
  });

  final String id;
  final String name;
  final String content;
  final Map<String, dynamic> meta;
  final List<WorkspaceAccessGrantInput> accessGrants;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'content': content,
    'meta': meta,
    'access_grants': workspaceGrantInputs(accessGrants),
  };
}

@immutable
class WorkspaceValveSpec {
  const WorkspaceValveSpec({required this.schema});

  final Map<String, dynamic> schema;

  factory WorkspaceValveSpec.fromJson(Map<String, dynamic> json) =>
      WorkspaceValveSpec(schema: json);

  /// The JSON-schema `properties` map (one entry per valve field).
  Map<String, dynamic> get properties => workspaceJsonMap(schema['properties']);

  /// Property keys marked `required` in the schema.
  List<String> get required => workspaceStringList(schema['required']);

  /// Whether the spec declares no valve fields.
  bool get isEmpty => properties.isEmpty;
}

@immutable
class WorkspaceSkillSummary {
  const WorkspaceSkillSummary({
    required this.id,
    required this.name,
    required this.userId,
    this.description,
    this.content,
    this.meta = const {},
    this.isActive = true,
    this.accessGrants = const [],
    this.writeAccess = false,
    this.owner,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  final String id;
  final String name;
  final String userId;
  final String? description;
  final String? content;
  final Map<String, dynamic> meta;
  final bool isActive;
  final List<WorkspaceAccessGrant> accessGrants;
  final bool writeAccess;
  final WorkspaceOwnerPreview? owner;
  final int createdAt;
  final int updatedAt;

  factory WorkspaceSkillSummary.fromJson(Map<String, dynamic> json) =>
      WorkspaceSkillSummary(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        userId: json['user_id']?.toString() ?? '',
        description: json['description']?.toString(),
        content: json['content']?.toString(),
        meta: workspaceJsonMap(json['meta']),
        isActive: workspaceBool(json['is_active'], true),
        accessGrants: workspaceGrants(json['access_grants']),
        writeAccess: workspaceBool(json['write_access']),
        owner: json['user'] is Map
            ? WorkspaceOwnerPreview.fromJson(workspaceJsonMap(json['user']))
            : null,
        createdAt: workspaceInt(json['created_at']),
        updatedAt: workspaceInt(json['updated_at']),
      );
}

typedef WorkspaceSkillDetail = WorkspaceSkillSummary;

@immutable
class WorkspaceSkillForm {
  const WorkspaceSkillForm({
    required this.id,
    required this.name,
    required this.content,
    this.description,
    this.meta = const {},
    this.isActive = true,
    this.accessGrants = const [],
  });

  final String id;
  final String name;
  final String? description;
  final String content;
  final Map<String, dynamic> meta;
  final bool isActive;
  final List<WorkspaceAccessGrantInput> accessGrants;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'description': description,
    'content': content,
    'meta': meta,
    'is_active': isActive,
    'access_grants': workspaceGrantInputs(accessGrants),
  };
}
