import 'package:freezed_annotation/freezed_annotation.dart';

part 'dictation.freezed.dart';
part 'dictation.g.dart';

/// Params for `dictation.status`: what dictation is for. The model names
/// the backend that transcribes on the server: an Open WebUI server for its
/// models, the Voice Provider for Direct and Apple models, a Hermes
/// gateway for Hermes, a LibreChat server for its own.
@freezed
abstract class DictationTarget with _$DictationTarget {
  const factory DictationTarget({
    /// The chat's model, or null for the account's default.
    String? modelId,
  }) = _DictationTarget;

  factory DictationTarget.fromJson(Map<String, dynamic> json) =>
      _$DictationTargetFromJson(json);
}

/// Reply to `dictation.status`: which engine dictation uses now, and what
/// each one can do. The window records; the daemon only transcribes.
@freezed
abstract class DictationStatus with _$DictationStatus {
  const factory DictationStatus({
    /// `device` (this computer's own speech recognition), `server`, or
    /// `local` (whisper on this computer): Settings › Audio's choice.
    @Default('device') String engine,

    /// Whether the target's backend transcribes speech.
    @Default(false) bool serverAvailable,

    /// Which backend that is: `openWebUi`, `hermes`, `direct` or
    /// `libreChat`; null when there is none.
    String? serverSource,

    /// Whether this build can run whisper (it has the library).
    @Default(false) bool localAvailable,

    /// Whether whisper can transcribe now: the library, and the chosen
    /// model downloaded.
    @Default(false) bool localReady,

    /// The whisper model chosen, by id (`base.en`).
    String? localModel,

    /// The transcription language (`de`, `pt-BR`), or null for automatic.
    String? language,

    /// How long a pause ends dictation, in milliseconds.
    @Default(2000) int silenceMs,
  }) = _DictationStatus;

  factory DictationStatus.fromJson(Map<String, dynamic> json) =>
      _$DictationStatusFromJson(json);
}
