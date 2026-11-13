import 'dart:async';

import 'package:riverpod/riverpod.dart';
import 'package:clock/clock.dart';

import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';

import 'package:conduit_core/providers/app_providers.dart';

import 'package:conduit_markdown/conduit_markdown.dart';

import 'spoken_word_estimate.dart';
import 'text_to_speech_service.dart';
import 'tts_manager.dart';

/// Whether the device engine reads aloud live, reporting each word as it
/// says it, rather than rendering audio clips the reading can scrub. The
/// phone renders clips (its bar seeks by time); the desktop speaks live
/// and moves from sentence to sentence. Server speech is clips either way.
final readAloudLiveDeviceSpeechProvider = Provider<bool>((ref) => false);

final _ttsDetailsPattern = RegExp(
  r'<details[^>]*>[\s\S]*?<\/details>',
  caseSensitive: false,
);

/// What reading [raw] (a reply's markdown) aloud says: the text without
/// markup, folded sections (thoughts, tool calls) or code fences' syntax.
String readAloudTextOf(String raw) {
  if (raw.trim().isEmpty) {
    return '';
  }

  final sanitized = ConduitMarkdownPreprocessor.sanitize(raw);
  final withoutDetails = sanitized.replaceAll(_ttsDetailsPattern, '');
  return ConduitMarkdownPreprocessor.cleanText(withoutDetails).trim();
}

enum TtsPlaybackStatus { idle, initializing, loading, speaking, paused, error }

class TextToSpeechState {
  final bool initialized;
  final bool available;
  final TtsPlaybackStatus status;
  final String? activeMessageId;

  /// The chat the reading's message belongs to, when the host names it.
  final String? activeChatId;
  final String? errorMessage;
  final Duration elapsed;
  final Duration duration;
  final bool canSeek;

  /// Whether the reading can move from sentence to sentence.
  final bool canSeekSentences;
  final bool seeking;
  final List<String> sentences;
  final List<int> sentenceOffsets; // start indices in full text
  final int activeSentenceIndex; // -1 when none
  // The word being spoken, as offsets in the active sentence: reported by the
  // device engine speaking live, estimated from the position for audio clips.
  final int? wordStartInSentence;
  final int? wordEndInSentence;

  const TextToSpeechState({
    this.initialized = false,
    this.available = false,
    this.status = TtsPlaybackStatus.idle,
    this.activeMessageId,
    this.activeChatId,
    this.errorMessage,
    this.elapsed = Duration.zero,
    this.duration = Duration.zero,
    this.canSeek = false,
    this.canSeekSentences = false,
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
    String? activeChatId,
    String? errorMessage,
    bool clearErrorMessage = false,
    Duration? elapsed,
    Duration? duration,
    bool? canSeek,
    bool? canSeekSentences,
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
      // The chat goes with its message.
      activeChatId: clearActiveMessageId
          ? null
          : activeChatId ?? this.activeChatId,
      errorMessage: clearErrorMessage
          ? null
          : errorMessage ?? this.errorMessage,
      elapsed: elapsed ?? this.elapsed,
      duration: duration ?? this.duration,
      canSeek: canSeek ?? this.canSeek,
      canSeekSentences: canSeekSentences ?? this.canSeekSentences,
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
  /// How often audio clips publish their position and the word estimated
  /// from it.
  static const _audioProgressInterval = Duration(milliseconds: 150);

  late TextToSpeechService _service;
  bool _handlersBound = false;
  late Stopwatch _playbackClock;
  Timer? _playbackTicker;
  Future<bool>? _initializationFuture;
  int _requestEpoch = 0;
  ({String messageId, String text, String? chatId})? _lastRequest;
  Duration? _pendingSeek;

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
          speed: next.ttsSpeed,
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
          speed: settings.ttsSpeed,
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
          );
          return false;
        });

    _initializationFuture = future;
    future.whenComplete(() {
      _initializationFuture = null;
    });

    return future;
  }

  /// The chat [readAloud] names for the reading it starts.
  String? _chatForNext;

  /// [toggleForMessage] for an answer in chat [chatId], which the reading
  /// keeps ([TextToSpeechState.activeChatId]): the desktop's playback bar
  /// shows in that chat only.
  Future<void> readAloud({
    required String messageId,
    required String text,
    required String chatId,
  }) {
    _chatForNext = chatId;
    return toggleForMessage(messageId: messageId, text: text);
  }

  Future<void> toggleForMessage({
    required String messageId,
    required String text,
  }) async {
    final chatId = _chatForNext;
    _chatForNext = null;
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
    _lastRequest = (messageId: messageId, text: text, chatId: chatId);
    _pendingSeek = null;
    state = state.copyWith(activeMessageId: messageId, activeChatId: chatId);
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
    _lastRequest = (messageId: messageId, text: text, chatId: chatId);

    _playbackClock.reset();

    // Prepare sentence split for highlighting
    final cleanText = ConduitMarkdownPreprocessor.cleanText(text);
    final seekable =
        !(ref.read(readAloudLiveDeviceSpeechProvider) &&
            !_service.prefersServerEngine);
    final sentences = _service.splitTextForSpeech(
      cleanText,
      seekable: seekable,
    );
    final offsets = _computeOffsets(cleanText, sentences);

    state = state.copyWith(
      status: TtsPlaybackStatus.loading,
      elapsed: Duration.zero,
      duration: Duration.zero,
      canSeek: false,
      canSeekSentences: false,
      seeking: false,
      activeMessageId: messageId,
      activeChatId: chatId,
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

      await _service.speak(cleanText, seekable: seekable);
      if (!ref.mounted || epoch != _requestEpoch) {
        return;
      }
      if (state.status == TtsPlaybackStatus.loading) {
        state = state.copyWith(
          status: TtsPlaybackStatus.speaking,
          canSeek: _service.canSeek,
          canSeekSentences: _sentenceSeekable,
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
      if (ref.mounted &&
          epoch == _requestEpoch &&
          state.seeking &&
          (state.status == TtsPlaybackStatus.speaking ||
              state.status == TtsPlaybackStatus.paused)) {
        _handlePause(userInitiated: true);
      }
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
    _pendingSeek = null;
    if (!await _stopPlayback(epoch)) return;
    _lastRequest = null;
    _playbackClock.reset();
    state = state.copyWith(
      status: TtsPlaybackStatus.idle,
      elapsed: Duration.zero,
      canSeek: false,
      canSeekSentences: false,
      seeking: false,
      clearActiveMessageId: true,
      clearErrorMessage: true,
    );
  }

  Future<void> retry() async {
    final request = _lastRequest;
    if (state.status != TtsPlaybackStatus.error || request == null) return;
    _chatForNext = request.chatId;
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

  Future<void> skip(Duration offset) =>
      _seek(() => _service.seekRelative(offset));

  /// Moves the reading to [position], as when scrubbing. A position asked
  /// for while a seek runs replaces any earlier one and follows it.
  Future<void> seekTo(Duration position) async {
    if (state.seeking) {
      _pendingSeek = position;
      return;
    }
    await _seek(() => _service.seekTo(position));
    final pending = _pendingSeek;
    _pendingSeek = null;
    if (pending != null && ref.mounted) await seekTo(pending);
  }

  /// Whether the reading can move from sentence to sentence: a live device
  /// reading asks its engine; clips can once they are seekable.
  bool get _sentenceSeekable => ref.read(readAloudLiveDeviceSpeechProvider)
      ? _service.canSeekChunks
      : _service.canSeek;

  /// Moves the reading to the start of sentence [index]: what clicking a
  /// sentence does. A paused reading stays paused there.
  Future<void> seekToSentence(int index) async {
    if (state.seeking ||
        state.isBusy ||
        state.activeMessageId == null ||
        !_sentenceSeekable ||
        state.sentences.isEmpty) {
      return;
    }
    final target = index.clamp(0, state.sentences.length - 1);
    final epoch = _requestEpoch;
    final message = state.activeMessageId;
    state = state.copyWith(seeking: true);
    try {
      final moved = await _service.seekToChunk(target);
      if (ref.mounted &&
          epoch == _requestEpoch &&
          state.activeMessageId == message &&
          moved != null) {
        state = state.copyWith(
          activeSentenceIndex: moved,
          clearWord: true,
          elapsed: _service.playbackPosition ?? state.elapsed,
          duration: _service.playbackDuration ?? state.duration,
        );
      }
    } catch (error) {
      if (ref.mounted && epoch == _requestEpoch) {
        _handleError(error.toString());
      }
    } finally {
      if (ref.mounted && epoch == _requestEpoch) {
        state = state.copyWith(
          seeking: false,
          canSeek: _service.canSeek,
          canSeekSentences: _sentenceSeekable,
        );
      }
    }
  }

  /// Moves [delta] sentences on (back when negative): Next and Previous
  /// Sentence. Past the last sentence there is nowhere to go.
  Future<void> skipSentences(int delta) async {
    final current = state.activeSentenceIndex;
    if (current < 0) return;
    final target = current + delta;
    if (target >= state.sentences.length) return;
    await seekToSentence(target < 0 ? 0 : target);
  }

  Future<void> _seek(Future<Duration?> Function() seek) async {
    if (!state.canSeek || state.seeking || state.isBusy) return;
    final epoch = _requestEpoch;
    final message = state.activeMessageId;
    state = state.copyWith(seeking: true);
    try {
      final position = await seek();
      if (ref.mounted &&
          epoch == _requestEpoch &&
          state.activeMessageId == message &&
          position != null) {
        state = state.copyWith(
          elapsed: position,
          duration: _service.playbackDuration ?? Duration.zero,
        );
        if (!_service.reportsSpokenWords) {
          final word = _estimatedWord();
          state = state.copyWith(
            wordStartInSentence: word?.start,
            wordEndInSentence: word?.end,
          );
        }
      }
    } catch (error) {
      if (ref.mounted && epoch == _requestEpoch) {
        _handleError(error.toString());
      }
    } finally {
      if (ref.mounted && epoch == _requestEpoch) {
        state = state.copyWith(
          seeking: false,
          canSeek: _service.canSeek,
          canSeekSentences: _sentenceSeekable,
        );
      }
    }
  }

  void _startPlaybackClock() {
    if (state.activeMessageId == null || _playbackClock.isRunning) return;
    _playbackClock.start();
    // The device engine speaking live reports each word itself. Audio clips
    // report none, so they are followed closely enough to estimate the word.
    final interval = _service.reportsSpokenWords
        ? const Duration(seconds: 1)
        : _audioProgressInterval;
    _playbackTicker = Timer.periodic(interval, (_) => _publishProgress());
  }

  /// Publishes the playback position and, for audio clips, the word
  /// estimated from it.
  void _publishProgress() {
    if (!ref.mounted) return;
    final word = _service.reportsSpokenWords ? null : _estimatedWord();
    state = state.copyWith(
      elapsed: _service.playbackPosition ?? _playbackClock.elapsed,
      duration: _service.playbackDuration ?? Duration.zero,
      wordStartInSentence: word?.start,
      wordEndInSentence: word?.end,
    );
  }

  /// The word of the active sentence at the clip's position, weighted by
  /// characters; null while the clip and the sentence disagree.
  ({int start, int end})? _estimatedWord() {
    final progress = _service.chunkProgress;
    final index = state.activeSentenceIndex;
    if (progress == null ||
        progress.index != index ||
        index < 0 ||
        index >= state.sentences.length) {
      return null;
    }
    return estimateSpokenWord(
      state.sentences[index],
      progress.position.inMicroseconds / progress.duration.inMicroseconds,
    );
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
      canSeekSentences: _sentenceSeekable,
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

  void _handlePause({bool userInitiated = false}) {
    if (!ref.mounted || (state.seeking && !userInitiated)) {
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
      canSeekSentences: _sentenceSeekable,
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
      canSeekSentences: _sentenceSeekable,
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
