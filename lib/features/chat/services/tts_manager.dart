import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/services/api_service.dart';
import '../../../shared/utils/bytes_audio_source.dart';

// =============================================================================
// TTS Events
// =============================================================================

/// Base class for all TTS events.
sealed class TtsEvent {
  const TtsEvent();
}

/// Emitted when TTS playback starts.
class TtsStarted extends TtsEvent {
  const TtsStarted();
}

/// Emitted when a new chunk starts playing.
class TtsChunkStarted extends TtsEvent {
  const TtsChunkStarted(this.chunkIndex);
  final int chunkIndex;
}

/// Emitted for word-level progress (device TTS only).
class TtsWordProgress extends TtsEvent {
  const TtsWordProgress(this.start, this.end);
  final int start;
  final int end;
}

/// Emitted when all chunks have finished playing.
class TtsCompleted extends TtsEvent {
  const TtsCompleted();
}

/// Emitted when playback is cancelled.
class TtsCancelled extends TtsEvent {
  const TtsCancelled();
}

/// Emitted when playback is paused.
class TtsPaused extends TtsEvent {
  const TtsPaused();
}

/// Emitted when playback resumes from pause.
class TtsResumed extends TtsEvent {
  const TtsResumed();
}

/// Emitted when an error occurs.
class TtsError extends TtsEvent {
  const TtsError(this.message);
  final String message;
}

// =============================================================================
// Playback Session
// =============================================================================

/// Represents a single TTS playback session.
class TtsPlaybackSession {
  TtsPlaybackSession._({
    required this.id,
    required this.chunks,
    required this.useServerTts,
  });

  /// Unique session identifier.
  final int id;

  /// Text chunks to be spoken.
  final List<String> chunks;

  /// Whether to use server TTS (true) or device TTS (false).
  final bool useServerTts;
}

// =============================================================================
// TTS Configuration
// =============================================================================

/// Configuration for TTS playback.
class TtsConfig {
  const TtsConfig({
    this.voice,
    this.serverVoice,
    this.speechRate = 0.5,
    this.pitch = 1.0,
    this.volume = 1.0,
    this.preferServer = false,
  });

  final String? voice;
  final String? serverVoice;
  final double speechRate;
  final double pitch;
  final double volume;
  final bool preferServer;

  TtsConfig copyWith({
    String? voice,
    String? serverVoice,
    double? speechRate,
    double? pitch,
    double? volume,
    bool? preferServer,
  }) {
    return TtsConfig(
      voice: voice ?? this.voice,
      serverVoice: serverVoice ?? this.serverVoice,
      speechRate: speechRate ?? this.speechRate,
      pitch: pitch ?? this.pitch,
      volume: volume ?? this.volume,
      preferServer: preferServer ?? this.preferServer,
    );
  }
}

// =============================================================================
// TTS Manager
// =============================================================================

/// Single global manager for all TTS operations.
///
/// This manager owns the FlutterTts and AudioPlayer instances and ensures
/// only one playback session is active at a time. Events are emitted via
/// a stream that consumers can listen to.
class TtsManager {
  TtsManager._();
  static final instance = TtsManager._();

  // FlutterTts instance (lazy initialized)
  FlutterTts? _tts;
  bool _ttsInitialized = false;
  bool _handlersSet = false;
  Completer<void>? _initCompleter;

  // AudioPlayer for server TTS (using just_audio)
  final AudioPlayer _player = AudioPlayer();
  bool _playerConfigured = false;
  StreamSubscription<PlayerState>? _playerStateSub;
  
  /// Flag to suppress spurious TtsPaused events during chunk transitions.
  /// When true, the player is actively switching audio sources and pause
  /// events should not be emitted to listeners.
  bool _isTransitioningChunks = false;

  // API service for server TTS (must be set before using server TTS)
  ApiService? _apiService;

  // Configuration
  TtsConfig _config = const TtsConfig();
  bool _deviceEngineAvailable = false;
  bool _voiceConfigured = false;

  // Session management
  int _sessionCounter = 0;
  TtsPlaybackSession? _activeSession;

  // Device TTS state
  int _currentChunkIndex = -1;

  // Server TTS state
  final List<_AudioChunk> _serverAudioBuffer = [];
  int _serverCurrentIndex = -1;
  bool _serverWaitingForNext = false;

  // Event stream
  final _eventController = StreamController<TtsEvent>.broadcast();

  // Cached server default voice
  String? _serverDefaultVoice;
  Future<String?>? _serverDefaultVoiceFuture;

  /// Stream of TTS events.
  Stream<TtsEvent> get events => _eventController.stream;

  /// Whether device TTS is available.
  bool get deviceAvailable => _deviceEngineAvailable;

  /// Whether server TTS is available.
  bool get serverAvailable => _apiService != null;

  /// Whether any TTS is available.
  bool get isAvailable => _deviceEngineAvailable || serverAvailable;

  /// Whether a session is currently active.
  bool get isPlaying => _activeSession != null;

  /// Current configuration.
  TtsConfig get config => _config;

  /// Sets the API service for server TTS.
  void setApiService(ApiService? api) {
    _apiService = api;
  }

  /// Updates the TTS configuration.
  Future<void> updateConfig(TtsConfig config) async {
    _config = config;

    if (_tts != null && _ttsInitialized) {
      await _tts!.setVolume(config.volume);
      await _tts!.setSpeechRate(config.speechRate);
      await _tts!.setPitch(config.pitch);

      if (config.voice != null) {
        await _setVoiceByName(config.voice);
      }
    }
  }

  /// Initializes the TTS engine.
  ///
  /// This must be called before any TTS operations.
  Future<bool> initialize({TtsConfig? config}) async {
    if (config != null) {
      _config = config;
    }

    // Initialize FlutterTts
    await _ensureTtsInitialized();

    // Configure AudioPlayer for all platforms (using just_audio)
    if (!_playerConfigured) {
      _playerStateSub = _player.playerStateStream.listen((state) {
        if (state.processingState == ProcessingState.completed) {
          _onServerAudioComplete();
        }
        if (state.playing) {
          // Clear transition flag when playback actually starts.
          // This ensures pause events aren't emitted during the brief window
          // between play() returning and the player entering playing state.
          _isTransitioningChunks = false;
          _emitEvent(const TtsStarted());
        } else if (!state.playing &&
                   state.processingState == ProcessingState.ready &&
                   !_isTransitioningChunks) {
          // Only emit pause when actually paused, ready, and NOT transitioning
          // between chunks. During chunk transitions, the player briefly enters
          // a ready-but-not-playing state which should not emit pause events.
          _emitEvent(const TtsPaused());
        }
      });
      _playerConfigured = true;
    }

    return isAvailable;
  }

  /// Speaks the given text.
  ///
  /// Returns the playback session. If another session is active, it will be
  /// cancelled first.
  Future<TtsPlaybackSession?> speak(String text, {bool? useServer}) async {
    if (text.trim().isEmpty) {
      return null;
    }

    // Cancel any existing session
    await stop();

    // Ensure TTS is initialized
    await _ensureTtsInitialized();

    // Determine whether to use server or device TTS
    final shouldUseServer = useServer ?? _shouldUseServer();

    // Split text into chunks
    final chunks = splitTextForSpeech(text);
    if (chunks.isEmpty) {
      return null;
    }

    // Create new session
    _sessionCounter++;
    final session = TtsPlaybackSession._(
      id: _sessionCounter,
      chunks: chunks,
      useServerTts: shouldUseServer,
    );
    _activeSession = session;

    // Start playback
    try {
      if (shouldUseServer) {
        await _startServerPlayback(session);
      } else {
        await _startDevicePlayback(session);
      }
      return session;
    } catch (e) {
      _emitEvent(TtsError(e.toString()));

      // Try fallback to device TTS if server fails
      if (shouldUseServer && _deviceEngineAvailable) {
        try {
          // Create a new session with useServerTts: false so device TTS
          // handlers emit events correctly
          final fallbackSession = TtsPlaybackSession._(
            id: session.id,
            chunks: session.chunks,
            useServerTts: false,
          );
          _activeSession = fallbackSession;
          await _startDevicePlayback(fallbackSession);
          return fallbackSession;
        } catch (e2) {
          _emitEvent(TtsError(e2.toString()));
        }
      }

      _activeSession = null;
      return null;
    }
  }

  /// Pauses the current playback.
  Future<void> pause() async {
    final session = _activeSession;
    if (session == null) return;

    try {
      if (session.useServerTts) {
        await _player.pause();
      } else {
        await _tts?.pause();
      }
    } catch (e) {
      _emitEvent(TtsError(e.toString()));
    }
  }

  /// Resumes paused playback.
  Future<void> resume() async {
    final session = _activeSession;
    if (session == null) return;

    try {
      if (session.useServerTts) {
        await _player.play();
        _emitEvent(const TtsResumed());
      } else {
        // Device TTS resume is handled by the native handler
      }
    } catch (e) {
      _emitEvent(TtsError(e.toString()));
    }
  }

  /// Stops the current playback.
  Future<void> stop() async {
    final session = _activeSession;
    if (session == null) return;

    _activeSession = null;
    _resetPlaybackState();

    try {
      if (session.useServerTts) {
        await _player.stop();
      } else {
        await _tts?.stop();
      }
      _emitEvent(const TtsCancelled());
    } catch (e) {
      _emitEvent(TtsError(e.toString()));
    }
  }

  /// Disposes the manager and releases resources.
  Future<void> dispose() async {
    await stop();
    await _playerStateSub?.cancel();
    await _player.dispose();
    await _eventController.close();
  }

  /// Splits text into chunks for TTS playback.
  ///
  /// This mirrors OpenWebUI's extractSentencesForAudio implementation.
  List<String> splitTextForSpeech(String text) {
    // 1. Preserve code blocks (replace with placeholders)
    final codeBlocks = <String>[];
    var processed = text;
    var codeBlockIndex = 0;

    final codeBlockRegex = RegExp(r'```[\s\S]*?```', multiLine: true);
    processed = processed.replaceAllMapped(codeBlockRegex, (match) {
      final placeholder = '\u0000$codeBlockIndex\u0000';
      codeBlocks.add(match.group(0)!);
      codeBlockIndex++;
      return placeholder;
    });

    // 2. Split on sentence-ending punctuation: .!?
    final sentences = processed
        .split(RegExp(r'(?<=[.!?])\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    // 3. Restore code blocks from placeholders
    final restoredSentences = sentences
        .map((sentence) {
          return sentence.replaceAllMapped(RegExp(r'\u0000(\d+)\u0000'), (m) {
            final idx = int.parse(m.group(1)!);
            return idx < codeBlocks.length ? codeBlocks[idx] : '';
          });
        })
        .where((s) => s.isNotEmpty)
        .toList();

    // 4. Merge short sentences (< 4 words OR < 50 chars)
    final mergedChunks = <String>[];
    for (final sentence in restoredSentences) {
      if (mergedChunks.isEmpty) {
        mergedChunks.add(sentence);
      } else {
        final lastIndex = mergedChunks.length - 1;
        final previousText = mergedChunks[lastIndex];
        final wordCount = previousText.split(RegExp(r'\s+')).length;
        final charCount = previousText.length;

        if (wordCount < 4 || charCount < 50) {
          mergedChunks[lastIndex] = '$previousText $sentence';
        } else {
          mergedChunks.add(sentence);
        }
      }
    }

    return mergedChunks.isEmpty ? [text.trim()] : mergedChunks;
  }

  /// Gets available voices from the device TTS engine.
  Future<List<Map<String, dynamic>>> getDeviceVoices() async {
    await _ensureTtsInitialized();
    if (_tts == null) return [];

    try {
      final voicesRaw = await _tts!.getVoices;
      if (voicesRaw is! List) return [];

      return voicesRaw
          .whereType<Map>()
          .map((e) => _normalizeVoiceEntry(e))
          .where((e) => e.isNotEmpty)
          .toList();
    } catch (e) {
      _emitEvent(TtsError(e.toString()));
      return [];
    }
  }

  /// Gets available voices from the server.
  Future<List<Map<String, dynamic>>> getServerVoices() async {
    if (_apiService == null) return [];

    try {
      final serverVoices = await _apiService!.getAvailableServerVoices();
      return serverVoices
          .map((v) {
            final id = (v['id'] ?? v['name'] ?? '').toString();
            final name = (v['name'] ?? v['id'] ?? '').toString();
            final locale = (v['locale'] ?? v['language'] ?? '').toString();
            return {'id': id, 'name': name, 'locale': locale};
          })
          .where((e) => e['name']?.toString().trim().isNotEmpty ?? false)
          .toList();
    } catch (e) {
      _emitEvent(TtsError(e.toString()));
      return [];
    }
  }

  /// Preloads server default voice configuration.
  Future<void> preloadServerDefaults() async {
    if (_apiService == null) return;
    try {
      await _getServerDefaultVoice();
    } catch (_) {}
  }

  /// Synthesizes a single text chunk to audio without playing it.
  ///
  /// This is used by [VoiceCallService] for its own audio playback pipeline.
  /// Returns the audio bytes and mime type.
  Future<({Uint8List bytes, String mimeType})> synthesizeChunk(
    String text,
  ) async {
    if (_apiService == null) {
      throw StateError('Server TTS is not available');
    }
    if (text.trim().isEmpty) {
      throw ArgumentError('Cannot synthesize empty text');
    }

    final voice = await _resolveServerVoice();
    final result = await _apiService!.generateSpeech(
      text: text,
      voice: voice,
      speed: _config.speechRate,
    );
    return (bytes: result.bytes, mimeType: result.mimeType);
  }

  // ===========================================================================
  // Private: Initialization
  // ===========================================================================

  Future<void> _ensureTtsInitialized() async {
    if (_ttsInitialized) return;

    // Prevent concurrent initialization
    if (_initCompleter != null) {
      await _initCompleter!.future;
      return;
    }

    _initCompleter = Completer<void>();

    try {
      final tts = FlutterTts();
      _tts = tts;

      // Wait for native TTS to be fully initialized before setting handlers.
      // The flutter_tts plugin has a bug where setting handlers during onInit
      // causes ConcurrentModificationException.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      if (!_handlersSet) {
        _setupTtsHandlers(tts);
        _handlersSet = true;
      }

      // Configure device engine
      await _configureDeviceEngine();

      _ttsInitialized = true;
      _initCompleter!.complete();
    } catch (e) {
      _initCompleter!.completeError(e);
      _initCompleter = null;
      rethrow;
    }
  }

  void _setupTtsHandlers(FlutterTts tts) {
    tts.setStartHandler(() {
      if (_activeSession != null && !_activeSession!.useServerTts) {
        _emitEvent(const TtsStarted());
      }
    });

    tts.setCompletionHandler(() {
      _onDeviceChunkComplete();
    });

    tts.setCancelHandler(() {
      if (_activeSession != null && !_activeSession!.useServerTts) {
        _activeSession = null;
        _resetPlaybackState();
        _emitEvent(const TtsCancelled());
      }
    });

    tts.setPauseHandler(() {
      if (_activeSession != null && !_activeSession!.useServerTts) {
        _emitEvent(const TtsPaused());
      }
    });

    tts.setContinueHandler(() {
      if (_activeSession != null && !_activeSession!.useServerTts) {
        _emitEvent(const TtsResumed());
      }
    });

    tts.setErrorHandler((msg) {
      _emitEvent(TtsError(msg.toString()));
    });

    try {
      tts.setProgressHandler((String text, int start, int end, String word) {
        if (_activeSession != null && !_activeSession!.useServerTts) {
          _emitEvent(TtsWordProgress(start, end));
        }
      });
    } catch (_) {
      // Some platforms may not support progress handler
    }
  }

  Future<void> _configureDeviceEngine() async {
    if (_tts == null) return;

    _deviceEngineAvailable = false;
    try {
      // Set default engine on Android
      if (!kIsWeb && Platform.isAndroid) {
        try {
          final engine = await _tts!.getDefaultEngine;
          if (engine is String && engine.isNotEmpty) {
            await _tts!.setEngine(engine);
          }
        } catch (_) {}
      }

      await _tts!.awaitSpeakCompletion(true);
      await _tts!.setVolume(_config.volume);
      await _tts!.setSpeechRate(_config.speechRate);
      await _tts!.setPitch(_config.pitch);

      if (!kIsWeb && Platform.isIOS) {
        await _tts!.setSharedInstance(true);
      }

      _deviceEngineAvailable = true;
    } catch (e) {
      _deviceEngineAvailable = false;
      _emitEvent(TtsError(e.toString()));
    }
  }

  // ===========================================================================
  // Private: Device TTS Playback
  // ===========================================================================

  Future<void> _startDevicePlayback(TtsPlaybackSession session) async {
    if (!_deviceEngineAvailable || _tts == null) {
      throw StateError('Device TTS is not available');
    }

    _currentChunkIndex = 0;

    // Configure voice if needed
    if (!_voiceConfigured) {
      await _configurePreferredVoice();
    }

    // Speak first chunk
    _emitEvent(const TtsChunkStarted(0));
    final result = await _tts!.speak(session.chunks.first);
    if (result is int && result != 1) {
      throw StateError('TTS engine returned error code $result');
    }
  }

  void _onDeviceChunkComplete() {
    final session = _activeSession;
    if (session == null || session.useServerTts) return;

    final nextIndex = _currentChunkIndex + 1;

    // Check if there are more chunks
    if (nextIndex >= session.chunks.length) {
      _activeSession = null;
      _resetPlaybackState();
      _emitEvent(const TtsCompleted());
      return;
    }

    // Play next chunk
    _currentChunkIndex = nextIndex;
    _emitEvent(TtsChunkStarted(nextIndex));

    _tts?.speak(session.chunks[nextIndex]).then((result) {
      if (result is int && result != 1) {
        _emitEvent(TtsError('TTS engine returned error code $result'));
      }
    });
  }

  // ===========================================================================
  // Private: Server TTS Playback
  // ===========================================================================

  Future<void> _startServerPlayback(TtsPlaybackSession session) async {
    if (_apiService == null) {
      throw StateError('Server TTS is not available');
    }

    _serverCurrentIndex = -1;
    _serverAudioBuffer.clear();
    _serverWaitingForNext = false;

    final voice = await _resolveServerVoice();

    // Fetch and play first chunk
    final firstChunk = await _fetchServerAudio(session.chunks.first, voice);
    if (_activeSession?.id != session.id) return; // Cancelled

    _serverAudioBuffer.add(firstChunk);
    _serverCurrentIndex = 0;

    await _player.stop();
    _isTransitioningChunks = true;
    // Flag will be cleared by state listener when playing=true is received.
    // This prevents race condition where flag is cleared before state fires.
    try {
      await _player.setAudioSource(BytesAudioSource(firstChunk.bytes, firstChunk.mimeType));
      await _player.play();
    } catch (e) {
      // Reset flag on error to avoid suppressing future pause events
      _isTransitioningChunks = false;
      rethrow;
    }
    _emitEvent(const TtsChunkStarted(0));

    // Prefetch remaining chunks in background
    unawaited(_prefetchServerChunks(session, voice, 1));
  }

  Future<void> _prefetchServerChunks(
    TtsPlaybackSession session,
    String? voice,
    int startIndex,
  ) async {
    for (var i = startIndex; i < session.chunks.length; i++) {
      if (_activeSession?.id != session.id) return; // Cancelled

      try {
        final chunk = await _fetchServerAudio(session.chunks[i], voice);
        if (_activeSession?.id != session.id) return;

        _serverAudioBuffer.add(chunk);

        // If player was waiting for this chunk, play it now
        if (_serverWaitingForNext &&
            _serverCurrentIndex + 1 < _serverAudioBuffer.length) {
          _serverWaitingForNext = false;
          await _playNextServerChunk();
        }
      } catch (e) {
        _emitEvent(TtsError(e.toString()));
      }
    }
  }

  Future<_AudioChunk> _fetchServerAudio(String text, String? voice) async {
    final result = await _apiService!.generateSpeech(
      text: text,
      voice: voice,
      speed: _config.speechRate,
    );
    return _AudioChunk(bytes: result.bytes, mimeType: result.mimeType);
  }

  void _onServerAudioComplete() {
    final session = _activeSession;
    if (session == null || !session.useServerTts) return;

    final nextIndex = _serverCurrentIndex + 1;

    // Check if all chunks are done
    if (nextIndex >= session.chunks.length) {
      _activeSession = null;
      _resetPlaybackState();
      _emitEvent(const TtsCompleted());
      return;
    }

    // Check if next chunk is buffered
    if (nextIndex < _serverAudioBuffer.length) {
      unawaited(_playNextServerChunk());
    } else {
      _serverWaitingForNext = true;
    }
  }

  Future<void> _playNextServerChunk() async {
    final session = _activeSession;
    if (session == null) return;

    final nextIndex = _serverCurrentIndex + 1;
    if (nextIndex >= _serverAudioBuffer.length) return;

    _serverCurrentIndex = nextIndex;
    final chunk = _serverAudioBuffer[nextIndex];

    _isTransitioningChunks = true;
    // Flag will be cleared by state listener when playing=true is received.
    try {
      await _player.setAudioSource(BytesAudioSource(chunk.bytes, chunk.mimeType));
      await _player.play();
    } catch (e) {
      // Reset flag on error to avoid suppressing future pause events
      _isTransitioningChunks = false;
      rethrow;
    }
    _emitEvent(TtsChunkStarted(nextIndex));
  }

  Future<String?> _resolveServerVoice() async {
    final serverSelected = _config.serverVoice?.trim();
    if (serverSelected != null && serverSelected.isNotEmpty) {
      return serverSelected;
    }
    final selected = _config.voice?.trim();
    if (selected != null && selected.isNotEmpty) {
      return selected;
    }
    return await _getServerDefaultVoice();
  }

  Future<String?> _getServerDefaultVoice() async {
    if (_apiService == null) return null;
    if (_serverDefaultVoice != null) return _serverDefaultVoice;

    if (_serverDefaultVoiceFuture != null) {
      return _serverDefaultVoiceFuture;
    }

    _serverDefaultVoiceFuture = _apiService!.getDefaultServerVoice();
    try {
      final voice = await _serverDefaultVoiceFuture;
      _serverDefaultVoice = voice?.trim();
      return _serverDefaultVoice;
    } catch (e) {
      _emitEvent(TtsError(e.toString()));
      return null;
    } finally {
      _serverDefaultVoiceFuture = null;
    }
  }

  // ===========================================================================
  // Private: Helpers
  // ===========================================================================

  bool _shouldUseServer() {
    if (_config.preferServer && _apiService != null) {
      return true;
    }
    if (_deviceEngineAvailable) {
      return false;
    }
    return _apiService != null;
  }

  void _resetPlaybackState() {
    _currentChunkIndex = -1;
    _serverCurrentIndex = -1;
    _serverAudioBuffer.clear();
    _serverWaitingForNext = false;
  }

  void _emitEvent(TtsEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  Future<void> _setVoiceByName(String? voiceName) async {
    if (_tts == null || voiceName == null) return;
    if (kIsWeb || (!Platform.isIOS && !Platform.isAndroid)) return;

    try {
      final voicesRaw = await _tts!.getVoices;
      if (voicesRaw is! List) return;

      for (final entry in voicesRaw) {
        if (entry is Map) {
          final normalized = _normalizeVoiceEntry(entry);
          final name = normalized['name'] as String?;
          if (name == voiceName) {
            await _tts!.setVoice(_voiceCommandFrom(normalized));
            _voiceConfigured = true;
            return;
          }
        }
      }
    } catch (e) {
      _emitEvent(TtsError(e.toString()));
    }
  }

  Future<void> _configurePreferredVoice() async {
    if (_voiceConfigured || _tts == null) return;
    if (kIsWeb || (!Platform.isIOS && !Platform.isAndroid)) {
      _voiceConfigured = true;
      return;
    }

    try {
      // Try to use configured voice
      if (_config.voice != null) {
        await _setVoiceByName(_config.voice);
        if (_voiceConfigured) return;
      }

      // Fall back to system default
      _voiceConfigured = true;
    } catch (e) {
      _emitEvent(TtsError(e.toString()));
      _voiceConfigured = true;
    }
  }

  Map<String, dynamic> _normalizeVoiceEntry(Map<dynamic, dynamic> entry) {
    final normalized = <String, dynamic>{};
    entry.forEach((key, value) {
      if (key != null) {
        normalized[key.toString()] = value;
      }
    });
    return normalized;
  }

  Map<String, String> _voiceCommandFrom(Map<String, dynamic> voice) {
    final command = <String, String>{};
    for (final key in [
      'name',
      'locale',
      'identifier',
      'id',
      'voiceIdentifier',
      'engine',
    ]) {
      final value = voice[key];
      if (value != null) {
        command[key] = value.toString();
      }
    }
    return command;
  }
}

// =============================================================================
// Internal Types
// =============================================================================

class _AudioChunk {
  const _AudioChunk({required this.bytes, required this.mimeType});
  final Uint8List bytes;
  final String mimeType;
}
