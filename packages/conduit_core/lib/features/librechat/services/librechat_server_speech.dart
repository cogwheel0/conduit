import 'dart:typed_data';

import 'package:conduit_core/features/chat/server_speech/server_speech.dart';
import 'package:conduit_core/features/librechat/services/librechat_api_service.dart';

/// Speech through a LibreChat server's speech routes, with the engines its
/// admin configured (`speech.stt` / `speech.tts` in librechat.yaml).
final class LibreChatServerSpeech implements ServerSpeechProvider {
  const LibreChatServerSpeech(
    this._api, {
    required this.canTranscribe,
    required this.canSynthesize,
    this.offersVoiceChoice = false,
  });

  /// Reads which engines the server has from its speech config.
  static Future<LibreChatServerSpeech> forServer(
    LibreChatApiService api,
  ) async {
    final config = await api.speechConfig();
    return LibreChatServerSpeech(
      api,
      canTranscribe: config['sttExternal'] == true,
      canSynthesize: config['ttsExternal'] == true,
    );
  }

  final LibreChatApiService _api;

  @override
  ServerSpeechSource get source => ServerSpeechSource.libreChat;

  @override
  final bool canTranscribe;

  @override
  final bool canSynthesize;

  @override
  final bool offersVoiceChoice;

  @override
  Future<String> transcribe(
    Uint8List audio, {
    required String fileName,
    required String mimeType,
    String? language,
  }) => _api.transcribe(
    audio,
    filename: fileName,
    mimeType: mimeType,
    language: language,
  );

  /// LibreChat's speech route takes no speed; [speed] is ignored.
  @override
  Future<SynthesizedSpeech> synthesize(
    String text, {
    String? preferredVoice,
    double? speed,
  }) async {
    final speech = await _api.synthesize(
      text,
      voice: offersVoiceChoice ? preferredVoice : null,
    );
    // MP3 unless the server's configured engine says otherwise.
    return (bytes: speech.bytes, mimeType: speech.mimeType ?? 'audio/mpeg');
  }
}
