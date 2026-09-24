import 'package:freezed_annotation/freezed_annotation.dart';

import 'chat_message.dart';

// Freezed applies JsonKey to constructor parameters.
// ignore_for_file: invalid_annotation_target

part 'conversation.freezed.dart';
part 'conversation.g.dart';

@freezed
sealed class Conversation with _$Conversation {
  const factory Conversation({
    required String id,
    required String title,
    required DateTime createdAt,
    required DateTime updatedAt,
    DateTime? lastReadAt,
    String? model,
    String? systemPrompt,
    @JsonKey(toJson: _messagesToJson) @Default([]) List<ChatMessage> messages,
    @Default({}) @_MetadataConverter() Map<String, dynamic> metadata,
    @Default(false) bool pinned,
    @Default(false) bool archived,
    String? shareId,
    String? folderId,
    @Default([]) List<String> tags,

    /// Server `user_id` of the chat owner. Null for local-only chats and
    /// rows that predate the field. A non-null value that differs from the
    /// signed-in user marks a chat reached through a shared folder.
    String? userId,
  }) = _Conversation;

  factory Conversation.fromJson(Map<String, dynamic> json) =>
      _$ConversationFromJson(json);
}

List<Map<String, dynamic>> _messagesToJson(List<ChatMessage> messages) {
  return messages.map((message) => message.toJson()).toList(growable: false);
}

class _MetadataConverter
    implements JsonConverter<Map<String, dynamic>, Object?> {
  const _MetadataConverter();

  @override
  Map<String, dynamic> fromJson(Object? json) {
    if (json == null) return {};
    if (json is Map<String, dynamic>) return json;
    if (json is Map) {
      return json.map((key, value) => MapEntry(key.toString(), value));
    }
    return {};
  }

  @override
  Object? toJson(Map<String, dynamic> object) => object;
}
