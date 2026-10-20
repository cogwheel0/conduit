import 'package:meta/meta.dart';

import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';

/// Whether [profile] can be the Voice provider: a usable connection that
/// speaks the OpenAI-compatible API, whose audio endpoints it calls.
bool canBeVoiceProvider(DirectConnectionProfile profile) =>
    profile.isUsable && profile.adapterKey == kOpenAiCompatibleAdapterKey;

/// A Voice provider setting the user edits as text.
enum DirectVoiceProviderField {
  transcriptionModel,
  speechModel,
  speechVoice,
  realtimeModel,
  realtimeVoice,
  realtimeInstructions,
}

/// The Voice provider: one Direct connection, chosen in Audio settings, that
/// does the speaking and listening for Direct and Apple chats.
///
/// Only ids and model names live here. The connection's address, key and
/// certificates stay with its profile in secure storage.
@immutable
final class DirectVoiceProviderSettings {
  const DirectVoiceProviderSettings({
    required this.profileId,
    this.transcriptionModel,
    this.speechModel,
    this.speechVoice,
    this.realtimeModel,
    this.realtimeVoice,
    this.realtimeInstructions,
  });

  /// The Direct connection profile the requests go to.
  final String profileId;

  /// The speech-to-text model, as for `POST audio/transcriptions`.
  final String? transcriptionModel;

  /// The text-to-speech model, as for `POST audio/speech`.
  final String? speechModel;

  /// The voice [speechModel] speaks with.
  final String? speechVoice;

  /// The realtime model a realtime call talks to.
  final String? realtimeModel;

  /// The voice [realtimeModel] speaks with.
  final String? realtimeVoice;

  /// Instructions that replace Conduit's own for a realtime call, or null.
  final String? realtimeInstructions;

  /// [current] moved to [profile]. Settings that already name [profile] are
  /// kept. For OpenAI itself the models start at the ones Open WebUI defaults
  /// to; any other server's names are left for the user to fill in.
  static DirectVoiceProviderSettings forConnection(
    DirectConnectionProfile profile, {
    DirectVoiceProviderSettings? current,
  }) {
    if (current != null && current.profileId == profile.id) return current;
    if (Uri.tryParse(profile.baseUrl)?.host != 'api.openai.com') {
      return DirectVoiceProviderSettings(profileId: profile.id);
    }
    return DirectVoiceProviderSettings(
      profileId: profile.id,
      transcriptionModel: 'whisper-1',
      speechModel: 'tts-1',
      speechVoice: 'alloy',
      realtimeModel: 'gpt-realtime-2.1-mini',
      realtimeVoice: 'marin',
    );
  }

  /// A copy with [field] set to [value]; a blank value clears it.
  DirectVoiceProviderSettings withField(
    DirectVoiceProviderField field,
    String? value,
  ) {
    final trimmed = value?.trim();
    final next = trimmed == null || trimmed.isEmpty ? null : trimmed;
    return DirectVoiceProviderSettings(
      profileId: profileId,
      transcriptionModel: field == DirectVoiceProviderField.transcriptionModel
          ? next
          : transcriptionModel,
      speechModel: field == DirectVoiceProviderField.speechModel
          ? next
          : speechModel,
      speechVoice: field == DirectVoiceProviderField.speechVoice
          ? next
          : speechVoice,
      realtimeModel: field == DirectVoiceProviderField.realtimeModel
          ? next
          : realtimeModel,
      realtimeVoice: field == DirectVoiceProviderField.realtimeVoice
          ? next
          : realtimeVoice,
      realtimeInstructions:
          field == DirectVoiceProviderField.realtimeInstructions
          ? (value == null || value.trim().isEmpty ? null : value)
          : realtimeInstructions,
    );
  }

  bool get canTranscribe => _isSet(transcriptionModel);

  bool get canSynthesize => _isSet(speechModel) && _isSet(speechVoice);

  static bool _isSet(String? value) => value != null && value.trim().isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'profile_id': profileId,
    'transcription_model': ?transcriptionModel,
    'speech_model': ?speechModel,
    'speech_voice': ?speechVoice,
    'realtime_model': ?realtimeModel,
    'realtime_voice': ?realtimeVoice,
    'realtime_instructions': ?realtimeInstructions,
  };

  /// The settings stored in [json], or null when they name no connection.
  static DirectVoiceProviderSettings? fromJson(Object? json) {
    if (json is! Map) return null;
    String? read(String key) {
      final value = json[key];
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    final profileId = read('profile_id');
    if (profileId == null) return null;
    final instructions = json['realtime_instructions'];
    return DirectVoiceProviderSettings(
      profileId: profileId,
      transcriptionModel: read('transcription_model'),
      speechModel: read('speech_model'),
      speechVoice: read('speech_voice'),
      realtimeModel: read('realtime_model'),
      realtimeVoice: read('realtime_voice'),
      // Kept as typed: leading space and blank lines can be meaningful.
      realtimeInstructions:
          instructions is String && instructions.trim().isNotEmpty
          ? instructions
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DirectVoiceProviderSettings &&
      other.profileId == profileId &&
      other.transcriptionModel == transcriptionModel &&
      other.speechModel == speechModel &&
      other.speechVoice == speechVoice &&
      other.realtimeModel == realtimeModel &&
      other.realtimeVoice == realtimeVoice &&
      other.realtimeInstructions == realtimeInstructions;

  @override
  int get hashCode => Object.hash(
    profileId,
    transcriptionModel,
    speechModel,
    speechVoice,
    realtimeModel,
    realtimeVoice,
    realtimeInstructions,
  );
}
