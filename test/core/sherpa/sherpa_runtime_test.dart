import 'dart:io';

import 'package:conduit/core/sherpa/sherpa_catalog.dart';
import 'package:conduit/core/sherpa/sherpa_model.dart';
import 'package:conduit/core/sherpa/sherpa_runtime.dart';
import 'package:conduit/core/sherpa/sherpa_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('disposed STT workers cannot spawn replacement isolates', () async {
    final worker = SherpaSttWorker();
    await worker.dispose();
    await worker.dispose();

    await expectLater(
      worker.configureVad(
        modelPath: '/unused/silero.onnx',
        threshold: 0.6,
        minSilenceDuration: 1,
        minSpeechDuration: 0.256,
        windowSize: 512,
        maxSpeechDuration: 90,
        sampleRate: 16000,
        bufferSizeInSeconds: 120,
        preRollSamples: 8192,
        postRollSamples: 3072,
        maximumHistorySamples: 1451264,
        feedRecognizer: false,
      ),
      throwsA(isA<StateError>()),
    );
    expect(worker.isAlive, isFalse);
  });

  test('disposed TTS workers cannot spawn replacement isolates', () async {
    final worker = SherpaTtsWorker();
    await worker.dispose();
    await worker.dispose();
    final model = sherpaModelCatalog.firstWhere(
      (candidate) => candidate.kind == SherpaModelKind.tts,
    );

    await expectLater(
      worker.load(
        InstalledSherpaModel(
          model: model,
          directory: Directory('/unused'),
          installedBytes: 0,
        ),
      ),
      throwsA(isA<StateError>()),
    );
    expect(worker.isAlive, isFalse);
  });
}
