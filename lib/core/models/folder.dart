import 'package:freezed_annotation/freezed_annotation.dart';

part 'folder.freezed.dart';

bool? _safeBool(dynamic value) {
  if (value == null) return null;
  if (value is bool) return value;
  if (value is String) {
    final lower = value.toLowerCase();
    if (lower == 'true' || lower == '1') return true;
    if (lower == 'false' || lower == '0') return false;
  }
  if (value is num) return value != 0;
  return null;
}

@freezed
sealed class Folder with _$Folder {
  const factory Folder({
    required String id,
    required String name,
    String? parentId,
    String? userId,
    DateTime? createdAt,
    DateTime? updatedAt,
    @Default(false) bool isExpanded,
    @Default([]) List<String> conversationIds,
    Map<String, dynamic>? meta,
    Map<String, dynamic>? data,
    Map<String, dynamic>? items,
  }) = _Folder;

  factory Folder.fromJson(Map<String, dynamic> json) {
    List<String> extractConversationIds(dynamic source) {
      if (source is! List) {
        return const <String>[];
      }
      final ids = <String>[];
      for (final entry in source) {
        String value = '';
        if (entry is String) {
          value = entry;
        } else if (entry is Map<String, dynamic>) {
          final id = entry['id'];
          if (id is String) {
            value = id;
          } else if (id != null) {
            value = id.toString();
          }
        } else if (entry != null) {
          value = entry.toString();
        }

        if (value.isNotEmpty) {
          ids.add(value);
        }
      }
      return ids;
    }

    final items = json['items'] as Map<String, dynamic>?;
    final chats = items?['chats'];
    final explicitIds = extractConversationIds(json['conversation_ids']);
    final implicitIds = extractConversationIds(chats);
    final conversationIds = explicitIds.isNotEmpty ? explicitIds : implicitIds;

    // Handle Unix timestamp conversion
    DateTime? parseTimestamp(dynamic timestamp) {
      if (timestamp == null) return null;
      if (timestamp is int) {
        return DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
      }
      if (timestamp is String) {
        return DateTime.parse(timestamp);
      }
      return null;
    }

    // Create the modified JSON with proper field mapping
    return Folder(
      id: json['id'] as String,
      name: json['name'] as String,
      parentId: json['parent_id'] as String?,
      userId: json['user_id'] as String?,
      createdAt: parseTimestamp(json['created_at']),
      updatedAt: parseTimestamp(json['updated_at']),
      isExpanded: _safeBool(json['is_expanded']) ?? false,
      conversationIds: conversationIds,
      meta: json['meta'] as Map<String, dynamic>?,
      data: json['data'] as Map<String, dynamic>?,
      items: json['items'] as Map<String, dynamic>?,
    );
  }
}

extension FolderJsonExtension on Folder {
  Map<String, dynamic> toJson() {
    Map<String, dynamic>? normalizedItems;
    if (items != null) {
      normalizedItems = Map<String, dynamic>.from(items!);
    } else if (conversationIds.isNotEmpty) {
      normalizedItems = {'chats': List<String>.from(conversationIds)};
    }

    return {
      'id': id,
      'name': name,
      if (parentId != null) 'parent_id': parentId,
      if (userId != null) 'user_id': userId,
      if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
      if (updatedAt != null) 'updated_at': updatedAt!.toIso8601String(),
      'is_expanded': isExpanded,
      'items': ?normalizedItems,
      if (meta != null) 'meta': Map<String, dynamic>.from(meta!),
      if (data != null) 'data': Map<String, dynamic>.from(data!),
      if (conversationIds.isNotEmpty)
        'conversation_ids': List<String>.from(conversationIds),
    };
  }
}
