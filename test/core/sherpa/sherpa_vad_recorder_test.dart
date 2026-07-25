import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/sherpa/sherpa_vad_recorder.dart';

void main() {
  test('uses the bundled Sherpa Silero VAD framing policy', () {
    check(SherpaVadRecorder.sampleRate).equals(16000);
    check(SherpaVadRecorder.frameSamples).equals(512);
    check(SherpaVadRecorder.threshold).equals(0.6);
    check(SherpaVadRecorder.minSpeechDurationSeconds).equals(0.256);
    check(SherpaVadRecorder.maxSpeechDurationSeconds).equals(90);
    check(SherpaVadRecorder.bufferSizeSeconds).equals(120);
    check(SherpaVadRecorder.preRollSamples).equals(8192);
    check(SherpaVadRecorder.postRollSamples).equals(3072);
  });
}
