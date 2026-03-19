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
    @Default('') String description,
    @Default(false) @JsonKey(name: 'is_private') bool isPrivate,
    @JsonKey(name: 'user_id') String? userId,
    @JsonKey(name: 'created_at') int? createdAt,
    @JsonKey(name: 'updated_at') int? updatedAt,
  }) = _Channel;

  const Channel._();

  factory Channel.fromJson(Map<String, dynamic> json) =>
      _$ChannelFromJson(json);

  /// Converts the [createdAt] epoch (seconds) to a [DateTime].
  DateTime? get createdDateTime => createdAt != null
      ? DateTime.fromMillisecondsSinceEpoch(createdAt! * 1000)
      : null;

  /// Converts the [updatedAt] epoch (seconds) to a [DateTime].
  DateTime? get updatedDateTime => updatedAt != null
      ? DateTime.fromMillisecondsSinceEpoch(updatedAt! * 1000)
      : null;
}
