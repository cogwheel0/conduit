import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/app_providers.dart';
import '../../../../core/services/settings_service.dart';
import '../../services/text_to_speech_service.dart';
import '../domain/voice_call_interfaces.dart';

/// Adapter that exposes [TextToSpeechService] through [VoiceOutputEngine].
class VoiceOutputEngineTts implements VoiceOutputEngine {
  VoiceOutputEngineTts(this._service);

  final TextToSpeechService _service;

  @override
  bool get prefersServerEngine => _service.prefersServerEngine;

  @override
  void bindHandlers({
    void Function()? onStart,
    void Function()? onComplete,
    void Function(String error)? onError,
  }) {
    _service.bindHandlers(
      onStart: onStart,
      onComplete: onComplete,
      onError: onError,
    );
  }

  @override
  Future<void> initializeWithSettings(AppSettings settings) {
    return _service.initialize(
      deviceVoice: settings.ttsVoice,
      serverVoice: settings.ttsServerVoiceId,
      speechRate: settings.ttsSpeechRate,
      pitch: settings.ttsPitch,
      volume: settings.ttsVolume,
      engine: settings.ttsEngine,
    );
  }

  @override
  Future<void> updateSettings(AppSettings settings) {
    return _service.updateSettings(
      voice: settings.ttsVoice,
      serverVoice: settings.ttsServerVoiceId,
      speechRate: settings.ttsSpeechRate,
      pitch: settings.ttsPitch,
      volume: settings.ttsVolume,
      engine: settings.ttsEngine,
    );
  }

  @override
  Future<void> preloadServerDefaults() => _service.preloadServerDefaults();

  @override
  List<String> splitTextForSpeech(String text) =>
      _service.splitTextForSpeech(text);

  @override
  Future<void> speak(String text) => _service.speak(text);

  @override
  Future<SpeechAudioChunk> synthesizeServerSpeechChunk(String text) {
    return _service.synthesizeServerSpeechChunk(text);
  }

  @override
  Future<void> stop() => _service.stop();

  @override
  Future<void> dispose() => _service.dispose();
}

final voiceOutputEngineProvider = Provider<VoiceOutputEngine>((ref) {
  final api = ref.watch(apiServiceProvider);
  final service = TextToSpeechService(api: api);
  return VoiceOutputEngineTts(service);
});
