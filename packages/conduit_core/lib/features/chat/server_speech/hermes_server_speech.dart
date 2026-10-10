import 'dart:typed_data';

import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';

import 'server_speech.dart';

/// Speech through a Hermes gateway's dashboard, with the speech-to-text and
/// text-to-speech providers configured on the gateway. The provider keys stay
/// there: only the gateway's relay routes are used.
final class HermesServerSpeech implements ServerSpeechProvider {
  const HermesServerSpeech(this._service);

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
  }) => _service.transcribeAudio(audio, mimeType: mimeType);

  @override
  Future<SynthesizedSpeech> synthesize(
    String text, {
    String? preferredVoice,
    double? speed,
  }) => _service.speak(text);
}
