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
  final int _sampleRate;
  final SileroV5Context _context;

  static const int _batch = 1;
  var _state = List.filled(
      2, List.filled(1, Float32List.fromList(List.filled(128, 0.0))));

  SileroV5Model._(
    this._session,
    this._sessionOptions,
    this._sampleRate,
  ) : _context = SileroV5Context(_sampleRate) {
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

    try {
      final sessionOptions = OrtSessionOptions()
        ..setInterOpNumThreads(config.interOpNumThreads)
        ..setIntraOpNumThreads(config.intraOpNumThreads)
        ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);

      final session = OrtSession.fromBuffer(bytes, sessionOptions);

      if (isDebug) {
        print('SileroV5Model initialized from $modelPath');
        print('Model input names: ${session.inputNames}');
        print('Model output names: ${session.outputNames}');
        print(
            'Threading config: intraOp=${config.intraOpNumThreads}, interOp=${config.interOpNumThreads}');
      }

      return SileroV5Model._(session, sessionOptions, sampleRate);
    } catch (e, st) {
      log('VadModel: OrtSession creation failed ($context): $e\n$st');
      rethrow;
    }
  }

  @override
  void resetState() {
    _state = List.filled(
        2, List.filled(1, Float32List.fromList(List.filled(128, 0.0))));
    _context.reset();
  }

  @override
  Future<SpeechProbabilities> process(Float32List frame) async {
    final inputNames = getModelInputNames('v5');
    final outputIndices = getModelOutputIndices('v5');

    final input = _context.prepend(frame);
    final inputOrt =
        OrtValueTensor.createTensorWithDataList(input, [_batch, input.length]);
    final srOrt = OrtValueTensor.createTensorWithData(_sampleRate);
    final stateOrt = OrtValueTensor.createTensorWithDataList(_state);
    final runOptions = OrtRunOptions();

    final inputs = {
      inputNames['input']!: inputOrt,
      inputNames['sr']!: srOrt,
      inputNames['state']!: stateOrt,
    };

    final outputs = _session.run(runOptions, inputs);

    // Safe to release inputs now - isolate creates its own copies
    inputOrt.release();
    srOrt.release();
    stateOrt.release();
    runOptions.release();

    final outputIdx = outputIndices['output']!;
    final stateIdx = outputIndices['state']!;

    // Check if we have the expected number of outputs
    if (outputs.length < 2 ||
        outputs[outputIdx] == null ||
        outputs[stateIdx] == null) {
      throw Exception(
          'Invalid model outputs: expected 2 outputs but got ${outputs.length}');
    }

    final speechProb = (outputs[outputIdx]!.value as List<List<double>>)[0][0];

    // Deep copy the state to avoid memory issues across isolates
    final stateValue = outputs[stateIdx]!.value as List<List<List<double>>>;
    _state = List.generate(
      stateValue.length,
      (i) => List.generate(
        stateValue[i].length,
        (j) => Float32List.fromList(List<double>.from(stateValue[i][j])),
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
