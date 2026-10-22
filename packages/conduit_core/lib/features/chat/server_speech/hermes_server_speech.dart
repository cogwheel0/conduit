import 'dart:typed_data';

import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';

import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';

import 'server_speech.dart';

/// The native bot's profile; ordinary Hermes chats use the connection profile.
String? hermesVoiceProfile(Conversation? conversation) {
  if (!isNativeHermesConversation(conversation)) return null;
  final profile = conversation!.metadata['hermesBotProfile'];
  if (profile == null) return null;
  if (profile is! String || !HermesConfig.isValidDesktopProfile(profile)) {
    throw StateError('Invalid bot voice profile');
  }
  return profile;
}

/// Speech through a Hermes gateway's dashboard, with the speech-to-text and
/// text-to-speech providers configured on the gateway. The provider keys stay
/// there: only the gateway's relay routes are used.
final class HermesServerSpeech implements ServerSpeechProvider {
  const HermesServerSpeech(this._service, {this.profile});

  final String? profile;

  final HermesDesktopApiService _service;

  @override
  ServerSpeechSource get source => ServerSpeechSource.hermes;

  @override
  bool get canTranscribe => true;

  @override
  bool get canSynthesize => true;

  @override
  bool get offersVoiceChoice => false;

  @override
  Future<String> transcribe(
    Uint8List audio, {
    required String fileName,
    required String mimeType,
    String? language,
  }) => _service.transcribeAudio(audio, mimeType: mimeType, profile: profile);

  @override
  Future<SynthesizedSpeech> synthesize(
    String text, {
    String? preferredVoice,
    double? speed,
  }) => _service.speak(text, profile: profile);
}
