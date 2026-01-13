import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

/// A [StreamAudioSource] that plays audio from raw bytes in memory.
///
/// This is useful for playing audio data that has been loaded from a network
/// response or other byte stream, such as server-side TTS audio.
///
/// Example:
/// ```dart
/// final audioPlayer = AudioPlayer();
/// final audioBytes = Uint8List.fromList([...]);
/// await audioPlayer.setAudioSource(
///   BytesAudioSource(audioBytes, 'audio/mpeg'),
/// );
/// await audioPlayer.play();
/// ```
class BytesAudioSource extends StreamAudioSource {
  /// Creates a [BytesAudioSource] from the given bytes and MIME type.
  ///
  /// The [mimeType] should be a valid audio MIME type such as:
  /// - `audio/mpeg` for MP3
  /// - `audio/wav` for WAV
  /// - `audio/mp4` or `audio/aac` for AAC/M4A
  /// - `audio/ogg` for Ogg Vorbis
  BytesAudioSource(this._bytes, this._mimeType);

  final Uint8List _bytes;
  final String _mimeType;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= _bytes.length;
    
    // Assert valid bounds in debug mode to catch bugs early, but don't
    // crash in release. just_audio should always pass valid ranges.
    assert(
      start >= 0 && start <= _bytes.length,
      'BytesAudioSource: start ($start) out of bounds [0, ${_bytes.length}]',
    );
    assert(
      end >= start && end <= _bytes.length,
      'BytesAudioSource: end ($end) out of bounds [$start, ${_bytes.length}]',
    );
    
    return StreamAudioResponse(
      sourceLength: _bytes.length,
      contentLength: end - start,
      offset: start,
      stream: Stream.value(_bytes.sublist(start, end)),
      contentType: _mimeType,
    );
  }
}
