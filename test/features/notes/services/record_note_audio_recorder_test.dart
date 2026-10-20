import 'package:checks/checks.dart';
import 'package:conduit/features/notes/services/audio_recording_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

void main() {
  test('records AAC in an m4a without altering the audio', () async {
    final client = _FakeAudioRecorderClient();
    final recorder = RecordNoteAudioRecorder.withClient(client);

    check(recorder.fileExtension).equals('m4a');
    await recorder.start('/tmp/note.m4a');

    final config = client.lastConfig!;
    check(client.startedPath).equals('/tmp/note.m4a');
    check(config.encoder).equals(AudioEncoder.aacLc);
    check(config.numChannels).equals(1);
    check(config.echoCancel).isFalse();
    check(config.autoGain).isFalse();
    check(config.noiseSuppress).isFalse();
    check(config.androidConfig.audioSource).equals(AndroidAudioSource.mic);
    check(config.androidConfig.audioManagerMode)
        .equals(AudioManagerMode.modeNormal);
  });

  test('the meter is the recorder amplitude in dBFS', () async {
    final recorder = RecordNoteAudioRecorder.withClient(
      _FakeAudioRecorderClient(),
    );
    final levels = await recorder
        .amplitudeChanges(const Duration(milliseconds: 100))
        .toList();
    check(levels).deepEquals(<double>[-30, -6]);
  });
}

class _FakeAudioRecorderClient implements AudioRecorderClient {
  RecordConfig? lastConfig;
  String? startedPath;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    lastConfig = config;
    startedPath = path;
  }

  @override
  Future<String?> stop() async => startedPath;

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) =>
      Stream.fromIterable([
        Amplitude(current: -30, max: -20),
        Amplitude(current: -6, max: -6),
      ]);

  @override
  Future<void> dispose() async {}
}
