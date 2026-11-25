import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vad/vad.dart';

class _FakeVadModel implements VadModel {
  final List<Float32List> seenFrames = [];
  final List<double> probabilities;
  int _index = 0;
  int resetCount = 0;
  int releaseCount = 0;

  _FakeVadModel([this.probabilities = const []]);

  @override
  Future<SpeechProbabilities> process(Float32List frame) async {
    seenFrames.add(Float32List.fromList(frame));
    final prob = _index < probabilities.length ? probabilities[_index++] : 0.1;
    return SpeechProbabilities(isSpeech: prob, notSpeech: 1.0 - prob);
  }

  @override
  void resetState() {
    resetCount++;
  }

  @override
  Future<void> release() async {
    releaseCount++;
  }
}

class _FakeVadInference implements VadInference {
  _FakeVadInference(this.model);

  @override
  final _FakeVadModel model;

  int releaseCount = 0;

  @override
  Future<void> release() async {
    releaseCount++;
    await model.release();
  }
}

Uint8List _pcm16Bytes(List<int> samples) {
  final int16 = Int16List.fromList(samples);
  return Uint8List.view(int16.buffer);
}

VadIterator _createIterator(
  _FakeVadInference inference, {
  bool isDebug = false,
  int frameSamples = 8,
  int redemptionFrames = 2,
  int preSpeechPadFrames = 1,
  int minSpeechFrames = 1,
  int endSpeechPadFrames = 0,
}) {
  return VadIterator.withInference(
    isDebug: isDebug,
    sampleRate: 16000,
    frameSamples: frameSamples,
    positiveSpeechThreshold: 0.5,
    negativeSpeechThreshold: 0.35,
    redemptionFrames: redemptionFrames,
    preSpeechPadFrames: preSpeechPadFrames,
    minSpeechFrames: minSpeechFrames,
    endSpeechPadFrames: endSpeechPadFrames,
    inference: inference,
  );
}

void main() {
  test(
    'decodes PCM16 samples directly to Float32List across odd chunk splits',
    () async {
      final model = _FakeVadModel();
      final iterator = _createIterator(
        _FakeVadInference(model),
        frameSamples: 8,
      );
      final events = <VadEvent>[];
      iterator.setVadEventCallback(events.add);

      final samples = <int>[
        -32768,
        -16384,
        -1,
        0,
        1,
        16384,
        32767,
        -8192,
        4096,
        -4096,
        2048,
        -2048,
        1024,
        -1024,
        512,
        -512,
      ];
      final allBytes = _pcm16Bytes(samples);

      // Feed odd-sized chunks (including non-zero-offset views) that cut across
      // 16-bit sample and frame boundaries.
      await iterator.processAudioData(Uint8List.sublistView(allBytes, 0, 1));
      await iterator.processAudioData(Uint8List.sublistView(allBytes, 1, 7));
      await iterator.processAudioData(Uint8List.sublistView(allBytes, 7, 17));
      await iterator.processAudioData(Uint8List.sublistView(allBytes, 17));

      check(model.seenFrames).length.equals(2);
      check(model.seenFrames[0]).deepEquals(
        Float32List.fromList([
          -32768 / 32768.0,
          -16384 / 32768.0,
          -1 / 32768.0,
          0.0,
          1 / 32768.0,
          16384 / 32768.0,
          32767 / 32768.0,
          -8192 / 32768.0,
        ]),
      );
      check(model.seenFrames[1]).deepEquals(
        Float32List.fromList([
          4096 / 32768.0,
          -4096 / 32768.0,
          2048 / 32768.0,
          -2048 / 32768.0,
          1024 / 32768.0,
          -1024 / 32768.0,
          512 / 32768.0,
          -512 / 32768.0,
        ]),
      );

      final frameEvents = events
          .where((e) => e.type == VadEventType.frameProcessed)
          .toList();
      check(frameEvents).length.equals(2);
      check(frameEvents[0].frameData).isNotNull().isA<Float32List>();
      check(frameEvents[0].frameData!).deepEquals(model.seenFrames[0]);
      check(frameEvents[1].frameData).isNotNull().isA<Float32List>();
      check(frameEvents[1].frameData!).deepEquals(model.seenFrames[1]);
    },
  );

  test(
    'frameData is unmodifiable and cannot corrupt buffered speech audio',
    () async {
      final model = _FakeVadModel([0.1, 0.9, 0.1, 0.1]);
      final iterator = _createIterator(
        _FakeVadInference(model),
        frameSamples: 4,
        preSpeechPadFrames: 1,
        minSpeechFrames: 1,
        redemptionFrames: 2,
        endSpeechPadFrames: 0,
      );
      final events = <VadEvent>[];
      final rejectedMutations = <bool>[];
      iterator.setVadEventCallback((event) {
        events.add(event);
        if (event.type == VadEventType.frameProcessed) {
          final frameData = event.frameData!;
          var threwUnsupported = false;
          try {
            frameData[0] = 0.0;
          } on UnsupportedError {
            threwUnsupported = true;
          }
          rejectedMutations.add(threwUnsupported);
        }
      });

      await iterator.processAudioData(
        _pcm16Bytes([
          16384, 16384, 16384, 16384, // pre-speech frame
          8192, 8192, 8192, 8192, // speech frame
          0, 0, 0, 0, // redemption 1
          0, 0, 0, 0, // redemption 2 -> triggers end
        ]),
      );

      final frameEvents = events
          .where((e) => e.type == VadEventType.frameProcessed)
          .toList();
      check(frameEvents).length.equals(4);
      for (final event in frameEvents) {
        check(event.frameData).isNotNull().isA<Float32List>();
      }
      check(rejectedMutations).deepEquals([true, true, true, true]);

      final endEvents = events
          .where((e) => e.type == VadEventType.end)
          .toList();
      check(endEvents).length.equals(1);
      final emitted = Int16List.view(endEvents.single.audioData!.buffer);
      // Pre-speech frame (0.5 * 32767 = 16383) + speech frame (0.25 * 32767 = 8191).
      check(emitted.sublist(0, 4)).every((s) => s.equals(16383));
      check(emitted.sublist(4, 8)).every((s) => s.equals(8191));
    },
  );

  test(
    'omits per-frame timestamp message formatting unless isDebug is true',
    () async {
      final quietModel = _FakeVadModel([0.1]);
      final quietIterator = _createIterator(
        _FakeVadInference(quietModel),
        isDebug: false,
        frameSamples: 4,
      );
      final quietEvents = <VadEvent>[];
      quietIterator.setVadEventCallback(quietEvents.add);
      await quietIterator.processAudioData(_pcm16Bytes([0, 0, 0, 0]));

      check(quietEvents.single.type).equals(VadEventType.frameProcessed);
      check(quietEvents.single.timestamp).equals(0.0);
      check(quietEvents.single.message).equals('');

      final debugModel = _FakeVadModel([0.1]);
      final debugIterator = _createIterator(
        _FakeVadInference(debugModel),
        isDebug: true,
        frameSamples: 4,
      );
      final debugEvents = <VadEvent>[];
      debugIterator.setVadEventCallback(debugEvents.add);
      await debugIterator.processAudioData(_pcm16Bytes([0, 0, 0, 0]));

      check(debugEvents.single.message).equals('Frame processed at 0.000s');
    },
  );

  test(
    'reset drops partial buffered bytes and release delegates to inference',
    () async {
      final model = _FakeVadModel();
      final inference = _FakeVadInference(model);
      final iterator = _createIterator(inference, frameSamples: 4);

      // Feed half a frame (4 bytes), then reset before feeding a full frame.
      await iterator.processAudioData(_pcm16Bytes([16384, 16384]));
      check(model.seenFrames).isEmpty();

      iterator.reset();
      check(model.resetCount).equals(1);

      await iterator.processAudioData(_pcm16Bytes([8192, 8192, 8192, 8192]));
      check(model.seenFrames).length.equals(1);
      check(model.seenFrames.single).every((s) => s.equals(8192 / 32768.0));

      await iterator.release();
      check(inference.releaseCount).equals(1);
      check(model.releaseCount).equals(1);
    },
  );
}
