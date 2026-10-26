// lib/src/core/vad_iterator.dart
// ignore_for_file: avoid_print

import 'dart:typed_data';

import 'package:vad/src/core/vad_event.dart';
import 'package:vad/src/core/vad_inference.dart';
import 'package:vad/src/core/vad_log.dart';
import 'package:vad/src/utils/model_utils.dart';

/// Callback function type for receiving VAD events during audio processing
typedef VadEventCallback = void Function(VadEvent event);

/// Low-level Voice Activity Detection iterator for direct audio processing
///
/// Provides frame-by-frame VAD processing with platform-specific implementations.
/// Used internally but can be used directly for more granular
/// control over VAD processing, such as processing non-streaming audio data.
class VadIterator {
  /// Whether to enable debug logging
  final bool _isDebug;

  /// Positive speech threshold
  final double _positiveSpeechThreshold;

  /// Negative speech threshold
  final double _negativeSpeechThreshold;

  /// Number of frames to wait before considering speech as valid
  final int _redemptionFrames;

  /// Frame size in samples - WARNING: Use 512, 1024, or 1536 for best performance
  /// as Silero models were trained on these specific frame sizes
  final int _frameSamples;

  /// Number of frames to pad before speech is considered valid
  final int _preSpeechPadFrames;

  /// Number of frames to pad after speech is considered ended
  final int _endSpeechPadFrames;

  /// Minimum number of speech frames required to consider speech as valid
  final int _minSpeechFrames;

  /// Number of frames to accumulate before emitting chunk
  final int _numFramesToEmit;

  /// Sample rate of the audio stream
  final int _sampleRate;

  /// VAD inference instance
  final VadInference _inference;

  /// Optional callback for routing non-debug failure logs
  final VadLogCallback? _onLog;

  /// Whether the user is currently speaking
  bool _speaking = false;

  /// Number of frames since the last speech event
  int _redemptionCounter = 0;

  /// Number of speech frames detected
  int _speechPositiveFrameCount = 0;

  /// Number of samples processed
  int _currentSample = 0;

  /// Buffer for pre-speech frames
  final List<Float32List> _preSpeechBuffer = [];

  /// Buffer for speech frames
  final List<Float32List> _speechBuffer = [];

  /// Index in speech buffer where current speech segment starts
  int _speechStartIndex = 0;

  /// Number of redemption frames that have been sent in chunks
  int _sentRedemptionFrames = 0;

  /// Callback for VAD events
  VadEventCallback? _onVadEvent;

  /// Buffer for audio data
  final List<int> _byteBuffer = [];

  /// Number of bytes per frame
  final int _frameByteCount;

  /// Number of frames processed (for debugging)
  int _totalFramesProcessed = 0;

  /// Whether the real speech start event has been fired
  bool _speechRealStartFired = false;

  /// Private constructor
  VadIterator._({
    required bool isDebug,
    required int sampleRate,
    required int frameSamples,
    required double positiveSpeechThreshold,
    required double negativeSpeechThreshold,
    required int redemptionFrames,
    required int preSpeechPadFrames,
    required int minSpeechFrames,
    required int endSpeechPadFrames,
    required int numFramesToEmit,
    required VadInference inference,
    VadLogCallback? onLog,
  })  : _isDebug = isDebug,
        _sampleRate = sampleRate,
        _frameSamples = frameSamples,
        _positiveSpeechThreshold = positiveSpeechThreshold,
        _negativeSpeechThreshold = negativeSpeechThreshold,
        _redemptionFrames = redemptionFrames,
        _preSpeechPadFrames = preSpeechPadFrames,
        _minSpeechFrames = minSpeechFrames,
        _endSpeechPadFrames = endSpeechPadFrames,
        _numFramesToEmit = numFramesToEmit,
        _inference = inference,
        _onLog = onLog,
        _frameByteCount = frameSamples * 2;

  void _log(String message) => (_onLog ?? print)(message);

  /// Reset VAD state and clear internal buffers
  void reset() {
    if (_isDebug) {
      print(
          'VadIteratorImpl: Resetting state (processed $_totalFramesProcessed frames so far)');
    }
    _speaking = false;
    _redemptionCounter = 0;
    _speechPositiveFrameCount = 0;
    _currentSample = 0;
    _speechStartIndex = 0;
    _sentRedemptionFrames = 0;
    _speechRealStartFired = false;
    _preSpeechBuffer.clear();
    _speechBuffer.clear();
    _byteBuffer.clear();
    _totalFramesProcessed = 0;
    _inference.model.resetState();
  }

  /// Release model resources and cleanup memory
  Future<void> release() async {
    await _inference.release();
  }

  /// Set callback function to receive VAD events
  void setVadEventCallback(VadEventCallback callback) {
    _onVadEvent = callback;
  }

  /// Process raw audio data bytes and emit VAD events
  Future<void> processAudioData(Uint8List data) async {
    _byteBuffer.addAll(data);

    while (_byteBuffer.length >= _frameByteCount) {
      final frameBytes = _byteBuffer.sublist(0, _frameByteCount);
      _byteBuffer.removeRange(0, _frameByteCount);
      final frameData = _convertBytesToFloat32(Uint8List.fromList(frameBytes));
      await _processFrame(Float32List.fromList(frameData));
    }
  }

  Future<void> _processFrame(Float32List data) async {
    if (data.length != _frameSamples) {
      _log(
          'VadIteratorImpl: Unexpected frame size: ${data.length}, expected: $_frameSamples');
      return;
    }

    _totalFramesProcessed++;

    try {
      final speechProb = await _runModelInference(data);

      if (_speaking && speechProb < _negativeSpeechThreshold && _isDebug) {
        print(
            'VadIteratorImpl: During speech - probability ${speechProb.toStringAsFixed(3)} < negativeSpeechThreshold ${_negativeSpeechThreshold.toStringAsFixed(3)}');
      }

      // Create a copy of the frame data for the event
      final frameData = data.toList();

      // Emit the frame processed event
      _onVadEvent?.call(VadEvent(
        type: VadEventType.frameProcessed,
        timestamp: _getCurrentTimestamp(),
        message:
            'Frame processed at ${_getCurrentTimestamp().toStringAsFixed(3)}s',
        probabilities: SpeechProbabilities(
            isSpeech: speechProb, notSpeech: 1.0 - speechProb),
        frameData: frameData,
      ));

      _currentSample += _frameSamples;
      _handleStateTransitions(speechProb, data);
    } catch (e, stackTrace) {
      _log('VadIteratorImpl: Error in _processFrame: $e\n$stackTrace');

      // Send error event
      _onVadEvent?.call(VadEvent(
        type: VadEventType.error,
        timestamp: _getCurrentTimestamp(),
        message: 'Frame processing error: $e',
      ));
    }
  }

  Future<double> _runModelInference(Float32List data) async {
    try {
      final probs = await _inference.model.process(data);
      return probs.isSpeech;
    } catch (e) {
      _log('VadIteratorImpl: Model inference error: $e');
      rethrow;
    }
  }

  void _handleStateTransitions(double speechProb, Float32List data) {
    if (speechProb >= _positiveSpeechThreshold) {
      // Speech-positive frame
      if (!_speaking) {
        _speaking = true;
        _speechStartIndex = 0;
        _speechRealStartFired = false;
        if (_isDebug) {
          print(
              'VadIteratorImpl: Speech started (prob: ${speechProb.toStringAsFixed(3)})');
        }
        _onVadEvent?.call(VadEvent(
          type: VadEventType.start,
          timestamp: _getCurrentTimestamp(),
          message:
              'Speech started at ${_getCurrentTimestamp().toStringAsFixed(3)}s',
        ));
        _speechBuffer.addAll(_preSpeechBuffer);
        _preSpeechBuffer.clear();
      }
      if (_redemptionCounter > 0 && _isDebug) {
        print(
            'VadIteratorImpl: Redemption counter reset from $_redemptionCounter to 0 due to positive speech (prob: ${speechProb.toStringAsFixed(3)})');
      }
      _redemptionCounter = 0;
      _sentRedemptionFrames = 0;
      _speechBuffer.add(data);
      _speechPositiveFrameCount++;

      // Add validation event when speech frames exceed minimum threshold
      if (_speechPositiveFrameCount == _minSpeechFrames &&
          !_speechRealStartFired) {
        _speechRealStartFired = true;
        if (_isDebug) {
          print('VadIteratorImpl: Real speech validated');
        }
        _onVadEvent?.call(VadEvent(
          type: VadEventType.realStart,
          timestamp: _getCurrentTimestamp(),
          message:
              'Speech validated at ${_getCurrentTimestamp().toStringAsFixed(3)}s',
        ));
      }
    } else if (speechProb < _negativeSpeechThreshold) {
      // Handle speech-negative frame
      _handleSpeechNegativeFrame(data);
    } else {
      // Probability between thresholds
      _handleIntermediateFrame(data);
    }

    // Handle chunk emission during speech
    if (_speaking &&
        _numFramesToEmit > 0 &&
        _speechBuffer.length - _speechStartIndex >= _numFramesToEmit &&
        _redemptionCounter <= _endSpeechPadFrames) {
      final framesToSend = _speechBuffer.sublist(
          _speechStartIndex, _speechStartIndex + _numFramesToEmit);
      _speechStartIndex = _speechStartIndex + _numFramesToEmit;
      _sentRedemptionFrames = _redemptionCounter;
      _emitChunkEvent(framesToSend,
          'Audio chunk emitted at ${_getCurrentTimestamp().toStringAsFixed(3)}s');
    }
  }

  void _handleSpeechNegativeFrame(Float32List data) {
    if (_speaking) {
      _speechBuffer.add(data);
      _redemptionCounter++;
      if (_isDebug) {
        print(
            'VadIteratorImpl: Redemption counter incremented to $_redemptionCounter/$_redemptionFrames');
      }

      if (_redemptionCounter >= _redemptionFrames) {
        // End of speech
        _speaking = false;
        _redemptionCounter = 0;

        if (_speechPositiveFrameCount >= _minSpeechFrames) {
          // Valid speech segment
          if (_isDebug) {
            print(
                'VadIteratorImpl: Speech ended (duration: ${(_speechBuffer.length * _frameSamples / _sampleRate).toStringAsFixed(2)}s)');
          }

          // Calculate the audio buffer with endSpeechPadFrames
          final framesToRemove = _redemptionFrames - _endSpeechPadFrames;
          const startIndex =
              0; // Always start from beginning for complete speech segment

          final audioBufferPad = _processAudioBuffer(
            frames: _speechBuffer,
            startIndex: startIndex,
            framesToRemove: framesToRemove,
          );

          final audio = _combineFrames(audioBufferPad);

          _onVadEvent?.call(VadEvent(
            type: VadEventType.end,
            timestamp: _getCurrentTimestamp(),
            message:
                'Speech ended at ${_getCurrentTimestamp().toStringAsFixed(3)}s',
            audioData: audio,
          ));

          // Handle final chunk emission if needed
          _handleFinalChunkEmission();
        } else {
          // Misfire
          if (_isDebug) {
            print(
                'VadIteratorImpl: Misfire (only $_speechPositiveFrameCount positive frames)');
          }
          _onVadEvent?.call(VadEvent(
            type: VadEventType.misfire,
            timestamp: _getCurrentTimestamp(),
            message:
                'Misfire detected at ${_getCurrentTimestamp().toStringAsFixed(3)}s',
          ));
        }
        // Reset counters and buffers
        _speechPositiveFrameCount = 0;
        _speechStartIndex = 0;
        _sentRedemptionFrames = 0;
        _speechRealStartFired = false;

        // Preserve frames between endSpeechPadFrames and redemptionFrames for next pre-speech buffer
        if (_endSpeechPadFrames < _redemptionFrames) {
          final framesToKeep = _speechBuffer.sublist(
              _speechBuffer.length - (_redemptionFrames - _endSpeechPadFrames));
          _speechBuffer.clear();
          _preSpeechBuffer.clear();
          _preSpeechBuffer.addAll(framesToKeep);
          // Ensure we don't exceed preSpeechPadFrames limit
          while (_preSpeechBuffer.length > _preSpeechPadFrames) {
            _preSpeechBuffer.removeAt(0);
          }
        } else {
          _speechBuffer.clear();
        }
      }
    } else {
      // Not speaking, maintain pre-speech buffer
      _addToPreSpeechBuffer(data);
    }
  }

  void _handleIntermediateFrame(Float32List data) {
    if (_speaking) {
      _speechBuffer.add(data);
      _redemptionCounter = 0;
      // DO NOT reset _sentRedemptionFrames here - this is critical!
    } else {
      _addToPreSpeechBuffer(data);
    }
  }

  /// Force speech end detection
  void forceEndSpeech() {
    if (_speaking && _speechPositiveFrameCount >= _minSpeechFrames) {
      if (_isDebug) print('VadIteratorImpl: Forcing speech end.');
      _onVadEvent?.call(VadEvent(
        type: VadEventType.end,
        timestamp: _getCurrentTimestamp(),
        message:
            'Speech forcefully ended at ${_getCurrentTimestamp().toStringAsFixed(3)}s',
        audioData: _combineFrames(_speechBuffer),
      ));
      // Reset state
      _speaking = false;
      _redemptionCounter = 0;
      _speechPositiveFrameCount = 0;
      _speechBuffer.clear();
      _preSpeechBuffer.clear();
      _speechStartIndex = 0;
      _sentRedemptionFrames = 0;
      _speechRealStartFired = false;
    }
  }

  void _addToPreSpeechBuffer(Float32List data) {
    _preSpeechBuffer.add(data);
    while (_preSpeechBuffer.length > _preSpeechPadFrames) {
      _preSpeechBuffer.removeAt(0);
    }
  }

  double _getCurrentTimestamp() {
    return _currentSample / _sampleRate;
  }

  /// Combines a list of audio frames into a single Uint8List audio buffer
  Uint8List _combineFrames(List<Float32List> frames) {
    final int totalLength = frames.fold(0, (sum, frame) => sum + frame.length);
    final Float32List combined = Float32List(totalLength);
    int offset = 0;
    for (var frame in frames) {
      combined.setRange(offset, offset + frame.length, frame);
      offset += frame.length;
    }
    final int16Data = Int16List.fromList(
        combined.map((e) => (e * 32767).clamp(-32768, 32767).toInt()).toList());
    final Uint8List audioData = Uint8List.view(int16Data.buffer);
    return audioData;
  }

  /// Adds silence padding frames to the given frame list
  void _addSilencePadding(List<Float32List> frames, int paddingFrames) {
    for (int i = 0; i < paddingFrames; i++) {
      frames.add(Float32List(_frameSamples)); // Silent frame (all zeros)
    }
  }

  /// Processes speech buffer with endSpeechPadFrames support
  /// Returns frames from startIndex to calculated end position, with silence padding if needed
  List<Float32List> _processAudioBuffer({
    required List<Float32List> frames,
    required int startIndex,
    required int framesToRemove,
  }) {
    List<Float32List> result;

    if (framesToRemove > 0) {
      // Standard case: remove frames from the end
      final endIndex =
          (frames.length - framesToRemove).clamp(startIndex, frames.length);
      result = frames.sublist(startIndex, endIndex);
    } else {
      // Need to add silence padding
      result = frames.sublist(startIndex);
      _addSilencePadding(result, -framesToRemove);
    }

    return result;
  }

  /// Emits a chunk VadEvent with the given frames and message
  void _emitChunkEvent(List<Float32List> frames, String message,
      {bool isFinal = false}) {
    final audioData = _combineFrames(frames);
    _onVadEvent?.call(VadEvent(
      type: VadEventType.chunk,
      timestamp: _getCurrentTimestamp(),
      message: message,
      audioData: audioData,
      isFinal: isFinal,
    ));
  }

  /// Handles final chunk emission when speech ends
  void _handleFinalChunkEmission() {
    if (_numFramesToEmit <= 0) return;

    // Calculate the end position based on whether we've sent redemption frames
    final int endFramesToRemove;
    if (_sentRedemptionFrames == 0) {
      endFramesToRemove = _redemptionFrames - _endSpeechPadFrames;
    } else {
      endFramesToRemove = _sentRedemptionFrames - _endSpeechPadFrames;
    }

    // Only emit if we have frames to send
    if (_speechStartIndex < _speechBuffer.length || endFramesToRemove < 0) {
      final frames = _processAudioBuffer(
        frames: _speechBuffer,
        startIndex: _speechStartIndex,
        framesToRemove: endFramesToRemove,
      );

      if (frames.isNotEmpty) {
        _emitChunkEvent(frames,
            'Final audio chunk emitted at ${_getCurrentTimestamp().toStringAsFixed(3)}s',
            isFinal: true);
      }
    }
  }

  List<double> _convertBytesToFloat32(Uint8List data) {
    final buffer = data.buffer;
    final int16List = Int16List.view(buffer);
    return int16List.map((e) => e / 32768.0).toList();
  }

  /// Factory method to create platform-appropriate VAD iterator
  ///
  /// [isDebug] - Enable debug logging
  /// [sampleRate] - Audio sample rate (typically 16000 Hz)
  /// [frameSamples] - Frame size in samples (512, 1024, or 1536 recommended)
  /// [positiveSpeechThreshold] - Threshold for detecting speech start (0.0-1.0)
  /// [negativeSpeechThreshold] - Threshold for detecting speech end (0.0-1.0)
  /// [redemptionFrames] - Frames of silence before ending speech
  /// [preSpeechPadFrames] - Frames to include before speech detection
  /// [minSpeechFrames] - Minimum frames required for valid speech
  /// [model] - Silero model version ('v4' or 'v5')
  /// [baseAssetPath] - Base URL or path for model assets
  /// [onnxWASMBasePath] - Base URL for ONNX Runtime WASM files (Web only)
  /// [endSpeechPadFrames] - Frames to append after speech detection
  /// [numFramesToEmit] - Number of frames before emitting chunk events
  /// [threadingConfig] - Threading configuration for ONNX Runtime (Native only)
  /// [onLog] - Optional callback for routing model-init breadcrumb logs
  static Future<VadIterator> create({
    required bool isDebug,
    required int sampleRate,
    required int frameSamples,
    required double positiveSpeechThreshold,
    required double negativeSpeechThreshold,
    required int redemptionFrames,
    required int preSpeechPadFrames,
    required int minSpeechFrames,
    required String model,
    String baseAssetPath = 'https://cdn.jsdelivr.net/npm/@keyurmaru/vad@0.0.1/',
    String onnxWASMBasePath =
        'https://cdn.jsdelivr.net/npm/onnxruntime-web@1.22.0/dist/',
    int endSpeechPadFrames = 1,
    int numFramesToEmit = 0,
    dynamic threadingConfig,
    VadLogCallback? onLog,
  }) async {
    // Get the model path
    final modelPath = getModelUrl(baseAssetPath, model);

    // Create the inference instance using the factory method
    final inference = await VadInference.create(
      model: model,
      modelPath: modelPath,
      sampleRate: sampleRate,
      isDebug: isDebug,
      onnxWASMBasePath: onnxWASMBasePath,
      threadingConfig: threadingConfig,
      onLog: onLog,
    );

    // Create and return the unified iterator implementation
    return VadIterator._(
      isDebug: isDebug,
      sampleRate: sampleRate,
      frameSamples: frameSamples,
      positiveSpeechThreshold: positiveSpeechThreshold,
      negativeSpeechThreshold: negativeSpeechThreshold,
      redemptionFrames: redemptionFrames,
      preSpeechPadFrames: preSpeechPadFrames,
      minSpeechFrames: minSpeechFrames,
      endSpeechPadFrames: endSpeechPadFrames,
      numFramesToEmit: numFramesToEmit,
      inference: inference,
      onLog: onLog,
    );
  }
}
