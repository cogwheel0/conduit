// lib/src/platform/native/inference/silero_v5_model.dart
// ignore_for_file: public_member_api_docs, avoid_print

// Dart imports:
import 'dart:io';
import 'dart:typed_data';

// Flutter imports:
import 'package:flutter/services.dart';

// Project imports:
import 'package:vad/src/core/vad_event.dart';
import 'package:vad/src/core/vad_log.dart';
import 'package:vad/src/core/vad_model.dart';
import 'package:vad/src/utils/model_utils.dart';
import 'package:vad/src/platform/native/inference/silero_v5_context.dart';
import 'package:vad/src/platform/native/onnxruntime/ort_session.dart';
import 'package:vad/src/platform/native/onnxruntime/ort_value.dart';
import 'package:vad/src/platform/native/onnxruntime/ort_threading_config.dart';

class SileroV5Model implements VadModel {
  final OrtSession _session;
  final OrtSessionOptions _sessionOptions;
  final OrtValueTensor _srOrt;
  final OrtPreparedRun _preparedRun;
  final SileroV5Context _context;
  final int _outputIdx;
  final int _stateIdx;

  static const int _batch = 1;
  static const List<int> _stateShape = [2, _batch, 128];

  final Float32List _state = Float32List(2 * _batch * 128);
  final List<int> _inputShape = [_batch, 0];
  Float32List? _inputBuffer;

  SileroV5Model._(
    this._session,
    this._sessionOptions,
    int sampleRate,
    this._srOrt,
    this._preparedRun,
    this._outputIdx,
    this._stateIdx,
  ) : _context = SileroV5Context(sampleRate) {
    resetState();
  }

  static Future<SileroV5Model> create(
    String modelPath,
    int sampleRate,
    bool isDebug, {
    OrtThreadingConfig? threadingConfig,
    VadLogCallback? onLog,
  }) async {
    final log = onLog ?? print;
    final config = threadingConfig ?? OrtThreadingConfig.platformOptimal();
    final bytes = await _loadModelBytes(modelPath);
    final context =
        'model=v5 path=$modelPath bytes=${bytes.length} sampleRate=$sampleRate '
        'intraOp=${config.intraOpNumThreads} interOp=${config.interOpNumThreads} '
        'os=${Platform.operatingSystem} osVersion=${Platform.operatingSystemVersion}';
    log('VadModel: creating OrtSession ($context)');

    OrtSessionOptions? sessionOptions;
    OrtSession? session;
    OrtValueTensor? srOrt;
    OrtPreparedRun? preparedRun;
    try {
      sessionOptions = OrtSessionOptions();
      sessionOptions
        ..setInterOpNumThreads(config.interOpNumThreads)
        ..setIntraOpNumThreads(config.intraOpNumThreads)
        ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);

      session = OrtSession.fromBuffer(bytes, sessionOptions);
      final inputNames = getModelInputNames('v5');
      final outputIndices = getModelOutputIndices('v5');
      srOrt = OrtValueTensor.createTensorWithData(sampleRate);
      preparedRun = OrtPreparedRun(
        [inputNames['input']!, inputNames['sr']!, inputNames['state']!],
        session.outputNames,
      );

      if (isDebug) {
        print('SileroV5Model initialized from $modelPath');
        print('Model input names: ${session.inputNames}');
        print('Model output names: ${session.outputNames}');
        print(
            'Threading config: intraOp=${config.intraOpNumThreads}, interOp=${config.interOpNumThreads}');
      }

      return SileroV5Model._(
        session,
        sessionOptions,
        sampleRate,
        srOrt,
        preparedRun,
        outputIndices['output']!,
        outputIndices['state']!,
      );
    } catch (e, st) {
      preparedRun?.release();
      srOrt?.release();
      session?.release();
      sessionOptions?.release();
      log('VadModel: OrtSession creation failed ($context): $e\n$st');
      rethrow;
    }
  }

  @override
  void resetState() {
    _state.fillRange(0, _state.length, 0.0);
    _context.reset();
  }

  @override
  Future<SpeechProbabilities> process(Float32List frame) async {
    final requiredLength = _context.length + frame.length;
    var inputBuffer = _inputBuffer;
    if (inputBuffer == null || inputBuffer.length != requiredLength) {
      inputBuffer = Float32List(requiredLength);
      _inputBuffer = inputBuffer;
    }
    _context.prependInto(frame, inputBuffer);
    _inputShape[1] = requiredLength;

    OrtValueTensor? inputOrt;
    OrtValueTensor? stateOrt;
    List<OrtValueTensor>? outputs;
    try {
      inputOrt =
          OrtValueTensor.createTensorWithDataList(inputBuffer, _inputShape);
      stateOrt = OrtValueTensor.createTensorWithDataList(_state, _stateShape);
      outputs =
          _session.runPrepared(_preparedRun, [inputOrt, _srOrt, stateOrt]);

      if (outputs.length < 2 ||
          _outputIdx >= outputs.length ||
          _stateIdx >= outputs.length) {
        throw Exception(
            'Invalid model outputs: expected 2 outputs but got ${outputs.length}');
      }

      final speechProb = outputs[_outputIdx].firstFloatValue();
      outputs[_stateIdx].copyFloatDataInto(_state);

      return SpeechProbabilities(
        isSpeech: speechProb,
        notSpeech: 1.0 - speechProb,
      );
    } finally {
      if (outputs != null) {
        for (final output in outputs) {
          output.release();
        }
      }
      stateOrt?.release();
      inputOrt?.release();
    }
  }

  @override
  Future<void> release() async {
    _preparedRun.release();
    _srOrt.release();
    _session.release();
    _sessionOptions.release();
  }

  static Future<Uint8List> _loadModelBytes(String modelPath) async {
    if (modelPath.startsWith('http://') || modelPath.startsWith('https://')) {
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(modelPath));
        final response = await request.close();
        if (response.statusCode == 200) {
          final completer = BytesBuilder();
          await for (final chunk in response) {
            completer.add(chunk);
          }
          return completer.toBytes();
        } else {
          throw Exception(
              'HTTP ${response.statusCode}: Failed to download model from $modelPath');
        }
      } finally {
        client.close();
      }
    } else {
      // Load from asset bundle (local file)
      final rawAssetFile = await rootBundle.load(modelPath);
      return rawAssetFile.buffer.asUint8List();
    }
  }
}
