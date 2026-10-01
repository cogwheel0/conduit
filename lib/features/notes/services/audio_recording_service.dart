import 'dart:io';

import 'package:conduit_core/features/notes/services/audio_recording_service.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../../core/services/background_streaming_handler.dart';

export 'package:conduit_core/features/notes/services/audio_recording_service.dart';

const String _noteRecordingBackgroundLeaseId = 'note-audio-recording';

@visibleForTesting
abstract class AudioRecorderClient {
  Future<bool> hasPermission();
  Future<void> start(RecordConfig config, {required String path});
  Future<String?> stop();
  Stream<Amplitude> onAmplitudeChanged(Duration interval);
  Future<void> dispose();
}

class _RecordAudioRecorderClient implements AudioRecorderClient {
  _RecordAudioRecorderClient([AudioRecorder? recorder])
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<void> start(RecordConfig config, {required String path}) =>
      _recorder.start(config, path: path);

  @override
  Future<String?> stop() => _recorder.stop();

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) =>
      _recorder.onAmplitudeChanged(interval);

  @override
  Future<void> dispose() => _recorder.dispose();
}

/// Notes recorded with `record`: AAC in an `.m4a`, which is widely supported
/// and what the server transcribes.
class RecordNoteAudioRecorder implements NoteAudioRecorder {
  @visibleForTesting
  RecordNoteAudioRecorder.withClient(AudioRecorderClient client)
    : _recorder = client;

  RecordNoteAudioRecorder() : _recorder = _RecordAudioRecorderClient();

  final AudioRecorderClient _recorder;

  @override
  String get fileExtension => 'm4a';

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<void> start(String path) {
    // High quality AAC for good compression and cross-platform
    // compatibility.
    return _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        sampleRate: 44100,
        bitRate: 128000,
        numChannels: 1,
        // Don't alter the recording - preserve original audio.
        echoCancel: false,
        autoGain: false,
        noiseSuppress: false,
        androidConfig: AndroidRecordConfig(
          audioSource: AndroidAudioSource.mic,
          audioManagerMode: AudioManagerMode.modeNormal,
          manageBluetooth: true,
          useLegacy: false,
        ),
      ),
      path: path,
    );
  }

  @override
  Future<String?> stop() => _recorder.stop();

  @override
  Stream<double> amplitudeChanges(Duration interval) =>
      _recorder.onAmplitudeChanged(interval).map((amp) => amp.current);

  @override
  Future<void> dispose() => _recorder.dispose();
}

class _PlatformAudioRecordingBackgroundCoordinator
    implements AudioRecordingBackgroundCoordinator {
  @override
  Future<bool> startMicrophoneLease() async {
    if (!Platform.isAndroid) return false;

    await BackgroundStreamingHandler.instance.startBackgroundExecution(
      const [_noteRecordingBackgroundLeaseId],
      requiresMicrophone: true,
      kind: BackgroundStreamKind.voice,
    );
    return true;
  }

  @override
  Future<void> stopMicrophoneLease() async {
    if (!Platform.isAndroid) return;

    await BackgroundStreamingHandler.instance.stopBackgroundExecution(const [
      _noteRecordingBackgroundLeaseId,
    ]);
  }
}

/// The note recording service over `record`, with the Android microphone
/// lease.
AudioRecordingService createNoteAudioRecordingService() =>
    AudioRecordingService(
      recorder: RecordNoteAudioRecorder(),
      backgroundCoordinator: _PlatformAudioRecordingBackgroundCoordinator(),
      temporaryDirectoryProvider: getTemporaryDirectory,
    );
