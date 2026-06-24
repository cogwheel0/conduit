import 'dart:async';
import 'dart:io' show Directory, File, Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/models/backend_config.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/background_streaming_handler.dart';
import '../../../shared/widgets/markdown/markdown_preprocessor.dart';
import 'native_tts_service.dart';

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

@visibleForTesting
bool isServerTtsPlaybackCompleteForTesting({
  required ProcessingState processingState,
  required int currentIndex,
  required int lastChunkIndex,
  required int lastEnqueuedIndex,
}) {
  return _isServerTtsPlaybackComplete(
    processingState: processingState,
    currentIndex: currentIndex,
    lastChunkIndex: lastChunkIndex,
    lastEnqueuedIndex: lastEnqueuedIndex,
  );
}

bool _isServerTtsPlaybackComplete({
  required ProcessingState processingState,
  required int currentIndex,
  required int lastChunkIndex,
  required int lastEnqueuedIndex,
}) {
  return processingState == ProcessingState.completed &&
      currentIndex >= lastChunkIndex &&
      lastEnqueuedIndex >= lastChunkIndex;
}

// =============================================================================
// TTS Configuration
// =============================================================================

/// Configuration for TTS playback.
class TtsConfig {
  const TtsConfig({
    this.voice,
    this.serverVoice,
    this.splitOn = TtsManager.splitOnPunctuation,
    this.speechRate = 0.5,
    this.pitch = 1.0,
    this.volume = 1.0,
    this.preferServer = false,
  });

  final String? voice;
  final String? serverVoice;
  final String splitOn;
  final double speechRate;
  final double pitch;
  final double volume;
  final bool preferServer;

  TtsConfig copyWith({
    String? voice,
    String? serverVoice,
    String? splitOn,
    double? speechRate,
    double? pitch,
    double? volume,
    bool? preferServer,
  }) {
    return TtsConfig(
      voice: voice ?? this.voice,
      serverVoice: serverVoice ?? this.serverVoice,
      splitOn: splitOn ?? this.splitOn,
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
/// This manager owns native device TTS and AudioPlayer instances and ensures
/// only one playback session is active at a time. Events are emitted via
/// a stream that consumers can listen to.
class TtsManager {
  static const int _serverPrefetchParallelism = 3;
  static const Duration _serverInitialLookaheadTimeout = Duration(
    milliseconds: 220,
  );
  static const String splitOnPunctuation = 'punctuation';
  static const String splitOnParagraphs = 'paragraphs';
  static const String splitOnNone = 'none';
  static const int _mergeMinWords = 4;
  static const int _mergeMinChars = 50;
  static const double _serverPlaybackRate = 1.0;

  TtsManager._();
  static final instance = TtsManager._();

  bool _ttsInitialized = false;
  Completer<void>? _initCompleter;
  final NativeTtsService _nativeTts = NativeTtsService();
  StreamSubscription<NativeTtsEvent>? _nativeTtsSub;
  bool _nativeTtsAvailable = false;

  // AudioPlayer for server TTS (using just_audio)
  final AudioPlayer _player = AudioPlayer();
  bool _playerConfigured = false;
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<int?>? _playerIndexSub;

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
  final List<_AudioChunk?> _serverAudioBuffer = [];
  int _serverCurrentIndex = -1;
  int _serverLastEnqueuedIndex = -1;
  bool _serverWaitingForNext = false;
  bool _serverRecoveringMissingChunk = false;
  String? _serverPlaybackVoice;
  Future<void> _serverPlaylistSerial = Future<void>.value();
  bool _isStreamingSession = false;
  bool _streamingFinalized = false;
  int _streamingFedChunkCount = 0;
  bool _deviceWaitingForStreamingChunk = false;
  int _serverLastFetchScheduledIndex = -1;
  final Set<int> _serverFetchingIndices = <int>{};
  final List<File> _serverTempFiles = <File>[];
  String? _serverBackgroundLeaseId;

  // Event stream
  final _eventController = StreamController<TtsEvent>.broadcast();

  // Cached server default voice
  String? _serverDefaultVoice;

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
    final voiceChanged = config.voice != _config.voice;
    _config = config;
    if (voiceChanged) {
      _voiceConfigured = false;
    }

    if (_playerConfigured) {
      await _player.setSpeed(_serverPlaybackRate);
    }
  }

  /// Applies backend-provided TTS defaults cached in [BackendConfig].
  void applyBackendConfig(BackendConfig? config) {
    if (config == null) {
      return;
    }

    _serverDefaultVoice = config.ttsVoice?.trim();
    _config = _config.copyWith(splitOn: _normalizeSplitOn(config.ttsSplitOn));
  }

  /// Initializes the TTS engine.
  ///
  /// This must be called before any TTS operations.
  Future<bool> initialize({TtsConfig? config}) async {
    if (config != null) {
      _config = config;
    }

    // Initialize native device TTS.
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
      _playerIndexSub = _player.currentIndexStream.listen((index) {
        final session = _activeSession;
        if (session == null || !session.useServerTts || index == null) {
          return;
        }
        if (index < 0 || index >= session.chunks.length) {
          return;
        }
        if (_serverCurrentIndex == index) {
          return;
        }
        _serverCurrentIndex = index;
        _emitEvent(TtsChunkStarted(index));
      });
      await _player.setSpeed(_serverPlaybackRate);
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

  /// Starts a mutable TTS session that accepts accumulated assistant text.
  Future<TtsPlaybackSession?> startStreaming({bool? useServer}) async {
    await stop();
    await _ensureTtsInitialized();

    final shouldUseServer = useServer ?? _shouldUseServer();
    _sessionCounter++;
    final session = TtsPlaybackSession._(
      id: _sessionCounter,
      chunks: <String>[],
      useServerTts: shouldUseServer,
    );
    _activeSession = session;
    _isStreamingSession = true;
    _streamingFinalized = false;
    _streamingFedChunkCount = 0;
    _deviceWaitingForStreamingChunk = false;
    _serverLastFetchScheduledIndex = -1;
    _serverFetchingIndices.clear();
    _serverPlaybackVoice = shouldUseServer ? await _resolveServerVoice() : null;

    if (shouldUseServer) {
      await _startServerBackgroundLease(session.id);
      await _player.stop();
      await _player.clearAudioSources();
    } else {
      if (!_deviceEngineAvailable) {
        throw StateError('Device TTS is not available');
      }
      if (!_voiceConfigured) {
        await _configurePreferredVoice();
      }
    }
    return session;
  }

  /// Feeds accumulated streaming response text and enqueues stable chunks.
  Future<void> feedStreamingText(String accumulatedText) async {
    final session = _activeSession;
    if (session == null || !_isStreamingSession || _streamingFinalized) {
      return;
    }
    await _enqueueStreamingText(session, accumulatedText, finalized: false);
  }

  /// Flushes any held trailing text and lets the active streaming session drain.
  Future<void> finishStreaming({String? finalText}) async {
    final session = _activeSession;
    if (session == null || !_isStreamingSession) {
      return;
    }

    _streamingFinalized = true;
    await _enqueueStreamingText(session, finalText ?? '', finalized: true);
    if (session.chunks.isEmpty) {
      _activeSession = null;
      _resetPlaybackState();
      _emitEvent(const TtsCompleted());
      return;
    }

    if (session.useServerTts) {
      await _enqueueBufferedServerChunks(session);
      final producerDone =
          _serverLastEnqueuedIndex >= session.chunks.length - 1 &&
          _serverFetchingIndices.isEmpty;
      final playerDone = _player.processingState == ProcessingState.completed;
      if (producerDone && playerDone) {
        _onServerAudioComplete();
      }
    } else if (_deviceWaitingForStreamingChunk) {
      _onDeviceChunkComplete();
    }
  }

  /// Cancels a mutable streaming TTS session.
  Future<void> stopStreaming() async {
    if (!_isStreamingSession) {
      return;
    }
    await stop();
  }

  /// Pauses the current playback.
  Future<void> pause() async {
    final session = _activeSession;
    if (session == null) return;

    try {
      if (session.useServerTts) {
        await _player.pause();
      } else {
        await _nativeTts.pause();
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
        await _nativeTts.resume();
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

    try {
      if (session.useServerTts) {
        await _player.stop();
      } else {
        await _nativeTts.stop();
      }
      _resetPlaybackState();
      _emitEvent(const TtsCancelled());
    } catch (e) {
      _resetPlaybackState();
      _emitEvent(TtsError(e.toString()));
    }
  }

  /// Resets the manager state for a new session.
  ///
  /// Call this between voice calls to ensure clean state. This clears
  /// playback buffers and resets session tracking without destroying
  /// the singleton instance.
  Future<void> reset() async {
    await stop();

    // Reset playback state
    _resetPlaybackState();
    _activeSession = null;
    _sessionCounter = 0;

    // Reset server audio buffer
    _serverAudioBuffer.clear();
    _serverWaitingForNext = false;

    // Reset cached voice defaults so they're refetched if needed
    _serverDefaultVoice = null;
  }

  /// Disposes the manager and releases resources.
  Future<void> dispose() async {
    await stop();
    await _nativeTtsSub?.cancel();
    _nativeTtsSub = null;
    await _playerStateSub?.cancel();
    await _playerIndexSub?.cancel();
    await _player.dispose();
    await _eventController.close();
  }

  /// Splits text into chunks for TTS playback.
  ///
  /// This wraps [getMessageContentParts] using OpenWebUI's default split mode.
  List<String> splitTextForSpeech(String text) {
    return getMessageContentParts(text, splitOn: _config.splitOn);
  }

  /// Mirrors OpenWebUI's `extractSentences`.
  List<String> extractSentences(String text) {
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

    final sentences = processed.split(RegExp(r'(?<=[.!?])\s+|\n+')).toList();

    return sentences
        .map((sentence) {
          return sentence.replaceAllMapped(RegExp(r'\u0000(\d+)\u0000'), (m) {
            final idx = int.parse(m.group(1)!);
            return idx < codeBlocks.length ? codeBlocks[idx] : '';
          });
        })
        .map(ConduitMarkdownPreprocessor.cleanText)
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// Mirrors OpenWebUI's `extractParagraphsForAudio`.
  List<String> extractParagraphsForAudio(String text) {
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

    final paragraphs = processed
        .split(RegExp(r'\n+'))
        .map((paragraph) {
          return paragraph.replaceAllMapped(RegExp(r'\u0000(\d+)\u0000'), (m) {
            final idx = int.parse(m.group(1)!);
            return idx < codeBlocks.length ? codeBlocks[idx] : '';
          });
        })
        .map(ConduitMarkdownPreprocessor.cleanText)
        .where((s) => s.isNotEmpty)
        .toList();

    return paragraphs;
  }

  /// Mirrors OpenWebUI's `extractSentencesForAudio`.
  List<String> extractSentencesForAudio(String text) {
    final sentences = extractSentences(text);

    final mergedChunks = <String>[];
    for (final sentence in sentences) {
      if (mergedChunks.isEmpty) {
        mergedChunks.add(sentence);
      } else {
        final lastIndex = mergedChunks.length - 1;
        final previousText = mergedChunks[lastIndex];
        final wordCount = previousText.split(RegExp(r'\s+')).length;
        final charCount = previousText.length;

        if (wordCount < _mergeMinWords || charCount < _mergeMinChars) {
          mergedChunks[lastIndex] = '$previousText $sentence';
        } else {
          mergedChunks.add(sentence);
        }
      }
    }

    return mergedChunks;
  }

  /// Mirrors OpenWebUI's `getMessageContentParts`.
  List<String> getMessageContentParts(
    String content, {
    String splitOn = splitOnPunctuation,
  }) {
    final sanitizedContent = content.replaceAll(
      RegExp(r'<details[^>]*>[\s\S]*?<\/details>', caseSensitive: false),
      '',
    );

    switch (splitOn) {
      case splitOnParagraphs:
        return extractParagraphsForAudio(sanitizedContent);
      case splitOnNone:
        final cleaned = ConduitMarkdownPreprocessor.cleanText(sanitizedContent);
        return cleaned.isEmpty ? const [] : [cleaned];
      case splitOnPunctuation:
      default:
        return extractSentencesForAudio(sanitizedContent);
    }
  }

  /// Gets available voices from the device TTS engine.
  Future<List<Map<String, dynamic>>> getDeviceVoices() async {
    await _ensureTtsInitialized();
    final voices = await _nativeTts.getVoices();
    final engine = !kIsWeb && Platform.isIOS ? 'AVSpeech' : 'AndroidTTS';
    return _mergeDeviceVoices([
      voices.map((voice) => {...voice, 'engine': engine}).toList(),
    ]);
  }

  List<Map<String, dynamic>> _mergeDeviceVoices(
    List<List<Map<String, dynamic>>> groups,
  ) {
    final merged = <String, Map<String, dynamic>>{};
    for (final group in groups) {
      for (final voice in group) {
        final key = _voiceDedupeKey(voice);
        if (key == null || merged.containsKey(key)) {
          continue;
        }
        merged[key] = voice;
      }
    }
    return merged.values.toList(growable: false);
  }

  String? _voiceDedupeKey(Map<String, dynamic> voice) {
    for (final key in const ['identifier', 'id', 'voiceIdentifier', 'name']) {
      final value = voice[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        return value.toLowerCase();
      }
    }
    return null;
  }

  String _normalizeSplitOn(String? splitOn) {
    return switch (splitOn?.trim()) {
      splitOnParagraphs => splitOnParagraphs,
      splitOnNone => splitOnNone,
      _ => splitOnPunctuation,
    };
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
    final result = await _apiService!.generateSpeech(text: text, voice: voice);
    return (bytes: result.bytes, mimeType: result.mimeType);
  }

  Future<void> _enqueueStreamingText(
    TtsPlaybackSession session,
    String accumulatedText, {
    required bool finalized,
  }) async {
    if (_activeSession?.id != session.id) return;

    final chunks = splitTextForSpeech(accumulatedText);
    final speakableCount = finalized
        ? chunks.length
        : (chunks.length <= 1 ? 0 : chunks.length - 1);

    while (_streamingFedChunkCount < speakableCount) {
      final chunk = chunks[_streamingFedChunkCount].trim();
      _streamingFedChunkCount++;
      if (chunk.isEmpty) {
        continue;
      }
      await _appendStreamingChunk(session, chunk);
    }
  }

  Future<void> _appendStreamingChunk(
    TtsPlaybackSession session,
    String chunk,
  ) async {
    if (_activeSession?.id != session.id) return;

    final index = session.chunks.length;
    session.chunks.add(chunk);

    if (session.useServerTts) {
      _scheduleServerStreamingFetch(session, index);
      return;
    }

    if (_currentChunkIndex < 0) {
      _currentChunkIndex = 0;
      _emitEvent(const TtsChunkStarted(0));
      try {
        await _speakDeviceChunk(chunk);
      } catch (error) {
        _failDevicePlayback(session, error);
      }
      return;
    }

    if (_deviceWaitingForStreamingChunk) {
      _deviceWaitingForStreamingChunk = false;
      _onDeviceChunkComplete();
    }
  }

  void _scheduleServerStreamingFetch(TtsPlaybackSession session, int index) {
    if (_activeSession?.id != session.id) return;
    if (index <= _serverLastFetchScheduledIndex ||
        _serverFetchingIndices.contains(index)) {
      return;
    }

    _serverLastFetchScheduledIndex = index;
    _serverFetchingIndices.add(index);
    final voice = _serverPlaybackVoice ?? _config.serverVoice;
    unawaited(() async {
      try {
        final chunk = await _fetchServerAudioWithRetry(
          session.chunks[index],
          voice,
        );
        if (_activeSession?.id != session.id) return;
        _setBufferedServerChunk(index, chunk);
        await _enqueueBufferedServerChunks(session);
      } catch (error) {
        _emitEvent(TtsError(error.toString()));
      } finally {
        _serverFetchingIndices.remove(index);
        if (_streamingFinalized &&
            _serverFetchingIndices.isEmpty &&
            _activeSession?.id == session.id) {
          _onServerAudioComplete();
        }
      }
    }());
  }

  // ===========================================================================
  // Private: Initialization
  // ===========================================================================

  Future<void> _ensureTtsInitialized() async {
    if (_ttsInitialized) return;

    if (_initCompleter != null) {
      await _initCompleter!.future;
      return;
    }

    _initCompleter = Completer<void>();

    try {
      await _configureDeviceEngine();

      _ttsInitialized = true;
      _initCompleter!.complete();
    } catch (e) {
      _initCompleter!.completeError(e);
      _initCompleter = null;
      rethrow;
    }
  }

  Future<void> _configureDeviceEngine() async {
    _deviceEngineAvailable = false;
    _nativeTtsAvailable = await _nativeTts.isAvailable();
    if (_nativeTtsAvailable && _nativeTtsSub == null) {
      _nativeTtsSub = _nativeTts.events.listen(
        _handleNativeTtsEvent,
        onError: (Object error) {
          _emitEvent(TtsError(error.toString()));
        },
      );
    }

    _deviceEngineAvailable = _nativeTtsAvailable;
  }

  void _handleNativeTtsEvent(NativeTtsEvent event) {
    final session = _activeSession;
    if (session == null || session.useServerTts) {
      return;
    }

    switch (event.type) {
      case 'start':
        _emitEvent(const TtsStarted());
      case 'complete':
        _onDeviceChunkComplete();
      case 'cancel':
        _activeSession = null;
        _resetPlaybackState();
        _emitEvent(const TtsCancelled());
      case 'pause':
        _emitEvent(const TtsPaused());
      case 'continue':
        _emitEvent(const TtsResumed());
      case 'progress':
        final start = event.start;
        final end = event.end;
        if (start != null && end != null) {
          _emitEvent(TtsWordProgress(start, end));
        }
      case 'error':
        _activeSession = null;
        _resetPlaybackState();
        _emitEvent(TtsError(event.message ?? 'Native TTS failed'));
    }
  }

  // ===========================================================================
  // Private: Device TTS Playback
  // ===========================================================================

  Future<void> _startDevicePlayback(TtsPlaybackSession session) async {
    if (!_deviceEngineAvailable) {
      throw StateError('Device TTS is not available');
    }

    _currentChunkIndex = 0;

    // Configure voice if needed
    if (!_voiceConfigured) {
      await _configurePreferredVoice();
    }

    // Speak first chunk
    _emitEvent(const TtsChunkStarted(0));
    await _speakDeviceChunk(session.chunks.first);
  }

  void _onDeviceChunkComplete() {
    final session = _activeSession;
    if (session == null || session.useServerTts) return;

    final nextIndex = _currentChunkIndex + 1;

    // Check if there are more chunks
    if (nextIndex >= session.chunks.length) {
      if (_isStreamingSession && !_streamingFinalized) {
        _deviceWaitingForStreamingChunk = true;
        return;
      }
      _activeSession = null;
      _resetPlaybackState();
      _emitEvent(const TtsCompleted());
      return;
    }

    // Play next chunk
    _currentChunkIndex = nextIndex;
    _emitEvent(TtsChunkStarted(nextIndex));

    _speakDeviceChunk(session.chunks[nextIndex]).catchError((Object error) {
      _failDevicePlayback(session, error);
    });
  }

  Future<void> _speakDeviceChunk(String chunk) async {
    final started = await _nativeTts.speak(
      text: chunk,
      voiceIdentifier: _config.voice,
      rate: _config.speechRate,
      pitch: _config.pitch,
      volume: _config.volume,
    );
    if (!started) {
      throw StateError('Native TTS failed to start');
    }
  }

  void _failDevicePlayback(TtsPlaybackSession session, Object error) {
    if (_activeSession?.id == session.id) {
      _activeSession = null;
      _resetPlaybackState();
    }
    _emitEvent(TtsError(error.toString()));
  }

  // ===========================================================================
  // Private: Server TTS Playback
  // ===========================================================================

  Future<void> _startServerPlayback(TtsPlaybackSession session) async {
    if (_apiService == null) {
      throw StateError('Server TTS is not available');
    }

    _serverCurrentIndex = -1;
    _serverLastEnqueuedIndex = -1;
    _serverAudioBuffer.clear();
    _serverWaitingForNext = false;

    final voice = await _resolveServerVoice();
    _serverPlaybackVoice = voice;
    await _startServerBackgroundLease(session.id);

    // Fetch and play first chunk
    final firstChunk = await _fetchServerAudioWithRetry(
      session.chunks.first,
      voice,
    );
    if (_activeSession?.id != session.id) return; // Cancelled

    _setBufferedServerChunk(0, firstChunk);
    _serverLastEnqueuedIndex = 0;
    final initialSources = <AudioSource>[
      await _audioSourceForServerChunk(session.id, 0, firstChunk),
    ];

    // Opportunistically prebuffer the second chunk before first play.
    // This reduces the most noticeable early boundary gap without changing
    // controller sequencing behavior.
    var prefetchStartIndex = 1;
    if (session.chunks.length > 1) {
      try {
        final secondChunk = await _fetchServerAudioWithRetry(
          session.chunks[1],
          voice,
        ).timeout(_serverInitialLookaheadTimeout);
        if (_activeSession?.id == session.id) {
          _setBufferedServerChunk(1, secondChunk);
          _serverLastEnqueuedIndex = 1;
          initialSources.add(
            await _audioSourceForServerChunk(session.id, 1, secondChunk),
          );
          prefetchStartIndex = 2;
        }
      } on TimeoutException {
        // Continue immediately; the background prefetch will append it.
      } catch (_) {
        // Non-fatal here; regular prefetch/recovery path will handle it.
      }
    }

    await _player.stop();
    _isTransitioningChunks = true;
    // Flag will be cleared by state listener when playing=true is received.
    // This prevents race condition where flag is cleared before state fires.
    try {
      await _player.setAudioSources(
        initialSources,
        initialIndex: 0,
        initialPosition: Duration.zero,
      );
      await _player.play();
    } catch (e) {
      // Reset flag on error to avoid suppressing future pause events
      _isTransitioningChunks = false;
      rethrow;
    }

    // Prefetch remaining chunks in background
    unawaited(_prefetchServerChunks(session, voice, prefetchStartIndex));
  }

  Future<void> _prefetchServerChunks(
    TtsPlaybackSession session,
    String? voice,
    int startIndex,
  ) async {
    var nextToFetch = startIndex;

    Future<void> worker() async {
      while (true) {
        if (_activeSession?.id != session.id) {
          return;
        }
        if (nextToFetch >= session.chunks.length) {
          return;
        }

        final i = nextToFetch;
        nextToFetch += 1;

        try {
          final chunk = await _fetchServerAudioWithRetry(
            session.chunks[i],
            voice,
          );
          if (_activeSession?.id != session.id) {
            return;
          }

          _setBufferedServerChunk(i, chunk);
          await _enqueueBufferedServerChunks(session);
        } catch (e) {
          _emitEvent(TtsError(e.toString()));
        }
      }
    }

    final workerCount = _serverPrefetchParallelism < 1
        ? 1
        : _serverPrefetchParallelism;
    await Future.wait(List.generate(workerCount, (_) => worker()));
  }

  Future<_AudioChunk> _fetchServerAudio(
    String text,
    String? voice, {
    double? speed,
  }) async {
    final result = await _apiService!.generateSpeech(
      text: text,
      voice: voice,
      speed: speed,
    );
    return _AudioChunk(bytes: result.bytes, mimeType: result.mimeType);
  }

  Future<_AudioChunk> _fetchServerAudioWithRetry(
    String text,
    String? voice,
  ) async {
    const maxAttempts = 4;
    Object? lastError;
    var requestText = text.trim();
    var requestVoice = voice?.trim();
    if (requestVoice != null && requestVoice.isEmpty) {
      requestVoice = null;
    }

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await _fetchServerAudio(requestText, requestVoice);
      } catch (error) {
        lastError = error;

        // Keep text exact: do not normalize/rewrite payload between attempts.
        // Only retry transient failures.
        if (error is DioException) {
          final statusCode = error.response?.statusCode;
          final isClientValidationError =
              statusCode != null &&
              statusCode >= 400 &&
              statusCode < 500 &&
              statusCode != 429;
          if (isClientValidationError) {
            break;
          }
        }

        if (attempt == maxAttempts) {
          break;
        }
        await Future<void>.delayed(Duration(milliseconds: 150 * attempt));
      }
    }

    throw StateError(
      'Server TTS synthesis failed after $maxAttempts attempts: $lastError',
    );
  }

  void _onServerAudioComplete() {
    final session = _activeSession;
    if (session == null || !session.useServerTts) return;

    final currentIndex = _player.currentIndex ?? _serverCurrentIndex;
    final lastChunkIndex = session.chunks.length - 1;

    // Complete only when the final session chunk has been enqueued and the
    // player reports that playlist playback has actually finished.
    if (_isServerTtsPlaybackComplete(
      processingState: _player.processingState,
      currentIndex: currentIndex,
      lastChunkIndex: lastChunkIndex,
      lastEnqueuedIndex: _serverLastEnqueuedIndex,
    )) {
      if (_isStreamingSession &&
          (!_streamingFinalized || _serverFetchingIndices.isNotEmpty)) {
        _serverWaitingForNext = true;
        return;
      }
      _activeSession = null;
      _resetPlaybackState();
      _emitEvent(const TtsCompleted());
      return;
    }

    if (_serverLastEnqueuedIndex > currentIndex) {
      _serverWaitingForNext = false;
      unawaited(_resumeServerQueueFromCompleted(currentIndex));
      return;
    }

    final nextIndex = currentIndex + 1;
    if (nextIndex >= session.chunks.length) {
      return;
    }

    if (_hasBufferedServerChunk(nextIndex)) {
      _serverWaitingForNext = false;
      unawaited(_enqueueBufferedServerChunks(session));
    } else {
      _serverWaitingForNext = true;
      final voice = _serverPlaybackVoice ?? _config.serverVoice;
      unawaited(_recoverMissingServerChunk(session, voice, nextIndex));
    }
  }

  Future<void> _recoverMissingServerChunk(
    TtsPlaybackSession session,
    String? voice,
    int index,
  ) async {
    if (_serverRecoveringMissingChunk ||
        _activeSession?.id != session.id ||
        index >= session.chunks.length) {
      return;
    }

    _serverRecoveringMissingChunk = true;
    try {
      if (_hasBufferedServerChunk(index)) {
        await _enqueueBufferedServerChunks(session);
        return;
      }

      final recovered = await _fetchServerAudioWithRetry(
        session.chunks[index],
        voice,
      );
      if (_activeSession?.id != session.id) {
        return;
      }

      _setBufferedServerChunk(index, recovered);
      await _enqueueBufferedServerChunks(session);
    } catch (error) {
      _emitEvent(TtsError(error.toString()));
      if (_activeSession?.id == session.id) {
        _activeSession = null;
        _resetPlaybackState();
      }
    } finally {
      _serverRecoveringMissingChunk = false;
    }
  }

  Future<void> _enqueueBufferedServerChunks(TtsPlaybackSession session) async {
    _serverPlaylistSerial = _serverPlaylistSerial
        .then((_) async {
          if (_activeSession?.id != session.id) {
            return;
          }

          while (true) {
            final nextIndex = _serverLastEnqueuedIndex + 1;
            if (nextIndex >= session.chunks.length) {
              break;
            }
            final chunk = _chunkAt(nextIndex);
            if (chunk == null) {
              break;
            }
            final source = await _audioSourceForServerChunk(
              session.id,
              nextIndex,
              chunk,
            );
            if (_isStreamingSession &&
                nextIndex == 0 &&
                _serverLastEnqueuedIndex < 0) {
              _isTransitioningChunks = true;
              try {
                await _player.setAudioSources(
                  [source],
                  initialIndex: 0,
                  initialPosition: Duration.zero,
                );
                await _player.play();
              } catch (_) {
                _isTransitioningChunks = false;
                rethrow;
              }
            } else {
              await _player.addAudioSource(source);
            }
            _serverLastEnqueuedIndex = nextIndex;
          }

          if (_serverWaitingForNext) {
            final currentIndex = _player.currentIndex ?? _serverCurrentIndex;
            if (_serverLastEnqueuedIndex > currentIndex) {
              _serverWaitingForNext = false;
              await _resumeServerQueueFromCompleted(currentIndex);
            }
          }
        })
        .catchError((_) {});
    await _serverPlaylistSerial;
  }

  Future<void> _resumeServerQueueFromCompleted(int currentIndex) async {
    if (_player.processingState != ProcessingState.completed) {
      return;
    }
    final nextIndex = currentIndex + 1;
    if (nextIndex < 0 || nextIndex > _serverLastEnqueuedIndex) {
      return;
    }
    await _player.seek(Duration.zero, index: nextIndex);
    await _player.play();
  }

  Future<AudioSource> _audioSourceForServerChunk(
    int sessionId,
    int index,
    _AudioChunk chunk,
  ) async {
    final tempDir = await getTemporaryDirectory();
    final dir = Directory(p.join(tempDir.path, 'conduit_tts', '$sessionId'));
    await dir.create(recursive: true);

    final extension = _audioExtensionForMimeType(chunk.mimeType);
    final file = File(p.join(dir.path, 'chunk_$index.$extension'));
    await file.writeAsBytes(chunk.bytes, flush: true);
    _serverTempFiles.add(file);
    return AudioSource.uri(file.uri, tag: index);
  }

  String _audioExtensionForMimeType(String mimeType) {
    final normalized = mimeType.toLowerCase();
    if (normalized.contains('mpeg') || normalized.contains('mp3')) {
      return 'mp3';
    }
    if (normalized.contains('wav')) {
      return 'wav';
    }
    if (normalized.contains('ogg')) {
      return 'ogg';
    }
    if (normalized.contains('aac')) {
      return 'aac';
    }
    if (normalized.contains('mp4') || normalized.contains('m4a')) {
      return 'm4a';
    }
    return 'audio';
  }

  Future<void> _startServerBackgroundLease(int sessionId) async {
    final leaseId = 'tts-server-$sessionId';
    _serverBackgroundLeaseId = leaseId;
    try {
      await BackgroundStreamingHandler.instance.startBackgroundExecution([
        leaseId,
      ]);
    } catch (_) {}
  }

  Future<void> _stopServerBackgroundLease() async {
    final leaseId = _serverBackgroundLeaseId;
    _serverBackgroundLeaseId = null;
    if (leaseId == null) return;
    try {
      await BackgroundStreamingHandler.instance.stopBackgroundExecution([
        leaseId,
      ]);
    } catch (_) {}
  }

  Future<void> _cleanupServerTempFiles() async {
    final files = List<File>.from(_serverTempFiles);
    _serverTempFiles.clear();
    for (final file in files) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  Future<String?> _resolveServerVoice() async {
    final serverSelected = _config.serverVoice?.trim();
    if (serverSelected != null && serverSelected.isNotEmpty) {
      return serverSelected;
    }
    final serverDefault = await _getServerDefaultVoice();
    if (serverDefault != null && serverDefault.isNotEmpty) {
      return serverDefault;
    }
    return null;
  }

  Future<String?> _getServerDefaultVoice() async {
    if (_serverDefaultVoice != null) return _serverDefaultVoice;
    return null;
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
    _serverLastEnqueuedIndex = -1;
    _serverAudioBuffer.clear();
    _serverWaitingForNext = false;
    _serverRecoveringMissingChunk = false;
    _serverPlaybackVoice = null;
    _serverPlaylistSerial = Future<void>.value();
    _isStreamingSession = false;
    _streamingFinalized = false;
    _streamingFedChunkCount = 0;
    _deviceWaitingForStreamingChunk = false;
    _serverLastFetchScheduledIndex = -1;
    _serverFetchingIndices.clear();
    unawaited(_stopServerBackgroundLease());
    unawaited(_cleanupServerTempFiles());
  }

  void _setBufferedServerChunk(int index, _AudioChunk chunk) {
    while (_serverAudioBuffer.length <= index) {
      _serverAudioBuffer.add(null);
    }
    _serverAudioBuffer[index] = chunk;
  }

  bool _hasBufferedServerChunk(int index) {
    if (index < 0 || index >= _serverAudioBuffer.length) {
      return false;
    }
    return _serverAudioBuffer[index] != null;
  }

  _AudioChunk? _chunkAt(int index) {
    if (index < 0 || index >= _serverAudioBuffer.length) {
      return null;
    }
    return _serverAudioBuffer[index];
  }

  void _emitEvent(TtsEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  Future<void> _configurePreferredVoice() async {
    if (_voiceConfigured) return;
    _voiceConfigured = true;
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
