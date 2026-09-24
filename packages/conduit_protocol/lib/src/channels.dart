import 'package:freezed_annotation/freezed_annotation.dart';

part 'channels.freezed.dart';
part 'channels.g.dart';

/// A channel, as the list shows it.
@freezed
abstract class ChannelSummary with _$ChannelSummary {
  const factory ChannelSummary({
    required String id,
    required String name,
    String? description,
    @Default(false) bool private,
    @Default(0) int unread,
    int? lastMessageAtMs,

    /// May rename, change or delete the channel.
    @Default(false) bool manager,

    /// May post; a read-only channel still lists.
    @Default(true) bool canPost,
    int? userCount,
  }) = _ChannelSummary;

  factory ChannelSummary.fromJson(Map<String, dynamic> json) =>
      _$ChannelSummaryFromJson(json);
}

/// Reply to `channels.list`.
@freezed
abstract class ChannelList with _$ChannelList {
  const factory ChannelList({
    @Default(<ChannelSummary>[]) List<ChannelSummary> channels,

    /// Whether the server has channels switched on at all.
    @Default(false) bool enabled,
  }) = _ChannelList;

  factory ChannelList.fromJson(Map<String, dynamic> json) =>
      _$ChannelListFromJson(json);
}

/// Someone in a channel.
@freezed
abstract class ChannelUser with _$ChannelUser {
  const factory ChannelUser({required String id, @Default('') String name}) =
      _ChannelUser;

  factory ChannelUser.fromJson(Map<String, dynamic> json) =>
      _$ChannelUserFromJson(json);
}

/// One emoji's reactions to a message.
@freezed
abstract class ChannelReaction with _$ChannelReaction {
  const factory ChannelReaction({
    required String name,
    @Default(0) int count,

    /// Whether the signed-in user is one of them, so a click removes it.
    @Default(false) bool mine,
  }) = _ChannelReaction;

  factory ChannelReaction.fromJson(Map<String, dynamic> json) =>
      _$ChannelReactionFromJson(json);
}

@freezed
abstract class ChannelMessageDto with _$ChannelMessageDto {
  const factory ChannelMessageDto({
    required String id,
    required String channelId,
    ChannelUser? user,
    @Default('') String content,

    /// Set on a reply in a thread: the message the thread hangs off.
    String? parentId,
    @Default(false) bool pinned,
    @Default(0) int replyCount,
    required int createdAtMs,

    /// Set when edited after it was posted.
    int? editedAtMs,
    @Default(<ChannelReaction>[]) List<ChannelReaction> reactions,

    /// Whether the signed-in user wrote it, and so may edit or delete it.
    @Default(false) bool mine,
  }) = _ChannelMessageDto;

  factory ChannelMessageDto.fromJson(Map<String, dynamic> json) =>
      _$ChannelMessageDtoFromJson(json);
}

/// Params for `channels.messages`: a channel's messages, or with
/// [parentId] one thread's. [older] loads the next page back.
@freezed
abstract class ChannelMessagesQuery with _$ChannelMessagesQuery {
  const factory ChannelMessagesQuery({
    required String channelId,
    String? parentId,
    @Default(false) bool older,
  }) = _ChannelMessagesQuery;

  factory ChannelMessagesQuery.fromJson(Map<String, dynamic> json) =>
      _$ChannelMessagesQueryFromJson(json);
}

/// Reply to `channels.messages`: newest first.
@freezed
abstract class ChannelMessages with _$ChannelMessages {
  const factory ChannelMessages({
    required String channelId,
    String? parentId,
    @Default(<ChannelMessageDto>[]) List<ChannelMessageDto> messages,
    @Default(false) bool hasOlder,
  }) = _ChannelMessages;

  factory ChannelMessages.fromJson(Map<String, dynamic> json) =>
      _$ChannelMessagesFromJson(json);
}

/// Params for `channels.post`.
@freezed
abstract class ChannelPost with _$ChannelPost {
  const factory ChannelPost({
    required String channelId,
    required String content,

    /// A reply in the thread of this message.
    String? parentId,
  }) = _ChannelPost;

  factory ChannelPost.fromJson(Map<String, dynamic> json) =>
      _$ChannelPostFromJson(json);
}

/// Params naming one message.
@freezed
abstract class ChannelMessageRef with _$ChannelMessageRef {
  const factory ChannelMessageRef({
    required String channelId,
    required String messageId,
  }) = _ChannelMessageRef;

  factory ChannelMessageRef.fromJson(Map<String, dynamic> json) =>
      _$ChannelMessageRefFromJson(json);
}

/// Params for `channels.editMessage`.
@freezed
abstract class ChannelMessageEdit with _$ChannelMessageEdit {
  const factory ChannelMessageEdit({
    required String channelId,
    required String messageId,
    required String content,
  }) = _ChannelMessageEdit;

  factory ChannelMessageEdit.fromJson(Map<String, dynamic> json) =>
      _$ChannelMessageEditFromJson(json);
}

/// Params for `channels.react`: add or take back one emoji.
@freezed
abstract class ChannelReact with _$ChannelReact {
  const factory ChannelReact({
    required String channelId,
    required String messageId,
    required String emoji,
    @Default(true) bool add,
  }) = _ChannelReact;

  factory ChannelReact.fromJson(Map<String, dynamic> json) =>
      _$ChannelReactFromJson(json);
}

/// Params for `channels.pin`.
@freezed
abstract class ChannelPin with _$ChannelPin {
  const factory ChannelPin({
    required String channelId,
    required String messageId,
    required bool pinned,
  }) = _ChannelPin;

  factory ChannelPin.fromJson(Map<String, dynamic> json) =>
      _$ChannelPinFromJson(json);
}

/// Params for `channels.save`: a new channel when [id] is null.
@freezed
abstract class ChannelEdit with _$ChannelEdit {
  const factory ChannelEdit({
    String? id,
    required String name,
    String? description,
    @Default(false) bool private,
  }) = _ChannelEdit;

  factory ChannelEdit.fromJson(Map<String, dynamic> json) =>
      _$ChannelEditFromJson(json);
}

/// Params naming one channel.
@freezed
abstract class ChannelRef with _$ChannelRef {
  const factory ChannelRef({required String id}) = _ChannelRef;

  factory ChannelRef.fromJson(Map<String, dynamic> json) =>
      _$ChannelRefFromJson(json);
}

/// Params for `channels.typing`: the signed-in user started or stopped.
@freezed
abstract class ChannelTyping with _$ChannelTyping {
  const factory ChannelTyping({
    required String channelId,
    @Default(true) bool typing,
  }) = _ChannelTyping;

  factory ChannelTyping.fromJson(Map<String, dynamic> json) =>
      _$ChannelTypingFromJson(json);
}

/// Payload of `channels.typing`: who is typing in a channel now.
@freezed
abstract class ChannelTypingUsers with _$ChannelTypingUsers {
  const factory ChannelTypingUsers({
    required String channelId,
    @Default(<String>[]) List<String> names,
  }) = _ChannelTypingUsers;

  factory ChannelTypingUsers.fromJson(Map<String, dynamic> json) =>
      _$ChannelTypingUsersFromJson(json);
}

/// Payload of `channels.message`: a channel's messages changed -- a post,
/// an edit, a reaction, a reply. The window refetches what it shows.
@freezed
abstract class ChannelMessagesChanged with _$ChannelMessagesChanged {
  const factory ChannelMessagesChanged({required String channelId}) =
      _ChannelMessagesChanged;

  factory ChannelMessagesChanged.fromJson(Map<String, dynamic> json) =>
      _$ChannelMessagesChangedFromJson(json);
}

/// Reply to `channels.members`: who can be mentioned.
@freezed
abstract class ChannelMembers with _$ChannelMembers {
  const factory ChannelMembers({
    @Default(<ChannelUser>[]) List<ChannelUser> users,
  }) = _ChannelMembers;

  factory ChannelMembers.fromJson(Map<String, dynamic> json) =>
      _$ChannelMembersFromJson(json);
}
