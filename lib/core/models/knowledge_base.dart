import 'package:freezed_annotation/freezed_annotation.dart';

import '../utils/json_parsing.dart';

part 'knowledge_base.freezed.dart';

/// A knowledge base containing documents for RAG retrieval.
@freezed
sealed class KnowledgeBase with _$KnowledgeBase {
  const factory KnowledgeBase({
    required String id,
    required String name,
    String? description,
    required DateTime createdAt,
    required DateTime updatedAt,
    @Default(0) int itemCount,
    @Default({}) Map<String, dynamic> metadata,
  }) = _KnowledgeBase;

  /// Creates a [KnowledgeBase] from JSON, handling both snake_case (new API)
  /// and camelCase (old API) field names.
  factory KnowledgeBase.fromJson(Map<String, dynamic> json) {
    return KnowledgeBase(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      createdAt: parseDateTime(json['created_at'] ?? json['createdAt']),
      updatedAt: parseDateTime(json['updated_at'] ?? json['updatedAt']),
      itemCount: parseInt(
            json['file_count'] ?? json['item_count'] ?? json['itemCount'],
          ) ??
          0,
      metadata:
          (json['metadata'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
    );
  }
}

/// An item within a knowledge base.
@freezed
sealed class KnowledgeBaseItem with _$KnowledgeBaseItem {
  const factory KnowledgeBaseItem({
    required String id,
    required String content,
    String? title,
    required DateTime createdAt,
    required DateTime updatedAt,
    @Default({}) Map<String, dynamic> metadata,
  }) = _KnowledgeBaseItem;

  /// Creates a [KnowledgeBaseItem] from JSON, handling both snake_case (new API)
  /// and camelCase (old API) field names.
  factory KnowledgeBaseItem.fromJson(Map<String, dynamic> json) {
    return KnowledgeBaseItem(
      id: json['id'] as String,
      content: json['content'] as String,
      title: json['title'] as String?,
      createdAt: parseDateTime(json['created_at'] ?? json['createdAt']),
      updatedAt: parseDateTime(json['updated_at'] ?? json['updatedAt']),
      metadata:
          (json['metadata'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
    );
  }
}
