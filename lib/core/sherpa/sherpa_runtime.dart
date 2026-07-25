import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'sherpa_model.dart';
import 'sherpa_storage.dart';

String buildSherpaTtsRuleFsts(Map<String, String> files) => [
  files['phoneFst'],
  files['dateFst'],
  files['numberFst'],
].whereType<String>().join(',');

final class SherpaSttEvent {
  const SherpaSttEvent({
    required this.text,
    required this.isFinal,
    this.language,
  });

  final String text;
  final bool isFinal;
  final String? language;
}

final class SherpaModelLoadException implements Exception {
  const SherpaModelLoadException(this.message);

  final String message;

  @override
  String toString() => 'SherpaModelLoadException: $message';
}

final class SherpaSttWorker {
  SherpaSttWorker({SherpaStorage? storage})
    : _storage = storage ?? SherpaStorage();

  final SherpaStorage _storage;
  final StreamController<SherpaSttEvent> _events = StreamController.broadcast();
  final StreamController<Float32List> _vadSegments = StreamController.broadcast(
    sync: true,
  );
  _SherpaRpc? _rpc;
  Future<_SherpaRpc>? _spawningRpc;

  Stream<SherpaSttEvent> get events => _events.stream;
  Stream<Float32List> get vadSegments => _vadSegments.stream;
  bool get isAlive => _rpc?.isAlive ?? false;

  Future<void> load(
    InstalledSherpaModel installed, {
    String? languageCode,
  }) async {
    final rpc = await _ensureRpc();
    final files = await _storage.resolveRuntimeFiles(
      installed.model,
      installed.directory,
    );
    await rpc.call('load', {
      'adapter': installed.model.adapter.name,
      'files': files,
      'modelType': installed.model.runtime.modelType,
      'threads': installed.model.runtime.threadCount,
      'language': languageCode ?? 'auto',
    });
  }

  Future<void> acceptWaveform(Float32List samples) async {
    final rpc = _rpc;
    if (rpc == null || !rpc.isAlive) {
      throw StateError('Sherpa STT worker is not running');
    }
    await rpc.call('audio', {'samples': samples});
  }

  Future<void> configureVad({
    required String modelPath,
    required double threshold,
    required double minSilenceDuration,
    required double minSpeechDuration,
    required int windowSize,
    required double maxSpeechDuration,
    required int sampleRate,
    required double bufferSizeInSeconds,
    required int preRollSamples,
    required int postRollSamples,
    required int maximumHistorySamples,
    required bool feedRecognizer,
  }) async {
    final rpc = await _ensureRpc();
    await rpc.call('vadConfigure', {
      'model': modelPath,
      'threshold': threshold,
      'minSilence': minSilenceDuration,
      'minSpeech': minSpeechDuration,
      'windowSize': windowSize,
      'maxSpeech': maxSpeechDuration,
      'sampleRate': sampleRate,
      'bufferSize': bufferSizeInSeconds,
      'preRoll': preRollSamples,
      'postRoll': postRollSamples,
      'maximumHistory': maximumHistorySamples,
      'feedRecognizer': feedRecognizer,
    });
  }

  Future<void> acceptVadWaveform(Float32List samples) async {
    final rpc = _rpc;
    if (rpc == null || !rpc.isAlive) {
      throw StateError('Sherpa speech worker is not running');
    }
    await rpc.call('vadAudio', {'samples': samples});
  }

  Future<void> flushVad() async {
    final rpc = _rpc;
    if (rpc == null || !rpc.isAlive) return;
    await rpc.call('vadFlush');
  }

  Future<void> unloadVad() async {
    final rpc = _rpc;
    if (rpc == null || !rpc.isAlive) return;
    await rpc.call('vadUnload');
  }

  Future<SherpaSttEvent> finalize(Float32List samples) async {
    final rpc = _rpc;
    if (rpc == null || !rpc.isAlive) {
      throw StateError('Sherpa STT worker is not running');
    }
    final result = await rpc.call('finalize', {'samples': samples});
    return SherpaSttEvent(
      text: result['text'] as String? ?? '',
      isFinal: true,
      language: result['language'] as String?,
    );
  }

  Future<void> unload() async {
    final rpc = _rpc;
    if (rpc == null || !rpc.isAlive) return;
    await rpc.call('unload');
  }

  Future<_SherpaRpc> _ensureRpc() async {
    final current = _rpc;
    if (current != null && current.isAlive) return current;
    final spawning = _spawningRpc;
    if (spawning != null) return spawning;
    final future = _spawnRpc(current);
    _spawningRpc = future;
    try {
      return await future;
    } finally {
      if (identical(_spawningRpc, future)) _spawningRpc = null;
    }
  }

  Future<_SherpaRpc> _spawnRpc(_SherpaRpc? current) async {
    if (current != null) await current.dispose();
    final rpc = await _SherpaRpc.spawn(
      _sttIsolate,
      onEvent: (event) {
        if (event['event'] == 'transcript') {
          _events.add(
            SherpaSttEvent(
              text: event['text'] as String? ?? '',
              isFinal: event['final'] as bool? ?? false,
              language: event['language'] as String?,
            ),
          );
        } else if (event['event'] == 'vadSegment') {
          final samples = event['samples'];
          if (samples is Float32List && samples.isNotEmpty) {
            _vadSegments.add(samples);
          }
        }
      },
    );
    _rpc = rpc;
    return rpc;
  }

  Future<void> dispose() async {
    try {
      await _spawningRpc;
    } on Object {
      // A failed startup has no worker resources left to release.
    }
    await _rpc?.dispose();
    _rpc = null;
    await _events.close();
    await _vadSegments.close();
  }
}

final class SherpaTtsWorker {
  SherpaTtsWorker({SherpaStorage? storage})
    : _storage = storage ?? SherpaStorage();

  final SherpaStorage _storage;
  _SherpaRpc? _rpc;
  Future<_SherpaRpc>? _spawningRpc;
  InstalledSherpaModel? _installed;
  String? _languageCode;

  bool get isAlive => _rpc?.isAlive ?? false;

  Future<void> load(
    InstalledSherpaModel installed, {
    String? languageCode,
  }) async {
    final rpc = await _ensureRpc();
    final files = await _storage.resolveRuntimeFiles(
      installed.model,
      installed.directory,
    );
    await rpc.call('load', {
      'adapter': installed.model.adapter.name,
      'files': files,
      'threads': installed.model.runtime.threadCount,
      'language': languageCode ?? '',
    });
    _installed = installed;
    _languageCode = languageCode;
  }

  Future<({Float32List samples, int sampleRate})> synthesize({
    required String text,
    required int speakerId,
    required double speed,
  }) async {
    var rpc = _rpc;
    if (rpc == null || !rpc.isAlive) {
      final installed = _installed;
      if (installed == null) {
        throw StateError('No Sherpa TTS model is loaded');
      }
      await load(installed, languageCode: _languageCode);
      rpc = _rpc!;
    }
    final result = await rpc.call('synthesize', {
      'text': text,
      'speakerId': speakerId,
      'speed': speed,
    });
    return (
      samples: result['samples'] as Float32List,
      sampleRate: result['sampleRate'] as int,
    );
  }

  Future<void> unload() async {
    final rpc = _rpc;
    if (rpc != null && rpc.isAlive) await rpc.call('unload');
    _installed = null;
    _languageCode = null;
  }

  Future<_SherpaRpc> _ensureRpc() async {
    final current = _rpc;
    if (current != null && current.isAlive) return current;
    final spawning = _spawningRpc;
    if (spawning != null) return spawning;
    final future = _spawnRpc(current);
    _spawningRpc = future;
    try {
      return await future;
    } finally {
      if (identical(_spawningRpc, future)) _spawningRpc = null;
    }
  }

  Future<_SherpaRpc> _spawnRpc(_SherpaRpc? current) async {
    if (current != null) await current.dispose();
    final rpc = await _SherpaRpc.spawn(_ttsIsolate);
    _rpc = rpc;
    return rpc;
  }

  Future<void> dispose() async {
    try {
      await _spawningRpc;
    } on Object {
      // A failed startup has no worker resources left to release.
    }
    await _rpc?.dispose();
    _rpc = null;
    _installed = null;
    _languageCode = null;
  }
}

Future<void> validateSherpaRuntime(
  SherpaModel model,
  Directory directory,
) async {
  final installed = InstalledSherpaModel(
    model: model,
    directory: directory,
    installedBytes: 0,
  );
  if (model.kind == SherpaModelKind.stt) {
    final worker = SherpaSttWorker();
    try {
      await worker.load(installed, languageCode: model.languages.first.tag);
    } finally {
      await worker.dispose();
    }
  } else {
    final worker = SherpaTtsWorker();
    try {
      await worker.load(installed, languageCode: model.languages.first.tag);
    } finally {
      await worker.dispose();
    }
  }
}

typedef _IsolateEntry = void Function(SendPort);

final class _SherpaRpc {
  _SherpaRpc._(
    this._isolate,
    this._commands,
    this._events,
    this._errors,
    this._exits,
    this._eventSubscription,
    this._errorSubscription,
    this._exitSubscription,
    this._onEvent,
  );

  static const _startupTimeout = Duration(seconds: 20);
  static const _commandTimeout = Duration(minutes: 2);

  static Future<_SherpaRpc> spawn(
    _IsolateEntry entry, {
    void Function(Map<Object?, Object?> event)? onEvent,
  }) async {
    final events = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();
    final commandPort = Completer<SendPort>();
    _SherpaRpc? rpc;
    Object? startupError;
    StackTrace? startupStackTrace;
    final eventSubscription = events.listen((message) {
      if (message is SendPort) {
        if (!commandPort.isCompleted) commandPort.complete(message);
      } else if (message is Map) {
        rpc?._receive(message);
      }
    });
    final errorSubscription = errors.listen((message) {
      final error = _isolateError(message);
      final current = rpc;
      if (current == null) {
        startupError = error.error;
        startupStackTrace = error.stackTrace;
        if (!commandPort.isCompleted) {
          commandPort.completeError(error.error, error.stackTrace);
        }
      } else {
        current._fail(error.error, error.stackTrace);
      }
    });
    final exitSubscription = exits.listen((_) {
      final error = StateError('Sherpa worker exited unexpectedly');
      final current = rpc;
      if (current == null) {
        startupError = error;
        startupStackTrace = StackTrace.current;
        if (!commandPort.isCompleted) commandPort.completeError(error);
      } else {
        current._fail(error, StackTrace.current);
      }
    });

    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        entry,
        events.sendPort,
        onError: errors.sendPort,
        onExit: exits.sendPort,
        errorsAreFatal: true,
      );
      final commands = await commandPort.future.timeout(_startupTimeout);
      if (startupError != null) {
        Error.throwWithStackTrace(startupError!, startupStackTrace!);
      }
      rpc = _SherpaRpc._(
        isolate,
        commands,
        events,
        errors,
        exits,
        eventSubscription,
        errorSubscription,
        exitSubscription,
        onEvent,
      );
      return rpc;
    } catch (_) {
      isolate?.kill();
      await eventSubscription.cancel();
      await errorSubscription.cancel();
      await exitSubscription.cancel();
      events.close();
      errors.close();
      exits.close();
      rethrow;
    }
  }

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _events;
  final ReceivePort _errors;
  final ReceivePort _exits;
  final StreamSubscription<Object?> _eventSubscription;
  final StreamSubscription<Object?> _errorSubscription;
  final StreamSubscription<Object?> _exitSubscription;
  final void Function(Map<Object?, Object?> event)? _onEvent;
  final Map<int, ({String type, Completer<Map<Object?, Object?>> completer})>
  _pending = {};
  var _nextId = 1;
  var _alive = true;
  var _disposed = false;
  Future<void>? _disposeFuture;
  Future<void>? _teardownFuture;

  bool get isAlive => _alive && !_disposed;

  Future<Map<Object?, Object?>> call(
    String type, [
    Map<String, Object?> arguments = const {},
  ]) => _call(type, arguments);

  Future<Map<Object?, Object?>> _call(
    String type,
    Map<String, Object?> arguments, {
    bool allowDuringDisposal = false,
    Duration timeout = _commandTimeout,
  }) {
    if (!_alive || (_disposed && !allowDuringDisposal)) {
      return Future.error(StateError('Sherpa worker is not running'));
    }
    final id = _nextId++;
    final completer = Completer<Map<Object?, Object?>>();
    _pending[id] = (type: type, completer: completer);
    _commands.send({'id': id, 'type': type, ...arguments});
    return completer.future.timeout(
      timeout,
      onTimeout: () async {
        final error = TimeoutException(
          'Sherpa worker did not complete "$type" within '
          '${timeout.inSeconds} seconds',
        );
        await _teardown(error, StackTrace.current);
        throw error;
      },
    );
  }

  void _receive(Map message) {
    if (message['event'] != null) {
      _onEvent?.call(message.cast<Object?, Object?>());
      return;
    }
    final id = message['id'] as int?;
    final pending = id == null ? null : _pending.remove(id);
    if (pending == null) return;
    final error = message['error'];
    if (error != null) {
      final exception = pending.type == 'load'
          ? SherpaModelLoadException(error.toString())
          : StateError(error.toString());
      pending.completer.completeError(exception);
    } else {
      pending.completer.complete(message.cast<Object?, Object?>());
    }
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (!_alive) return;
    _alive = false;
    final pending = _pending.values
        .map((entry) => entry.completer)
        .toList(growable: false);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    }
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    if (_alive) {
      try {
        await _call(
          'dispose',
          const {},
          allowDuringDisposal: true,
          timeout: const Duration(seconds: 2),
        );
      } on Object {
        // The worker is best-effort during application teardown.
      }
    }
    await _teardown(
      StateError('Sherpa worker was disposed'),
      StackTrace.current,
    );
  }

  Future<void> _teardown(Object error, StackTrace stackTrace) {
    return _teardownFuture ??= _performTeardown(error, stackTrace);
  }

  Future<void> _performTeardown(Object error, StackTrace stackTrace) async {
    _disposed = true;
    _fail(error, stackTrace);
    _isolate.kill();
    await _eventSubscription.cancel();
    await _errorSubscription.cancel();
    await _exitSubscription.cancel();
    _events.close();
    _errors.close();
    _exits.close();
  }
}

({Object error, StackTrace stackTrace}) _isolateError(Object? message) {
  if (message case [final Object error, final Object stack]) {
    return (
      error: StateError('Sherpa worker failed: $error'),
      stackTrace: StackTrace.fromString(stack.toString()),
    );
  }
  return (
    error: StateError('Sherpa worker failed: $message'),
    stackTrace: StackTrace.current,
  );
}

void _sttIsolate(SendPort events) {
  sherpa.initBindings();
  final commands = ReceivePort();
  events.send(commands.sendPort);
  sherpa.OfflineRecognizer? offline;
  sherpa.OnlineRecognizer? online;
  sherpa.OnlineStream? onlineStream;
  sherpa.VoiceActivityDetector? vad;
  final vadHistory = <double>[];
  var vadHistoryStart = 0;
  var vadPreRollSamples = 0;
  var vadPostRollSamples = 0;
  var vadMaximumHistorySamples = 0;
  var vadFeedsRecognizer = false;
  String language = 'auto';

  void unload() {
    onlineStream?.free();
    onlineStream = null;
    online?.free();
    online = null;
    offline?.free();
    offline = null;
  }

  void unloadVad() {
    vad?.free();
    vad = null;
    vadHistory.clear();
    vadHistoryStart = 0;
    vadFeedsRecognizer = false;
  }

  void decodeOnline(Float32List samples) {
    final stream = onlineStream;
    final recognizer = online;
    if (stream == null || recognizer == null) return;
    stream.acceptWaveform(samples: samples, sampleRate: 16000);
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }
    final result = recognizer.getResult(stream);
    events.send({'event': 'transcript', 'text': result.text, 'final': false});
  }

  void drainVadSegments() {
    final detector = vad;
    if (detector == null) return;
    while (!detector.isEmpty()) {
      final segment = detector.front();
      detector.pop();
      final start = (segment.start - vadHistoryStart - vadPreRollSamples).clamp(
        0,
        vadHistory.length,
      );
      final end =
          (segment.start -
                  vadHistoryStart +
                  segment.samples.length +
                  vadPostRollSamples)
              .clamp(start, vadHistory.length);
      events.send({
        'event': 'vadSegment',
        'samples': Float32List.fromList(vadHistory.sublist(start, end)),
      });
    }
  }

  commands.listen((raw) {
    if (raw is! Map) return;
    final id = raw['id'] as int;
    try {
      switch (raw['type']) {
        case 'load':
          unload();
          final adapter = SherpaRuntimeAdapter.values.byName(
            raw['adapter'] as String,
          );
          final files = (raw['files'] as Map).cast<String, String>();
          final threads = raw['threads'] as int? ?? 2;
          language = raw['language'] as String? ?? 'auto';
          if (adapter == SherpaRuntimeAdapter.onlineTransducer ||
              adapter == SherpaRuntimeAdapter.onlineZipformer2Ctc) {
            final model = sherpa.OnlineModelConfig(
              transducer: adapter == SherpaRuntimeAdapter.onlineTransducer
                  ? sherpa.OnlineTransducerModelConfig(
                      encoder: files['encoder']!,
                      decoder: files['decoder']!,
                      joiner: files['joiner']!,
                    )
                  : const sherpa.OnlineTransducerModelConfig(),
              zipformer2Ctc: adapter == SherpaRuntimeAdapter.onlineZipformer2Ctc
                  ? sherpa.OnlineZipformer2CtcModelConfig(
                      model: files['model']!,
                    )
                  : const sherpa.OnlineZipformer2CtcModelConfig(),
              tokens: files['tokens']!,
              numThreads: threads,
              provider: 'cpu',
              debug: false,
              modelType: raw['modelType'] as String? ?? '',
            );
            online = sherpa.OnlineRecognizer(
              sherpa.OnlineRecognizerConfig(
                model: model,
                enableEndpoint: false,
              ),
            );
            onlineStream = online!.createStream();
            onlineStream!.setOption(key: 'language', value: language);
          } else {
            final model = sherpa.OfflineModelConfig(
              whisper: adapter == SherpaRuntimeAdapter.offlineWhisper
                  ? sherpa.OfflineWhisperModelConfig(
                      encoder: files['encoder']!,
                      decoder: files['decoder']!,
                      language: language == 'auto' ? '' : language,
                      task: 'transcribe',
                    )
                  : const sherpa.OfflineWhisperModelConfig(),
              senseVoice: adapter == SherpaRuntimeAdapter.offlineSenseVoice
                  ? sherpa.OfflineSenseVoiceModelConfig(
                      model: files['model']!,
                      language: language == 'auto' ? 'auto' : language,
                      useInverseTextNormalization: true,
                    )
                  : const sherpa.OfflineSenseVoiceModelConfig(),
              nemoCtc: adapter == SherpaRuntimeAdapter.offlineNemoCtc
                  ? sherpa.OfflineNemoEncDecCtcModelConfig(
                      model: files['model']!,
                    )
                  : const sherpa.OfflineNemoEncDecCtcModelConfig(),
              transducer: adapter == SherpaRuntimeAdapter.offlineNemoTransducer
                  ? sherpa.OfflineTransducerModelConfig(
                      encoder: files['encoder']!,
                      decoder: files['decoder']!,
                      joiner: files['joiner']!,
                    )
                  : const sherpa.OfflineTransducerModelConfig(),
              tokens: files['tokens']!,
              numThreads: threads,
              provider: 'cpu',
              debug: false,
              modelType: raw['modelType'] as String? ?? '',
            );
            offline = sherpa.OfflineRecognizer(
              sherpa.OfflineRecognizerConfig(model: model),
            );
          }
          events.send({'id': id});
          break;
        case 'audio':
          decodeOnline(raw['samples'] as Float32List);
          events.send({'id': id});
          break;
        case 'vadConfigure':
          unloadVad();
          final feedRecognizer = raw['feedRecognizer'] as bool? ?? false;
          if (!feedRecognizer) unload();
          vadPreRollSamples = raw['preRoll'] as int;
          vadPostRollSamples = raw['postRoll'] as int;
          vadMaximumHistorySamples = raw['maximumHistory'] as int;
          vadFeedsRecognizer = feedRecognizer;
          final sampleRate = raw['sampleRate'] as int;
          vad = sherpa.VoiceActivityDetector(
            config: sherpa.VadModelConfig(
              sileroVad: sherpa.SileroVadModelConfig(
                model: raw['model'] as String,
                threshold: (raw['threshold'] as num).toDouble(),
                minSilenceDuration: (raw['minSilence'] as num).toDouble(),
                minSpeechDuration: (raw['minSpeech'] as num).toDouble(),
                windowSize: raw['windowSize'] as int,
                maxSpeechDuration: (raw['maxSpeech'] as num).toDouble(),
              ),
              sampleRate: sampleRate,
              numThreads: 2,
              provider: 'cpu',
              debug: false,
            ),
            bufferSizeInSeconds: (raw['bufferSize'] as num).toDouble(),
          );
          events.send({'id': id});
          break;
        case 'vadAudio':
          final samples = raw['samples'] as Float32List;
          vadHistory.addAll(samples);
          if (vadHistory.length > vadMaximumHistorySamples) {
            final overflow = vadHistory.length - vadMaximumHistorySamples;
            vadHistory.removeRange(0, overflow);
            vadHistoryStart += overflow;
          }
          vad?.acceptWaveform(samples);
          drainVadSegments();
          if (vadFeedsRecognizer) decodeOnline(samples);
          events.send({'id': id});
          break;
        case 'vadFlush':
          vad?.flush();
          drainVadSegments();
          events.send({'id': id});
          break;
        case 'vadUnload':
          unloadVad();
          events.send({'id': id});
          break;
        case 'finalize':
          final samples = raw['samples'] as Float32List;
          String text;
          String? resultLanguage;
          if (offline case final recognizer?) {
            final stream = recognizer.createStream();
            stream.setOption(key: 'language', value: language);
            stream.acceptWaveform(samples: samples, sampleRate: 16000);
            recognizer.decode(stream);
            final result = recognizer.getResult(stream);
            text = result.text;
            resultLanguage = result.lang.isEmpty ? null : result.lang;
            stream.free();
          } else if (online case final recognizer?) {
            final stream = onlineStream!;
            stream.inputFinished();
            while (recognizer.isReady(stream)) {
              recognizer.decode(stream);
            }
            text = recognizer.getResult(stream).text;
            stream.free();
            onlineStream = recognizer.createStream();
            onlineStream!.setOption(key: 'language', value: language);
          } else {
            throw StateError('No Sherpa STT model is loaded');
          }
          events.send({'id': id, 'text': text, 'language': resultLanguage});
          break;
        case 'unload':
          unload();
          events.send({'id': id});
          break;
        case 'dispose':
          unload();
          unloadVad();
          events.send({'id': id});
          commands.close();
          break;
      }
    } catch (error) {
      events.send({'id': id, 'error': error.toString()});
    }
  });
}

void _ttsIsolate(SendPort events) {
  sherpa.initBindings();
  final commands = ReceivePort();
  events.send(commands.sendPort);
  sherpa.OfflineTts? tts;

  void unload() {
    tts?.free();
    tts = null;
  }

  commands.listen((raw) {
    if (raw is! Map) return;
    final id = raw['id'] as int;
    try {
      switch (raw['type']) {
        case 'load':
          unload();
          final adapter = SherpaRuntimeAdapter.values.byName(
            raw['adapter'] as String,
          );
          final files = (raw['files'] as Map).cast<String, String>();
          final threads = raw['threads'] as int? ?? 2;
          final language = raw['language'] as String? ?? '';
          final kokoroLexicon = [
            files['lexicon'],
            files['lexiconEn'],
            files['lexiconZh'],
          ].whereType<String>().join(',');
          final model = sherpa.OfflineTtsModelConfig(
            vits: adapter == SherpaRuntimeAdapter.ttsVits
                ? sherpa.OfflineTtsVitsModelConfig(
                    model: files['model']!,
                    tokens: files['tokens']!,
                    dataDir: files['espeakData'] ?? '',
                    lexicon: files['lexicon'] ?? '',
                  )
                : const sherpa.OfflineTtsVitsModelConfig(),
            supertonic: adapter == SherpaRuntimeAdapter.ttsSupertonic
                ? sherpa.OfflineTtsSupertonicModelConfig(
                    durationPredictor: files['durationPredictor']!,
                    textEncoder: files['textEncoder']!,
                    vectorEstimator: files['vectorEstimator']!,
                    vocoder: files['vocoder']!,
                    ttsJson: files['ttsJson']!,
                    unicodeIndexer: files['unicodeIndexer']!,
                    voiceStyle: files['voiceStyle']!,
                  )
                : const sherpa.OfflineTtsSupertonicModelConfig(),
            kokoro: adapter == SherpaRuntimeAdapter.ttsKokoro
                ? sherpa.OfflineTtsKokoroModelConfig(
                    model: files['model']!,
                    voices: files['voices']!,
                    tokens: files['tokens']!,
                    dataDir: files['espeakData']!,
                    dictDir: files['dictDir'] ?? '',
                    lexicon: kokoroLexicon,
                    lang: language,
                  )
                : const sherpa.OfflineTtsKokoroModelConfig(),
            numThreads: threads,
            provider: 'cpu',
            debug: false,
          );
          final ruleFsts = buildSherpaTtsRuleFsts(files);
          tts = sherpa.OfflineTts(
            sherpa.OfflineTtsConfig(model: model, ruleFsts: ruleFsts),
          );
          events.send({'id': id});
          break;
        case 'synthesize':
          final engine = tts;
          if (engine == null) throw StateError('No Sherpa TTS model is loaded');
          final audio = engine.generateWithConfig(
            text: raw['text'] as String,
            config: sherpa.OfflineTtsGenerationConfig(
              sid: raw['speakerId'] as int,
              speed: (raw['speed'] as num).toDouble(),
            ),
          );
          if (audio.samples.isEmpty || audio.sampleRate <= 0) {
            throw StateError('Sherpa returned no synthesized audio');
          }
          events.send({
            'id': id,
            'samples': audio.samples,
            'sampleRate': audio.sampleRate,
          });
          break;
        case 'unload':
          unload();
          events.send({'id': id});
          break;
        case 'dispose':
          unload();
          events.send({'id': id});
          commands.close();
          break;
      }
    } catch (error) {
      events.send({'id': id, 'error': error.toString()});
    }
  });
}
