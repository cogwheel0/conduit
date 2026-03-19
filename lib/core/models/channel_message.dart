// ignore_for_file: invalid_annotation_target
import 'package:freezed_annotation/freezed_annotation.dart';

part 'channel_message.freezed.dart';
part 'channel_message.g.dart';

/// A single message within a channel.
@freezed
sealed class ChannelMessage with _$ChannelMessage {
  const factory ChannelMessage({
    required String id,
    @JsonKey(name: 'channel_id') required String channelId,
    @Default('') String content,
    @JsonKey(name: 'user_id') String? userId,
    @JsonKey(name: 'user') ChannelMessageUser? user,
    @JsonKey(name: 'parent_id') String? parentId,
    @Default([]) List<MessageReaction> reactions,
    @JsonKey(name: 'created_at') int? createdAt,
    @JsonKey(name: 'updated_at') int? updatedAt,
  }) = _ChannelMessage;

  const ChannelMessage._();

  factory ChannelMessage.fromJson(Map<String, dynamic> json) =>
      _$ChannelMessageFromJson(json);

  /// Display name from the embedded user object.
  String get userName => user?.name ?? 'Unknown';

  /// Profile image URL from the embedded user object.
  String? get userProfileImage => user?.profileImageUrl;

  DateTime? get createdDateTime => createdAt != null
      ? DateTime.fromMillisecondsSinceEpoch(createdAt! * 1000)
      : null;

  DateTime? get updatedDateTime => updatedAt != null
      ? DateTime.fromMillisecondsSinceEpoch(updatedAt! * 1000)
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
}

/// A reaction on a channel message.
@freezed
sealed class MessageReaction with _$MessageReaction {
  const factory MessageReaction({
    required String emoji,
    @JsonKey(name: 'user_id') required String userId,
    @JsonKey(name: 'user_name') String? userName,
  }) = _MessageReaction;

  factory MessageReaction.fromJson(Map<String, dynamic> json) =>
      _$MessageReactionFromJson(json);
}
