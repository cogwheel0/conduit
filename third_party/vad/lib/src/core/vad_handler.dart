// lib/src/vad_handler.dart

// ignore_for_file: avoid_print

// Dart imports:
import 'dart:async';
import 'dart:typed_data';

// Package imports:
import 'package:record/record.dart';

// Project imports:
import 'package:vad/src/core/vad_event.dart';
import 'package:vad/src/core/vad_iterator.dart';
import 'package:vad/src/core/vad_log.dart';

/// Platform-agnostic Voice Activity Detection handler for real-time audio processing
///
/// Provides cross-platform VAD capabilities using Silero models with unified
/// implementation using the record library for both web and native platforms.
class VadHandler {
  AudioRecorder? _audioRecorder;
  VadIterator? _vadIterator;
  StreamSubscription<List<int>>? _audioStreamSubscription;

  bool _isDebug = false;
  bool _isInitialized = false;
  bool _submitUserSpeechOnPause = false;
  bool _isPaused = false;
  VadLogCallback? _onLog;

  // Track current model parameters to detect changes
  String? _currentModel;
  int? _currentFrameSamples;
  double? _currentPositiveSpeechThreshold;
  double? _currentNegativeSpeechThreshold;
  int? _currentRedemptionFrames;
  int? _currentPreSpeechPadFrames;
  int? _currentMinSpeechFrames;
  String? _currentBaseAssetPath;
  String? _currentOnnxWASMBasePath;
  int? _currentEndSpeechPadFrames;
  int? _currentNumFramesToEmit;

  final _onSpeechEndController = StreamController<List<double>>.broadcast();
  final _onFrameProcessedController = StreamController<
      ({double isSpeech, double notSpeech, List<double> frame})>.broadcast();
  final _onSpeechStartController = StreamController<void>.broadcast();
  final _onRealSpeechStartController = StreamController<void>.broadcast();
  final _onVADMisfireController = StreamController<void>.broadcast();
  final _onErrorController = StreamController<String>.broadcast();
  final _onEmitChunkController =
      StreamController<({List<double> samples, bool isFinal})>.broadcast();

  /// Constructor
  /// [isDebug] - Whether to enable debug logging (default: false)
  /// [onLog] - Optional callback that receives model-init breadcrumb logs
  VadHandler._({bool isDebug = false, VadLogCallback? onLog}) {
    _isDebug = isDebug;
    _onLog = onLog;
  }

  void _log(String message) => (_onLog ?? print)(message);

  /// Stream of speech end events containing processed audio data as floating point samples
  Stream<List<double>> get onSpeechEnd => _onSpeechEndController.stream;

  /// Stream of frame processing events with speech probabilities and raw frame data
  Stream<({double isSpeech, double notSpeech, List<double> frame})>
      get onFrameProcessed => _onFrameProcessedController.stream;

  /// Stream of initial speech start detection events
  Stream<void> get onSpeechStart => _onSpeechStartController.stream;

  /// Stream of validated speech start events (after minimum frame requirement)
  Stream<void> get onRealSpeechStart => _onRealSpeechStartController.stream;

  /// Stream of VAD misfire events (false positive detections)
  Stream<void> get onVADMisfire => _onVADMisfireController.stream;

  /// Stream of error events with descriptive error messages
  Stream<String> get onError => _onErrorController.stream;

  /// Stream of audio chunk events containing intermediate audio data during speech with final flag
  Stream<({List<double> samples, bool isFinal})> get onEmitChunk =>
      _onEmitChunkController.stream;

  void _handleVadEvent(VadEvent event) {
    switch (event.type) {
      case VadEventType.start:
        _onSpeechStartController.add(null);
        break;
      case VadEventType.realStart:
        _onRealSpeechStartController.add(null);
        break;
      case VadEventType.end:
        if (event.audioData != null) {
          final int16List = event.audioData!.buffer.asInt16List();
          final floatSamples = int16List.map((e) => e / 32768.0).toList();
          _onSpeechEndController.add(floatSamples);
        }
        break;
      case VadEventType.frameProcessed:
        if (event.probabilities != null && event.frameData != null) {
          _onFrameProcessedController.add((
            isSpeech: event.probabilities!.isSpeech,
            notSpeech: event.probabilities!.notSpeech,
            frame: event.frameData!
          ));
        }
        break;
      case VadEventType.misfire:
        _onVADMisfireController.add(null);
        break;
      case VadEventType.error:
        _onErrorController.add(event.message);
        break;
      case VadEventType.chunk:
        if (event.audioData != null) {
          final int16List = event.audioData!.buffer.asInt16List();
          final floatSamples = int16List.map((e) => e / 32768.0).toList();
          _onEmitChunkController
              .add((samples: floatSamples, isFinal: event.isFinal ?? false));
        }
        break;
    }
  }

  /// Start or resume listening for speech events with configurable parameters
  ///
  /// Default values are optimized for the v4 model. When using model='v5',
  /// the following parameters are automatically adjusted if not explicitly set:
  /// - preSpeechPadFrames: 1 → 3
  /// - redemptionFrames: 8 → 24
  /// - frameSamples: 1536 → 512
  /// - minSpeechFrames: 3 → 9
  ///
  /// [positiveSpeechThreshold] - Probability threshold for speech detection (0.0-1.0), default: 0.5
  /// [negativeSpeechThreshold] - Probability threshold for speech end detection (0.0-1.0), default: 0.35
  /// [preSpeechPadFrames] - Number of frames to include before speech starts, default: 1 (v4) or 3 (v5)
  /// [redemptionFrames] - Number of negative frames before ending speech, default: 8 (v4) or 24 (v5)
  /// [frameSamples] - Audio frame size in samples (512, 1024, or 1536 recommended), default: 1536 (v4) or 512 (v5)
  /// [minSpeechFrames] - Minimum frames required for valid speech detection, default: 3 (v4) or 9 (v5)
  /// [submitUserSpeechOnPause] - Whether to emit speech end event on pause, default: false
  /// [model] - VAD model version ('v4, 'v5'), default: 'v4'
  /// [baseAssetPath] - Base URL or path for model assets, default: 'https://cdn.jsdelivr.net/npm/@keyurmaru/vad@0.0.1/'
  /// [onnxWASMBasePath] - Base URL for ONNX Runtime WASM files (Web only), default: 'https://cdn.jsdelivr.net/npm/onnxruntime-web@1.22.0/dist/'
  /// [recordConfig] - Custom audio recording configuration (native platforms only)
  /// [endSpeechPadFrames] - Number of redemption frames to append to speech end, default: 1
  /// [numFramesToEmit] - Number of frames to accumulate before emitting chunk, default: 0 (disabled)
  /// [audioStream] - Custom audio stream to use instead of the built-in recorder. When provided, the internal AudioRecorder is not used.
  ///                 Should provide PCM16 audio data at 16kHz sample rate, mono channel.
  Future<void> startListening(
      {double positiveSpeechThreshold = 0.5,
      double negativeSpeechThreshold = 0.35,
      int preSpeechPadFrames = 1,
      int redemptionFrames = 8,
      int frameSamples = 1536,
      int minSpeechFrames = 3,
      bool submitUserSpeechOnPause = false,
      String model = 'v4',
      String baseAssetPath =
          'https://cdn.jsdelivr.net/npm/@keyurmaru/vad@0.0.1/',
      String onnxWASMBasePath =
          'https://cdn.jsdelivr.net/npm/onnxruntime-web@1.22.0/dist/',
      RecordConfig? recordConfig,
      int endSpeechPadFrames = 1,
      int numFramesToEmit = 0,
      Stream<Uint8List>? audioStream}) async {
    if (_isDebug) {
      print('VadHandler: startListening called with model: $model');
    }

    // Adjust parameters for v5 model if using defaults
    if (model == 'v5') {
      if (preSpeechPadFrames == 1) {
        preSpeechPadFrames = 3;
      }
      if (redemptionFrames == 8) {
        redemptionFrames = 24;
      }
      if (frameSamples == 1536) {
        frameSamples = 512;
      }
      if (minSpeechFrames == 3) {
        minSpeechFrames = 9;
      }
      if (endSpeechPadFrames == 1) {
        endSpeechPadFrames = 3;
      }
    }

    if (_isPaused && _audioStreamSubscription != null) {
      if (_isDebug) print('VadHandler: Resuming from paused state');
      _isPaused = false;
      return;
    }

    // Check if model parameters have changed
    final parametersChanged = _currentModel != model ||
        _currentFrameSamples != frameSamples ||
        _currentPositiveSpeechThreshold != positiveSpeechThreshold ||
        _currentNegativeSpeechThreshold != negativeSpeechThreshold ||
        _currentRedemptionFrames != redemptionFrames ||
        _currentPreSpeechPadFrames != preSpeechPadFrames ||
        _currentMinSpeechFrames != minSpeechFrames ||
        _currentBaseAssetPath != baseAssetPath ||
        _currentOnnxWASMBasePath != onnxWASMBasePath ||
        _currentEndSpeechPadFrames != endSpeechPadFrames ||
        _currentNumFramesToEmit != numFramesToEmit;

    if (!_isInitialized || parametersChanged) {
      if (_isDebug) {
        print(
            'VadHandler: Creating new VAD iterator - initialized: $_isInitialized, parametersChanged: $parametersChanged');
      }

      // Release old iterator if it exists
      if (_vadIterator != null) {
        if (_isDebug) {
          print('VadHandler: Releasing old VAD iterator');
        }
        await _vadIterator?.release();
        _vadIterator = null;
      }

      if (_isDebug) {
        print('VadHandler: Creating VadIterator with model: $model');
      }

      _vadIterator = await VadIterator.create(
        isDebug: _isDebug,
        sampleRate: 16000,
        frameSamples: frameSamples,
        positiveSpeechThreshold: positiveSpeechThreshold,
        negativeSpeechThreshold: negativeSpeechThreshold,
        redemptionFrames: redemptionFrames,
        preSpeechPadFrames: preSpeechPadFrames,
        minSpeechFrames: minSpeechFrames,
        model: model,
        baseAssetPath: baseAssetPath,
        onnxWASMBasePath: onnxWASMBasePath,
        endSpeechPadFrames: endSpeechPadFrames,
        numFramesToEmit: numFramesToEmit,
        onLog: _onLog,
      );
      _vadIterator?.setVadEventCallback(_handleVadEvent);

      // Update current parameters
      _currentModel = model;
      _currentFrameSamples = frameSamples;
      _currentPositiveSpeechThreshold = positiveSpeechThreshold;
      _currentNegativeSpeechThreshold = negativeSpeechThreshold;
      _currentRedemptionFrames = redemptionFrames;
      _currentPreSpeechPadFrames = preSpeechPadFrames;
      _currentMinSpeechFrames = minSpeechFrames;
      _currentBaseAssetPath = baseAssetPath;
      _currentOnnxWASMBasePath = onnxWASMBasePath;
      _currentEndSpeechPadFrames = endSpeechPadFrames;
      _currentNumFramesToEmit = numFramesToEmit;

      _submitUserSpeechOnPause = submitUserSpeechOnPause;
      _isInitialized = true;

      if (_isDebug) {
        print('VadHandler: VAD iterator created successfully');
      }
    } else {
      if (_isDebug) {
        print('VadHandler: Using existing VAD iterator');
      }
    }

    _isPaused = false;

    // Use custom audio stream if provided, otherwise use built-in recorder
    if (audioStream != null) {
      if (_isDebug) {
        print('VadHandler: Using custom audio stream');
      }

      _audioStreamSubscription = audioStream.listen((data) async {
        if (!_isPaused) {
          await _vadIterator?.processAudioData(data);
        }
      });

      if (_isDebug) {
        print('VadHandler: Custom audio stream connected successfully');
      }
    } else {
      // Create a new AudioRecorder if needed (e.g., after stopListening disposed it)
      if (_audioRecorder == null) {
        if (_isDebug) {
          print('VadHandler: Creating new AudioRecorder instance');
        }
        _audioRecorder = AudioRecorder();
      }

      if (_isDebug) {
        print('VadHandler: Checking audio permissions');
      }

      bool hasPermission = await _audioRecorder!.hasPermission();
      if (!hasPermission) {
        _onErrorController.add('VadHandler: No permission to record audio.');
        _log('VadHandler: No permission to record audio.');
        return;
      }

      if (_isDebug) {
        print('VadHandler: Audio permissions granted');
      }

      if (_isDebug) {
        print('VadHandler: Creating audio recorder config');
      }

      final config = recordConfig ??
          const RecordConfig(
              encoder: AudioEncoder.pcm16bits,
              sampleRate: 16000,
              bitRate: 16,
              numChannels: 1,
              echoCancel: true,
              autoGain: true,
              noiseSuppress: true,
              androidConfig: AndroidRecordConfig(
                audioSource: AndroidAudioSource.voiceCommunication,
                audioManagerMode: AudioManagerMode.modeInCommunication,
                speakerphone: true,
                manageBluetooth: true,
                useLegacy: false,
              ));
      if (_isDebug) {
        print('VadHandler: Starting audio stream');
      }

      try {
        final stream = await _audioRecorder!.startStream(config);

        _audioStreamSubscription = stream.listen((data) async {
          if (!_isPaused) {
            await _vadIterator?.processAudioData(data);
          }
        });

        if (_isDebug) {
          print('VadHandler: Audio stream started successfully');
        }
      } catch (e) {
        _log('VadHandler: Error starting audio stream: $e');
        _onErrorController.add('Error starting audio stream: $e');
        rethrow;
      }
    }
  }

  /// Stop listening and clean up audio resources
  Future<void> stopListening() async {
    if (_isDebug) print('VadHandler: stopListening called');
    try {
      if (_submitUserSpeechOnPause) {
        _vadIterator?.forceEndSpeech();
      }

      if (_audioStreamSubscription != null) {
        if (_isDebug) {
          print('VadHandler: Canceling audio stream subscription');
        }
        await _audioStreamSubscription?.cancel();
        _audioStreamSubscription = null;
      }

      if (_audioRecorder != null) {
        if (_isDebug) print('VadHandler: Stopping audio recorder');
        await _audioRecorder!.stop();
        await _audioRecorder!.dispose();
        _audioRecorder = null;
      }

      if (_isDebug) print('VadHandler: Resetting VAD iterator');
      _vadIterator?.reset();
      _isPaused = false;

      if (_isDebug) print('VadHandler: stopListening completed');
    } catch (e) {
      _onErrorController.add(e.toString());
      _log('VadHandler: Error stopping audio stream: $e');
    }
  }

  /// Pause listening while maintaining audio stream (can be resumed)
  Future<void> pauseListening() async {
    if (_isDebug) print('pauseListening');
    _isPaused = true;
    if (_submitUserSpeechOnPause) {
      _vadIterator?.forceEndSpeech();
    }
  }

  /// Release all resources and close streams
  Future<void> dispose() async {
    if (_isDebug) print('VadHandler: dispose called');

    if (_isDebug) print('VadHandler: stopping listening');
    await stopListening();

    if (_audioRecorder != null) {
      if (_isDebug) print('VadHandler: disposing audio recorder');
      await _audioRecorder!.dispose();
      _audioRecorder = null;
    }

    if (_isDebug) {
      print('VadHandler: canceling audio stream subscription');
    }
    _audioStreamSubscription?.cancel();
    _audioStreamSubscription = null;
    _isInitialized = false;

    // Reset current parameters
    _currentModel = null;
    _currentFrameSamples = null;
    _currentPositiveSpeechThreshold = null;
    _currentNegativeSpeechThreshold = null;
    _currentRedemptionFrames = null;
    _currentPreSpeechPadFrames = null;
    _currentMinSpeechFrames = null;
    _currentBaseAssetPath = null;
    _currentOnnxWASMBasePath = null;
    _currentEndSpeechPadFrames = null;
    _currentNumFramesToEmit = null;

    await _vadIterator?.release();
    _onSpeechEndController.close();
    _onFrameProcessedController.close();
    _onSpeechStartController.close();
    _onRealSpeechStartController.close();
    _onVADMisfireController.close();
    _onErrorController.close();
    _onEmitChunkController.close();
  }

  /// Factory method to create VAD handler instance
  ///
  /// [isDebug] - Enable debug logging for troubleshooting (default: false)
  /// [onLog] - Optional callback that receives model-init breadcrumb logs.
  /// When provided, the always-on log line emitted immediately before each
  /// ONNX Runtime session creation is routed here instead of `print`. Wire it
  /// to your crash reporter (e.g. `FirebaseCrashlytics.instance.log`) so the
  /// breadcrumb lands in crash reports if the native session creation fails.
  ///
  /// Uses unified implementation with record library for both web and native platforms.
  /// Supports Silero VAD models v4 and v5.
  static VadHandler create({bool isDebug = false, VadLogCallback? onLog}) {
    return VadHandler._(isDebug: isDebug, onLog: onLog);
  }
}
