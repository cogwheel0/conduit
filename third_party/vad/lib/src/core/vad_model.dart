import 'dart:typed_data';

import 'package:vad/src/core/vad_event.dart';

/// A class that represents a VAD model.
abstract class VadModel {
  /// Processes a frame of audio data and returns the speech probabilities.
  Future<SpeechProbabilities> process(Float32List frame);

  /// Resets the state of the model.
  void resetState();

  /// Releases the model.
  Future<void> release();
}
