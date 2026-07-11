import 'package:flutter/foundation.dart';

import 'workspace_common.dart';

@immutable
class WorkspaceKnowledgeSummary {
  const WorkspaceKnowledgeSummary({
    required this.id,
    required this.name,
    required this.userId,
    this.description = '',
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
  final String description;
  final Map<String, dynamic> meta;
  final List<WorkspaceAccessGrant> accessGrants;
  final bool writeAccess;
  final WorkspaceOwnerPreview? owner;
  final int createdAt;
  final int updatedAt;

  factory WorkspaceKnowledgeSummary.fromJson(Map<String, dynamic> json) =>
      WorkspaceKnowledgeSummary(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        userId: json['user_id']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
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

@immutable
class WorkspaceKnowledgeForm {
  const WorkspaceKnowledgeForm({
    required this.name,
    this.description = '',
    this.accessGrants = const [],
  });

  final String name;
  final String description;
  final List<WorkspaceAccessGrantInput> accessGrants;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'description': description,
    'access_grants': workspaceGrantInputs(accessGrants),
  };
}

@immutable
class WorkspaceKnowledgeDirectory {
  const WorkspaceKnowledgeDirectory({
    required this.id,
    required this.knowledgeId,
    required this.name,
    required this.userId,
    this.parentId,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  final String id;
  final String knowledgeId;
  final String? parentId;
  final String name;
  final String userId;
  final int createdAt;
  final int updatedAt;

  factory WorkspaceKnowledgeDirectory.fromJson(Map<String, dynamic> json) =>
      WorkspaceKnowledgeDirectory(
        id: json['id']?.toString() ?? '',
        knowledgeId: json['knowledge_id']?.toString() ?? '',
        parentId: json['parent_id']?.toString(),
        name: json['name']?.toString() ?? '',
        userId: json['user_id']?.toString() ?? '',
        createdAt: workspaceInt(json['created_at']),
        updatedAt: workspaceInt(json['updated_at']),
      );
}

@immutable
class WorkspaceKnowledgeFile {
  const WorkspaceKnowledgeFile({
    required this.id,
    required this.filename,
    this.contentType,
    this.directoryId,
    this.meta = const {},
    this.data = const {},
    this.size,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  final String id;
  final String filename;
  final String? contentType;
  final String? directoryId;
  final Map<String, dynamic> meta;
  final Map<String, dynamic> data;
  final int? size;
  final int createdAt;
  final int updatedAt;

  factory WorkspaceKnowledgeFile.fromJson(Map<String, dynamic> json) =>
      WorkspaceKnowledgeFile(
        id: json['id']?.toString() ?? json['file_id']?.toString() ?? '',
        filename:
            json['filename']?.toString() ??
            workspaceJsonMap(json['meta'])['name']?.toString() ??
            '',
        contentType: json['content_type']?.toString(),
        directoryId: json['directory_id']?.toString(),
        meta: workspaceJsonMap(json['meta']),
        data: workspaceJsonMap(json['data']),
        size: json['size'] is num ? (json['size'] as num).toInt() : null,
        createdAt: workspaceInt(json['created_at']),
        updatedAt: workspaceInt(json['updated_at']),
      );
}

@immutable
class WorkspaceKnowledgeFilePage {
  const WorkspaceKnowledgeFilePage({
    required this.items,
    required this.total,
    this.directories = const [],
    this.breadcrumbs = const [],
  });

  final List<WorkspaceKnowledgeFile> items;
  final List<WorkspaceKnowledgeDirectory> directories;
  final List<WorkspaceKnowledgeDirectory> breadcrumbs;
  final int total;

  factory WorkspaceKnowledgeFilePage.fromJson(dynamic json) {
    if (json is List) {
      final items = workspaceJsonList(
        json,
      ).map(WorkspaceKnowledgeFile.fromJson).toList(growable: false);
      return WorkspaceKnowledgeFilePage(items: items, total: items.length);
    }
    final map = workspaceJsonMap(json);
    final items = workspaceJsonList(
      map['items'] ?? map['files'],
    ).map(WorkspaceKnowledgeFile.fromJson).toList(growable: false);
    return WorkspaceKnowledgeFilePage(
      items: items,
      directories: workspaceJsonList(
        map['directories'],
      ).map(WorkspaceKnowledgeDirectory.fromJson).toList(growable: false),
      breadcrumbs: workspaceJsonList(
        map['breadcrumbs'],
      ).map(WorkspaceKnowledgeDirectory.fromJson).toList(growable: false),
      total: workspaceInt(map['total'], items.length),
    );
  }
}

@immutable
class WorkspacePendingFile {
  const WorkspacePendingFile({
    required this.id,
    this.status,
    this.error,
    this.raw = const {},
  });

  final String id;
  final String? status;
  final String? error;
  final Map<String, dynamic> raw;

  factory WorkspacePendingFile.fromJson(Map<String, dynamic> json) =>
      WorkspacePendingFile(
        id: json['id']?.toString() ?? json['file_id']?.toString() ?? '',
        status: json['status']?.toString(),
        error: json['error']?.toString(),
        raw: json,
      );
}

@immutable
class WorkspaceKnowledgeDetail {
  const WorkspaceKnowledgeDetail({
    required this.summary,
    this.files = const [],
  });

  final WorkspaceKnowledgeSummary summary;
  final List<WorkspaceKnowledgeFile> files;

  factory WorkspaceKnowledgeDetail.fromJson(Map<String, dynamic> json) =>
      WorkspaceKnowledgeDetail(
        summary: WorkspaceKnowledgeSummary.fromJson(json),
        files: workspaceJsonList(
          json['files'],
        ).map(WorkspaceKnowledgeFile.fromJson).toList(growable: false),
      );
}

@immutable
class WorkspaceSyncDiff {
  const WorkspaceSyncDiff({required this.raw});
  final Map<String, dynamic> raw;

  factory WorkspaceSyncDiff.fromJson(Map<String, dynamic> json) =>
      WorkspaceSyncDiff(raw: json);
}
