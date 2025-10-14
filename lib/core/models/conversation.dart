import 'package:freezed_annotation/freezed_annotation.dart';
import 'chat_message.dart';

part 'conversation.freezed.dart';
part 'conversation.g.dart';

@freezed
sealed class Conversation with _$Conversation {
  const factory Conversation({
    required String id,
    required String title,
    required DateTime createdAt,
    required DateTime updatedAt,
    String? model,
    String? systemPrompt,
    @Default([]) List<ChatMessage> messages,
    @Default({}) @_MetadataConverter() Map<String, dynamic> metadata,
    @Default(false) bool pinned,
    @Default(false) bool archived,
    String? shareId,
    String? folderId,
    @Default([]) List<String> tags,
  }) = _Conversation;

  factory Conversation.fromJson(Map<String, dynamic> json) =>
      _$ConversationFromJson(json);
}

/// Custom converter to handle Map<dynamic, dynamic> from storage
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
