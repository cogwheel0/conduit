import 'package:freezed_annotation/freezed_annotation.dart';

// Freezed applies JsonKey to constructor parameters which triggers
// invalid_annotation_target; suppress it for this data model file.
// ignore_for_file: invalid_annotation_target

part 'chat_message.freezed.dart';
part 'chat_message.g.dart';

@freezed
sealed class ChatMessage with _$ChatMessage {
  const factory ChatMessage({
    required String id,
    required String role, // 'user', 'assistant', 'system'
    required String content,
    required DateTime timestamp,
    String? model,
    @Default(false) bool isStreaming,
    List<String>? attachmentIds,
    List<Map<String, dynamic>>? files, // For generated images
    /// OR-aligned structured output items from the backend middleware.
    /// Each item has a `type` (message, reasoning, code_interpreter, etc.).
    List<Map<String, dynamic>>? output,

    /// Rich UI embed objects attached to this message.
    List<Map<String, dynamic>>? embeds,
    Map<String, dynamic>? metadata,
    @Default(<ChatStatusUpdate>[]) List<ChatStatusUpdate> statusHistory,
    @Default(<String>[]) List<String> followUps,
    @Default(<ChatCodeExecution>[]) List<ChatCodeExecution> codeExecutions,
    @JsonKey(
      name: 'sources',
      fromJson: _sourceRefsFromJson,
      toJson: _sourceRefsToJson,
    )
    @Default(<ChatSourceReference>[])
    List<ChatSourceReference> sources,
    Map<String, dynamic>? usage,
    // Previous generated versions of this assistant message (OpenWebUI-style)
    // Parsed from sibling messages in OpenWebUI history
    @JsonKey(fromJson: _versionsFromJson, toJson: _versionsToJson)
    @Default(<ChatMessageVersion>[])
    List<ChatMessageVersion> versions,
    // Error information from OpenWebUI (stored separately from content)
    @JsonKey(
      fromJson: _chatMessageErrorFromJson,
      toJson: _chatMessageErrorToJson,
    )
    ChatMessageError? error,
  }) = _ChatMessage;

  factory ChatMessage.fromJson(Map<String, dynamic> json) =>
      _$ChatMessageFromJson(json);
}

/// Error information for a chat message, matching OpenWebUI's error format.
/// OpenWebUI stores errors as `{ error: { content: "..." } }` on messages.
@freezed
abstract class ChatMessageError with _$ChatMessageError {
  const factory ChatMessageError({
    /// The error message content
    @JsonKey(fromJson: _nullableString) String? content,
  }) = _ChatMessageError;

  factory ChatMessageError.fromJson(Map<String, dynamic> json) =>
      _$ChatMessageErrorFromJson(json);
}

/// Parse ChatMessageError from various OpenWebUI formats.
ChatMessageError? _chatMessageErrorFromJson(dynamic value) {
  if (value == null) return null;

  // Legacy format: error === true means content IS the error
  if (value == true) {
    return const ChatMessageError(content: null);
  }

  if (value is String && value.isNotEmpty) {
    return ChatMessageError(content: value);
  }

  if (value is Map) {
    // Most common: { content: "error message" }
    final content = value['content'];
    if (content is String && content.isNotEmpty) {
      return ChatMessageError(content: content);
    }

    // Alternative: { message: "error message" }
    final message = value['message'];
    if (message is String && message.isNotEmpty) {
      return ChatMessageError(content: message);
    }

    // Nested error: { error: { message: "..." } }
    final nestedError = value['error'];
    if (nestedError is Map) {
      final nestedMessage = nestedError['message'];
      if (nestedMessage is String && nestedMessage.isNotEmpty) {
        return ChatMessageError(content: nestedMessage);
      }
    }

    // FastAPI detail format: { detail: "..." }
    final detail = value['detail'];
    if (detail is String && detail.isNotEmpty) {
      return ChatMessageError(content: detail);
    }

    // If it's a map but we couldn't extract content, still return an error
    // to indicate there was an error (matches legacy error === true behavior)
    return const ChatMessageError(content: null);
  }

  return null;
}

/// Convert ChatMessageError to OpenWebUI format for persistence.
Map<String, dynamic>? _chatMessageErrorToJson(ChatMessageError? error) {
  if (error == null) return null;
  if (error.content == null) {
    // Legacy format - just return true to indicate error
    // But OpenWebUI expects a map, so return empty content
    return const {'content': ''};
  }
  return {'content': error.content};
}

@freezed
abstract class ChatMessageVersion with _$ChatMessageVersion {
  const factory ChatMessageVersion({
    required String id,
    required String content,
    required DateTime timestamp,
    String? model,
    List<Map<String, dynamic>>? files,
    List<Map<String, dynamic>>? output,
    List<Map<String, dynamic>>? embeds,
    @JsonKey(
      name: 'sources',
      fromJson: _sourceRefsFromJson,
      toJson: _sourceRefsToJson,
    )
    @Default(<ChatSourceReference>[])
    List<ChatSourceReference> sources,
    @Default(<String>[]) List<String> followUps,
    @Default(<ChatCodeExecution>[]) List<ChatCodeExecution> codeExecutions,
    Map<String, dynamic>? usage,
    // Error information preserved from the original message
    @JsonKey(
      fromJson: _chatMessageErrorFromJson,
      toJson: _chatMessageErrorToJson,
    )
    ChatMessageError? error,
  }) = _ChatMessageVersion;

  factory ChatMessageVersion.fromJson(Map<String, dynamic> json) =>
      _$ChatMessageVersionFromJson(json);
}

@freezed
abstract class ChatStatusUpdate with _$ChatStatusUpdate {
  const factory ChatStatusUpdate({
    String? action,
    String? description,
    @JsonKey(fromJson: _safeBool) bool? done,
    @JsonKey(fromJson: _safeBool) bool? hidden,
    @JsonKey(fromJson: _safeInt) int? count,
    String? query,
    @JsonKey(fromJson: _safeStringList, toJson: _stringListToJson)
    @Default(<String>[])
    List<String> queries,
    @JsonKey(fromJson: _safeStringList, toJson: _stringListToJson)
    @Default(<String>[])
    List<String> urls,
    @JsonKey(fromJson: _statusItemsFromJson, toJson: _statusItemsToJson)
    @Default(<ChatStatusItem>[])
    List<ChatStatusItem> items,
    @JsonKey(
      name: 'timestamp',
      fromJson: _timestampFromJson,
      toJson: _timestampToJson,
    )
    DateTime? occurredAt,
  }) = _ChatStatusUpdate;

  factory ChatStatusUpdate.fromJson(Map<String, dynamic> json) =>
      _$ChatStatusUpdateFromJson(json);
}

@freezed
abstract class ChatStatusItem with _$ChatStatusItem {
  const factory ChatStatusItem({
    String? title,
    String? link,
    String? snippet,
    Map<String, dynamic>? metadata,
  }) = _ChatStatusItem;

  factory ChatStatusItem.fromJson(Map<String, dynamic> json) =>
      _$ChatStatusItemFromJson(json);
}

@freezed
abstract class ChatCodeExecution with _$ChatCodeExecution {
  const factory ChatCodeExecution({
    @JsonKey(fromJson: _requiredString) required String id,
    @JsonKey(fromJson: _nullableString) String? name,
    @JsonKey(fromJson: _nullableString) String? language,
    @JsonKey(fromJson: _nullableString) String? code,
    @JsonKey(fromJson: _safeCodeExecutionResult)
    ChatCodeExecutionResult? result,
    @JsonKey(fromJson: _safeJsonMap) Map<String, dynamic>? metadata,
  }) = _ChatCodeExecution;

  factory ChatCodeExecution.fromJson(Map<String, dynamic> json) =>
      _$ChatCodeExecutionFromJson(json);
}

@freezed
abstract class ChatCodeExecutionResult with _$ChatCodeExecutionResult {
  const factory ChatCodeExecutionResult({
    @JsonKey(fromJson: _nullableString) String? output,
    @JsonKey(fromJson: _nullableString) String? error,
    @JsonKey(fromJson: _executionFilesFromJson, toJson: _executionFilesToJson)
    @Default(<ChatExecutionFile>[])
    List<ChatExecutionFile> files,
    @JsonKey(fromJson: _safeJsonMap) Map<String, dynamic>? metadata,
  }) = _ChatCodeExecutionResult;

  factory ChatCodeExecutionResult.fromJson(Map<String, dynamic> json) =>
      _$ChatCodeExecutionResultFromJson(json);
}

@freezed
abstract class ChatExecutionFile with _$ChatExecutionFile {
  const factory ChatExecutionFile({
    @JsonKey(fromJson: _nullableString) String? name,
    @JsonKey(fromJson: _nullableString) String? url,
    @JsonKey(fromJson: _safeJsonMap) Map<String, dynamic>? metadata,
  }) = _ChatExecutionFile;

  factory ChatExecutionFile.fromJson(Map<String, dynamic> json) =>
      _$ChatExecutionFileFromJson(json);
}

@freezed
abstract class ChatSourceReference with _$ChatSourceReference {
  const factory ChatSourceReference({
    @JsonKey(fromJson: _nullableString) String? id,
    @JsonKey(fromJson: _nullableString) String? title,
    @JsonKey(fromJson: _nullableString) String? url,
    @JsonKey(fromJson: _nullableString) String? snippet,
    @JsonKey(fromJson: _nullableString) String? type,
    @JsonKey(fromJson: _safeJsonMap) Map<String, dynamic>? metadata,
  }) = _ChatSourceReference;

  factory ChatSourceReference.fromJson(Map<String, dynamic> json) =>
      _$ChatSourceReferenceFromJson(json);
}

List<String> _safeStringList(dynamic value) {
  if (value is List) {
    return value
        .whereType<dynamic>()
        .map((e) => e?.toString().trim() ?? '')
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }
  if (value is String && value.isNotEmpty) {
    return [value];
  }
  return const [];
}

/// Safely parse a boolean from various formats (bool, String, int).
bool? _safeBool(dynamic value) {
  if (value == null) return null;
  if (value is bool) return value;
  if (value is String) {
    final lower = value.toLowerCase();
    if (lower == 'true' || lower == '1') return true;
    if (lower == 'false' || lower == '0') return false;
    return null;
  }
  if (value is num) return value != 0;
  return null;
}

/// Safely parse an integer from various formats (int, double, String).
int? _safeInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

List<String> _stringListToJson(List<String> value) =>
    List<String>.from(value, growable: false);

/// Parse ChatMessageVersion list from JSON.
List<ChatMessageVersion> _versionsFromJson(dynamic value) {
  if (value is List) {
    return value
        .whereType<Map>()
        .map((item) {
          try {
            final Map<String, dynamic> versionMap = {};
            item.forEach((key, v) {
              versionMap[key.toString()] = v;
            });
            return ChatMessageVersion.fromJson(versionMap);
          } catch (e) {
            // Skip invalid entries
            return null;
          }
        })
        .where((item) => item != null)
        .cast<ChatMessageVersion>()
        .toList(growable: false);
  }
  return const [];
}

/// Convert ChatMessageVersion list to JSON.
List<Map<String, dynamic>> _versionsToJson(List<ChatMessageVersion> versions) {
  return versions.map((v) => v.toJson()).toList(growable: false);
}

List<ChatStatusItem> _statusItemsFromJson(dynamic value) {
  if (value is List) {
    return value
        .whereType<Map>()
        .map((item) {
          try {
            // Convert Map to Map<String, dynamic> safely
            final Map<String, dynamic> itemMap = {};
            item.forEach((key, v) {
              itemMap[key.toString()] = v;
            });
            return ChatStatusItem.fromJson(itemMap);
          } catch (e) {
            // Skip invalid entries
            return null;
          }
        })
        .where((item) => item != null)
        .cast<ChatStatusItem>()
        .toList(growable: false);
  }
  return const [];
}

List<Map<String, dynamic>> _statusItemsToJson(List<ChatStatusItem> value) {
  return value.map((item) => item.toJson()).toList(growable: false);
}

List<ChatExecutionFile> _executionFilesFromJson(dynamic value) {
  if (value is List) {
    return value
        .whereType<Map>()
        .map((item) {
          try {
            // Convert Map to Map<String, dynamic> safely
            final Map<String, dynamic> fileMap = {};
            item.forEach((key, v) {
              fileMap[key.toString()] = v;
            });
            return ChatExecutionFile.fromJson(fileMap);
          } catch (e) {
            // Skip invalid entries
            return null;
          }
        })
        .where((item) => item != null)
        .cast<ChatExecutionFile>()
        .toList(growable: false);
  }
  return const [];
}

List<Map<String, dynamic>> _executionFilesToJson(
  List<ChatExecutionFile> files,
) {
  return files.map((file) => file.toJson()).toList(growable: false);
}

List<ChatSourceReference> _sourceRefsFromJson(dynamic value) {
  if (value is List) {
    return value
        .whereType<Map>()
        .map((item) {
          try {
            // Convert Map to Map<String, dynamic> safely
            final Map<String, dynamic> refMap = {};
            item.forEach((key, v) {
              refMap[key.toString()] = v;
            });
            return ChatSourceReference.fromJson(refMap);
          } catch (e) {
            // Skip invalid entries
            return null;
          }
        })
        .where((item) => item != null)
        .cast<ChatSourceReference>()
        .toList(growable: false);
  }
  return const [];
}

List<Map<String, dynamic>> _sourceRefsToJson(
  List<ChatSourceReference> references,
) {
  return references.map((ref) => ref.toJson()).toList(growable: false);
}

DateTime? _timestampFromJson(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is int) {
    // Heuristics: treat seconds vs milliseconds
    final isSeconds = value < 1000000000000;
    final millis = isSeconds ? value * 1000 : value;
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).toLocal();
  }
  if (value is double) {
    final millis = value < 1000000000 ? (value * 1000).toInt() : value.toInt();
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).toLocal();
  }
  if (value is String && value.isNotEmpty) {
    return DateTime.tryParse(value)?.toLocal();
  }
  return null;
}

String? _timestampToJson(DateTime? value) => value?.toIso8601String();

String _requiredString(dynamic value, {String fallback = ''}) {
  if (value == null) return fallback;
  final str = value.toString();
  return str.isEmpty ? fallback : str;
}

String? _nullableString(dynamic value) {
  if (value == null) return null;
  final str = value.toString();
  return str.isEmpty ? null : str;
}

/// Safely parse a `Map<String, dynamic>` from various formats.
/// Returns null if the value cannot be converted to a valid map or is empty.
Map<String, dynamic>? _safeJsonMap(dynamic value) {
  if (value == null) return null;
  if (value is Map<String, dynamic>) {
    return value.isEmpty ? null : value;
  }
  if (value is Map) {
    final result = <String, dynamic>{};
    value.forEach((key, v) {
      result[key.toString()] = v;
    });
    return result.isEmpty ? null : result;
  }
  return null;
}

/// Safely parse a ChatCodeExecutionResult from various formats.
/// Returns null if the value cannot be converted to a valid result.
ChatCodeExecutionResult? _safeCodeExecutionResult(dynamic value) {
  if (value == null) return null;
  if (value is Map<String, dynamic>) {
    try {
      return ChatCodeExecutionResult.fromJson(value);
    } catch (_) {
      return null;
    }
  }
  if (value is Map) {
    try {
      final map = <String, dynamic>{};
      value.forEach((key, v) {
        map[key.toString()] = v;
      });
      return ChatCodeExecutionResult.fromJson(map);
    } catch (_) {
      return null;
    }
  }
  return null;
}
