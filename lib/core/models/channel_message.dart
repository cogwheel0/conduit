// ignore_for_file: invalid_annotation_target
import 'package:freezed_annotation/freezed_annotation.dart';

part 'channel_message.freezed.dart';
part 'channel_message.g.dart';

/// A single message within a channel.
@freezed
sealed class ChannelMessage with _$ChannelMessage {
  const factory ChannelMessage({
    required String id,
    @JsonKey(name: 'channel_id') String? channelId,
    @JsonKey(name: 'user_id') String? userId,
    @Default('') String content,

    @JsonKey(name: 'user') ChannelMessageUser? user,

    /// ID of the message this replies to (inline reply).
    @JsonKey(name: 'reply_to_id') String? replyToId,

    /// ID of the parent message (thread root).
    @JsonKey(name: 'parent_id') String? parentId,

    /// Whether the message is pinned.
    @Default(false)
    @JsonKey(name: 'is_pinned')
    bool isPinned,
    @JsonKey(name: 'pinned_by') String? pinnedBy,
    @JsonKey(name: 'pinned_at') int? pinnedAt,

    /// File attachments and other structured data.
    /// In list responses the server returns a bool; in detail
    /// responses it is the full dict.
    @JsonKey(fromJson: _dataFromJson)
    Map<String, dynamic>? data,

    /// Metadata (webhook info, model_id, etc.).
    Map<String, dynamic>? meta,

    /// The message being replied to (populated in list
    /// responses).
    @JsonKey(name: 'reply_to_message')
    ChannelMessage? replyToMessage,

    /// Grouped reactions from the server.
    @Default([]) List<MessageReaction> reactions,

    /// Number of thread replies.
    @Default(0)
    @JsonKey(name: 'reply_count')
    int replyCount,

    /// Timestamp of the latest thread reply.
    @JsonKey(name: 'latest_reply_at') int? latestReplyAt,

    @JsonKey(name: 'created_at') int? createdAt,
    @JsonKey(name: 'updated_at') int? updatedAt,
  }) = _ChannelMessage;

  const ChannelMessage._();

  factory ChannelMessage.fromJson(
    Map<String, dynamic> json,
  ) => _$ChannelMessageFromJson(json);

  /// Display name from the embedded user object.
  String get userName => user?.name ?? 'Unknown';

  /// Profile image URL from the embedded user object.
  String? get userProfileImage => user?.profileImageUrl;

  /// Converts the nanosecond epoch timestamp to [DateTime].
  DateTime? get createdDateTime => createdAt != null
      ? DateTime.fromMicrosecondsSinceEpoch(
          createdAt! ~/ 1000,
        )
      : null;

  /// Converts the nanosecond epoch timestamp to [DateTime].
  DateTime? get updatedDateTime => updatedAt != null
      ? DateTime.fromMicrosecondsSinceEpoch(
          updatedAt! ~/ 1000,
        )
      : null;
}

/// Embedded user info on a channel message.
@freezed
sealed class ChannelMessageUser with _$ChannelMessageUser {
  const factory ChannelMessageUser({
    required String id,
    String? name,
    String? email,
    @JsonKey(name: 'profile_image_url')
    String? profileImageUrl,
  }) = _ChannelMessageUser;

  factory ChannelMessageUser.fromJson(
    Map<String, dynamic> json,
  ) => _$ChannelMessageUserFromJson(json);
}

/// Handles the server returning `data` as either a bool
/// or a Map.
Map<String, dynamic>? _dataFromJson(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  return null; // bool or null → treat as no data
}

/// A grouped reaction on a channel message.
///
/// OpenWebUI returns reactions as `{name, users, count}`
/// where [users] is a list of `{user_id, ...}` maps.
@freezed
sealed class MessageReaction with _$MessageReaction {
  const factory MessageReaction({
    /// The emoji/reaction name.
    required String name,

    /// Users who reacted with this emoji.
    @Default([])
    List<Map<String, dynamic>> users,

    /// Total count of this reaction.
    @Default(0) int count,
  }) = _MessageReaction;

  factory MessageReaction.fromJson(
    Map<String, dynamic> json,
  ) => _$MessageReactionFromJson(json);
}
