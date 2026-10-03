import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/notes/services/audio_recording_service.dart';
import 'package:test/test.dart';

void main() {
  group('AudioRecordingService', () {
    test('starts microphone background lease before recorder', () async {
      final tempDir = await _createTempDir();
      final events = <String>[];
      final recorder = _FakeNoteAudioRecorder(events: events);
      final background = _FakeBackgroundCoordinator(events: events);
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

      check(events).deepEquals(<String>['lease-start', 'recorder-start']);
      check(path).endsWith('.m4a');
      check(path).contains('note_recording_');
      check(background.startCalls).equals(1);
      check(service.isRecording).isTrue();
    });

    test('takes the file extension from the recorder', () async {
      final tempDir = await _createTempDir();
      final service = AudioRecordingService(
        recorder: _FakeNoteAudioRecorder(events: <String>[], extension: 'wav'),
        temporaryDirectoryProvider: () async => tempDir,
      );
      addTearDown(() async {
        await service.dispose();
        await _deleteTempDir(tempDir);
      });

      check(await service.startRecording()).endsWith('.wav');
    });

    test('stopRecording returns file and releases background lease', () async {
      final tempDir = await _createTempDir();
      final events = <String>[];
      final recorder = _FakeNoteAudioRecorder(events: events);
      final background = _FakeBackgroundCoordinator(events: events);
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

      check(file).isNotNull();
      check(await file!.length()).equals(recorder.bytesWrittenOnStop);
      check(events).deepEquals(<String>[
        'lease-start',
        'recorder-start',
        'recorder-stop',
        'lease-stop',
      ]);
      check(background.stopCalls).equals(1);
      check(service.isRecording).isFalse();
    });

    test(
      'cancelRecording stops recorder, releases lease, and deletes temp file',
      () async {
        final tempDir = await _createTempDir();
        final events = <String>[];
        final recorder = _FakeNoteAudioRecorder(events: events);
        final background = _FakeBackgroundCoordinator(events: events);
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

        check(await File(path).exists()).isFalse();
        check(events).deepEquals(<String>[
          'lease-start',
          'recorder-start',
          'recorder-stop',
          'lease-stop',
        ]);
        check(background.stopCalls).equals(1);
        check(service.isRecording).isFalse();
      },
    );

    test('releases background lease if recorder start fails', () async {
      final tempDir = await _createTempDir();
      final events = <String>[];
      final recorder = _FakeNoteAudioRecorder(
        events: events,
        startError: Exception('recorder failed'),
      );
      final background = _FakeBackgroundCoordinator(events: events);
      final service = AudioRecordingService(
        recorder: recorder,
        backgroundCoordinator: background,
        temporaryDirectoryProvider: () async => tempDir,
      );

      addTearDown(() async {
        await service.dispose();
        await _deleteTempDir(tempDir);
      });

      await check(service.startRecording()).throws<Exception>();

      check(events)
          .deepEquals(<String>['lease-start', 'recorder-start', 'lease-stop']);
      check(background.stopCalls).equals(1);
      check(service.isRecording).isFalse();
    });

    test(
      'releases background lease and deletes invalid tiny recordings',
      () async {
        final tempDir = await _createTempDir();
        final events = <String>[];
        final recorder = _FakeNoteAudioRecorder(
          events: events,
          bytesWrittenOnStop: 10,
        );
        final background = _FakeBackgroundCoordinator(events: events);
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

        await check(service.stopRecording()).throws<AudioRecordingException>();

        check(await File(path).exists()).isFalse();
        check(events).deepEquals(<String>[
          'lease-start',
          'recorder-start',
          'recorder-stop',
          'lease-stop',
        ]);
        check(background.stopCalls).equals(1);
        check(service.isRecording).isFalse();
      },
    );

    test(
      'does not start background lease without microphone permission',
      () async {
        final tempDir = await _createTempDir();
        final events = <String>[];
        final recorder = _FakeNoteAudioRecorder(
          events: events,
          hasPermissionResult: false,
        );
        final background = _FakeBackgroundCoordinator(events: events);
        final service = AudioRecordingService(
          recorder: recorder,
          backgroundCoordinator: background,
          temporaryDirectoryProvider: () async => tempDir,
        );

        addTearDown(() async {
          await service.dispose();
          await _deleteTempDir(tempDir);
        });

        await check(service.startRecording()).throws<Exception>();

        check(events).isEmpty();
        check(background.startCalls).equals(0);
        check(service.isRecording).isFalse();
      },
    );

    test('reports the elapsed duration while recording', () async {
      final tempDir = await _createTempDir();
      final service = AudioRecordingService(
        recorder: _FakeNoteAudioRecorder(events: <String>[]),
        temporaryDirectoryProvider: () async => tempDir,
      );
      addTearDown(() async {
        await service.dispose();
        await _deleteTempDir(tempDir);
      });

      await service.startRecording();
      final first = await service.durationStream.first.timeout(
        const Duration(seconds: 2),
      );
      check(first).isGreaterOrEqual(Duration.zero);
      check(service.currentDuration).isGreaterThan(Duration.zero);
    });
  });

  group('noteRecordingFileName', () {
    test('keeps the recorded extension', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      check(noteRecordingFileName('/tmp/x/note_recording_1.wav', now: now))
          .equals('recording_1700000000000.wav');
      check(noteRecordingFileName('/tmp/x/note_recording_1.M4A', now: now))
          .equals('recording_1700000000000.m4a');
    });

    test('defaults to m4a when the path has no extension', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      check(noteRecordingFileName('/tmp/dir.with.dots/recording', now: now))
          .equals('recording_1700000000000.m4a');
    });
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

class _FakeNoteAudioRecorder implements NoteAudioRecorder {
  _FakeNoteAudioRecorder({
    required this.events,
    this.hasPermissionResult = true,
    this.startError,
    this.bytesWrittenOnStop = 2048,
    String extension = 'm4a',
  }) : fileExtension = extension;

  final List<String> events;
  final bool hasPermissionResult;
  final Object? startError;
  final int bytesWrittenOnStop;

  @override
  final String fileExtension;

  String? startedPath;

  @override
  Future<bool> hasPermission() async => hasPermissionResult;

  @override
  Future<void> start(String path) async {
    events.add('recorder-start');
    startedPath = path;
    final error = startError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<String?> stop() async {
    events.add('recorder-stop');
    final path = startedPath;
    if (path == null) return null;

    await File(path).writeAsBytes(List<int>.filled(bytesWrittenOnStop, 1));
    return path;
  }

  @override
  Stream<double> amplitudeChanges(Duration interval) =>
      const Stream<double>.empty();

  @override
  Future<void> dispose() async {}
}

class _FakeBackgroundCoordinator
    implements AudioRecordingBackgroundCoordinator {
  _FakeBackgroundCoordinator({required this.events});

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
