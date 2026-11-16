import 'package:freezed_annotation/freezed_annotation.dart';

part 'hermes_rooms.freezed.dart';
part 'hermes_rooms.g.dart';

// ---------------------------------------------------------------------------
// hermes.bots.* -- Bot Mode: the gateway's bots and their Bot Chats
// ---------------------------------------------------------------------------

/// A Bot Mode bot: a Hermes profile the gateway marks as a bot, with its
/// face. Opened with `hermes.bots.open`, as its permanent Bot Chat.
@freezed
abstract class HermesBotDto with _$HermesBotDto {
  const factory HermesBotDto({
    /// The profile's name: what the bot is addressed by.
    required String name,

    /// What the roster calls it (its profile name when it has no title).
    required String title,
    String? description,

    /// The newest message in its Bot Chat.
    String? preview,

    /// Its Bot Chat's Hermes session, when known: the chat
    /// `local:hermes_<sessionId>` is this bot's.
    String? sessionId,

    /// It has a picture (`hermes.bots.avatar`); without one its face is a
    /// shape in a colour.
    @Default(false) bool hasAvatar,

    /// The face's shape: `circle`, `squircle`, `pill`, `triangle`,
    /// `hexagon`, `cloud` or `drop`.
    @Default('squircle') String shape,

    /// The face's colour, `#rrggbb`.
    @Default('#8b5cf6') String color,

    /// When its Bot Chat was last active, in milliseconds since the epoch.
    int? lastActiveMs,
  }) = _HermesBotDto;

  factory HermesBotDto.fromJson(Map<String, dynamic> json) =>
      _$HermesBotDtoFromJson(json);
}

/// Reply to `hermes.bots.list`: the roster, most recently active first.
@freezed
abstract class HermesBots with _$HermesBots {
  const factory HermesBots({
    /// The gateway has Bot Mode (a Desktop Gateway that lists bots); the
    /// sidebar's Bots group shows only then.
    @Default(false) bool available,
    @Default(<HermesBotDto>[]) List<HermesBotDto> bots,

    /// The Hermes connection this answer is for (`HermesChanged.connection`).
    String? connection,
  }) = _HermesBots;

  factory HermesBots.fromJson(Map<String, dynamic> json) =>
      _$HermesBotsFromJson(json);
}

/// Params naming a bot, by its profile name.
@freezed
abstract class HermesBotRef with _$HermesBotRef {
  const factory HermesBotRef({
    required String name,

    /// The Hermes connection this was asked under (`HermesChanged.connection`):
    /// refused (`sessionExpired`) once another connection is in use.
    String? connection,
  }) = _HermesBotRef;

  factory HermesBotRef.fromJson(Map<String, dynamic> json) =>
      _$HermesBotRefFromJson(json);
}

/// Reply to `hermes.bots.avatar`: the bot's picture as a `data:image/...`
/// URL, or none.
@freezed
abstract class HermesBotAvatar with _$HermesBotAvatar {
  const factory HermesBotAvatar({required String name, String? image}) =
      _HermesBotAvatar;

  factory HermesBotAvatar.fromJson(Map<String, dynamic> json) =>
      _$HermesBotAvatarFromJson(json);
}

// ---------------------------------------------------------------------------
// hermes.rooms.* -- Group Chats: bots talking together, on a Desktop Gateway
// ---------------------------------------------------------------------------

/// One bot seated in a room.
@freezed
abstract class HermesRoomMemberDto with _$HermesRoomMemberDto {
  const factory HermesRoomMemberDto({
    required String memberId,

    /// The profile it runs as (a roster bot's [HermesBotDto.name]).
    required String profile,

    /// What an @mention calls it.
    required String handle,

    /// What the room calls it.
    required String name,
  }) = _HermesRoomMemberDto;

  factory HermesRoomMemberDto.fromJson(Map<String, dynamic> json) =>
      _$HermesRoomMemberDtoFromJson(json);
}

/// A Group Chat, as the sidebar lists it.
@freezed
abstract class HermesRoomDto with _$HermesRoomDto {
  const factory HermesRoomDto({
    required String id,
    required String name,
    @Default(<HermesRoomMemberDto>[]) List<HermesRoomMemberDto> members,

    /// Its last activity, in milliseconds since the epoch.
    int? updatedAtMs,

    /// Something was said since this device last showed it.
    @Default(false) bool unread,

    /// Its bots were at work when it was last read.
    @Default(false) bool working,

    /// One of its bots waits for an answer (an approval).
    @Default(false) bool needsYou,
  }) = _HermesRoomDto;

  factory HermesRoomDto.fromJson(Map<String, dynamic> json) =>
      _$HermesRoomDtoFromJson(json);
}

/// Reply to `hermes.rooms.list`, and payload of `hermes.rooms.listChanged`:
/// the gateway's live Group Chats, most recently active first.
@freezed
abstract class HermesRooms with _$HermesRooms {
  const factory HermesRooms({
    /// The gateway hosts Group Chats: the sidebar's Rooms group shows.
    @Default(false) bool available,

    /// A new room can be made: the gateway runs rooms and two bots can sit
    /// in one.
    @Default(false) bool canCreate,

    /// The bots a new room may seat, by profile name.
    @Default(<String>[]) List<String> seatable,
    @Default(<HermesRoomDto>[]) List<HermesRoomDto> rooms,

    /// The list could not be read (one read before stays).
    @Default(false) bool failed,

    /// The Hermes connection this answer is for (`HermesChanged.connection`).
    String? connection,
  }) = _HermesRooms;

  factory HermesRooms.fromJson(Map<String, dynamic> json) =>
      _$HermesRoomsFromJson(json);
}

/// Params naming a room.
@freezed
abstract class HermesRoomRef with _$HermesRoomRef {
  const factory HermesRoomRef({
    required String roomId,

    /// The Hermes connection this was asked under (`HermesChanged.connection`):
    /// refused (`sessionExpired`) once another connection is in use.
    String? connection,
  }) = _HermesRoomRef;

  factory HermesRoomRef.fromJson(Map<String, dynamic> json) =>
      _$HermesRoomRefFromJson(json);
}

/// Params for `hermes.rooms.create`: a name and two to six bots.
@freezed
abstract class HermesRoomCreate with _$HermesRoomCreate {
  const factory HermesRoomCreate({
    required String name,

    /// The bots to seat, by profile name, in the order picked.
    required List<String> bots,

    /// The Hermes connection this was asked under (`HermesChanged.connection`):
    /// refused (`sessionExpired`) once another connection is in use.
    String? connection,
  }) = _HermesRoomCreate;

  factory HermesRoomCreate.fromJson(Map<String, dynamic> json) =>
      _$HermesRoomCreateFromJson(json);
}

/// Params for `hermes.rooms.rename`.
@freezed
abstract class HermesRoomRename with _$HermesRoomRename {
  const factory HermesRoomRename({
    required String roomId,
    required String name,

    /// The Hermes connection this was asked under (`HermesChanged.connection`):
    /// refused (`sessionExpired`) once another connection is in use.
    String? connection,
  }) = _HermesRoomRename;

  factory HermesRoomRename.fromJson(Map<String, dynamic> json) =>
      _$HermesRoomRenameFromJson(json);
}

/// Who answers a message that names nobody.
enum HermesRoomRouting {
  /// Every bot takes a turn.
  everyone,

  /// The lead bot hands the message on.
  lead,

  /// A quick model call picks who answers.
  auto,
}

/// A room's purpose, shared notes and who answers.
@freezed
abstract class HermesRoomContextDto with _$HermesRoomContextDto {
  const factory HermesRoomContextDto({
    @Default('') String purpose,
    @Default('') String notes,

    /// None on a Hermes that cannot choose (everyone answers).
    HermesRoomRouting? routing,

    /// The lead bot, when [routing] is [HermesRoomRouting.lead].
    String? leadMemberId,
  }) = _HermesRoomContextDto;

  factory HermesRoomContextDto.fromJson(Map<String, dynamic> json) =>
      _$HermesRoomContextDtoFromJson(json);
}

/// Params for `hermes.rooms.saveContext`; replies with what Hermes saved.
@freezed
abstract class HermesRoomContextEdit with _$HermesRoomContextEdit {
  const factory HermesRoomContextEdit({
    required String roomId,
    required HermesRoomContextDto context,

    /// The Hermes connection this was asked under (`HermesChanged.connection`):
    /// refused (`sessionExpired`) once another connection is in use.
    String? connection,
  }) = _HermesRoomContextEdit;

  factory HermesRoomContextEdit.fromJson(Map<String, dynamic> json) =>
      _$HermesRoomContextEditFromJson(json);
}

/// Params for `hermes.rooms.send`.
@freezed
abstract class HermesRoomMessage with _$HermesRoomMessage {
  const factory HermesRoomMessage({
    required String roomId,
    required String text,

    /// The Hermes connection this was asked under (`HermesChanged.connection`):
    /// refused (`sessionExpired`) once another connection is in use.
    String? connection,
  }) = _HermesRoomMessage;

  factory HermesRoomMessage.fromJson(Map<String, dynamic> json) =>
      _$HermesRoomMessageFromJson(json);
}

/// Reply to `hermes.rooms.send`.
///
/// Sent: Hermes has the words (the field clears). Otherwise the words stay
/// in the field: refused before Hermes posted anything (with Hermes's
/// [detail] when it gave one), or unclear -- Hermes may have them, and
/// sending again posts them at most once (the room's view keeps
/// [HermesRoomView.unsentText] until its log settles it).
@freezed
abstract class HermesRoomSendResult with _$HermesRoomSendResult {
  const factory HermesRoomSendResult({
    @Default(false) bool sent,
    @Default(false) bool refused,
    String? detail,
  }) = _HermesRoomSendResult;

  factory HermesRoomSendResult.fromJson(Map<String, dynamic> json) =>
      _$HermesRoomSendResultFromJson(json);
}

/// Reply to `hermes.rooms.stop`: how many tasks stopped.
@freezed
abstract class HermesRoomStopped with _$HermesRoomStopped {
  const factory HermesRoomStopped({@Default(0) int stopped}) =
      _HermesRoomStopped;

  factory HermesRoomStopped.fromJson(Map<String, dynamic> json) =>
      _$HermesRoomStoppedFromJson(json);
}

/// Params for `hermes.rooms.continue`: one more budget for a paused
/// discussion.
@freezed
abstract class HermesRoomContinue with _$HermesRoomContinue {
  const factory HermesRoomContinue({
    required String roomId,
    required String discussionEventId,

    /// The Hermes connection this was asked under (`HermesChanged.connection`):
    /// refused (`sessionExpired`) once another connection is in use.
    String? connection,
  }) = _HermesRoomContinue;

  factory HermesRoomContinue.fromJson(Map<String, dynamic> json) =>
      _$HermesRoomContinueFromJson(json);
}

/// Params for `hermes.rooms.answer`: an approval answered (`once` or
/// `deny`), or uncertain work retried (no [choice]).
@freezed
abstract class HermesRoomAnswer with _$HermesRoomAnswer {
  const factory HermesRoomAnswer({
    required String roomId,
    required String taskId,
    required int executionGeneration,
    String? choice,

    /// The Hermes connection this was asked under (`HermesChanged.connection`):
    /// refused (`sessionExpired`) once another connection is in use.
    String? connection,
  }) = _HermesRoomAnswer;

  factory HermesRoomAnswer.fromJson(Map<String, dynamic> json) =>
      _$HermesRoomAnswerFromJson(json);
}

/// What a row of a room's timeline is.
enum HermesRoomItemKind {
  /// A message: the user's ([HermesRoomItemDto.own]), a scheduled post's
  /// or a bot's.
  message,

  /// A quiet line about the room's work ([HermesRoomItemDto.notice]).
  notice,

  /// Who a message went to ([HermesRoomItemDto.route]).
  route,

  /// A discussion paused at its limit, with Continue while
  /// [HermesRoomItemDto.actionable].
  pause,
}

/// What a notice line says.
enum HermesRoomNoticeKind {
  turnFailed,
  turnCancelled,
  turnDeferred,
  memberUnavailable,
  stopped,
  disbanded,
  authorityLost,
  workLimit,
}

/// What a routing line says.
enum HermesRoomRouteKind {
  /// Hermes picked who answers ([HermesRoomItemDto.names]).
  routedTo,
  routedEveryone,

  /// Hermes could not pick, so everyone answers.
  routedFallback,

  /// The lead gave the message to [HermesRoomItemDto.names].
  assigned,

  /// The lead takes the message itself.
  leadTaking,

  /// The user continued a paused discussion.
  continued,

  /// A bot asked another in its reply.
  handoff,
}

/// One row of a room's timeline: one flat record for every
/// [HermesRoomItemKind], whose [kind] says which fields it uses.
@freezed
abstract class HermesRoomItemDto with _$HermesRoomItemDto {
  const factory HermesRoomItemDto({
    required HermesRoomItemKind kind,

    /// Stays with the row across reads.
    required String key,

    /// The log event the row belongs to.
    required int seq,

    /// `message`: the user's own.
    @Default(false) bool own,

    /// `message`: a scheduled job's post.
    @Default(false) bool scheduled,

    /// `message`: who wrote it (empty for the user's own).
    @Default('') String author,

    /// `message`: the bot that wrote it; `notice`: the bot it is about.
    String? memberId,

    /// `message`: its markdown.
    @Default('') String text,

    /// `message`: the same author wrote the row before (no name or face).
    @Default(false) bool continued,
    int? createdAtMs,

    /// `notice`.
    HermesRoomNoticeKind? notice,

    /// `notice`: the bot it is about, by name; and Hermes's reason.
    String? memberName,
    String? detail,

    /// `route`.
    HermesRoomRouteKind? route,
    @Default(<String>[]) List<String> names,
    String? lead,

    /// `pause`: the discussion Continue continues, how many bot messages
    /// it had, and whether Continue and Stop still apply.
    String? discussionEventId,
    @Default(0) int messageCount,
    @Default(false) bool actionable,
  }) = _HermesRoomItemDto;

  factory HermesRoomItemDto.fromJson(Map<String, dynamic> json) =>
      _$HermesRoomItemDtoFromJson(json);
}

/// A bot's state in the room right now.
enum HermesRoomMemberState {
  idle,
  queued,
  working,

  /// Working, but silent for two minutes.
  stalled,
  replied,
  passed,
  failed,
  cancelled,
  unavailable,
}

/// One bot's state, for the header and the Info sheet.
@freezed
abstract class HermesRoomMemberStatusDto with _$HermesRoomMemberStatusDto {
  const factory HermesRoomMemberStatusDto({
    required String memberId,
    required HermesRoomMemberState state,

    /// How long its turn has run, when it works; the window counts on.
    int? elapsedMs,

    /// The tool it is in.
    String? tool,

    /// Why its last turn failed.
    String? reason,
  }) = _HermesRoomMemberStatusDto;

  factory HermesRoomMemberStatusDto.fromJson(Map<String, dynamic> json) =>
      _$HermesRoomMemberStatusDtoFromJson(json);
}

/// A decision the room waits on, drawn as a card under the timeline.
@freezed
abstract class HermesRoomActionDto with _$HermesRoomActionDto {
  const factory HermesRoomActionDto({
    /// `approval` or `retry`.
    required String kind,
    required String memberId,
    required String taskId,
    required int executionGeneration,

    /// What the approval would run (a command, or the operation it stands
    /// for).
    String? summary,

    /// The answers this app may give (`once`, `deny`); none: the card says
    /// what waits, without buttons.
    @Default(<String>[]) List<String> choices,
  }) = _HermesRoomActionDto;

  factory HermesRoomActionDto.fromJson(Map<String, dynamic> json) =>
      _$HermesRoomActionDtoFromJson(json);
}

/// An open room, as its pane shows it. Reply to `hermes.rooms.watch`, and
/// payload of `hermes.rooms.changed` (scoped to `hermes-room:<roomId>`)
/// while a window watches it: the daemon reads the room every 2 s.
@freezed
abstract class HermesRoomView with _$HermesRoomView {
  const factory HermesRoomView({
    required String roomId,

    /// Read once.
    @Default(false) bool loaded,

    /// None until read, or when the read failed with nothing read before.
    HermesRoomDto? room,
    HermesRoomContextDto? context,

    /// The room left the gateway (disbanded, or not this user's).
    @Default(false) bool gone,

    /// The last read failed (the last good read stays shown).
    @Default(false) bool readFailed,

    /// Its driver runs: messages can be sent.
    @Default(false) bool running,

    /// Its bots are at work: Stop applies.
    @Default(false) bool working,
    @Default(false) bool sending,

    /// Words Hermes may or may not have; sending them again posts them at
    /// most once.
    String? unsentText,

    /// Who-answers modes Hermes offers (none: Hermes cannot choose).
    @Default(<HermesRoomRouting>[]) List<HermesRoomRouting> routingModes,
    @Default(<HermesRoomItemDto>[]) List<HermesRoomItemDto> items,
    @Default(<HermesRoomMemberStatusDto>[])
    List<HermesRoomMemberStatusDto> members,
    @Default(<HermesRoomActionDto>[]) List<HermesRoomActionDto> actions,

    /// The Hermes connection this view was read on (`HermesChanged.connection`).
    String? connection,
  }) = _HermesRoomView;

  factory HermesRoomView.fromJson(Map<String, dynamic> json) =>
      _$HermesRoomViewFromJson(json);
}
