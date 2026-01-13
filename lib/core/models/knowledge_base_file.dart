import 'package:freezed_annotation/freezed_annotation.dart';

import '../utils/json_parsing.dart';

part 'knowledge_base_file.freezed.dart';

/// A file within a knowledge base.
///
/// The new WebUI API returns files from a dedicated endpoint with pagination.
/// Files are deduplicated by content hash (not filename).
@freezed
sealed class KnowledgeBaseFile with _$KnowledgeBaseFile {
  const factory KnowledgeBaseFile({
    required String id,
    required String filename,
    Map<String, dynamic>? meta,
    required DateTime createdAt,
    DateTime? updatedAt,

    /// Content hash used for server-side deduplication.
    String? contentHash,
  }) = _KnowledgeBaseFile;

  /// Creates a [KnowledgeBaseFile] from JSON, handling various API formats.
  factory KnowledgeBaseFile.fromJson(Map<String, dynamic> json) {
    return KnowledgeBaseFile(
      id: json['id'] as String,
      filename: _extractFilename(json),
      meta: json['meta'] as Map<String, dynamic>?,
      createdAt: parseDateTime(json['created_at'] ?? json['createdAt']),
      updatedAt: parseDateTimeOrNull(json['updated_at'] ?? json['updatedAt']),
      contentHash:
          (json['hash'] ?? json['content_hash'] ?? json['contentHash'])
              as String?,
    );
  }
}

/// Extracts filename from various possible locations in the JSON.
String _extractFilename(Map<String, dynamic> json) {
  if (json.containsKey('filename')) {
    return json['filename'] as String? ?? 'Unknown';
  }
  if (json.containsKey('name')) {
    return json['name'] as String? ?? 'Unknown';
  }
  // Check nested meta object
  final meta = json['meta'];
  if (meta is Map) {
    final name = meta['name'] ?? meta['filename'];
    if (name is String) return name;
  }
  return 'Unknown';
}
