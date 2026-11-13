import 'dart:io';
import 'dart:typed_data';

import 'package:conduitd/src/local_whisper.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

/// A WAV of [samples] at [rate], [channels] interleaved, 16-bit.
Uint8List _wav(List<double> samples, {int rate = 16000, int channels = 1}) {
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, (samples[i] * 32767).round(), Endian.little);
  }
  final header = ByteData(44);
  void ascii(int at, String text) {
    for (var i = 0; i < 4; i++) {
      header.setUint8(at + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + samples.length * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, rate, Endian.little);
  header.setUint32(28, rate * channels * 2, Endian.little);
  header.setUint16(32, channels * 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, samples.length * 2, Endian.little);
  return Uint8List.fromList(<int>[
    ...header.buffer.asUint8List(),
    ...data.buffer.asUint8List(),
  ]);
}

void main() {
  group('decodeWavTo16kMono', () {
    test('passes 16 kHz mono through', () {
      final out = decodeWavTo16kMono(_wav(<double>[0, 0.5, -0.5, 0.25]));
      expect(out, hasLength(4));
      expect(out[1], closeTo(0.5, 0.001));
      expect(out[2], closeTo(-0.5, 0.001));
    });

    test('mixes stereo down and resamples 48 kHz to 16 kHz', () {
      // 48,000 stereo frames: one second.
      final interleaved = <double>[
        for (var i = 0; i < 48000; i++) ...<double>[0.5, -0.5],
      ];
      final out = decodeWavTo16kMono(
        _wav(interleaved, rate: 48000, channels: 2),
      );
      expect(out, hasLength(16000));
      expect(out[100], closeTo(0, 0.001));
    });

    test('refuses what is not a WAV', () {
      expect(
        () => decodeWavTo16kMono(Uint8List.fromList(<int>[1, 2, 3])),
        throwsFormatException,
      );
    });
  });

  group('WhisperModelStore', () {
    late Directory dir;
    late HttpServer server;
    final body = Uint8List.fromList(List<int>.generate(4096, (i) => i % 251));

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('conduit-whisper-');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        request.response.add(body);
        request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      dir.deleteSync(recursive: true);
    });

    Uri source() => Uri.parse('http://127.0.0.1:${server.port}/model.bin');

    test('keeps a download whose checksum is right', () async {
      final model = WhisperModel(
        id: 'test',
        name: 'Test',
        sizeBytes: body.length,
        sha256: sha256.convert(body).toString(),
      );
      final store = WhisperModelStore(dir);
      var reports = 0;
      await store.download(
        model,
        source: source(),
        onProgress: () => reports++,
      );
      expect(store.isDownloaded(model), isTrue);
      expect(reports, greaterThanOrEqualTo(2));
      expect(store.downloading, isEmpty);
      store.delete(model);
      expect(store.isDownloaded(model), isFalse);
    });

    test('throws away a download that is not the file expected', () async {
      final model = WhisperModel(
        id: 'test',
        name: 'Test',
        sizeBytes: body.length,
        sha256: '0' * 64,
      );
      final store = WhisperModelStore(dir);
      await expectLater(
        store.download(model, source: source(), onProgress: () {}),
        throwsStateError,
      );
      expect(store.isDownloaded(model), isFalse);
      expect(dir.listSync(), isEmpty, reason: 'no partial file is left');
    });
  });

  // The real thing, when a built library and a model are at hand:
  // CONDUIT_WHISPER_LIB, CONDUIT_WHISPER_MODEL, and CONDUIT_SPEECH_SAMPLE
  // (a WAV of "The quick brown fox jumps over the lazy dog.").
  final library = Platform.environment['CONDUIT_WHISPER_LIB'];
  final model = Platform.environment['CONDUIT_WHISPER_MODEL'];
  final sample = Platform.environment['CONDUIT_SPEECH_SAMPLE'];
  test(
    'transcribes speech on this computer',
    () async {
      final text = await whisperTranscribe(
        library: library!,
        modelPath: model!,
        samples: decodeWavTo16kMono(File(sample!).readAsBytesSync()),
        language: 'en',
      );
      expect(text.toLowerCase(), contains('quick brown fox'));
    },
    skip: library == null || model == null || sample == null
        ? 'set CONDUIT_WHISPER_LIB, CONDUIT_WHISPER_MODEL and CONDUIT_SPEECH_SAMPLE'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
