import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';

import 'settled.dart';

/// `voice.*`, `POST /transcribe` and `GET /tts/{jobId}` (M8).
///
/// The window records and plays; this is where the server is asked. A
/// recording comes in as bytes and leaves as the server's transcription; a
/// speech job is text the window names by id, so an `<audio>` element can
/// fetch it with no credential of its own.
final class VoiceService {
  VoiceService(this._container);

  final ProviderContainer _container;
  final Random _random = Random.secure();

  /// Speech jobs by id, oldest first. Kept after they are played, so the
  /// element can seek or replay without asking the server again, and
  /// bounded so a long call does not keep every sentence.
  final LinkedHashMap<String, _SpeechJob> _jobs =
      LinkedHashMap<String, _SpeechJob>();
  static const int _maxJobs = 64;

  /// Whether [config]'s server transcribes. Open WebUI's STT engine `""`
  /// is its own Whisper, so an unnamed engine is a yes; `web` means the
  /// admin wants the browser to do it, which a desktop window cannot.
  static bool transcribes(BackendConfig config) =>
      config.enableAudioInput ?? (config.sttProvider?.trim() != 'web');

  /// Whether [config]'s server speaks. Its TTS engine `""` is the
  /// browser's voices, so only a named engine other than `web` is a yes.
  static bool speaks(BackendConfig config) =>
      switch (config.ttsProvider?.trim()) {
        null || '' || 'web' => false,
        _ => true,
      };

  AppSettingsNotifier get _notifier =>
      _container.read(appSettingsProvider.notifier);

  Future<BackendConfig?> _config() async {
    final api = _container.read(apiServiceProvider);
    if (api == null) return null;
    try {
      final cached = await readSettled(
        _container,
        backendConfigProvider.future,
      );
      if (cached != null && cached.serverId == api.serverConfig.id) {
        return cached;
      }
      // The provider answers from a cache and refreshes behind it, and
      // straight after signing in it has neither. Ask the server itself.
      return await api.getBackendConfig();
    } on Object {
      // No server, or it will not say: then it offers no voice features.
      return null;
    }
  }

  Future<VoiceSettings> settings() async {
    final config = await _config();
    final stored = _container.read(appSettingsProvider);
    return VoiceSettings(
      serverStt: config != null && transcribes(config),
      serverTts: config != null && speaks(config),
      sttLanguage: stored.sttLanguageCode,
      silenceMs: stored.voiceSilenceDuration,
      holdToTalk: stored.voiceHoldToTalk,
      autoSend: stored.voiceAutoSendFinal,
      bargeIn: stored.voiceBargeInEnabled,
      ttsEngine: stored.ttsEngine.name,
      deviceVoice: stored.ttsVoice,
      serverVoice: stored.ttsServerVoiceId,
      rate: stored.ttsSpeechRate,
      pitch: stored.ttsPitch,
      volume: stored.ttsVolume,
      splitOn: switch (config?.ttsSplitOn?.trim()) {
        'paragraphs' => 'paragraphs',
        'none' => 'none',
        _ => 'punctuation',
      },
    );
  }

  Future<VoiceSettings> save(VoiceSettingsEdit edit) async {
    final notifier = _notifier;
    if (edit.clearSttLanguage) {
      await notifier.setSttLanguageCode(null);
    } else if (edit.sttLanguage case final language?) {
      await notifier.setSttLanguageCode(language);
    }
    if (edit.silenceMs case final ms?) {
      await notifier.setVoiceSilenceDuration(
        ms.clamp(
          SettingsService.minVoiceSilenceDurationMs,
          SettingsService.maxVoiceSilenceDurationMs,
        ),
      );
    }
    if (edit.holdToTalk case final value?) {
      await notifier.setVoiceHoldToTalk(value);
    }
    if (edit.autoSend case final value?) {
      await notifier.setVoiceAutoSendFinal(value);
    }
    if (edit.bargeIn case final value?) {
      await notifier.setVoiceBargeInEnabled(value);
    }
    if (edit.ttsEngine case final engine?) {
      await notifier.setTtsEngine(switch (engine) {
        'server' => TtsEngine.server,
        'device' => TtsEngine.device,
        _ => throw RpcError(
          code: ConduitErrorCodes.invalidParams,
          debugMessage: 'no engine "$engine"',
        ),
      });
    }
    if (edit.clearDeviceVoice) {
      await notifier.setTtsDeviceVoiceSelection(null, null);
    } else if (edit.deviceVoice case final voice?) {
      await notifier.setTtsDeviceVoiceSelection(voice, voice);
    }
    if (edit.clearServerVoice) {
      await notifier.setTtsServerVoiceSelection(null, null);
    } else if (edit.serverVoice case final voice?) {
      await notifier.setTtsServerVoiceSelection(voice, voice);
    }
    if (edit.rate case final rate?) {
      await notifier.setTtsSpeechRate(rate.clamp(0.1, 1.0).toDouble());
    }
    if (edit.pitch case final pitch?) {
      await notifier.setTtsPitch(pitch.clamp(0.5, 2.0).toDouble());
    }
    if (edit.volume case final volume?) {
      await notifier.setTtsVolume(volume.clamp(0.0, 1.0).toDouble());
    }
    return settings();
  }

  Future<VoiceVoices> voices() async {
    final config = await _config();
    if (config == null) return const VoiceVoices();
    return VoiceVoices(
      voices: <VoiceOption>[
        for (final voice in config.ttsVoices)
          VoiceOption(id: voice.id, name: voice.name),
      ],
      defaultVoice: config.ttsVoice,
    );
  }

  /// Makes a job for [request]; the audio is asked for when it is played.
  Future<VoiceSpeech> speak(VoiceSpeak request) async {
    final text = request.text.trim();
    if (text.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'nothing to say',
      );
    }
    _api();
    final voice = switch (request.voice?.trim()) {
      final String chosen when chosen.isNotEmpty => chosen,
      _ =>
        _container.read(appSettingsProvider).ttsServerVoiceId ??
            (await _config())?.ttsVoice,
    };
    final id =
        'tts-${_random.nextInt(1 << 32).toRadixString(16)}'
        '${_random.nextInt(1 << 32).toRadixString(16)}';
    _jobs[id] = _SpeechJob(text, voice);
    while (_jobs.length > _maxJobs) {
      _jobs.remove(_jobs.keys.first);
    }
    return VoiceSpeech(jobId: id);
  }

  /// The audio for job [id], generated on first request.
  Future<({Uint8List bytes, String contentType})> audio(String id) async {
    final job = _jobs[id];
    if (job == null) {
      throw const RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'no such speech job',
      );
    }
    final api = _api();
    try {
      final result = await (job.audio ??= api.generateSpeech(
        text: job.text,
        voice: job.voice,
      ));
      return (bytes: result.bytes, contentType: result.mimeType);
    } on DioException catch (error) {
      // A failure is not kept: playing it again asks again.
      job.audio = null;
      throw _fromDio(error);
    } on Object {
      job.audio = null;
      rethrow;
    }
  }

  /// The server's transcription of [bytes], in the saved language.
  Future<VoiceTranscript> transcribe(
    Uint8List bytes, {
    String? contentType,
  }) async {
    if (bytes.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'an empty recording',
      );
    }
    final api = _api();
    final type = (contentType ?? 'audio/webm').split(';').first.trim();
    try {
      final result = await api.transcribeSpeech(
        audioBytes: bytes,
        fileName: 'dictation.${_extensionFor(type)}',
        mimeType: type,
        language: _container.read(appSettingsProvider).sttLanguageCode,
      );
      final text = result['text'];
      return VoiceTranscript(text: text is String ? text.trim() : '');
    } on DioException catch (error) {
      throw _fromDio(error);
    }
  }

  ApiService _api() {
    final api = _container.read(apiServiceProvider);
    if (api == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'voice goes through a server; sign in first',
      );
    }
    return api;
  }

  static String _extensionFor(String type) => switch (type) {
    'audio/ogg' => 'ogg',
    'audio/wav' || 'audio/x-wav' || 'audio/wave' => 'wav',
    'audio/mp4' || 'audio/m4a' || 'audio/x-m4a' => 'm4a',
    'audio/mpeg' || 'audio/mp3' => 'mp3',
    _ => 'webm',
  };

  static RpcError _fromDio(DioException error) {
    final status = error.response?.statusCode;
    return switch (status) {
      401 => const RpcError(code: ConduitErrorCodes.sessionExpired),
      403 => const RpcError(code: ConduitErrorCodes.unauthorized),
      _ => RpcError(
        code: status == null
            ? ConduitErrorCodes.connectionFailed
            : ConduitErrorCodes.serverError,
        args: <String, String>{'status': '${status ?? ''}'},
        debugMessage: error.message,
        retryable: true,
      ),
    };
  }
}

final class _SpeechJob {
  _SpeechJob(this.text, this.voice);

  final String text;
  final String? voice;
  Future<({Uint8List bytes, String mimeType})>? audio;
}
