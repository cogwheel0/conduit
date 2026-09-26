import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// Speech recognition on this computer: whisper.cpp through
/// `libconduit_whisper`, with models downloaded when the user asks.

/// A whisper.cpp model the user may download.
class WhisperModel {
  const WhisperModel({
    required this.id,
    required this.name,
    required this.sizeBytes,
    required this.sha256,
    this.englishOnly = false,
  });

  final String id;
  final String name;
  final int sizeBytes;
  final String sha256;

  /// Faster and better at English; hears nothing else.
  final bool englishOnly;

  String get url =>
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$id.bin';

  String get fileName => 'ggml-$id.bin';
}

/// The models on offer: small enough to download and fast enough to run on
/// a CPU. Sizes and checksums are Hugging Face's, for these exact files.
const List<WhisperModel> whisperModels = <WhisperModel>[
  WhisperModel(
    id: 'tiny.en',
    name: 'Tiny (English)',
    sizeBytes: 77704715,
    sha256: '921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f',
    englishOnly: true,
  ),
  WhisperModel(
    id: 'tiny',
    name: 'Tiny',
    sizeBytes: 77691713,
    sha256: 'be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21',
  ),
  WhisperModel(
    id: 'base.en',
    name: 'Base (English)',
    sizeBytes: 147964211,
    sha256: 'a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002',
    englishOnly: true,
  ),
  WhisperModel(
    id: 'base',
    name: 'Base',
    sizeBytes: 147951465,
    sha256: '60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe',
  ),
  WhisperModel(
    id: 'small.en',
    name: 'Small (English)',
    sizeBytes: 487614201,
    sha256: 'c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d',
    englishOnly: true,
  ),
  WhisperModel(
    id: 'small',
    name: 'Small',
    sizeBytes: 487601967,
    sha256: '1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b',
  ),
];

WhisperModel? whisperModel(String id) {
  for (final model in whisperModels) {
    if (model.id == id) return model;
  }
  return null;
}

/// The library's file name on this OS.
String get whisperLibraryName => Platform.isWindows
    ? 'conduit_whisper.dll'
    : Platform.isMacOS
    ? 'libconduit_whisper.dylib'
    : 'libconduit_whisper.so';

/// Where `libconduit_whisper` is: `CONDUIT_WHISPER_LIB`, else next to the
/// daemon in its bundle (`bin/../lib/`). Null when this build has none.
String? findWhisperLibrary({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final given = env['CONDUIT_WHISPER_LIB'];
  if (given != null && given.isNotEmpty) {
    return File(given).existsSync() ? given : null;
  }
  final bundled = p.join(
    File(Platform.resolvedExecutable).parent.parent.path,
    'lib',
    whisperLibraryName,
  );
  return File(bundled).existsSync() ? bundled : null;
}

typedef _TranscribeC = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Float>,
  Int32,
  Pointer<Utf8>,
  Int32,
);
typedef _TranscribeDart = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Float>,
  int,
  Pointer<Utf8>,
  int,
);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);
typedef _UnloadC = Void Function();
typedef _UnloadDart = void Function();

/// Transcribes 16 kHz mono [samples] with the model at [modelPath], in an
/// isolate of its own: whisper holds the thread for as long as it takes,
/// and the daemon's event loop must keep answering meanwhile.
Future<String> whisperTranscribe({
  required String library,
  required String modelPath,
  required Float32List samples,
  String? language,
  int threads = 0,
}) {
  final cores = threads > 0
      ? threads
      : math.max(1, Platform.numberOfProcessors ~/ 2);
  return Isolate.run(() {
    final lib = DynamicLibrary.open(library);
    final transcribe = lib.lookupFunction<_TranscribeC, _TranscribeDart>(
      'cw_transcribe',
    );
    final free = lib.lookupFunction<_FreeC, _FreeDart>('cw_free');
    final path = modelPath.toNativeUtf8();
    final lang = (language ?? '').toNativeUtf8();
    final pcm = malloc<Float>(samples.length);
    try {
      pcm.asTypedList(samples.length).setAll(0, samples);
      final text = transcribe(path, pcm, samples.length, lang, cores);
      if (text == nullptr) {
        throw StateError('the model could not be loaded or run');
      }
      try {
        return text.toDartString().trim();
      } finally {
        free(text);
      }
    } finally {
      malloc.free(path);
      malloc.free(lang);
      malloc.free(pcm);
    }
  });
}

/// Lets go of the loaded model, so its file can be deleted.
void whisperUnload(String library) {
  try {
    DynamicLibrary.open(library)
        .lookupFunction<_UnloadC, _UnloadDart>('cw_unload')();
  } on Object {
    // Not loaded, or no library: nothing to let go of.
  }
}

/// 16 kHz mono samples from a WAV file: 16-bit PCM or 32-bit float, any
/// channel count and sample rate.
Float32List decodeWavTo16kMono(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  String tag(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));
  if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
    throw const FormatException('not a WAV file');
  }
  var format = 0, channels = 0, rate = 0, bits = 0;
  int? dataAt, dataLength;
  var at = 12;
  while (at + 8 <= bytes.length) {
    final id = tag(at);
    final size = data.getUint32(at + 4, Endian.little);
    final body = at + 8;
    if (id == 'fmt ') {
      format = data.getUint16(body, Endian.little);
      channels = data.getUint16(body + 2, Endian.little);
      rate = data.getUint32(body + 4, Endian.little);
      bits = data.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      dataAt = body;
      dataLength = math.min(size, bytes.length - body);
      break;
    }
    at = body + size + (size.isOdd ? 1 : 0);
  }
  if (dataAt == null || channels == 0 || rate == 0) {
    throw const FormatException('a WAV file with no audio');
  }
  final pcm = format == 1 && bits == 16;
  final float = format == 3 && bits == 32;
  if (!pcm && !float) {
    throw FormatException('WAV format $format at $bits bits is not supported');
  }
  final frameBytes = (bits ~/ 8) * channels;
  final frames = dataLength! ~/ frameBytes;
  final mono = Float32List(frames);
  for (var i = 0; i < frames; i++) {
    var sum = 0.0;
    for (var c = 0; c < channels; c++) {
      final offset = dataAt + i * frameBytes + c * (bits ~/ 8);
      sum += pcm
          ? data.getInt16(offset, Endian.little) / 32768.0
          : data.getFloat32(offset, Endian.little);
    }
    mono[i] = sum / channels;
  }
  if (rate == 16000) return mono;
  // Linear resampling: speech survives it, and it needs no filter design.
  final outLength = (frames * 16000 / rate).floor();
  final out = Float32List(outLength);
  final step = rate / 16000;
  for (var i = 0; i < outLength; i++) {
    final position = i * step;
    final left = position.floor();
    final right = math.min(left + 1, frames - 1);
    final fraction = position - left;
    out[i] = mono[left] * (1 - fraction) + mono[right] * fraction;
  }
  return out;
}

/// The downloaded models, in `<userData>/whisper/`.
class WhisperModelStore {
  WhisperModelStore(this.directory);

  final Directory directory;

  /// Bytes received so far, by model id, while downloading.
  final Map<String, int> downloading = <String, int>{};
  final Map<String, HttpClient> _clients = <String, HttpClient>{};

  String pathFor(WhisperModel model) => p.join(directory.path, model.fileName);

  bool isDownloaded(WhisperModel model) {
    final file = File(pathFor(model));
    return file.existsSync() && file.lengthSync() == model.sizeBytes;
  }

  /// Downloads [model], reporting progress, and keeps it only if its
  /// SHA-256 is the one expected. Resolves when it is on disk.
  Future<void> download(
    WhisperModel model, {
    required void Function() onProgress,
    Uri? source,
  }) async {
    if (downloading.containsKey(model.id) || isDownloaded(model)) return;
    directory.createSync(recursive: true);
    final part = File('${pathFor(model)}.part');
    final client = HttpClient()..userAgent = 'Conduit Desktop';
    _clients[model.id] = client;
    downloading[model.id] = 0;
    onProgress();
    IOSink? sink;
    try {
      final request = await client.getUrl(source ?? Uri.parse(model.url));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}', uri: request.uri);
      }
      sink = part.openWrite();
      final hash = _DigestSink();
      final hasher = sha256.startChunkedConversion(hash);
      var received = 0;
      var lastReport = DateTime.now();
      await for (final chunk in response) {
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        downloading[model.id] = received;
        if (DateTime.now().difference(lastReport) >
            const Duration(milliseconds: 250)) {
          lastReport = DateTime.now();
          onProgress();
        }
      }
      await sink.close();
      sink = null;
      hasher.close();
      if (hash.value?.toString() != model.sha256) {
        throw StateError('the download was not the file expected');
      }
      part.renameSync(pathFor(model));
    } finally {
      await sink?.close();
      if (part.existsSync()) part.deleteSync();
      client.close(force: true);
      _clients.remove(model.id);
      downloading.remove(model.id);
      onProgress();
    }
  }

  /// Stops a download in progress.
  void cancel(WhisperModel model) => _clients[model.id]?.close(force: true);

  void delete(WhisperModel model) {
    cancel(model);
    final file = File(pathFor(model));
    if (file.existsSync()) file.deleteSync();
  }
}

/// Keeps the one digest a chunked hash produces.
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
