import 'package:flutter/foundation.dart';

Map<String, dynamic> workspaceJsonMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

List<Map<String, dynamic>> workspaceJsonList(dynamic value) => value is List
    ? value.whereType<Map>().map(Map<String, dynamic>.from).toList()
    : const <Map<String, dynamic>>[];

List<String> workspaceStringList(dynamic value) => value is List
    ? value.whereType<Object>().map((item) => item.toString()).toList()
    : const <String>[];

int workspaceInt(dynamic value, [int fallback = 0]) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? fallback;

bool workspaceBool(dynamic value, [bool fallback = false]) => switch (value) {
  bool() => value,
  num() => value != 0,
  String() => value.toLowerCase() == 'true' || value == '1',
  _ => fallback,
};

@immutable
class WorkspaceOwnerPreview {
  const WorkspaceOwnerPreview({
    required this.id,
    required this.name,
    this.email,
    this.profileImageUrl,
  });

  final String id;
  final String name;
  final String? email;
  final String? profileImageUrl;

  factory WorkspaceOwnerPreview.fromJson(Map<String, dynamic> json) =>
      WorkspaceOwnerPreview(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? json['username']?.toString() ?? '',
        email: json['email']?.toString(),
        profileImageUrl:
            json['profile_image_url']?.toString() ??
            json['profileImageUrl']?.toString(),
      );
}

enum WorkspacePrincipalType { user, group }

enum WorkspaceGrantPermission { read, write }

@immutable
class WorkspaceAccessGrant {
  const WorkspaceAccessGrant({
    this.id,
    required this.principalType,
    required this.principalId,
    required this.permission,
  });

  final String? id;
  final WorkspacePrincipalType principalType;
  final String principalId;
  final WorkspaceGrantPermission permission;

  bool get isPublic =>
      principalType == WorkspacePrincipalType.user && principalId == '*';

  factory WorkspaceAccessGrant.fromJson(Map<String, dynamic> json) =>
      WorkspaceAccessGrant(
        id: json['id']?.toString(),
        principalType: json['principal_type'] == 'group'
            ? WorkspacePrincipalType.group
            : WorkspacePrincipalType.user,
        principalId: json['principal_id']?.toString() ?? '',
        permission: json['permission'] == 'write'
            ? WorkspaceGrantPermission.write
            : WorkspaceGrantPermission.read,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (id != null) 'id': id,
    'principal_type': principalType.name,
    'principal_id': principalId,
    'permission': permission.name,
  };
}

@immutable
class WorkspaceAccessGrantInput {
  const WorkspaceAccessGrantInput({
    required this.principalType,
    required this.principalId,
    required this.permission,
  });

  final WorkspacePrincipalType principalType;
  final String principalId;
  final WorkspaceGrantPermission permission;

  factory WorkspaceAccessGrantInput.fromGrant(WorkspaceAccessGrant grant) =>
      WorkspaceAccessGrantInput(
        principalType: grant.principalType,
        principalId: grant.principalId,
        permission: grant.permission,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'principal_type': principalType.name,
    'principal_id': principalId,
    'permission': permission.name,
  };
}

@immutable
class WorkspacePrincipalPreview {
  const WorkspacePrincipalPreview({
    required this.id,
    required this.type,
    required this.name,
    this.email,
    this.profileImageUrl,
  });

  final String id;
  final WorkspacePrincipalType type;
  final String name;
  final String? email;
  final String? profileImageUrl;

  factory WorkspacePrincipalPreview.user(Map<String, dynamic> json) =>
      WorkspacePrincipalPreview(
        id: json['id']?.toString() ?? '',
        type: WorkspacePrincipalType.user,
        name: json['name']?.toString() ?? json['username']?.toString() ?? '',
        email: json['email']?.toString(),
        profileImageUrl: json['profile_image_url']?.toString(),
      );

  factory WorkspacePrincipalPreview.group(Map<String, dynamic> json) =>
      WorkspacePrincipalPreview(
        id: json['id']?.toString() ?? '',
        type: WorkspacePrincipalType.group,
        name: json['name']?.toString() ?? '',
      );
}

@immutable
class WorkspacePagedResponse<T> {
  const WorkspacePagedResponse({required this.items, required this.total});

  final List<T> items;
  final int total;

  factory WorkspacePagedResponse.fromJson(
    dynamic json,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    if (json is List) {
      final items = workspaceJsonList(
        json,
      ).map(fromJson).toList(growable: false);
      return WorkspacePagedResponse(items: items, total: items.length);
    }
    final map = workspaceJsonMap(json);
    final items = workspaceJsonList(
      map['items'] ?? map['users'] ?? map['groups'],
    ).map(fromJson).toList(growable: false);
    return WorkspacePagedResponse(
      items: items,
      total: workspaceInt(map['total'], items.length),
    );
  }
}

List<WorkspaceAccessGrant> workspaceGrants(dynamic value) => workspaceJsonList(
  value,
).map(WorkspaceAccessGrant.fromJson).toList(growable: false);

List<Map<String, dynamic>> workspaceGrantInputs(
  List<WorkspaceAccessGrantInput> grants,
) => grants.map((grant) => grant.toJson()).toList(growable: false);
