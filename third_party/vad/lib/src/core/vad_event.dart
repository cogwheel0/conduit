// lib/src/vad_event.dart

// Dart imports:
import 'dart:typed_data';

/// Voice Activity Detection event types for real-time audio processing
enum VadEventType {
  /// Initial speech detection - fired when speech probability exceeds threshold
  start,

  /// Validated speech start - fired after minimum speech frames are detected
  realStart,

  /// Speech end event - fired when speech concludes with audio data
  end,

  /// Frame processing event - emitted for each audio frame with probabilities
  frameProcessed,

  /// False positive detection - speech ended before minimum frame requirement
  misfire,

  /// Error during VAD processing
  error,

  /// Audio chunk event - emitted when numFramesToEmit frames accumulate during speech
  chunk,
}

/// Speech probability scores from VAD model inference
class SpeechProbabilities {
  /// Probability that the audio frame contains speech (0.0 to 1.0)
  final double isSpeech;

  /// Probability that the audio frame does not contain speech (0.0 to 1.0)
  final double notSpeech;

  /// Creates speech probability scores
  SpeechProbabilities({required this.isSpeech, required this.notSpeech});
}

/// Voice Activity Detection event containing processing results and audio data
class VadEvent {
  /// The type of VAD event that occurred
  final VadEventType type;

  /// Timestamp in seconds when the event occurred
  final double timestamp;

  /// Human-readable description of the event
  final String message;

  /// Raw audio data for speech segments (available for 'end' and 'chunk' events)
  final Uint8List? audioData;

  /// Speech probability scores (available for 'frameProcessed' events)
  final SpeechProbabilities? probabilities;

  /// Raw audio frame data as floating point values (available for 'frameProcessed' events)
  final List<double>? frameData;

  /// Indicates if this is the final chunk in a sequence (only available for 'chunk' events)
  final bool? isFinal;

  /// Creates a VAD event with the specified parameters
  VadEvent({
    required this.type,
    required this.timestamp,
    required this.message,
    this.audioData,
    this.probabilities,
    this.frameData,
    this.isFinal,
  });
}
