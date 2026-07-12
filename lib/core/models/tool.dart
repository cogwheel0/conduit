import 'package:freezed_annotation/freezed_annotation.dart';

import '../utils/json_parsing.dart';

part 'tool.freezed.dart';

@freezed
sealed class Tool with _$Tool {
  const Tool._();

  const factory Tool({
    required String id,
    required String name,
    String? description,
    String? userId,
    String? content,
    @Default(<Map<String, dynamic>>[]) List<Map<String, dynamic>> specs,
    Map<String, dynamic>? meta,
    @Default(<Map<String, dynamic>>[]) List<Map<String, dynamic>> accessGrants,
    @Default(false) bool writeAccess,
    int? createdAt,
    int? updatedAt,
  }) = _Tool;

  factory Tool.fromJson(Map<String, dynamic> json) {
    final meta = json['meta'] is Map
        ? Map<String, dynamic>.from(json['meta'] as Map)
        : null;
    final rawSpecs = json['specs'] ?? json['spec'];
    final rawGrants = json['access_grants'];
    final id = json['id']?.toString();
    final name = json['name']?.toString();
    if (id == null || id.isEmpty) {
      throw const FormatException('Tool JSON missing required "id" field.');
    }
    if (name == null || name.isEmpty) {
      throw const FormatException('Tool JSON missing required "name" field.');
    }

    return Tool(
      id: id,
      name: name,
      description:
          json['description']?.toString() ?? meta?['description']?.toString(),
      userId: json['user_id']?.toString(),
      content: json['content']?.toString(),
      specs: switch (rawSpecs) {
        List() =>
          rawSpecs.whereType<Map>().map(Map<String, dynamic>.from).toList(),
        Map() => <Map<String, dynamic>>[Map<String, dynamic>.from(rawSpecs)],
        _ => const <Map<String, dynamic>>[],
      },
      meta: meta,
      accessGrants: rawGrants is List
          ? rawGrants.whereType<Map>().map(Map<String, dynamic>.from).toList()
          : const [],
      writeAccess: json['write_access'] == true,
      createdAt: parseInt(json['created_at']),
      updatedAt: parseInt(json['updated_at']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    if (description != null) 'description': description,
    if (userId != null) 'user_id': userId,
    if (content != null) 'content': content,
    if (specs.isNotEmpty) 'specs': specs,
    if (meta != null) 'meta': meta,
    if (accessGrants.isNotEmpty) 'access_grants': accessGrants,
    'write_access': writeAccess,
    if (createdAt != null) 'created_at': createdAt,
    if (updatedAt != null) 'updated_at': updatedAt,
  };
}
