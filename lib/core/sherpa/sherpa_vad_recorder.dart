import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'sherpa_runtime.dart';
import 'sherpa_storage.dart';

/// Captures microphone PCM while the shared STT worker owns VAD and, when
/// selected, the recognizer. Server STT uses the same worker in VAD-only mode.
final class SherpaVadRecorder {
  SherpaVadRecorder({required SherpaSttWorker worker, SherpaStorage? storage})
    : _worker = worker,
      _storage = storage ?? SherpaStorage();

  static const sampleRate = 16000;
  static const frameSamples = 512;
  static const threshold = 0.6;
  static const minSpeechDurationSeconds = 0.256;
  static const int maxSpeechDurationSeconds = 90;
  static const int maxSpeechDurationSamples =
      maxSpeechDurationSeconds * sampleRate;
  static const bufferSizeSeconds = 120.0;
  static const preRollSamples = 16 * frameSamples;
  static const postRollSamples = 6 * frameSamples;
  static const maximumHistorySamples =
      maxSpeechDurationSamples + preRollSamples + postRollSamples;

  final SherpaSttWorker _worker;
  final SherpaStorage _storage;
  AudioRecorder? _recorder;
  final StreamController<List<double>> _speechEnd = StreamController.broadcast(
    sync: true,
  );
  final StreamController<List<double>> _frames = StreamController.broadcast();
  final StreamController<String> _errors = StreamController.broadcast();
  final List<int> _pendingPcm = [];
  StreamSubscription<Uint8List>? _audioSubscription;
  StreamSubscription<Float32List>? _segmentSubscription;
  Future<void> _frameQueue = Future<void>.value();
  Future<void> _lifecycleQueue = Future<void>.value();
  var _generation = 0;
  var _disposed = false;

  Stream<List<double>> get onSpeechEnd => _speechEnd.stream;
  Stream<List<double>> get onFrameProcessed => _frames.stream;
  Stream<String> get onError => _errors.stream;

  Future<void> start({
    required RecordConfig recordConfig,
    required double minSilenceDuration,
    bool feedRecognizer = false,
  }) {
    final generation = ++_generation;
    return _serializeLifecycle(() async {
      await _stopCurrent();
      _checkActive(generation);

      final vad = await _storage.prepareVadModel();
      _checkActive(generation);
      await _worker.configureVad(
        modelPath: vad.path,
        threshold: threshold,
        minSilenceDuration: minSilenceDuration,
        minSpeechDuration: minSpeechDurationSeconds,
        windowSize: frameSamples,
        maxSpeechDuration: maxSpeechDurationSeconds.toDouble(),
        sampleRate: sampleRate,
        bufferSizeInSeconds: bufferSizeSeconds,
        preRollSamples: preRollSamples,
        postRollSamples: postRollSamples,
        maximumHistorySamples: maximumHistorySamples,
        feedRecognizer: feedRecognizer,
      );
      _checkActive(generation);

      _segmentSubscription = _worker.vadSegments.listen((samples) {
        if (samples.isNotEmpty) _speechEnd.add(samples);
      });
      final recorder = _recorder ??= AudioRecorder();
      final stream = await recorder.startStream(recordConfig);
      if (!_isActive(generation)) {
        await recorder.stop();
        throw StateError('Sherpa VAD startup was cancelled');
      }
      _audioSubscription = stream.listen(
        _acceptPcm,
        onError: (Object error) => _errors.add(error.toString()),
      );
    });
  }

  Future<void> stop() {
    _generation++;
    return _serializeLifecycle(_stopCurrent);
  }

  Future<void> _stopCurrent() async {
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    try {
      await _recorder?.stop();
    } on Object {
      // The recorder may not have been started.
    }
    if (_pendingPcm.isNotEmpty) {
      _pendingPcm.addAll(
        List<int>.filled(frameSamples * 2 - _pendingPcm.length, 0),
      );
      _sendFrame(_pendingPcm);
      _pendingPcm.clear();
    }
    await _frameQueue;
    _frameQueue = Future<void>.value();
    try {
      await _worker.flushVad().timeout(const Duration(seconds: 2));
    } on Object {
      // A failed worker is surfaced by the frame/configure operation.
    }
    await _segmentSubscription?.cancel();
    _segmentSubscription = null;
    try {
      await _worker.unloadVad();
    } on Object {
      // The worker may already have exited.
    }
  }

  Future<void> _serializeLifecycle(Future<void> Function() action) {
    final previous = _lifecycleQueue;
    final operation = () async {
      try {
        await previous;
      } on Object {
        // A failed prior operation must not wedge later stop/start requests.
      }
      await action();
    }();
    _lifecycleQueue = operation;
    return operation;
  }

  bool _isActive(int generation) => !_disposed && generation == _generation;

  void _checkActive(int generation) {
    if (!_isActive(generation)) {
      throw StateError('Sherpa VAD startup was cancelled');
    }
  }

  void _acceptPcm(Uint8List bytes) {
    _pendingPcm.addAll(bytes);
    const frameBytes = frameSamples * 2;
    while (_pendingPcm.length >= frameBytes) {
      final frame = _pendingPcm.sublist(0, frameBytes);
      _pendingPcm.removeRange(0, frameBytes);
      _sendFrame(frame);
    }
  }

  void _sendFrame(List<int> pcm) {
    final samples = Float32List(frameSamples);
    for (var i = 0; i < frameSamples; i++) {
      var value = pcm[i * 2] | (pcm[i * 2 + 1] << 8);
      if (value >= 0x8000) value -= 0x10000;
      samples[i] = value / 32768.0;
    }
    _frames.add(samples);
    _frameQueue = _frameQueue
        .then((_) => _worker.acceptVadWaveform(samples))
        .catchError((Object error) {
          _errors.add(error.toString());
        });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    await _serializeLifecycle(_stopCurrent);
    await _recorder?.dispose();
    _recorder = null;
    await _speechEnd.close();
    await _frames.close();
    await _errors.close();
  }
}
