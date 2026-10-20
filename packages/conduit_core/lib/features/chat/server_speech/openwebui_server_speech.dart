import 'dart:typed_data';

import 'package:conduit_core/services/api_service.dart';

import 'server_speech.dart';
import 'transcription_response.dart';

/// Speech through an Open WebUI server's audio endpoints, with the engines
/// and voices its admin configured.
final class OpenWebUiServerSpeech implements ServerSpeechProvider {
  const OpenWebUiServerSpeech(this._api);

  final ApiService _api;

  @override
  ServerSpeechSource get source => ServerSpeechSource.openWebUi;

  @override
  bool get canTranscribe => true;

  @override
  bool get canSynthesize => true;

  @override
  bool get offersVoiceChoice => true;

  @override
  Future<String> transcribe(
    Uint8List audio, {
    required String fileName,
    required String mimeType,
    String? language,
  }) async {
    final response = await _api.transcribeSpeech(
      audioBytes: audio,
      fileName: fileName,
      mimeType: mimeType,
      language: language,
    );
    return transcriptionResponseText(response) ?? '';
  }

  @override
  Future<SynthesizedSpeech> synthesize(
    String text, {
    String? preferredVoice,
    double? speed,
  }) => _api.generateSpeech(text: text, voice: preferredVoice, speed: speed);
}
