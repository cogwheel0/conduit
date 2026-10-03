// ignore_for_file: invalid_annotation_target
import 'package:freezed_annotation/freezed_annotation.dart';

import 'user.dart';

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
    @Default(false) @JsonKey(name: 'is_pinned') bool isPinned,
    @JsonKey(name: 'pinned_by') String? pinnedBy,
    @JsonKey(name: 'pinned_at') int? pinnedAt,

    /// File attachments and other structured data.
    /// In list responses the server returns a bool; in detail
    /// responses it is the full dict.
    @JsonKey(fromJson: _dataFromJson) Map<String, dynamic>? data,

    /// Metadata (webhook info, model_id, etc.).
    Map<String, dynamic>? meta,

    /// The message being replied to (populated in list
    /// responses).
    @JsonKey(name: 'reply_to_message') ChannelMessage? replyToMessage,

    /// Grouped reactions from the server.
    @Default([]) List<MessageReaction> reactions,

    /// Number of thread replies.
    @Default(0) @JsonKey(name: 'reply_count') int replyCount,

    /// Timestamp of the latest thread reply.
    @JsonKey(name: 'latest_reply_at') int? latestReplyAt,

    @JsonKey(name: 'created_at') int? createdAt,
    @JsonKey(name: 'updated_at') int? updatedAt,
  }) = _ChannelMessage;

  const ChannelMessage._();

  factory ChannelMessage.fromJson(Map<String, dynamic> json) =>
      _$ChannelMessageFromJson(json);

  /// Display name from the embedded user object.
  String get userName => user?.name ?? 'Unknown';

  /// This message with [sender] embedded when the server left it out: the
  /// post endpoint answers with a bare row that names only `user_id`.
  ChannelMessage withSenderIfMissing(User sender) {
    if (user != null || userId != sender.id) return this;
    return copyWith(user: ChannelMessageUser.fromUser(sender));
  }

  /// Applies an edit [response] to this message. Only what an edit changes is
  /// taken from it, so a pin that was answered first is not undone. The
  /// response is a bare row without the reactions and thread counts of list
  /// responses, so keep those.
  ChannelMessage withEditResponse(ChannelMessage response) => copyWith(
    content: response.content,
    data: response.data ?? data,
    meta: response.meta ?? meta,
    updatedAt: response.updatedAt ?? updatedAt,
    user: response.user ?? user,
  );

  /// Applies a pin or unpin [response] to this message. Only the pin fields
  /// are taken from it, so an edit that was answered first is not undone.
  ChannelMessage withPinResponse(ChannelMessage response) => copyWith(
    isPinned: response.isPinned,
    pinnedBy: response.pinnedBy,
    pinnedAt: response.pinnedAt,
  );

  /// Profile image URL from the embedded user object.
  String? get userProfileImage => user?.profileImageUrl;

  /// Converts the nanosecond epoch timestamp to [DateTime].
  DateTime? get createdDateTime => createdAt != null
      ? DateTime.fromMicrosecondsSinceEpoch(createdAt! ~/ 1000)
      : null;

  /// Converts the nanosecond epoch timestamp to [DateTime].
  DateTime? get updatedDateTime => updatedAt != null
      ? DateTime.fromMicrosecondsSinceEpoch(updatedAt! ~/ 1000)
      : null;
}

/// Embedded user info on a channel message.
@freezed
sealed class ChannelMessageUser with _$ChannelMessageUser {
  const factory ChannelMessageUser({
    required String id,
    String? name,
    String? email,
    @JsonKey(name: 'profile_image_url') String? profileImageUrl,
  }) = _ChannelMessageUser;

  factory ChannelMessageUser.fromJson(Map<String, dynamic> json) =>
      _$ChannelMessageUserFromJson(json);

  /// The signed-in [user] as a message sender.
  factory ChannelMessageUser.fromUser(User user) => ChannelMessageUser(
    id: user.id,
    name: user.name ?? user.username,
    email: user.email,
    profileImageUrl: user.profileImage,
  );
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
    @Default([]) List<Map<String, dynamic>> users,

    /// Total count of this reaction.
    @Default(0) int count,
  }) = _MessageReaction;

  factory MessageReaction.fromJson(Map<String, dynamic> json) =>
      _$MessageReactionFromJson(json);
}
