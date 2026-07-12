import 'package:flutter/foundation.dart';

import '../utils/json_parsing.dart';

@immutable
class Prompt {
  const Prompt({
    required this.command,
    required this.title,
    required this.content,
    this.id,
    this.data,
    this.meta,
    this.tags = const [],
    this.accessControl,
    this.accessGrants = const [],
    this.userId,
    this.isActive = true,
    this.versionId,
    this.writeAccess = false,
    this.createdAt,
    this.updatedAt,
    this.timestamp,
  });

  final String? id;
  final String command;
  final String title;
  final String content;
  final Map<String, dynamic>? data;
  final Map<String, dynamic>? meta;
  final List<String> tags;
  final Map<String, dynamic>? accessControl;
  final List<Map<String, dynamic>> accessGrants;
  final String? userId;
  final bool isActive;
  final String? versionId;
  final bool writeAccess;
  final int? createdAt;
  final int? updatedAt;
  final int? timestamp;

  String get name => title;
  String? get description => meta?['description']?.toString();

  factory Prompt.fromJson(Map<String, dynamic> json) {
    final rawCommand = (json['command']?.toString() ?? '').trim();
    final normalizedCommand = rawCommand.startsWith('/')
        ? rawCommand
        : (rawCommand.isEmpty ? rawCommand : '/$rawCommand');
    final rawTags = json['tags'];
    final rawGrants = json['access_grants'];

    return Prompt(
      id: json['id']?.toString(),
      command: normalizedCommand,
      title: json['name']?.toString() ?? json['title']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      data: json['data'] is Map
          ? Map<String, dynamic>.from(json['data'] as Map)
          : null,
      meta: json['meta'] is Map
          ? Map<String, dynamic>.from(json['meta'] as Map)
          : null,
      tags: rawTags is List
          ? rawTags.whereType<Object>().map((tag) => tag.toString()).toList()
          : const [],
      accessControl: json['access_control'] is Map
          ? Map<String, dynamic>.from(json['access_control'] as Map)
          : null,
      accessGrants: rawGrants is List
          ? rawGrants.whereType<Map>().map(Map<String, dynamic>.from).toList()
          : const [],
      userId: json['user_id']?.toString(),
      isActive: json['is_active'] is bool ? json['is_active'] as bool : true,
      versionId: json['version_id']?.toString(),
      writeAccess: json['write_access'] == true,
      createdAt: parseInt(json['created_at']),
      updatedAt: parseInt(json['updated_at']),
      timestamp: parseInt(json['timestamp'] ?? json['updated_at']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (id != null) 'id': id,
    'command': command,
    'name': title,
    'title': title,
    'content': content,
    if (data != null) 'data': data,
    if (meta != null) 'meta': meta,
    if (tags.isNotEmpty) 'tags': tags,
    if (accessControl != null) 'access_control': accessControl,
    if (accessGrants.isNotEmpty) 'access_grants': accessGrants,
    if (userId != null) 'user_id': userId,
    'is_active': isActive,
    if (versionId != null) 'version_id': versionId,
    'write_access': writeAccess,
    if (createdAt != null) 'created_at': createdAt,
    if (updatedAt != null) 'updated_at': updatedAt,
    if (timestamp != null) 'timestamp': timestamp,
  };

  Prompt copyWith({
    String? id,
    String? command,
    String? title,
    String? content,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
    List<String>? tags,
    Map<String, dynamic>? accessControl,
    List<Map<String, dynamic>>? accessGrants,
    String? userId,
    bool? isActive,
    String? versionId,
    bool? writeAccess,
    int? createdAt,
    int? updatedAt,
    int? timestamp,
  }) => Prompt(
    id: id ?? this.id,
    command: command ?? this.command,
    title: title ?? this.title,
    content: content ?? this.content,
    data: data ?? this.data,
    meta: meta ?? this.meta,
    tags: tags ?? this.tags,
    accessControl: accessControl ?? this.accessControl,
    accessGrants: accessGrants ?? this.accessGrants,
    userId: userId ?? this.userId,
    isActive: isActive ?? this.isActive,
    versionId: versionId ?? this.versionId,
    writeAccess: writeAccess ?? this.writeAccess,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    timestamp: timestamp ?? this.timestamp,
  );
}
