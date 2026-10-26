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

  Float32List _context;

  /// Number of samples carried from one frame to the next.
  int get length => _context.length;

  /// Returns [frame] with the previous frame's tail in front of it, and keeps
  /// the tail of the result for the next frame.
  Float32List prepend(Float32List frame) {
    final input = Float32List(_context.length + frame.length)
      ..setAll(0, _context)
      ..setAll(_context.length, frame);
    _context = input.sublist(input.length - _context.length);
    return input;
  }

  /// Forgets the previous frame, for a new stream.
  void reset() => _context = Float32List(_context.length);
}
