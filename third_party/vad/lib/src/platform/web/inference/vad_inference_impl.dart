// lib/src/platform/web/vad_inference_impl.dart
// ignore_for_file: avoid_print

import 'package:vad/src/core/vad_inference.dart';
import 'package:vad/src/core/vad_log.dart';
import 'package:vad/src/core/vad_model.dart';
import 'package:vad/src/platform/web/inference/silero_v4_model.dart';
import 'package:vad/src/platform/web/inference/silero_v5_model.dart';

/// Web implementation of VadInference
class _VadInferenceImpl implements VadInference {
  final VadModel _model;

  _VadInferenceImpl(this._model);

  @override
  VadModel get model => _model;

  @override
  Future<void> release() async {
    await _model.release();
  }
}

/// Factory function to create VadInference for web platform
Future<VadInference> createVadInference({
  required String model,
  required String modelPath,
  required int sampleRate,
  required bool isDebug,
  String? onnxWASMBasePath,
  dynamic threadingConfig, // Unused on web
  VadLogCallback? onLog,
}) async {
  if (isDebug) {
    print('VadInferenceWeb: Creating $model model from $modelPath');
  }

  VadModel vadModel;
  if (model == 'v5') {
    vadModel = await SileroV5Model.create(modelPath, onnxWASMBasePath, onLog);
  } else {
    vadModel = await SileroV4Model.create(modelPath, onnxWASMBasePath, onLog);
  }

  return _VadInferenceImpl(vadModel);
}
