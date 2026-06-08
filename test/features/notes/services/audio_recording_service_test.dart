import 'dart:async';
import 'dart:io';

import 'package:conduit/features/notes/services/audio_recording_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioRecordingService', () {
    test('starts microphone background lease before recorder', () async {
      final tempDir = await _createTempDir();
      final events = <String>[];
      final recorder = _FakeAudioRecorderClient(events: events);
      final background = _FakeAudioRecordingBackgroundCoordinator(
        events: events,
      );
      final service = AudioRecordingService(
        recorder: recorder,
        backgroundCoordinator: background,
        temporaryDirectoryProvider: () async => tempDir,
      );

      addTearDown(() async {
        await service.dispose();
        await _deleteTempDir(tempDir);
      });

      await service.startRecording();

      expect(events, <String>['lease-start', 'recorder-start']);
      expect(
        recorder.lastConfig?.androidConfig.audioSource,
        AndroidAudioSource.mic,
      );
      expect(
        recorder.lastConfig?.androidConfig.audioManagerMode,
        AudioManagerMode.modeNormal,
      );
      expect(background.startCalls, 1);
      expect(service.isRecording, isTrue);
    });

    test('stopRecording returns file and releases background lease', () async {
      final tempDir = await _createTempDir();
      final events = <String>[];
      final recorder = _FakeAudioRecorderClient(events: events);
      final background = _FakeAudioRecordingBackgroundCoordinator(
        events: events,
      );
      final service = AudioRecordingService(
        recorder: recorder,
        backgroundCoordinator: background,
        temporaryDirectoryProvider: () async => tempDir,
      );

      addTearDown(() async {
        await service.dispose();
        await _deleteTempDir(tempDir);
      });

      await service.startRecording();
      final file = await service.stopRecording();

      expect(file, isNotNull);
      expect(await file!.length(), recorder.bytesWrittenOnStop);
      expect(events, <String>[
        'lease-start',
        'recorder-start',
        'recorder-stop',
        'lease-stop',
      ]);
      expect(background.stopCalls, 1);
      expect(service.isRecording, isFalse);
    });

    test(
      'cancelRecording stops recorder, releases lease, and deletes temp file',
      () async {
        final tempDir = await _createTempDir();
        final events = <String>[];
        final recorder = _FakeAudioRecorderClient(events: events);
        final background = _FakeAudioRecordingBackgroundCoordinator(
          events: events,
        );
        final service = AudioRecordingService(
          recorder: recorder,
          backgroundCoordinator: background,
          temporaryDirectoryProvider: () async => tempDir,
        );

        addTearDown(() async {
          await service.dispose();
          await _deleteTempDir(tempDir);
        });

        final path = await service.startRecording();
        await service.cancelRecording();

        expect(await File(path).exists(), isFalse);
        expect(events, <String>[
          'lease-start',
          'recorder-start',
          'recorder-stop',
          'lease-stop',
        ]);
        expect(background.stopCalls, 1);
        expect(service.isRecording, isFalse);
      },
    );

    test('releases background lease if recorder start fails', () async {
      final tempDir = await _createTempDir();
      final events = <String>[];
      final recorder = _FakeAudioRecorderClient(
        events: events,
        startError: Exception('recorder failed'),
      );
      final background = _FakeAudioRecordingBackgroundCoordinator(
        events: events,
      );
      final service = AudioRecordingService(
        recorder: recorder,
        backgroundCoordinator: background,
        temporaryDirectoryProvider: () async => tempDir,
      );

      addTearDown(() async {
        await service.dispose();
        await _deleteTempDir(tempDir);
      });

      await expectLater(service.startRecording(), throwsException);

      expect(events, <String>['lease-start', 'recorder-start', 'lease-stop']);
      expect(background.stopCalls, 1);
      expect(service.isRecording, isFalse);
    });

    test(
      'releases background lease and deletes invalid tiny recordings',
      () async {
        final tempDir = await _createTempDir();
        final events = <String>[];
        final recorder = _FakeAudioRecorderClient(
          events: events,
          bytesWrittenOnStop: 10,
        );
        final background = _FakeAudioRecordingBackgroundCoordinator(
          events: events,
        );
        final service = AudioRecordingService(
          recorder: recorder,
          backgroundCoordinator: background,
          temporaryDirectoryProvider: () async => tempDir,
        );

        addTearDown(() async {
          await service.dispose();
          await _deleteTempDir(tempDir);
        });

        final path = await service.startRecording();

        await expectLater(
          service.stopRecording(),
          throwsA(isA<AudioRecordingException>()),
        );

        expect(await File(path).exists(), isFalse);
        expect(events, <String>[
          'lease-start',
          'recorder-start',
          'recorder-stop',
          'lease-stop',
        ]);
        expect(background.stopCalls, 1);
        expect(service.isRecording, isFalse);
      },
    );

    test(
      'does not start background lease without microphone permission',
      () async {
        final tempDir = await _createTempDir();
        final events = <String>[];
        final recorder = _FakeAudioRecorderClient(
          events: events,
          hasPermissionResult: false,
        );
        final background = _FakeAudioRecordingBackgroundCoordinator(
          events: events,
        );
        final service = AudioRecordingService(
          recorder: recorder,
          backgroundCoordinator: background,
          temporaryDirectoryProvider: () async => tempDir,
        );

        addTearDown(() async {
          await service.dispose();
          await _deleteTempDir(tempDir);
        });

        await expectLater(service.startRecording(), throwsException);

        expect(events, isEmpty);
        expect(background.startCalls, 0);
        expect(service.isRecording, isFalse);
      },
    );
  });
}

Future<Directory> _createTempDir() {
  return Directory.systemTemp.createTemp('conduit_audio_recording_test_');
}

Future<void> _deleteTempDir(Directory dir) async {
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
}

class _FakeAudioRecorderClient implements AudioRecorderClient {
  _FakeAudioRecorderClient({
    required this.events,
    this.hasPermissionResult = true,
    this.startError,
    this.bytesWrittenOnStop = 2048,
  });

  final List<String> events;
  final bool hasPermissionResult;
  final Object? startError;
  final int bytesWrittenOnStop;

  RecordConfig? lastConfig;
  String? startedPath;
  int stopCalls = 0;

  @override
  Future<bool> hasPermission() async => hasPermissionResult;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    events.add('recorder-start');
    lastConfig = config;
    startedPath = path;
    final error = startError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<String?> stop() async {
    events.add('recorder-stop');
    stopCalls += 1;
    final path = startedPath;
    if (path == null) return null;

    await File(path).writeAsBytes(List<int>.filled(bytesWrittenOnStop, 1));
    return path;
  }

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) =>
      const Stream<Amplitude>.empty();

  @override
  Future<void> dispose() async {}
}

class _FakeAudioRecordingBackgroundCoordinator
    implements AudioRecordingBackgroundCoordinator {
  _FakeAudioRecordingBackgroundCoordinator({required this.events});

  final List<String> events;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<bool> startMicrophoneLease() async {
    events.add('lease-start');
    startCalls += 1;
    return true;
  }

  @override
  Future<void> stopMicrophoneLease() async {
    events.add('lease-stop');
    stopCalls += 1;
  }
}
