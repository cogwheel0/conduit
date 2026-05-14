// ignore_for_file: invalid_annotation_target
import 'package:freezed_annotation/freezed_annotation.dart';

part 'channel.freezed.dart';
part 'channel.g.dart';

/// A persistent topic-based collaborative workspace where multiple
/// users and AI models can interact in a shared timeline.
@freezed
sealed class Channel with _$Channel {
  const factory Channel({
    required String id,
    required String name,
    @JsonKey(name: 'user_id') String? userId,

    /// Channel type: 'group', 'dm', or null for standard ACL-based.
    String? type,

    @Default('') String description,
    @Default(false) @JsonKey(name: 'is_private') bool isPrivate,

    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
    @Default([])
    @JsonKey(name: 'access_grants')
    List<Map<String, dynamic>> accessGrants,

    @JsonKey(name: 'created_at') int? createdAt,
    @JsonKey(name: 'updated_at') int? updatedAt,
    @JsonKey(name: 'updated_by') String? updatedBy,

    @JsonKey(name: 'archived_at') int? archivedAt,
    @JsonKey(name: 'archived_by') String? archivedBy,

    @JsonKey(name: 'deleted_at') int? deletedAt,
    @JsonKey(name: 'deleted_by') String? deletedBy,

    // Response-only fields
    // (from ChannelResponse / ChannelFullResponse).
    @Default(false) @JsonKey(name: 'is_manager') bool isManager,
    @Default(false) @JsonKey(name: 'write_access') bool writeAccess,
    @JsonKey(name: 'user_count') int? userCount,

    @JsonKey(name: 'last_read_at') int? lastReadAt,
    @Default(0) @JsonKey(name: 'unread_count') int unreadCount,
    @JsonKey(name: 'last_message_at') int? lastMessageAt,

    /// Member user IDs (group/dm channels only).
    @JsonKey(name: 'user_ids') List<String>? userIds,

    /// Member user objects (group/dm channels only).
    List<Map<String, dynamic>>? users,
  }) = _Channel;

  const Channel._();

  factory Channel.fromJson(Map<String, dynamic> json) =>
      _$ChannelFromJson(json);

  /// Whether this is a direct-message channel.
  bool get isDm => type == 'dm';

  /// Whether this is a group channel.
  bool get isGroup => type == 'group';

  /// Converts the nanosecond epoch timestamp to [DateTime].
  DateTime? get createdDateTime => createdAt != null
      ? DateTime.fromMicrosecondsSinceEpoch(createdAt! ~/ 1000)
      : null;

  /// Converts the nanosecond epoch timestamp to [DateTime].
  DateTime? get updatedDateTime => updatedAt != null
      ? DateTime.fromMicrosecondsSinceEpoch(updatedAt! ~/ 1000)
      : null;
}
