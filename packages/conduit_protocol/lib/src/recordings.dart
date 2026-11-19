import 'package:freezed_annotation/freezed_annotation.dart';

part 'recordings.freezed.dart';
part 'recordings.g.dart';

/// Names the draft whose recordings these are: a stored chat's, or a new
/// chat's (in a folder, or none), as `drafts.*` does. Params for
/// `recordings.list` and `recordings.begin`.
///
/// A recording is the audio of a dictation, kept in the account's database
/// with the unsent draft (never in chat history or a sync payload) until
/// the draft is sent or the recording discarded. A temporary or read-only
/// chat keeps none.
@freezed
abstract class RecordingTarget with _$RecordingTarget {
  const factory RecordingTarget({
    /// Null for a chat not started yet.
    String? chatId,

    /// A new chat's folder; ignored with a [chatId].
    String? folderId,
  }) = _RecordingTarget;

  factory RecordingTarget.fromJson(Map<String, dynamic> json) =>
      _$RecordingTargetFromJson(json);
}

/// One saved recording: 16 kHz mono 16-bit PCM.
@freezed
abstract class RecordingDto with _$RecordingDto {
  const factory RecordingDto({
    required String id,

    /// When it started, in milliseconds since the epoch.
    @Default(0) int createdAt,
    @Default(0) int byteCount,

    /// How long it is, from [byteCount].
    @Default(0) int durationMs,
  }) = _RecordingDto;

  factory RecordingDto.fromJson(Map<String, dynamic> json) =>
      _$RecordingDtoFromJson(json);
}

/// Reply to `recordings.list` and `recordings.discard`: the draft's
/// recordings, oldest first.
@freezed
abstract class RecordingList with _$RecordingList {
  const factory RecordingList({
    /// False when the draft keeps none (a temporary or read-only chat).
    @Default(true) bool stored,
    @Default(<RecordingDto>[]) List<RecordingDto> recordings,
  }) = _RecordingList;

  factory RecordingList.fromJson(Map<String, dynamic> json) =>
      _$RecordingListFromJson(json);
}

/// Reply to `recordings.begin`: the new recording, or none when the draft
/// keeps no recordings (the window then holds the audio itself).
@freezed
abstract class RecordingStarted with _$RecordingStarted {
  const factory RecordingStarted({String? id, @Default(true) bool stored}) =
      _RecordingStarted;

  factory RecordingStarted.fromJson(Map<String, dynamic> json) =>
      _$RecordingStartedFromJson(json);
}

/// Params for `recordings.append`: the next audio of an open recording.
@freezed
abstract class RecordingChunk with _$RecordingChunk {
  const factory RecordingChunk({
    required String id,

    /// 16 kHz mono 16-bit little-endian PCM, base64.
    required String pcm,
  }) = _RecordingChunk;

  factory RecordingChunk.fromJson(Map<String, dynamic> json) =>
      _$RecordingChunkFromJson(json);
}

/// Reply to `recordings.append` and `recordings.close`: how much of the
/// recording is safely stored.
@freezed
abstract class RecordingSaved with _$RecordingSaved {
  const factory RecordingSaved({
    required String id,
    @Default(0) int savedBytes,

    /// Closed with nothing in it, so not kept.
    @Default(false) bool discarded,
  }) = _RecordingSaved;

  factory RecordingSaved.fromJson(Map<String, dynamic> json) =>
      _$RecordingSavedFromJson(json);
}

/// Params for `recordings.close` and `recordings.discard`, and for
/// `GET /recordings/{id}` (as its query): a recording of a draft.
@freezed
abstract class RecordingRef with _$RecordingRef {
  const factory RecordingRef({
    required String id,
    String? chatId,
    String? folderId,
  }) = _RecordingRef;

  factory RecordingRef.fromJson(Map<String, dynamic> json) =>
      _$RecordingRefFromJson(json);
}

/// Params for `recordings.transcribe`: a saved recording, as text.
@freezed
abstract class RecordingTranscribe with _$RecordingTranscribe {
  const factory RecordingTranscribe({
    required String id,
    String? chatId,
    String? folderId,

    /// `server` (the model's backend) or `local` (whisper on this
    /// computer).
    @Default('server') String engine,

    /// The chat's model, whose backend transcribes on the server.
    String? modelId,
  }) = _RecordingTranscribe;

  factory RecordingTranscribe.fromJson(Map<String, dynamic> json) =>
      _$RecordingTranscribeFromJson(json);
}
