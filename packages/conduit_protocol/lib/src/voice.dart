import 'package:freezed_annotation/freezed_annotation.dart';

part 'voice.freezed.dart';
part 'voice.g.dart';

/// Dictation, read aloud and call mode settings (M8), with what the active
/// server can do. The same stored preferences the phone app keeps.
@freezed
abstract class VoiceSettings with _$VoiceSettings {
  const factory VoiceSettings({
    /// Whether the active server transcribes speech.
    @Default(false) bool serverStt,

    /// Whether this build can transcribe on this computer (M11): it has the
    /// whisper library. A model must be downloaded too; see [localReady].
    @Default(false) bool localStt,

    /// `server`, or `local` for whisper on this computer.
    @Default('server') String sttEngine,

    /// The whisper model chosen for `local`, by id (`base.en`).
    String? localModel,

    /// Whether `local` can transcribe now: the library, and the chosen
    /// model downloaded.
    @Default(false) bool localReady,

    /// Whether the active server speaks text.
    @Default(false) bool serverTts,

    /// The language the server transcribes, or null to let it guess.
    String? sttLanguage,

    /// How long a pause ends dictation, in milliseconds.
    @Default(2000) int silenceMs,
    @Default(false) bool holdToTalk,

    /// Sends what was dictated as soon as it is transcribed.
    @Default(false) bool autoSend,

    /// Speaking over the assistant in a call interrupts it.
    @Default(false) bool bargeIn,

    /// `device` (the system's voices) or `server`.
    @Default('device') String ttsEngine,

    /// The system voice's name, or null for the default.
    String? deviceVoice,

    /// The server voice's id, or null for the server's default.
    String? serverVoice,

    /// The phone app's scale: 0.5 is normal speed.
    @Default(0.5) double rate,
    @Default(1.0) double pitch,
    @Default(1.0) double volume,

    /// Open WebUI's `TTS_SPLIT_ON`: `punctuation`, `paragraphs` or `none`.
    @Default('punctuation') String splitOn,
  }) = _VoiceSettings;

  factory VoiceSettings.fromJson(Map<String, dynamic> json) =>
      _$VoiceSettingsFromJson(json);
}

/// Params for `voice.saveSettings`: null leaves a field alone, and the
/// `clear*` flags choose a default where null cannot.
@freezed
abstract class VoiceSettingsEdit with _$VoiceSettingsEdit {
  const factory VoiceSettingsEdit({
    String? sttEngine,
    String? localModel,
    String? sttLanguage,
    @Default(false) bool clearSttLanguage,
    int? silenceMs,
    bool? holdToTalk,
    bool? autoSend,
    bool? bargeIn,
    String? ttsEngine,
    String? deviceVoice,
    @Default(false) bool clearDeviceVoice,
    String? serverVoice,
    @Default(false) bool clearServerVoice,
    double? rate,
    double? pitch,
    double? volume,
  }) = _VoiceSettingsEdit;

  factory VoiceSettingsEdit.fromJson(Map<String, dynamic> json) =>
      _$VoiceSettingsEditFromJson(json);
}

@freezed
abstract class VoiceOption with _$VoiceOption {
  const factory VoiceOption({required String id, @Default('') String name}) =
      _VoiceOption;

  factory VoiceOption.fromJson(Map<String, dynamic> json) =>
      _$VoiceOptionFromJson(json);
}

/// Reply to `voice.voices`: the server's voices and its default.
@freezed
abstract class VoiceVoices with _$VoiceVoices {
  const factory VoiceVoices({
    @Default(<VoiceOption>[]) List<VoiceOption> voices,
    String? defaultVoice,
  }) = _VoiceVoices;

  factory VoiceVoices.fromJson(Map<String, dynamic> json) =>
      _$VoiceVoicesFromJson(json);
}

/// Params for `voice.speak`: text for the server to say. The voice is the
/// saved one unless given.
@freezed
abstract class VoiceSpeak with _$VoiceSpeak {
  const factory VoiceSpeak({required String text, String? voice}) = _VoiceSpeak;

  factory VoiceSpeak.fromJson(Map<String, dynamic> json) =>
      _$VoiceSpeakFromJson(json);
}

/// Reply to `voice.speak`: the job whose audio `GET /tts/{jobId}` plays.
@freezed
abstract class VoiceSpeech with _$VoiceSpeech {
  const factory VoiceSpeech({required String jobId}) = _VoiceSpeech;

  factory VoiceSpeech.fromJson(Map<String, dynamic> json) =>
      _$VoiceSpeechFromJson(json);
}

/// Reply to `POST /transcribe`.
@freezed
abstract class VoiceTranscript with _$VoiceTranscript {
  const factory VoiceTranscript({@Default('') String text}) = _VoiceTranscript;

  factory VoiceTranscript.fromJson(Map<String, dynamic> json) =>
      _$VoiceTranscriptFromJson(json);
}

/// A whisper model for transcribing on this computer (M11).
@freezed
abstract class VoiceModel with _$VoiceModel {
  const factory VoiceModel({
    required String id,
    @Default('') String name,
    @Default(0) int sizeBytes,

    /// Hears only English, and hears it better for its size.
    @Default(false) bool englishOnly,
    @Default(false) bool downloaded,

    /// Bytes received, while downloading.
    int? receivedBytes,
  }) = _VoiceModel;

  factory VoiceModel.fromJson(Map<String, dynamic> json) =>
      _$VoiceModelFromJson(json);
}

/// Reply to `voice.models`, and the payload of `voice.changed`.
@freezed
abstract class VoiceModels with _$VoiceModels {
  const factory VoiceModels({
    @Default(<VoiceModel>[]) List<VoiceModel> models,

    /// The last download that failed, by id, and why (`checksum`,
    /// `network`).
    String? failedId,
    String? failure,
  }) = _VoiceModels;

  factory VoiceModels.fromJson(Map<String, dynamic> json) =>
      _$VoiceModelsFromJson(json);
}

/// Params for `voice.downloadModel` and `voice.deleteModel`.
@freezed
abstract class VoiceModelRef with _$VoiceModelRef {
  const factory VoiceModelRef({required String id}) = _VoiceModelRef;

  factory VoiceModelRef.fromJson(Map<String, dynamic> json) =>
      _$VoiceModelRefFromJson(json);
}
