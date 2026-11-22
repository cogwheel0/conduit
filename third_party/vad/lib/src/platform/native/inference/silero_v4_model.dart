// lib/src/platform/native/inference/silero_v4_model.dart
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
import 'package:vad/src/platform/native/onnxruntime/ort_session.dart';
import 'package:vad/src/platform/native/onnxruntime/ort_value.dart';
import 'package:vad/src/platform/native/onnxruntime/ort_threading_config.dart';

class SileroV4Model implements VadModel {
  final OrtSession _session;
  final OrtSessionOptions _sessionOptions;
  final OrtValueTensor _srOrt;
  final OrtPreparedRun _preparedRun;
  final int _outputIdx;
  final int _hIdx;
  final int _cIdx;

  static const int _batch = 1;
  static const List<int> _stateShape = [2, _batch, 64];

  final Float32List _hide = Float32List(2 * _batch * 64);
  final Float32List _cell = Float32List(2 * _batch * 64);
  final List<int> _inputShape = [_batch, 0];

  SileroV4Model._(
    this._session,
    this._sessionOptions,
    this._srOrt,
    this._preparedRun,
    this._outputIdx,
    this._hIdx,
    this._cIdx,
  ) {
    resetState();
  }

  static Future<SileroV4Model> create(
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
        'model=v4 path=$modelPath bytes=${bytes.length} sampleRate=$sampleRate '
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
      final inputNames = getModelInputNames('v4');
      final outputIndices = getModelOutputIndices('v4');
      srOrt = OrtValueTensor.createTensorWithData(sampleRate);
      preparedRun = OrtPreparedRun(
        [
          inputNames['input']!,
          inputNames['sr']!,
          inputNames['h']!,
          inputNames['c']!,
        ],
        session.outputNames,
      );

      if (isDebug) {
        print('SileroV4Model initialized from $modelPath');
        print('Model input names: ${session.inputNames}');
        print('Model output names: ${session.outputNames}');
        print(
            'Threading config: intraOp=${config.intraOpNumThreads}, interOp=${config.interOpNumThreads}');
      }

      return SileroV4Model._(
        session,
        sessionOptions,
        srOrt,
        preparedRun,
        outputIndices['output']!,
        outputIndices['h']!,
        outputIndices['c']!,
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
    _hide.fillRange(0, _hide.length, 0.0);
    _cell.fillRange(0, _cell.length, 0.0);
  }

  @override
  Future<SpeechProbabilities> process(Float32List frame) async {
    _inputShape[1] = frame.length;

    OrtValueTensor? inputOrt;
    OrtValueTensor? hOrt;
    OrtValueTensor? cOrt;
    List<OrtValueTensor>? outputs;
    try {
      inputOrt = OrtValueTensor.createTensorWithDataList(frame, _inputShape);
      hOrt = OrtValueTensor.createTensorWithDataList(_hide, _stateShape);
      cOrt = OrtValueTensor.createTensorWithDataList(_cell, _stateShape);
      outputs = _session.runPrepared(
        _preparedRun,
        [inputOrt, _srOrt, hOrt, cOrt],
      );

      if (outputs.length < 3 ||
          _outputIdx >= outputs.length ||
          _hIdx >= outputs.length ||
          _cIdx >= outputs.length) {
        throw Exception(
            'Invalid model outputs: expected 3 outputs but got ${outputs.length}');
      }

      final speechProb = outputs[_outputIdx].firstFloatValue();
      outputs[_hIdx].copyFloatDataInto(_hide);
      outputs[_cIdx].copyFloatDataInto(_cell);

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
      cOrt?.release();
      hOrt?.release();
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
