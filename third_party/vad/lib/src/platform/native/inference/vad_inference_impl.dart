// lib/src/platform/native/inference/vad_inference_impl.dart
// ignore_for_file: avoid_print

import 'package:vad/src/core/vad_inference.dart';
import 'package:vad/src/core/vad_log.dart';
import 'package:vad/src/core/vad_model.dart';
import 'package:vad/src/platform/native/onnxruntime/ort_threading_config.dart';
import 'package:vad/src/platform/native/inference/silero_v4_model.dart';
import 'package:vad/src/platform/native/inference/silero_v5_model.dart';

/// Native implementation of VadInference
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

/// Factory function to create VadInference for native platform
Future<VadInference> createVadInference({
  required String model,
  required String modelPath,
  required int sampleRate,
  required bool isDebug,
  String? onnxWASMBasePath, // Unused on native
  dynamic threadingConfig,
  VadLogCallback? onLog,
}) async {
  if (isDebug) {
    print('VadInferenceNative: Creating $model model from $modelPath');
  }

  // Cast threadingConfig to proper type if provided
  OrtThreadingConfig? ortConfig;
  if (threadingConfig != null) {
    ortConfig = threadingConfig as OrtThreadingConfig;
  }

  VadModel vadModel;
  if (model == 'v5') {
    vadModel = await SileroV5Model.create(
      modelPath,
      sampleRate,
      isDebug,
      threadingConfig: ortConfig,
      onLog: onLog,
    );
  } else {
    vadModel = await SileroV4Model.create(
      modelPath,
      sampleRate,
      isDebug,
      threadingConfig: ortConfig,
      onLog: onLog,
    );
  }

  return _VadInferenceImpl(vadModel);
}
