import 'dart:async';

import 'package:riverpod/riverpod.dart';
import 'package:clock/clock.dart';

import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';

import 'package:conduit_core/providers/app_providers.dart';

import 'package:conduit_markdown/conduit_markdown.dart';

import '../services/text_to_speech_service.dart';
import '../services/tts_manager.dart';

enum TtsPlaybackStatus { idle, initializing, loading, speaking, paused, error }

class TextToSpeechState {
  final bool initialized;
  final bool available;
  final TtsPlaybackStatus status;
  final String? activeMessageId;
  final String? errorMessage;
  final Duration elapsed;
  final Duration duration;
  final bool canSeek;
  final bool seeking;
  final List<String> sentences;
  final List<int> sentenceOffsets; // start indices in full text
  final int activeSentenceIndex; // -1 when none
  final int? wordStartInSentence; // nullable; only for on-device
  final int? wordEndInSentence; // nullable; only for on-device

  const TextToSpeechState({
    this.initialized = false,
    this.available = false,
    this.status = TtsPlaybackStatus.idle,
    this.activeMessageId,
    this.errorMessage,
    this.elapsed = Duration.zero,
    this.duration = Duration.zero,
    this.canSeek = false,
    this.seeking = false,
    this.sentences = const [],
    this.sentenceOffsets = const [],
    this.activeSentenceIndex = -1,
    this.wordStartInSentence,
    this.wordEndInSentence,
  });

  bool get isSpeaking => status == TtsPlaybackStatus.speaking;
  bool get isBusy =>
      status == TtsPlaybackStatus.loading ||
      status == TtsPlaybackStatus.initializing;

  TextToSpeechState copyWith({
    bool? initialized,
    bool? available,
    TtsPlaybackStatus? status,
    String? activeMessageId,
    bool clearActiveMessageId = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    Duration? elapsed,
    Duration? duration,
    bool? canSeek,
    bool? seeking,
    List<String>? sentences,
    List<int>? sentenceOffsets,
    int? activeSentenceIndex,
    bool clearWord = false,
    int? wordStartInSentence,
    int? wordEndInSentence,
  }) {
    return TextToSpeechState(
      initialized: initialized ?? this.initialized,
      available: available ?? this.available,
      status: status ?? this.status,
      activeMessageId: clearActiveMessageId
          ? null
          : activeMessageId ?? this.activeMessageId,
      errorMessage: clearErrorMessage
          ? null
          : errorMessage ?? this.errorMessage,
      elapsed: elapsed ?? this.elapsed,
      duration: duration ?? this.duration,
      canSeek: canSeek ?? this.canSeek,
      seeking: seeking ?? this.seeking,
      sentences: sentences ?? this.sentences,
      sentenceOffsets: sentenceOffsets ?? this.sentenceOffsets,
      activeSentenceIndex: activeSentenceIndex ?? this.activeSentenceIndex,
      wordStartInSentence: clearWord
          ? null
          : (wordStartInSentence ?? this.wordStartInSentence),
      wordEndInSentence: clearWord
          ? null
          : (wordEndInSentence ?? this.wordEndInSentence),
    );
  }
}

class TextToSpeechController extends Notifier<TextToSpeechState> {
  late TextToSpeechService _service;
  bool _handlersBound = false;
  late Stopwatch _playbackClock;
  Timer? _playbackTicker;
  Future<bool>? _initializationFuture;
  int _requestEpoch = 0;
  ({String messageId, String text})? _lastRequest;

  @override
  TextToSpeechState build() {
    _playbackTicker?.cancel();
    _playbackClock = clock.stopwatch();
    _requestEpoch++;
    _lastRequest = null;
    _service = ref.watch(textToSpeechServiceProvider);

    if (!_handlersBound) {
      _handlersBound = true;
      _service.bindHandlers(
        onStart: _handleStart,
        onComplete: _handleCompletion,
        onCancel: _handleCancellation,
        onPause: _handlePause,
        onContinue: _handleContinue,
        onError: _handleError,
        onSentenceIndex: _handleSentenceIndex,
        onDeviceWordProgress: _handleDeviceWordProgress,
      );

      ref.onDispose(() {
        _stopPlaybackClock();
        unawaited(_service.stop());
      });
    }

    // Listen to settings changes and update TTS when initialized
    ref.listen<AppSettings>(appSettingsProvider, (previous, next) {
      if (_service.isInitialized && _service.isAvailable) {
        _service.updateSettings(
          voice: next.ttsVoice,
          serverVoice: next.ttsServerVoiceId,
          speechRate: next.ttsSpeechRate,
          pitch: next.ttsPitch,
          volume: next.ttsVolume,
          engine: next.ttsEngine,
        );
      }
    }, fireImmediately: false);

    return const TextToSpeechState();
  }

  Future<bool> _ensureInitialized() {
    final existing = _initializationFuture;
    if (existing != null) {
      return existing;
    }

    state = state.copyWith(
      status: TtsPlaybackStatus.initializing,
      clearErrorMessage: true,
    );

    final settings = ref.read(appSettingsProvider);
    final future = _service
        .initialize(
          deviceVoice: settings.ttsVoice,
          serverVoice: settings.ttsServerVoiceId,
          speechRate: settings.ttsSpeechRate,
          pitch: settings.ttsPitch,
          volume: settings.ttsVolume,
          engine: settings.ttsEngine,
        )
        .then((available) {
          if (!ref.mounted) {
            return available;
          }

          state = state.copyWith(
            initialized: true,
            available: available,
            status: TtsPlaybackStatus.idle,
          );
          return available;
        })
        .catchError((error, _) {
          if (!ref.mounted) {
            return false;
          }

          state = state.copyWith(
            initialized: true,
            available: false,
            status: TtsPlaybackStatus.error,
            errorMessage: error.toString(),
            clearActiveMessageId: true,
          );
          return false;
        });

    _initializationFuture = future;
    future.whenComplete(() {
      _initializationFuture = null;
    });

    return future;
  }

  Future<void> toggleForMessage({
    required String messageId,
    required String text,
  }) async {
    final isPausedActive =
        state.activeMessageId == messageId &&
        state.status == TtsPlaybackStatus.paused;
    if (isPausedActive) {
      await resume();
      return;
    }

    final isCurrentlyActive =
        state.activeMessageId == messageId &&
        state.status != TtsPlaybackStatus.idle &&
        state.status != TtsPlaybackStatus.error &&
        state.status != TtsPlaybackStatus.paused;

    if (isCurrentlyActive) {
      await stop();
      return;
    }

    if (text.trim().isEmpty) {
      return;
    }

    final epoch = ++_requestEpoch;
    _lastRequest = (messageId: messageId, text: text);
    state = state.copyWith(activeMessageId: messageId);
    final available = await _ensureInitialized();
    if (!ref.mounted || epoch != _requestEpoch) return;
    if (!available) {
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(
        status: TtsPlaybackStatus.error,
        errorMessage: 'Text-to-speech unavailable',
        activeMessageId: messageId,
      );
      return;
    }

    // Finish the previous cancellation before publishing the playing state;
    // its callback clears the active message id (issue #709).
    if (!await _stopPlayback(epoch)) return;
    _lastRequest = (messageId: messageId, text: text);

    _playbackClock.reset();

    // Prepare sentence split for highlighting
    final cleanText = ConduitMarkdownPreprocessor.cleanText(text);
    final sentences = _service.splitTextForSpeech(cleanText, seekable: true);
    final offsets = _computeOffsets(cleanText, sentences);

    state = state.copyWith(
      status: TtsPlaybackStatus.loading,
      elapsed: Duration.zero,
      duration: Duration.zero,
      canSeek: false,
      seeking: false,
      activeMessageId: messageId,
      clearErrorMessage: true,
      sentences: sentences,
      sentenceOffsets: offsets,
      activeSentenceIndex: sentences.isEmpty ? -1 : 0,
      clearWord: true,
    );

    try {
      // Convert markdown to clean text for TTS
      if (cleanText.isEmpty) {
        // No speakable content
        if (!ref.mounted) {
          return;
        }
        _lastRequest = null;
        state = state.copyWith(
          status: TtsPlaybackStatus.idle,
          clearActiveMessageId: true,
        );
        return;
      }

      await _service.speak(cleanText, seekable: true);
      if (!ref.mounted || epoch != _requestEpoch) {
        return;
      }
      if (state.status == TtsPlaybackStatus.loading) {
        state = state.copyWith(
          status: TtsPlaybackStatus.speaking,
          canSeek: _service.canSeek,
        );
      }
    } catch (e) {
      if (!ref.mounted || epoch != _requestEpoch) {
        return;
      }
      _handleError(e.toString());
    }
  }

  List<int> _computeOffsets(String source, List<String> sentences) {
    if (sentences.isEmpty) return const [];
    final offsets = <int>[];
    var cursor = 0;
    for (final sentence in sentences) {
      final chunk = sentence.trim();
      if (chunk.isEmpty) {
        offsets.add(cursor);
        continue;
      }
      final index = source.indexOf(chunk, cursor);
      if (index == -1) {
        offsets.add(cursor);
        cursor += chunk.length;
      } else {
        offsets.add(index);
        cursor = index + chunk.length;
      }
    }
    return offsets;
  }

  Future<void> pause() async {
    if (!state.initialized || !state.available) {
      return;
    }
    final epoch = _requestEpoch;
    try {
      await _service.pause();
    } catch (error) {
      if (ref.mounted && epoch == _requestEpoch) {
        _handleError(error.toString());
      }
    }
  }

  Future<void> resume() async {
    if (!state.initialized || !state.available) {
      return;
    }
    final epoch = _requestEpoch;
    try {
      await _service.resume();
    } catch (e) {
      if (!ref.mounted || epoch != _requestEpoch) {
        return;
      }
      _handleError(e.toString());
    }
  }

  Future<void> stop() async {
    final epoch = ++_requestEpoch;
    if (!await _stopPlayback(epoch)) return;
    _lastRequest = null;
    _playbackClock.reset();
    state = state.copyWith(
      status: TtsPlaybackStatus.idle,
      elapsed: Duration.zero,
      canSeek: false,
      seeking: false,
      clearActiveMessageId: true,
      clearErrorMessage: true,
    );
  }

  Future<void> retry() async {
    final request = _lastRequest;
    if (state.status != TtsPlaybackStatus.error || request == null) return;
    await toggleForMessage(messageId: request.messageId, text: request.text);
  }

  Future<bool> _stopPlayback(int epoch) async {
    try {
      await _service.stop();
    } catch (error) {
      if (ref.mounted && epoch == _requestEpoch) {
        _handleError(error.toString());
      }
      return false;
    }
    return ref.mounted && epoch == _requestEpoch;
  }

  Future<void> skip(Duration offset) async {
    if (!state.canSeek || state.seeking || state.isBusy) return;
    final epoch = _requestEpoch;
    final message = state.activeMessageId;
    state = state.copyWith(seeking: true);
    try {
      final position = await _service.seekRelative(offset);
      if (ref.mounted &&
          epoch == _requestEpoch &&
          state.activeMessageId == message &&
          position != null) {
        state = state.copyWith(
          elapsed: position,
          duration: _service.playbackDuration ?? Duration.zero,
        );
      }
    } catch (error) {
      if (ref.mounted && epoch == _requestEpoch) {
        _handleError(error.toString());
      }
    } finally {
      if (ref.mounted && epoch == _requestEpoch) {
        state = state.copyWith(seeking: false, canSeek: _service.canSeek);
      }
    }
  }

  void _startPlaybackClock() {
    if (state.activeMessageId == null || _playbackClock.isRunning) return;
    _playbackClock.start();
    _playbackTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (ref.mounted) {
        state = state.copyWith(
          elapsed: _service.playbackPosition ?? _playbackClock.elapsed,
          duration: _service.playbackDuration ?? Duration.zero,
        );
      }
    });
  }

  void _stopPlaybackClock() {
    _playbackClock.stop();
    _playbackTicker?.cancel();
    _playbackTicker = null;
  }

  void _handleStart() {
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(
      status: TtsPlaybackStatus.speaking,
      canSeek: _service.canSeek,
    );
    _startPlaybackClock();
  }

  void _handleCompletion() {
    if (!ref.mounted) {
      return;
    }
    _lastRequest = null;
    _stopPlaybackClock();
    state = state.copyWith(
      status: TtsPlaybackStatus.idle,
      clearActiveMessageId: true,
    );
  }

  void _handleCancellation() {
    if (!ref.mounted) {
      return;
    }
    _stopPlaybackClock();
    state = state.copyWith(
      status: TtsPlaybackStatus.idle,
      clearActiveMessageId: true,
    );
  }

  void _handlePause() {
    if (!ref.mounted) {
      return;
    }
    _stopPlaybackClock();
    state = state.copyWith(
      status: TtsPlaybackStatus.paused,
      elapsed: _service.playbackPosition ?? _playbackClock.elapsed,
      duration: _service.playbackDuration ?? Duration.zero,
    );
  }

  void _handleContinue() {
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(
      status: TtsPlaybackStatus.speaking,
      canSeek: _service.canSeek,
    );
    _startPlaybackClock();
  }

  void _handleError(String message) {
    if (!ref.mounted) {
      return;
    }
    _stopPlaybackClock();
    state = state.copyWith(
      status: TtsPlaybackStatus.error,
      errorMessage: message,
      activeMessageId: _lastRequest?.messageId,
      clearActiveMessageId: _lastRequest == null,
    );
  }

  void _handleSentenceIndex(int index) {
    if (!ref.mounted) return;
    final clamped = index.clamp(
      -1,
      state.sentences.isEmpty ? -1 : state.sentences.length - 1,
    );
    state = state.copyWith(
      activeSentenceIndex: clamped,
      // clear per-word highlight when sentence switches (server or device)
      clearWord: true,
    );
  }

  void _handleDeviceWordProgress(int start, int end) {
    if (!ref.mounted) return;
    // Word progress offsets are relative to the current chunk/sentence being
    // spoken, NOT the full original text. TtsChunkStarted already sets the
    // correct activeSentenceIndex, so we only update word highlighting here.
    state = state.copyWith(
      wordStartInSentence: start.clamp(0, 1 << 20),
      wordEndInSentence: end.clamp(0, 1 << 20),
    );
  }
}

final textToSpeechServiceProvider = Provider<TextToSpeechService>((ref) {
  BackendConfig? readBackendConfig() {
    return ref
        .read(backendConfigProvider)
        .maybeWhen(data: (value) => value, orElse: () => null);
  }

  // Follows the selected model's backend without rebuilding the service.
  final service = TextToSpeechService(
    serverSpeech: ref.read(serverSpeechProviderProvider),
    backendConfig: readBackendConfig(),
    loadBackendConfig: () async {
      await ref.read(backendConfigProvider.notifier).refresh();
      return readBackendConfig();
    },
  );
  ref.listen(serverSpeechProviderProvider, (_, next) {
    TtsManager.instance.setServerSpeech(next);
  });
  ref.listen(backendConfigProvider, (_, next) {
    service.setBackendConfig(
      next.maybeWhen(data: (value) => value, orElse: () => null),
    );
  });
  ref.onDispose(() {
    unawaited(service.dispose());
  });
  return service;
});

final textToSpeechControllerProvider =
    NotifierProvider<TextToSpeechController, TextToSpeechState>(
      TextToSpeechController.new,
    );
