import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/services/api_service.dart';
import '../../../core/services/settings_service.dart';
import 'tts_manager.dart';

export 'tts_manager.dart' show TtsEvent, TtsPlaybackSession;

/// Wrapper around [TtsManager] that provides a callback-based API.
///
/// This service is used by the [TextToSpeechController] and [VoiceCallService]
/// to interact with TTS. It translates [TtsEvent]s from the manager into
/// callbacks for backward compatibility.
class TextToSpeechService {
  TextToSpeechService({ApiService? api}) {
    // Set the API service on the manager
    TtsManager.instance.setApiService(api);

    // Listen to TTS events and route to callbacks
    _eventSubscription = TtsManager.instance.events.listen(_handleEvent);
  }

  StreamSubscription<TtsEvent>? _eventSubscription;
  bool _initialized = false;

  // Callbacks
  VoidCallback? _onStart;
  VoidCallback? _onComplete;
  VoidCallback? _onCancel;
  VoidCallback? _onPause;
  VoidCallback? _onContinue;
  void Function(String message)? _onError;
  void Function(int sentenceIndex)? _onSentenceIndex;
  void Function(int start, int end)? _onDeviceWordProgress;

  /// Whether the service has been initialized.
  bool get isInitialized => _initialized;

  /// Whether TTS is available.
  bool get isAvailable => TtsManager.instance.isAvailable;

  /// Whether device TTS is available.
  bool get deviceEngineAvailable => TtsManager.instance.deviceAvailable;

  /// Whether server TTS is available.
  bool get serverEngineAvailable => TtsManager.instance.serverAvailable;

  /// Whether server TTS is preferred and available.
  bool get prefersServerEngine {
    final config = TtsManager.instance.config;
    if (config.preferServer && TtsManager.instance.serverAvailable) {
      return true;
    }
    return !TtsManager.instance.deviceAvailable &&
        TtsManager.instance.serverAvailable;
  }

  /// Registers callbacks for TTS lifecycle events.
  void bindHandlers({
    VoidCallback? onStart,
    VoidCallback? onComplete,
    VoidCallback? onCancel,
    VoidCallback? onPause,
    VoidCallback? onContinue,
    void Function(String message)? onError,
    void Function(int sentenceIndex)? onSentenceIndex,
    void Function(int start, int end)? onDeviceWordProgress,
  }) {
    _onStart = onStart;
    _onComplete = onComplete;
    _onCancel = onCancel;
    _onPause = onPause;
    _onContinue = onContinue;
    _onError = onError;
    _onSentenceIndex = onSentenceIndex;
    _onDeviceWordProgress = onDeviceWordProgress;
  }

  /// Initializes the TTS engine.
  Future<bool> initialize({
    String? deviceVoice,
    String? serverVoice,
    double speechRate = 0.5,
    double pitch = 1.0,
    double volume = 1.0,
    TtsEngine engine = TtsEngine.device,
  }) async {
    if (_initialized) {
      // Update config if already initialized
      await TtsManager.instance.updateConfig(
        TtsConfig(
          voice: deviceVoice,
          serverVoice: serverVoice,
          speechRate: speechRate,
          pitch: pitch,
          volume: volume,
          preferServer: engine == TtsEngine.server,
        ),
      );
      return isAvailable;
    }

    final available = await TtsManager.instance.initialize(
      config: TtsConfig(
        voice: deviceVoice,
        serverVoice: serverVoice,
        speechRate: speechRate,
        pitch: pitch,
        volume: volume,
        preferServer: engine == TtsEngine.server,
      ),
    );

    _initialized = true;
    return available;
  }

  /// Speaks the given text.
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) {
      throw ArgumentError('Cannot speak empty text');
    }

    if (!_initialized) {
      await initialize();
    }

    await TtsManager.instance.speak(text);
  }

  /// Pauses the current playback.
  Future<void> pause() async {
    await TtsManager.instance.pause();
  }

  /// Resumes paused playback.
  Future<void> resume() async {
    await TtsManager.instance.resume();
  }

  /// Stops the current playback.
  Future<void> stop() async {
    await TtsManager.instance.stop();
  }

  /// Disposes the service.
  Future<void> dispose() async {
    await _eventSubscription?.cancel();
    _eventSubscription = null;

    // Reset the singleton state for next session
    await TtsManager.instance.reset();
  }

  /// Updates TTS settings.
  Future<void> updateSettings({
    Object? voice = const _NotProvided(),
    Object? serverVoice = const _NotProvided(),
    double? speechRate,
    double? pitch,
    double? volume,
    TtsEngine? engine,
  }) async {
    final current = TtsManager.instance.config;

    await TtsManager.instance.updateConfig(
      TtsConfig(
        voice: voice is _NotProvided ? current.voice : voice as String?,
        serverVoice: serverVoice is _NotProvided
            ? current.serverVoice
            : serverVoice as String?,
        speechRate: speechRate ?? current.speechRate,
        pitch: pitch ?? current.pitch,
        volume: volume ?? current.volume,
        preferServer: engine != null
            ? engine == TtsEngine.server
            : current.preferServer,
      ),
    );
  }

  /// Gets available voices from the device TTS engine.
  Future<List<Map<String, dynamic>>> getAvailableVoices() async {
    if (!_initialized) {
      await initialize();
    }

    final config = TtsManager.instance.config;
    if (config.preferServer && TtsManager.instance.serverAvailable) {
      return TtsManager.instance.getServerVoices();
    }

    return TtsManager.instance.getDeviceVoices();
  }

  /// Splits text into chunks for TTS playback.
  List<String> splitTextForSpeech(String text) {
    return TtsManager.instance.splitTextForSpeech(text);
  }

  /// Preloads server default voice configuration.
  Future<void> preloadServerDefaults() async {
    await TtsManager.instance.preloadServerDefaults();
  }

  /// Synthesizes a single chunk of text to audio (server TTS only).
  Future<SpeechAudioChunk> synthesizeServerSpeechChunk(String text) async {
    final result = await TtsManager.instance.synthesizeChunk(text);
    return SpeechAudioChunk(bytes: result.bytes, mimeType: result.mimeType);
  }

  void _handleEvent(TtsEvent event) {
    switch (event) {
      case TtsStarted():
        _onStart?.call();
      case TtsChunkStarted(:final chunkIndex):
        _onSentenceIndex?.call(chunkIndex);
      case TtsWordProgress(:final start, :final end):
        _onDeviceWordProgress?.call(start, end);
      case TtsCompleted():
        _onComplete?.call();
      case TtsCancelled():
        _onCancel?.call();
      case TtsPaused():
        _onPause?.call();
      case TtsResumed():
        _onContinue?.call();
      case TtsError(:final message):
        _onError?.call(message);
    }
  }
}

/// Marker class to distinguish "not provided" from null.
class _NotProvided {
  const _NotProvided();
}

/// Audio chunk for server TTS synthesis.
class SpeechAudioChunk {
  const SpeechAudioChunk({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;
}
