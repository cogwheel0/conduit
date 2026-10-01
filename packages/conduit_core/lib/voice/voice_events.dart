/// What the speech recognizer and the speech synthesizer report to a voice
/// session.
///
/// Plain values, so the voice-mode controller can live in the core and each
/// app's recognizer and speech engine can feed it. They moved here from the
/// Flutter app's `voice_input_service.dart` and `tts_manager.dart`, which
/// re-export them under their old names.
library;

/// A transcript update from the recognizer: the text so far, and whether the
/// recognizer considers it finished.
class VoiceTranscriptEvent {
  const VoiceTranscriptEvent({required this.text, required this.isFinal});

  final String text;
  final bool isFinal;
}

/// Base class for all text-to-speech events.
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
