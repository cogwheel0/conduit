import 'dart:async';
import 'dart:io';

import 'package:conduit_core/utils/debug_logger.dart';

/// Minimum valid audio file size (anything smaller is likely just a header).
const int _minValidAudioSize = 1000; // 1KB minimum

/// Exception thrown when audio recording fails.
class AudioRecordingException implements Exception {
  final String message;
  AudioRecordingException(this.message);

  @override
  String toString() => message;
}

/// Records the note's original audio to a file.
///
/// The app backs this with `record` (AAC in an `.m4a`); tests substitute a
/// fake.
abstract interface class NoteAudioRecorder {
  /// The extension, without a dot, of the file [start] writes (`m4a`, `wav`).
  String get fileExtension;

  /// Whether the microphone may be used; asks the user when not yet known.
  Future<bool> hasPermission();

  /// Starts recording into [path].
  Future<void> start(String path);

  /// Stops and finishes the file, returning its path (null when nothing was
  /// recording).
  Future<String?> stop();

  /// The input level in dBFS (about -160 silence to 0 full scale), every
  /// [interval], while recording.
  Stream<double> amplitudeChanges(Duration interval);

  Future<void> dispose();
}

/// Keeps a recording alive while the app is in the background.
///
/// Android can mute background microphone capture after lock unless a
/// microphone foreground service is already active.
abstract interface class AudioRecordingBackgroundCoordinator {
  Future<bool> startMicrophoneLease();
  Future<void> stopMicrophoneLease();
}

/// A host with no background microphone lease to take.
class NoAudioRecordingBackground
    implements AudioRecordingBackgroundCoordinator {
  const NoAudioRecordingBackground();

  @override
  Future<bool> startMicrophoneLease() async => false;

  @override
  Future<void> stopMicrophoneLease() async {}
}

/// The name a note recording is uploaded under: `recording_<ms>.<extension>`,
/// the extension being the recorded file's.
String noteRecordingFileName(String recordedPath, {DateTime? now}) {
  final dot = recordedPath.lastIndexOf('.');
  final slash = recordedPath.lastIndexOf(Platform.pathSeparator);
  final extension = dot > slash && dot >= 0
      ? recordedPath.substring(dot).toLowerCase()
      : '.m4a';
  final stamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
  return 'recording_$stamp$extension';
}

/// Service for recording raw audio files without real-time transcription.
///
/// This is used in the notes feature where users want to preserve their
/// original audio recordings for later transcription using server-side
/// Whisper, rather than using Apple's real-time speech transcription which:
/// - Sends data to Apple's servers (privacy concern for self-hosted setups)
/// - Auto-stops after silence periods
/// - Loses the original audio after transcription
class AudioRecordingService {
  AudioRecordingService({
    required NoteAudioRecorder recorder,
    required Future<Directory> Function() temporaryDirectoryProvider,
    AudioRecordingBackgroundCoordinator? backgroundCoordinator,
  }) : _recorder = recorder,
       _backgroundCoordinator =
           backgroundCoordinator ?? const NoAudioRecordingBackground(),
       _temporaryDirectoryProvider = temporaryDirectoryProvider;

  final NoteAudioRecorder _recorder;
  final AudioRecordingBackgroundCoordinator _backgroundCoordinator;
  final Future<Directory> Function() _temporaryDirectoryProvider;
  bool _isRecording = false;
  bool _backgroundLeaseActive = false;
  String? _currentFilePath;
  DateTime? _startTime;

  final _durationController = StreamController<Duration>.broadcast();
  Stream<Duration> get durationStream => _durationController.stream;

  Timer? _durationTimer;

  bool get isRecording => _isRecording;

  Duration get currentDuration => _startTime != null
      ? DateTime.now().difference(_startTime!)
      : Duration.zero;

  /// Starts recording audio to a file.
  ///
  /// Returns the file path where audio will be saved.
  /// Throws an exception if microphone permission is denied.
  Future<String> startRecording() async {
    if (_isRecording) {
      throw StateError('Already recording');
    }

    // Check/request microphone permission
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      throw Exception('Microphone permission denied');
    }

    // Generate unique file path
    final tempDir = await _temporaryDirectoryProvider();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _currentFilePath =
        '${tempDir.path}/note_recording_$timestamp.${_recorder.fileExtension}';

    try {
      _backgroundLeaseActive = await _backgroundCoordinator
          .startMicrophoneLease();
      await _recorder.start(_currentFilePath!);
    } catch (_) {
      await _releaseBackgroundLease();
      _currentFilePath = null;
      rethrow;
    }

    _isRecording = true;
    _startTime = DateTime.now();

    // Start duration timer for UI updates
    _durationTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      // Use try-catch to handle race condition where dispose() closes
      // the controller between the check and the add
      try {
        _durationController.add(currentDuration);
      } catch (_) {
        // Controller was closed, timer will be cancelled by dispose()
      }
    });

    DebugLogger.log(
      'recording-started',
      scope: 'notes/audio',
      data: {'extension': _recorder.fileExtension},
    );
    return _currentFilePath!;
  }

  /// Stops recording and returns the recorded file.
  ///
  /// Returns null if recording was not active, the file doesn't exist,
  /// or the recording failed (file too small).
  /// Throws an exception if the recording captured no audio data.
  Future<File?> stopRecording() async {
    if (!_isRecording || _currentFilePath == null) {
      return null;
    }

    _durationTimer?.cancel();
    _durationTimer = null;

    final String? path;
    try {
      path = await _recorder.stop();
    } finally {
      _isRecording = false;
      _startTime = null;
      await _releaseBackgroundLease();
    }

    if (path == null) {
      DebugLogger.warning('recording-stop-no-path', scope: 'notes/audio');
      return null;
    }

    final file = File(path);
    if (!await file.exists()) {
      DebugLogger.warning('recording-file-missing', scope: 'notes/audio');
      return null;
    }

    final fileSize = await file.length();
    DebugLogger.log(
      'recording-stopped',
      scope: 'notes/audio',
      data: {'bytes': fileSize},
    );

    // Check if the file is too small (likely just header, no audio data)
    if (fileSize < _minValidAudioSize) {
      DebugLogger.warning(
        'recording-too-small',
        scope: 'notes/audio',
        data: {'bytes': fileSize, 'minimum': _minValidAudioSize},
      );
      // Clean up the invalid file
      try {
        await file.delete();
      } catch (_) {}
      _currentFilePath = null;
      throw AudioRecordingException(
        'Recording captured no audio. '
        'Please check microphone permissions and try again.',
      );
    }

    _currentFilePath = null;
    return file;
  }

  /// Cancels recording and deletes any recorded data.
  Future<void> cancelRecording() async {
    _durationTimer?.cancel();
    _durationTimer = null;

    if (_isRecording) {
      try {
        await _recorder.stop();
      } finally {
        _isRecording = false;
        _startTime = null;
        await _releaseBackgroundLease();
      }
    } else {
      await _releaseBackgroundLease();
    }

    if (_currentFilePath != null) {
      try {
        final file = File(_currentFilePath!);
        if (await file.exists()) {
          await file.delete();
          DebugLogger.log('recording-cancelled', scope: 'notes/audio');
        }
      } catch (error) {
        DebugLogger.warning(
          'recording-delete-failed',
          scope: 'notes/audio',
          data: {'errorType': error.runtimeType.toString()},
        );
      }
      _currentFilePath = null;
    }
  }

  /// The input level in dBFS every 100 ms while recording, for the meter.
  Stream<double> get amplitudeStream =>
      _recorder.amplitudeChanges(const Duration(milliseconds: 100));

  Future<void> _releaseBackgroundLease() async {
    if (!_backgroundLeaseActive) return;
    _backgroundLeaseActive = false;
    try {
      await _backgroundCoordinator.stopMicrophoneLease();
    } catch (error) {
      DebugLogger.warning(
        'recording-lease-stop-failed',
        scope: 'notes/audio',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }

  /// Disposes of resources used by the service.
  ///
  /// This should be called when the service is no longer needed to properly
  /// release native audio resources. If a recording is in progress, it will
  /// be cancelled and any temp files cleaned up.
  Future<void> dispose() async {
    // Cancel any in-progress recording first to clean up temp files.
    // Wrapped in try-catch to ensure timer/controller cleanup always happens.
    if (_isRecording) {
      try {
        await cancelRecording();
      } catch (error) {
        DebugLogger.warning(
          'recording-cancel-in-dispose-failed',
          scope: 'notes/audio',
          data: {'errorType': error.runtimeType.toString()},
        );
      }
    } else {
      await _releaseBackgroundLease();
    }

    // Cancel timer BEFORE closing controller to avoid relying on exception
    // handling for control flow. The try-catch in the timer callback is a
    // safety net for any remaining race condition.
    _durationTimer?.cancel();
    _durationTimer = null;

    if (!_durationController.isClosed) {
      await _durationController.close();
    }

    // Await recorder disposal to ensure native resources are released.
    // Wrapped in try-catch since recorder may be in inconsistent state if
    // cancelRecording() failed above.
    try {
      await _recorder.dispose();
    } catch (error) {
      DebugLogger.warning(
        'recording-recorder-dispose-failed',
        scope: 'notes/audio',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }
}
