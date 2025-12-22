import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/settings_service.dart';
import '../../../core/providers/app_providers.dart';
import '../../../shared/widgets/markdown/markdown_preprocessor.dart';
import '../services/text_to_speech_service.dart';

enum TtsPlaybackStatus { idle, initializing, loading, speaking, paused, error }

class TextToSpeechState {
  final bool initialized;
  final bool available;
  final TtsPlaybackStatus status;
  final String? activeMessageId;
  final String? errorMessage;
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
  Future<bool>? _initializationFuture;

  @override
  TextToSpeechState build() {
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
    if (text.trim().isEmpty) {
      return;
    }

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

    final available = await _ensureInitialized();
    if (!available) {
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(
        status: TtsPlaybackStatus.error,
        errorMessage: 'Text-to-speech unavailable',
        clearActiveMessageId: true,
      );
      return;
    }

    // Prepare sentence split for highlighting
    final cleanText = ConduitMarkdownPreprocessor.toPlainText(text);
    final sentences = _service.splitTextForSpeech(cleanText);
    final offsets = _computeOffsets(cleanText, sentences);

    state = state.copyWith(
      status: TtsPlaybackStatus.loading,
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
        state = state.copyWith(
          status: TtsPlaybackStatus.idle,
          clearActiveMessageId: true,
        );
        return;
      }

      await _service.speak(cleanText);
      if (!ref.mounted) {
        return;
      }
      if (state.status == TtsPlaybackStatus.loading) {
        state = state.copyWith(status: TtsPlaybackStatus.speaking);
      }
    } catch (e) {
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(
        status: TtsPlaybackStatus.error,
        errorMessage: e.toString(),
        clearActiveMessageId: true,
      );
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
    await _service.pause();
  }

  Future<void> resume() async {
    if (!state.initialized || !state.available) {
      return;
    }
    try {
      await _service.resume();
    } catch (e) {
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(
        status: TtsPlaybackStatus.error,
        errorMessage: e.toString(),
        clearActiveMessageId: true,
      );
    }
  }

  Future<void> stop() async {
    await _service.stop();
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(
      status: TtsPlaybackStatus.idle,
      clearActiveMessageId: true,
      clearErrorMessage: true,
    );
  }

  void _handleStart() {
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(status: TtsPlaybackStatus.speaking);
  }

  void _handleCompletion() {
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(
      status: TtsPlaybackStatus.idle,
      clearActiveMessageId: true,
    );
  }

  void _handleCancellation() {
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(
      status: TtsPlaybackStatus.idle,
      clearActiveMessageId: true,
    );
  }

  void _handlePause() {
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(status: TtsPlaybackStatus.paused);
  }

  void _handleContinue() {
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(status: TtsPlaybackStatus.speaking);
  }

  void _handleError(String message) {
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(
      status: TtsPlaybackStatus.error,
      errorMessage: message,
      clearActiveMessageId: true,
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
  final api = ref.watch(apiServiceProvider);
  final service = TextToSpeechService(api: api);
  ref.onDispose(() {
    unawaited(service.dispose());
  });
  return service;
});

final textToSpeechControllerProvider =
    NotifierProvider<TextToSpeechController, TextToSpeechState>(
      TextToSpeechController.new,
    );
