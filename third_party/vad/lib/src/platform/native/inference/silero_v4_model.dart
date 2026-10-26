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
  final int _sampleRate;

  static const int _batch = 1;
  var _hide = List.filled(
      2, List.filled(_batch, Float32List.fromList(List.filled(64, 0.0))));
  var _cell = List.filled(
      2, List.filled(_batch, Float32List.fromList(List.filled(64, 0.0))));

  SileroV4Model._(
    this._session,
    this._sessionOptions,
    this._sampleRate,
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

    try {
      final sessionOptions = OrtSessionOptions()
        ..setInterOpNumThreads(config.interOpNumThreads)
        ..setIntraOpNumThreads(config.intraOpNumThreads)
        ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);

      final session = OrtSession.fromBuffer(bytes, sessionOptions);

      if (isDebug) {
        print('SileroV4Model initialized from $modelPath');
        print('Model input names: ${session.inputNames}');
        print('Model output names: ${session.outputNames}');
        print(
            'Threading config: intraOp=${config.intraOpNumThreads}, interOp=${config.interOpNumThreads}');
      }

      return SileroV4Model._(session, sessionOptions, sampleRate);
    } catch (e, st) {
      log('VadModel: OrtSession creation failed ($context): $e\n$st');
      rethrow;
    }
  }

  @override
  void resetState() {
    _hide = List.filled(
        2, List.filled(_batch, Float32List.fromList(List.filled(64, 0.0))));
    _cell = List.filled(
        2, List.filled(_batch, Float32List.fromList(List.filled(64, 0.0))));
  }

  @override
  Future<SpeechProbabilities> process(Float32List frame) async {
    final inputNames = getModelInputNames('v4');
    final outputIndices = getModelOutputIndices('v4');

    final inputOrt =
        OrtValueTensor.createTensorWithDataList(frame, [_batch, frame.length]);
    final srOrt = OrtValueTensor.createTensorWithData(_sampleRate);
    final hOrt = OrtValueTensor.createTensorWithDataList(_hide);
    final cOrt = OrtValueTensor.createTensorWithDataList(_cell);
    final runOptions = OrtRunOptions();

    final inputs = {
      inputNames['input']!: inputOrt,
      inputNames['sr']!: srOrt,
      inputNames['h']!: hOrt,
      inputNames['c']!: cOrt,
    };

    final outputs = _session.run(runOptions, inputs);

    // Safe to release inputs now - isolate creates its own copies
    inputOrt.release();
    srOrt.release();
    hOrt.release();
    cOrt.release();
    runOptions.release();

    final outputIdx = outputIndices['output']!;
    final hIdx = outputIndices['h']!;
    final cIdx = outputIndices['c']!;

    // Check if we have the expected number of outputs
    if (outputs.length < 3 ||
        outputs[outputIdx] == null ||
        outputs[hIdx] == null ||
        outputs[cIdx] == null) {
      throw Exception(
          'Invalid model outputs: expected 3 outputs but got ${outputs.length}');
    }

    final speechProb = (outputs[outputIdx]!.value as List<List<double>>)[0][0];

    // Deep copy the state to avoid memory issues across isolates
    final hideValue = outputs[hIdx]!.value as List<List<List<double>>>;
    final cellValue = outputs[cIdx]!.value as List<List<List<double>>>;

    _hide = List.generate(
      hideValue.length,
      (i) => List.generate(
        hideValue[i].length,
        (j) => Float32List.fromList(List<double>.from(hideValue[i][j])),
      ),
    );

    _cell = List.generate(
      cellValue.length,
      (i) => List.generate(
        cellValue[i].length,
        (j) => Float32List.fromList(List<double>.from(cellValue[i][j])),
      ),
    );

    // Don't release outputs - they're already released in the isolate

    return SpeechProbabilities(
      isSpeech: speechProb,
      notSpeech: 1.0 - speechProb,
    );
  }

  @override
  Future<void> release() async {
    _sessionOptions.release();
    _session.release();
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
