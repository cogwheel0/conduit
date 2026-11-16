import 'package:freezed_annotation/freezed_annotation.dart';

import 'composer.dart';

part 'channels.freezed.dart';
part 'channels.g.dart';

/// What sort of channel it is: an Open WebUI channel the server's access
/// rules open ([standard]), one with its own members ([group]), or a
/// direct message between people ([dm]).
enum ChannelKind { standard, group, dm }

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
    @Default(ChannelKind.standard) ChannelKind kind,

    /// What the list and the pane call it: the name, or for a direct
    /// message the people in it (the core's `channelDisplayName`). Empty
    /// when the server gave neither.
    @Default('') String title,

    /// Notifies for mentions only: no unread badge, and no alert for a
    /// message that does not mention the user (Open WebUI's mute).
    @Default(false) bool muted,

    /// May delete it: its owner, or an admin.
    @Default(false) bool canDelete,

    /// Has members one can leave (a group or a direct message).
    @Default(false) bool canLeave,
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

    /// May make a channel (New Channel): an admin, or a user the server's
    /// permissions let.
    @Default(false) bool canCreate,
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

    /// Who they are, as far as the server names them (a tooltip).
    @Default(<String>[]) List<String> names,
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

    /// Who is speaking, for grouping a run of messages under one name: a
    /// user's id, `model:<id>` or `app:<id>` (the core's
    /// `channelMessageSender`).
    @Default('') String senderKey,
    @Default(ChannelSenderKind.user) ChannelSenderKind senderKind,

    /// [content] ready to draw: mention markup as `@Name`, and the core's
    /// plain-markdown normalisation. [content] stays as written, for an
    /// edit.
    @Default('') String display,

    /// Files and images posted with it (`data.files`).
    @Default(<ChannelFileDto>[]) List<ChannelFileDto> files,

    /// The cards and buttons of an app's message.
    ChannelAppContentDto? app,

    /// The message this one replies to, inline (not a thread).
    String? replyToId,
    ChannelReplyPreview? replyTo,
    int? latestReplyAtMs,
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

    /// May be empty when [files] are posted.
    @Default('') String content,

    /// A reply in the thread of this message.
    String? parentId,

    /// The mentions in [content], which the daemon writes as Open WebUI's
    /// `<@U:id|Name>` and `<@M:id|Name>`.
    @Default(<ComposerMentionDto>[]) List<ComposerMentionDto> mentions,

    /// Files already uploaded (`/upload`), posted with the message.
    @Default(<ChannelFileDto>[]) List<ChannelFileDto> files,

    /// An inline reply to this message.
    String? replyToId,
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
/// an edit, a reaction, a reply. It carries what changed in the list it
/// names ([parentId]: a thread's), so the window patches what it shows;
/// with [full] (or neither list) the window refetches it.
@freezed
abstract class ChannelMessagesChanged with _$ChannelMessagesChanged {
  const factory ChannelMessagesChanged({
    required String channelId,
    String? parentId,

    /// New or changed messages, as the list now holds them.
    @Default(<ChannelMessageDto>[]) List<ChannelMessageDto> upserts,
    @Default(<String>[]) List<String> removed,
    @Default(false) bool full,

    /// Whether older messages are left to load, as the list now says.
    bool? hasOlder,
  }) = _ChannelMessagesChanged;

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

/// Who wrote a channel message.
enum ChannelSenderKind { user, model, app }

/// A file or image posted in a channel (`data.files`). [id] is the server
/// file's: the window loads it through `/files`.
@freezed
abstract class ChannelFileDto with _$ChannelFileDto {
  const factory ChannelFileDto({
    required String id,
    @Default('') String name,
    @Default(false) bool image,
    int? size,
    String? contentType,
  }) = _ChannelFileDto;

  factory ChannelFileDto.fromJson(Map<String, dynamic> json) =>
      _$ChannelFileDtoFromJson(json);
}

/// The message an inline reply answers, as a one-line preview.
@freezed
abstract class ChannelReplyPreview with _$ChannelReplyPreview {
  const factory ChannelReplyPreview({
    @Default('') String name,

    /// Its text (or its cards' text), mentions as `@Name`.
    @Default('') String text,
  }) = _ChannelReplyPreview;

  factory ChannelReplyPreview.fromJson(Map<String, dynamic> json) =>
      _$ChannelReplyPreviewFromJson(json);
}

/// One name and value of an app card.
@freezed
abstract class ChannelAppFieldDto with _$ChannelAppFieldDto {
  const factory ChannelAppFieldDto({
    required String name,

    /// Markdown.
    required String value,

    /// May share a row with the other inline fields.
    @Default(false) bool inline,
  }) = _ChannelAppFieldDto;

  factory ChannelAppFieldDto.fromJson(Map<String, dynamic> json) =>
      _$ChannelAppFieldDtoFromJson(json);
}

/// A card an app attaches to a message or a reply (the core's `AppEmbed`).
@freezed
abstract class ChannelAppEmbedDto with _$ChannelAppEmbedDto {
  const factory ChannelAppEmbedDto({
    @Default('') String title,

    /// Markdown.
    @Default('') String description,

    /// What the title opens (http or https).
    String? url,

    /// An accent, as 24-bit RGB.
    int? color,
    String? authorName,
    String? footerText,
    String? thumbnailUrl,
    @Default(<ChannelAppFieldDto>[]) List<ChannelAppFieldDto> fields,
  }) = _ChannelAppEmbedDto;

  factory ChannelAppEmbedDto.fromJson(Map<String, dynamic> json) =>
      _$ChannelAppEmbedDtoFromJson(json);
}

/// A button ([actionId]) or a link ([url]) of an app's message.
@freezed
abstract class ChannelAppActionDto with _$ChannelAppActionDto {
  const factory ChannelAppActionDto({
    required String label,
    String? actionId,
    String? url,
  }) = _ChannelAppActionDto;

  factory ChannelAppActionDto.fromJson(Map<String, dynamic> json) =>
      _$ChannelAppActionDtoFromJson(json);
}

/// The cards and buttons of an app's message.
@freezed
abstract class ChannelAppContentDto with _$ChannelAppContentDto {
  const factory ChannelAppContentDto({
    required String appId,
    @Default(<ChannelAppEmbedDto>[]) List<ChannelAppEmbedDto> embeds,
    @Default(<ChannelAppActionDto>[]) List<ChannelAppActionDto> actions,
  }) = _ChannelAppContentDto;

  factory ChannelAppContentDto.fromJson(Map<String, dynamic> json) =>
      _$ChannelAppContentDtoFromJson(json);
}

/// What kind of answer an app gave.
enum ChannelAppReplyKind { message, update, download, error }

/// An app's answer shown to the signed-in user alone (the core's
/// `AppChannelReply`): never stored, gone once dismissed or once the
/// channel closes.
@freezed
abstract class ChannelAppReplyDto with _$ChannelAppReplyDto {
  const factory ChannelAppReplyDto({
    @Default(ChannelAppReplyKind.message) ChannelAppReplyKind kind,
    @Default('') String title,

    /// Markdown; a download's file content.
    @Default('') String content,

    /// A download's file name.
    @Default('report.md') String filename,
    @Default(<ChannelAppEmbedDto>[]) List<ChannelAppEmbedDto> embeds,
    @Default(<ChannelAppActionDto>[]) List<ChannelAppActionDto> actions,
  }) = _ChannelAppReplyDto;

  factory ChannelAppReplyDto.fromJson(Map<String, dynamic> json) =>
      _$ChannelAppReplyDtoFromJson(json);
}

/// A private app answer under message [messageId]: payload of
/// `channels.appReply` (scoped to `channel:<id>`), and what
/// `channels.appAction` answers when the answer is for the asker alone.
@freezed
abstract class ChannelAppReplyEvent with _$ChannelAppReplyEvent {
  const factory ChannelAppReplyEvent({
    required String channelId,
    required String messageId,

    /// The thread it belongs to; null for the channel itself.
    String? parentId,
    required String appId,
    String? appName,
    required ChannelAppReplyDto reply,
  }) = _ChannelAppReplyEvent;

  factory ChannelAppReplyEvent.fromJson(Map<String, dynamic> json) =>
      _$ChannelAppReplyEventFromJson(json);
}

/// Params for `channels.appAction`: press a button on an app's message.
@freezed
abstract class ChannelAppAction with _$ChannelAppAction {
  const factory ChannelAppAction({
    required String channelId,
    required String messageId,
    required String actionId,
    String? parentId,
  }) = _ChannelAppAction;

  factory ChannelAppAction.fromJson(Map<String, dynamic> json) =>
      _$ChannelAppActionFromJson(json);
}

/// Reply to `channels.appAction`: the answer shown to the asker alone, if
/// the app gave one (a reply to everyone arrives as a message).
@freezed
abstract class ChannelAppActionResult with _$ChannelAppActionResult {
  const factory ChannelAppActionResult({ChannelAppReplyEvent? reply}) =
      _ChannelAppActionResult;

  factory ChannelAppActionResult.fromJson(Map<String, dynamic> json) =>
      _$ChannelAppActionResultFromJson(json);
}

/// Reply to `channels.open`: the channel as its pane shows it.
@freezed
abstract class ChannelDetails with _$ChannelDetails {
  const factory ChannelDetails({
    required ChannelSummary channel,

    /// May add and remove members (a group the user manages).
    @Default(false) bool canManageMembers,

    /// An admin: may delete anyone's message, not only their own.
    @Default(false) bool moderator,
  }) = _ChannelDetails;

  factory ChannelDetails.fromJson(Map<String, dynamic> json) =>
      _$ChannelDetailsFromJson(json);
}

/// Params for `channels.focus`: the channel in front of the user now (its
/// pane shown in the key window), or none.
@freezed
abstract class ChannelFocus with _$ChannelFocus {
  const factory ChannelFocus({String? id}) = _ChannelFocus;

  factory ChannelFocus.fromJson(Map<String, dynamic> json) =>
      _$ChannelFocusFromJson(json);
}

/// Params for `channels.setMuted`.
@freezed
abstract class ChannelMute with _$ChannelMute {
  const factory ChannelMute({required String id, required bool muted}) =
      _ChannelMute;

  factory ChannelMute.fromJson(Map<String, dynamic> json) =>
      _$ChannelMuteFromJson(json);
}

/// Params for `channels.mentions`: the channel's members whose name
/// matches [query], for `@`.
@freezed
abstract class ChannelMentionQuery with _$ChannelMentionQuery {
  const factory ChannelMentionQuery({
    required String channelId,
    @Default('') String query,
  }) = _ChannelMentionQuery;

  factory ChannelMentionQuery.fromJson(Map<String, dynamic> json) =>
      _$ChannelMentionQueryFromJson(json);
}

/// One member, as the members sheet lists them.
@freezed
abstract class ChannelMemberDto with _$ChannelMemberDto {
  const factory ChannelMemberDto({
    required String id,
    @Default('') String name,
    String? email,

    /// `admin`, `user` or `pending`.
    String? role,

    /// Online now.
    @Default(false) bool active,

    /// The signed-in user.
    @Default(false) bool me,
  }) = _ChannelMemberDto;

  factory ChannelMemberDto.fromJson(Map<String, dynamic> json) =>
      _$ChannelMemberDtoFromJson(json);
}

/// Params for `channels.memberPage`: the first page of [query], or with
/// [more] the next one.
@freezed
abstract class ChannelMemberQuery with _$ChannelMemberQuery {
  const factory ChannelMemberQuery({
    required String channelId,
    @Default('') String query,
    @Default(false) bool more,
  }) = _ChannelMemberQuery;

  factory ChannelMemberQuery.fromJson(Map<String, dynamic> json) =>
      _$ChannelMemberQueryFromJson(json);
}

/// How the members list stands.
enum ChannelMemberListPhase { loading, ready, failed, ownerChanged }

/// Reply to `channels.memberPage`: the members loaded so far for the
/// query, by name, and what the user may change.
@freezed
abstract class ChannelMemberPage with _$ChannelMemberPage {
  const factory ChannelMemberPage({
    required String channelId,
    @Default('') String query,
    @Default(ChannelMemberListPhase.ready) ChannelMemberListPhase phase,
    @Default(<ChannelMemberDto>[]) List<ChannelMemberDto> members,
    int? total,
    @Default(false) bool hasMore,
    @Default(false) bool loadMoreFailed,

    /// May add and remove members, and whom one may add.
    @Default(false) bool canManage,
    @Default(false) bool allowUsers,
    @Default(false) bool allowGroups,
  }) = _ChannelMemberPage;

  factory ChannelMemberPage.fromJson(Map<String, dynamic> json) =>
      _$ChannelMemberPageFromJson(json);
}

/// Params for `channels.addMembers`.
@freezed
abstract class ChannelMembersAdd with _$ChannelMembersAdd {
  const factory ChannelMembersAdd({
    required String channelId,
    @Default(<String>[]) List<String> userIds,
    @Default(<String>[]) List<String> groupIds,
  }) = _ChannelMembersAdd;

  factory ChannelMembersAdd.fromJson(Map<String, dynamic> json) =>
      _$ChannelMembersAddFromJson(json);
}

/// Params for `channels.removeMember`.
@freezed
abstract class ChannelMemberRemove with _$ChannelMemberRemove {
  const factory ChannelMemberRemove({
    required String channelId,
    required String userId,
  }) = _ChannelMemberRemove;

  factory ChannelMemberRemove.fromJson(Map<String, dynamic> json) =>
      _$ChannelMemberRemoveFromJson(json);
}

/// What became of an add or a remove (the core's
/// `ChannelMemberMutationResult`).
enum ChannelMemberChangeResult {
  done,
  ownerChanged,
  notPermitted,
  denied,
  failed,
  busy,
}

/// Reply to `channels.addMembers` and `channels.removeMember`.
@freezed
abstract class ChannelMemberChange with _$ChannelMemberChange {
  const factory ChannelMemberChange({
    required ChannelMemberChangeResult result,
    required ChannelMemberPage page,
  }) = _ChannelMemberChange;

  factory ChannelMemberChange.fromJson(Map<String, dynamic> json) =>
      _$ChannelMemberChangeFromJson(json);
}

/// Payload of `channels.posted` (unscoped): someone else posted in a
/// channel that is not in front of the user. Its unread count went up;
/// [alert] says whether it notifies (Open WebUI's rule: always, or for a
/// channel set to mentions only, when it mentions the user). Never the
/// message's text.
@freezed
abstract class ChannelPosted with _$ChannelPosted {
  const factory ChannelPosted({
    required String channelId,
    required String messageId,
    @Default('') String author,

    /// The channel's name ([ChannelSummary.title]); empty for a direct
    /// message, which the author names.
    @Default('') String channelTitle,
    @Default(ChannelKind.standard) ChannelKind kind,
    @Default(true) bool alert,

    /// The message mentions the user.
    @Default(false) bool mention,
  }) = _ChannelPosted;

  factory ChannelPosted.fromJson(Map<String, dynamic> json) =>
      _$ChannelPostedFromJson(json);
}
