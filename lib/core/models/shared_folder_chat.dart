import 'package:freezed_annotation/freezed_annotation.dart';

part 'shared_folder_chat.freezed.dart';

/// A row from `GET /api/v1/folders/{id}/shared/chats` — a chat owned by
/// another user, visible because its folder was shared with the current
/// user. Deliberately not merged into [Conversation]: unlike owned
/// conversations, these are never persisted locally, never editable, and
/// never routed through the sync engine, so keeping a separate, smaller
/// model avoids implying capabilities (pin, archive, edit) that the shared
/// folder API doesn't support for non-owners.
@freezed
sealed class SharedFolderChat with _$SharedFolderChat {
  const factory SharedFolderChat({
    required String id,
    required String title,
    DateTime? updatedAt,
    required String ownerName,
    @Default(true) bool readonly,
  }) = _SharedFolderChat;

  factory SharedFolderChat.fromJson(Map<String, dynamic> json) {
    DateTime? parseTimestamp(dynamic timestamp) {
      if (timestamp == null) return null;
      if (timestamp is int) {
        return DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
      }
      if (timestamp is double) {
        return DateTime.fromMillisecondsSinceEpoch((timestamp * 1000).round());
      }
      if (timestamp is String) {
        return DateTime.tryParse(timestamp);
      }
      return null;
    }

    final title = json['title'] as String?;
    return SharedFolderChat(
      id: json['id'] as String,
      title: (title == null || title.isEmpty) ? 'Chat' : title,
      updatedAt: parseTimestamp(json['updated_at']),
      ownerName: json['owner_name'] as String? ?? 'Unknown',
      readonly: json['readonly'] as bool? ?? true,
    );
  }
}
