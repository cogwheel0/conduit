import 'package:freezed_annotation/freezed_annotation.dart';

part 'calls.freezed.dart';
part 'calls.g.dart';

/// Where a voice call is: the phone's `ChatVoiceModePhase`.
enum CallPhase {
  idle,
  starting,
  listening,

  /// The user's words went to the chat; the answer is on its way.
  sending,
  speaking,
  paused,
  muted,
  ending,
  ended,
  error,
}

/// How a call runs: turn by turn (`standard`: listen, send, speak the
/// answer), or with a realtime voice that hears and speaks as the call goes.
enum CallMode { standard, realtime }

/// Why a call shows an error: the phone's `ChatVoiceModeError`. Only
/// [message] carries text meant for the user ([CallState.error]); the window
/// says the others in its own words.
enum CallErrorKind {
  microphoneDenied,
  inputUnavailable,
  timeout,
  noSpeech,
  message,
  other,
}

/// Something worth telling the user mid-call that does not end it: the
/// phone's `ChatVoiceModeNotice`.
enum CallNotice { transcriptionFailed, replyIncomplete, transcriptNotSaved }

/// Why a call is Standard although Settings › Audio chose Realtime: the
/// core's `RealtimeCallBlock`, or `noAudio` when the window has no realtime
/// audio.
enum CallStandardReason {
  standardChosen,
  temporaryChat,
  unsupportedBackend,
  voiceProviderIncomplete,
  serverRealtimeOff,
  callNotPermitted,
  noSessionToken,
  hermesVoiceLiveOff,
  noAudio,
}

/// Why core refused to start a call (the core's `VoiceCallRefusal`), so
/// the window words it in its own language; [CallState.error] keeps the
/// English the phone shows.
enum CallRefusal {
  modelRequired,
  hermesLoading,
  hermesUnavailable,
  directUnavailable,
  signInRequired,

  /// The model's backend has no voice calls (LibreChat).
  backendUnsupported,
}

/// The call now: what `calls.changed` carries and every `calls.*` answers.
/// There is at most one call at a time, app-wide.
@freezed
abstract class CallState with _$CallState {
  const factory CallState({
    @Default(CallPhase.idle) CallPhase phase,

    /// Each call's own number; 0 before the first.
    @Default(0) int call,
    CallMode? mode,

    /// The call's chat. Null for a call that started a new chat until its
    /// first turn has given the chat an id.
    String? chatId,
    String? modelId,
    String? modelName,

    /// What the user is saying, or said last.
    @Default('') String transcript,

    /// What is being said: the sentence of the chat's answer the Mac says
    /// now in a Standard call (the answer so far before it speaks), the
    /// voice's caption in a realtime one.
    @Default('') String reply,

    /// The meter, 0 to 1: the microphone while listening, the voice while
    /// it speaks (realtime).
    @Default(0.0) double level,
    @Default(false) bool muted,
    @Default(false) bool canPause,
    @Default(false) bool canResume,

    /// When the call started, in milliseconds since the epoch.
    int? startedAtMs,
    CallErrorKind? errorKind,

    /// The error's text: for the user when [errorKind] is `message`, else
    /// only for the log.
    String? error,

    /// The latest notice; [noticeCount] grows with each, so the same
    /// notice twice is shown twice.
    CallNotice? notice,
    @Default(0) int noticeCount,

    /// Why a call that could have been realtime runs Standard.
    CallStandardReason? standardReason,

    /// With [errorKind] `message`: why core would not start the call, when
    /// that is the error ([error] is its English).
    CallRefusal? refusal,
  }) = _CallState;

  factory CallState.fromJson(Map<String, dynamic> json) =>
      _$CallStateFromJson(json);
}

/// Params for `calls.start`: a call in chat [chatId], or in a new chat
/// (with [model], in [folderId], [temporary] as the new chat would be).
@freezed
abstract class CallStart with _$CallStart {
  const factory CallStart({
    String? chatId,

    /// The model a new chat's call talks to; the chat's own otherwise.
    String? model,
    String? folderId,
    @Default(false) bool temporary,
  }) = _CallStart;

  factory CallStart.fromJson(Map<String, dynamic> json) =>
      _$CallStartFromJson(json);
}

/// What `calls.command` asks the window to do for the call.
enum CallCommandKind {
  /// Whether the microphone may be used (asking the user if never asked):
  /// answered with [CallReport.value].
  permission,

  /// Listen as dictation does (Settings › Audio's engine and pause), for
  /// listen [CallCommand.listen], reporting words, the meter and the end.
  /// [CallCommand.continuous]: after each pause, listen again until
  /// stopped, so the user can talk over the answer (barge-in).
  listen,

  /// Stop listen [CallCommand.listen] and drop what it heard.
  stopListen,

  /// Open the realtime audio: the microphone and the speaker on one
  /// echo-cancelled engine, over `WS` [CallCommand.path]. Answered once
  /// the audio runs, or with why it cannot.
  audioStart,

  /// Close the realtime audio, or the WebRTC peer, at [CallCommand.path].
  audioStop,

  /// Open the realtime voice's WebRTC peer (Hermes GPT-Live): the
  /// microphone with echo cancellation, the voice played, and a data channel
  /// for the voice's events, driven over `WS` [CallCommand.path]. Answered
  /// once the peer is ready to make its offer, or with why it cannot.
  webRtcStart,
}

/// Payload of `calls.command`. Answered with `calls.report` naming [id].
@freezed
abstract class CallCommand with _$CallCommand {
  const factory CallCommand({
    required int id,
    required CallCommandKind kind,

    /// The listen this is about: its reports name it, so a stopped one's
    /// late reports are told apart.
    @Default(0) int listen,
    @Default(false) bool continuous,

    /// The model whose backend transcribes (server speech).
    String? modelId,

    /// The realtime audio's (or WebRTC peer's) WebSocket path on the daemon.
    String? path,
  }) = _CallCommand;

  factory CallCommand.fromJson(Map<String, dynamic> json) =>
      _$CallCommandFromJson(json);
}

/// What a [CallReport] tells, besides answering a command.
enum CallReportKind {
  /// The words so far ([CallReport.text]); [CallReport.done]: the last of
  /// one utterance.
  words,

  /// The meter, [CallReport.level] 0 to 1.
  level,

  /// The listen ended (nothing more comes for it).
  ended,

  /// The listen could not go on: [CallReport.failure].
  failed,
}

/// Why a listen failed, as the window's dictation says it.
enum CallListenFailure {
  microphoneDenied,
  speechDenied,
  notOnThisMac,
  serverUnavailable,
  whisperNeedsModel,
  transcriptionFailed,
}

/// Params for `calls.report`: a command's answer ([id]) and/or what a
/// listen did ([kind]).
@freezed
abstract class CallReport with _$CallReport {
  const factory CallReport({
    /// The command answered, if any.
    int? id,
    @Default(true) bool ok,
    String? error,
    bool? value,
    CallReportKind? kind,
    @Default(0) int listen,
    String? text,
    @Default(false) bool done,
    double? level,
    CallListenFailure? failure,
  }) = _CallReport;

  factory CallReport.fromJson(Map<String, dynamic> json) =>
      _$CallReportFromJson(json);
}
