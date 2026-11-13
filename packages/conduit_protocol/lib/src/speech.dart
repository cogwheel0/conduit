import 'package:freezed_annotation/freezed_annotation.dart';

part 'speech.freezed.dart';
part 'speech.g.dart';

/// Where a reading is: the phone's `TtsPlaybackStatus`.
enum SpeechStatus { idle, initializing, loading, speaking, paused, error }

/// What reads aloud: the Mac's own voices (`device`) or the chat's server
/// (`server`: Open WebUI, the Direct voice provider, Hermes or LibreChat).
enum SpeechEngine { device, server }

/// A reading's progress: what `speech.changed` carries. Its sentences come
/// with [SpeechState], fetched once per [reading].
@freezed
abstract class SpeechProgress with _$SpeechProgress {
  const factory SpeechProgress({
    @Default(SpeechStatus.idle) SpeechStatus status,

    /// Each reading's own number: when it changes, the sentences did too.
    @Default(0) int reading,

    /// The chat the message is in. None for Settings' preview.
    String? chatId,

    /// The message read: an answer's id (a version's while one is shown),
    /// or `tts_preview` for Settings' preview.
    String? messageId,
    SpeechEngine? engine,

    /// The sentence being said, or -1.
    @Default(-1) int sentence,

    /// The word being said, as UTF-16 offsets in the sentence: reported by
    /// the Mac's voices, estimated from the position for server speech.
    int? wordStart,
    int? wordEnd,

    /// Whether the engine reports each word as it says it.
    @Default(false) bool wordsReported,
    @Default(0) int elapsedMs,

    /// The whole reading's length, once known (server speech); 0 otherwise.
    @Default(0) int durationMs,

    /// Whether the reading can move to a time ([durationMs] known).
    @Default(false) bool canSeek,

    /// Whether it can move from sentence to sentence.
    @Default(false) bool canSeekSentences,
    @Default(false) bool seeking,

    /// What went wrong, for the log; the window says it in its own words.
    String? error,
  }) = _SpeechProgress;

  factory SpeechProgress.fromJson(Map<String, dynamic> json) =>
      _$SpeechProgressFromJson(json);
}

/// The reading now, with its sentences: what every `speech.*` call answers.
@freezed
abstract class SpeechState with _$SpeechState {
  const factory SpeechState({
    required SpeechProgress progress,

    /// The text read, as the engine says it, sentence by sentence.
    @Default(<String>[]) List<String> sentences,
  }) = _SpeechState;

  factory SpeechState.fromJson(Map<String, dynamic> json) =>
      _$SpeechStateFromJson(json);
}

/// Params for `speech.toggle`: reads an answer aloud, or stops (pauses
/// resume) the reading of it, as the phone's Read Aloud button does.
@freezed
abstract class SpeechToggle with _$SpeechToggle {
  const factory SpeechToggle({
    required String chatId,

    /// The answer's id (a version's while one is shown).
    required String messageId,
  }) = _SpeechToggle;

  factory SpeechToggle.fromJson(Map<String, dynamic> json) =>
      _$SpeechToggleFromJson(json);
}

/// Params for `speech.seek`: moves the reading to the start of a sentence,
/// or by some sentences ([by]), or to a time ([ms]); exactly one is given.
@freezed
abstract class SpeechSeek with _$SpeechSeek {
  const factory SpeechSeek({int? sentence, int? by, int? ms}) = _SpeechSeek;

  factory SpeechSeek.fromJson(Map<String, dynamic> json) =>
      _$SpeechSeekFromJson(json);
}

/// Params for `speech.preview`: Settings › Audio's sample, in the chosen
/// engine, voice and speed. Pressing it again stops it.
@freezed
abstract class SpeechPreview with _$SpeechPreview {
  const factory SpeechPreview({required String text}) = _SpeechPreview;

  factory SpeechPreview.fromJson(Map<String, dynamic> json) =>
      _$SpeechPreviewFromJson(json);
}

/// What `speech.command` asks the window's speech engine to do.
enum SpeechCommandKind {
  /// Whether the Mac's voices can speak: answered with [SpeechReport.value].
  deviceAvailable,

  /// The installed voices: answered with [SpeechReport.voices].
  deviceVoices,

  /// Say [SpeechCommand.text] as utterance [SpeechCommand.utterance],
  /// replacing whatever is being said without reporting a cancel for it.
  deviceSpeak,
  devicePause,
  deviceResume,

  /// Stop speaking; the utterance reports `cancel`.
  deviceStop,

  /// Replace the queue with [SpeechCommand.clips], at
  /// [SpeechCommand.index] and [SpeechCommand.positionMs].
  playerSet,

  /// Append [SpeechCommand.clips] without interrupting.
  playerAdd,
  playerClear,
  playerPlay,
  playerPause,
  playerStop,

  /// Move to [SpeechCommand.positionMs] in clip [SpeechCommand.index] (the
  /// current one when null).
  playerSeek,

  /// Play at [SpeechCommand.speed] (1 is normal).
  playerSpeed,

  /// The length of clip [SpeechCommand.clips]' first, without playing it:
  /// answered with [SpeechReport.durationMs].
  playerDuration,
}

/// Payload of `speech.command`: the daemon runs the reading, the window
/// speaks and plays it. Answered with `speech.report` naming [id].
@freezed
abstract class SpeechCommand with _$SpeechCommand {
  const factory SpeechCommand({
    required int id,
    required SpeechCommandKind kind,
    String? text,

    /// An installed voice's identifier, or null for the system's.
    String? voice,

    /// AVSpeech's rate (0.5 is the voice's own pace), pitch and volume.
    double? rate,
    double? pitch,
    double? volume,

    /// The utterance [text] is: events report it, so a replaced one's
    /// late events are told apart.
    @Default(0) int utterance,

    /// Clips, as paths the window fetches from the daemon (`/tts/{job}`).
    @Default(<String>[]) List<String> clips,
    int? index,
    int? positionMs,
    double? speed,
  }) = _SpeechCommand;

  factory SpeechCommand.fromJson(Map<String, dynamic> json) =>
      _$SpeechCommandFromJson(json);
}

/// What a [SpeechReport] tells, besides answering a command.
enum SpeechReportKind {
  /// The Mac's voice: started, said a word ([SpeechReport.start] to
  /// [SpeechReport.end]), finished, was cancelled, paused, continued, or
  /// failed.
  start,
  progress,
  complete,
  cancel,
  pause,
  resume,
  failed,

  /// The player: playing or not, how ready, which clip and where.
  player,
}

/// How ready the window's player is: core's `AudioProcessingState`.
enum SpeechPlayerState { idle, loading, buffering, ready, completed }

/// An installed voice, for `deviceVoices`.
@freezed
abstract class SpeechVoice with _$SpeechVoice {
  const factory SpeechVoice({
    required String id,
    @Default('') String name,
    @Default('') String language,
  }) = _SpeechVoice;

  factory SpeechVoice.fromJson(Map<String, dynamic> json) =>
      _$SpeechVoiceFromJson(json);
}

/// Params for `speech.report`: a command's answer ([id]) and/or what the
/// engine did ([kind]).
@freezed
abstract class SpeechReport with _$SpeechReport {
  const factory SpeechReport({
    /// The command answered, if any.
    int? id,

    /// Whether the command was carried out; [error] says why not.
    @Default(true) bool ok,
    String? error,

    /// A yes/no answer (`deviceAvailable`, `deviceSpeak`).
    bool? value,
    int? durationMs,
    @Default(<SpeechVoice>[]) List<SpeechVoice> voices,

    /// What happened, when it reports an event.
    SpeechReportKind? kind,
    @Default(0) int utterance,
    int? start,
    int? end,
    @Default(false) bool playing,
    SpeechPlayerState? state,
    int? index,
    int? positionMs,
  }) = _SpeechReport;

  factory SpeechReport.fromJson(Map<String, dynamic> json) =>
      _$SpeechReportFromJson(json);
}
