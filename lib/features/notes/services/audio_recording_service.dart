import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Minimum valid audio file size (anything smaller is likely just a header)
const int _minValidAudioSize = 1000; // 1KB minimum

/// Exception thrown when audio recording fails.
class AudioRecordingException implements Exception {
  final String message;
  AudioRecordingException(this.message);
  
  @override
  String toString() => message;
}

/// Service for recording raw audio files without real-time transcription.
///
/// This is used in the notes feature where users want to preserve their original
/// audio recordings for later transcription using server-side Whisper, rather
/// than using Apple's real-time speech transcription which:
/// - Sends data to Apple's servers (privacy concern for self-hosted setups)
/// - Auto-stops after silence periods
/// - Loses the original audio after transcription
class AudioRecordingService {
  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
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
    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    // Use AAC for iOS (native support) and better compatibility
    // Use m4a extension which is widely supported
    _currentFilePath = '${tempDir.path}/note_recording_$timestamp.m4a';

    // Configure recording for high quality audio
    // Using AAC encoder for good compression and cross-platform compatibility
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        sampleRate: 44100,
        bitRate: 128000,
        numChannels: 1,
        // Don't alter the recording - preserve original audio
        echoCancel: false,
        autoGain: false,
        noiseSuppress: false,
      ),
      path: _currentFilePath!,
    );

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

    debugPrint('AudioRecordingService: Started recording to $_currentFilePath');
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

    final path = await _recorder.stop();
    _isRecording = false;
    _startTime = null;

    if (path == null) {
      debugPrint('AudioRecordingService: Stop returned null path');
      return null;
    }

    final file = File(path);
    if (!await file.exists()) {
      debugPrint('AudioRecordingService: File does not exist at $path');
      return null;
    }

    final fileSize = await file.length();
    debugPrint(
      'AudioRecordingService: Recording stopped, file size: $fileSize bytes',
    );

    // Check if the file is too small (likely just header, no audio data)
    if (fileSize < _minValidAudioSize) {
      debugPrint(
        'AudioRecordingService: Recording failed - file too small '
        '($fileSize bytes < $_minValidAudioSize minimum). '
        'This usually means the microphone is not working or not available.',
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
      await _recorder.stop();
      _isRecording = false;
      _startTime = null;
    }

    if (_currentFilePath != null) {
      try {
        final file = File(_currentFilePath!);
        if (await file.exists()) {
          await file.delete();
          debugPrint('AudioRecordingService: Deleted cancelled recording');
        }
      } catch (e) {
        debugPrint('AudioRecordingService: Failed to delete file: $e');
      }
      _currentFilePath = null;
    }
  }

  /// Stream of amplitude values for visualization.
  ///
  /// Returns amplitude data every 100ms while recording.
  Stream<Amplitude> get amplitudeStream => _recorder.onAmplitudeChanged(
        const Duration(milliseconds: 100),
      );

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
      } catch (e) {
        debugPrint('AudioRecordingService: Error cancelling recording in dispose: $e');
      }
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
    } catch (e) {
      debugPrint('AudioRecordingService: Error disposing recorder: $e');
    }
  }
}

