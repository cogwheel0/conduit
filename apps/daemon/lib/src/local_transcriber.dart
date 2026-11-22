import 'dart:typed_data';

/// A model a [LocalTranscriber] offers.
final class LocalSpeechModel {
  const LocalSpeechModel({
    required this.id,
    required this.name,
    required this.sizeBytes,
    this.englishOnly = false,
  });

  final String id;
  final String name;
  final int sizeBytes;

  /// Faster and better at English; hears nothing else.
  final bool englishOnly;
}

/// Speech to text on this device, which the host supplies when it has an
/// engine. Without one, the voice service offers no local transcription.
abstract interface class LocalTranscriber {
  /// Whether the engine runs in this build. Its models can be listed and
  /// downloaded either way.
  bool get available;

  /// The models on offer.
  List<LocalSpeechModel> get models;

  bool isDownloaded(String modelId);

  /// Bytes received so far while [modelId] downloads; null otherwise.
  int? receivedBytes(String modelId);

  /// Downloads [modelId], calling [onProgress] as it goes. A [StateError]
  /// means the file was not the one expected.
  Future<void> download(String modelId, {required void Function() onProgress});

  /// Deletes [modelId], or stops its download.
  void delete(String modelId);

  /// Lets go of a loaded model.
  void unload();

  /// The text of [wav] (16 kHz WAV) by [modelId]. A [FormatException] means
  /// [wav] is not audio the engine reads.
  Future<String> transcribe(String modelId, Uint8List wav, {String? language});
}
