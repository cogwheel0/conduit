// lib/src/platform/native/inference/silero_v5_context.dart

// Dart imports:
import 'dart:typed_data';

/// The audio Silero v5 expects in front of each frame.
///
/// Silero v5 scores a 512-sample frame (16 kHz) together with the last 64
/// samples of the frame before it; the reference implementation
/// (snakers4/silero-vad, `OnnxWrapper`) prepends them on every call. Without
/// them the model scores quiet speech as silence.
class SileroV5Context {
  /// Creates an all-zero context sized for [sampleRate], as the reference
  /// implementation starts.
  SileroV5Context(int sampleRate)
      : _context = Float32List(sampleRate == 16000 ? 64 : 32);

  final Float32List _context;

  /// Number of samples carried from one frame to the next.
  int get length => _context.length;

  /// Returns [frame] with the previous frame's tail in front of it, and keeps
  /// the tail of the result for the next frame.
  Float32List prepend(Float32List frame) {
    final input = Float32List(_context.length + frame.length);
    prependInto(frame, input);
    return input;
  }

  /// Writes the previous frame's tail followed by [frame] into [target], and
  /// keeps the tail of the result for the next frame.
  void prependInto(Float32List frame, Float32List target) {
    final contextLength = _context.length;
    final totalLength = contextLength + frame.length;
    if (target.length != totalLength) {
      throw ArgumentError.value(
        target.length,
        'target.length',
        'Expected $totalLength samples',
      );
    }
    target.setRange(0, contextLength, _context);
    target.setRange(contextLength, totalLength, frame);
    _context.setRange(0, contextLength, target, frame.length);
  }

  /// Forgets the previous frame, for a new stream.
  void reset() => _context.fillRange(0, _context.length, 0.0);
}
