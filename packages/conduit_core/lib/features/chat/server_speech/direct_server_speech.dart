import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/services/direct_http_client.dart';

import 'direct_voice_provider_settings.dart';
import 'server_speech.dart';
import 'transcription_response.dart';

/// Speech through the Voice provider's OpenAI-compatible audio endpoints,
/// reached with the same client, key, headers and certificates its chats use.
final class DirectServerSpeech implements ServerSpeechProvider {
  const DirectServerSpeech({
    required DirectConnectionProfile profile,
    required DirectVoiceProviderSettings settings,
    required DirectHttpClientPool clientPool,
  }) : _profile = profile,
       _settings = settings,
       _clientPool = clientPool;

  final DirectConnectionProfile _profile;
  final DirectVoiceProviderSettings _settings;
  final DirectHttpClientPool _clientPool;

  @override
  ServerSpeechSource get source => ServerSpeechSource.direct;

  @override
  bool get canTranscribe => _settings.canTranscribe;

  @override
  bool get canSynthesize => _settings.canSynthesize;

  @override
  bool get offersVoiceChoice => false;

  @override
  Future<String> transcribe(
    Uint8List audio, {
    required String fileName,
    required String mimeType,
    String? language,
  }) async {
    final model = _settings.transcriptionModel;
    if (!_settings.canTranscribe || model == null) {
      throw StateError('The Voice provider has no transcription model.');
    }
    final lease = _clientPool.acquire(_profile);
    try {
      final response = await lease.dio.post<Object?>(
        'audio/transcriptions',
        data: FormData.fromMap({
          'file': MultipartFile.fromBytes(
            audio,
            filename: fileName,
            contentType: DioMediaType.parse(mimeType),
          ),
          'model': model,
          if (language != null && language.trim().isNotEmpty)
            'language': language.trim(),
          'response_format': 'json',
        }),
      );
      final data = response.data;
      if (data is! Map) return '';
      return transcriptionResponseText(
            data.map((key, value) => MapEntry(key.toString(), value)),
          ) ??
          '';
    } finally {
      lease.release();
    }
  }

  @override
  Future<SynthesizedSpeech> synthesize(
    String text, {
    String? preferredVoice,
    double? speed,
  }) async {
    final model = _settings.speechModel;
    final voice = _settings.speechVoice;
    if (!_settings.canSynthesize || model == null || voice == null) {
      throw StateError('The Voice provider has no speech model and voice.');
    }
    final lease = _clientPool.acquire(_profile);
    try {
      final response = await lease.dio.post<List<int>>(
        'audio/speech',
        data: {
          'model': model,
          'input': text,
          'voice': voice,
          'response_format': 'mp3',
          'speed': ?speed,
        },
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Accept': 'audio/mpeg'},
        ),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        throw StateError('The Voice provider returned no audio.');
      }
      final contentType = response.headers.value(Headers.contentTypeHeader);
      return (
        bytes: Uint8List.fromList(bytes),
        mimeType: contentType != null && contentType.startsWith('audio/')
            ? contentType.split(';').first.trim()
            : 'audio/mpeg',
      );
    } finally {
      lease.release();
    }
  }
}
