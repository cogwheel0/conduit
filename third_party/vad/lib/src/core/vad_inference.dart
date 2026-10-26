// lib/src/core/vad_inference.dart

import 'package:vad/src/core/vad_log.dart';
import 'package:vad/src/core/vad_model.dart';
import 'package:vad/src/platform/web/inference/vad_inference_impl.dart'
    if (dart.library.io) 'package:vad/src/platform/native/inference/vad_inference_impl.dart'
    as implementation;

/// Abstract interface for VAD inference operations
///
/// This interface abstracts away platform-specific ONNX runtime details
/// and provides a consistent API for model loading and inference.
abstract class VadInference {
  /// Create a VAD inference instance for the specified model
  ///
  /// [model] - Silero model version: 'v4' or 'v5'
  /// [modelPath] - Path or URL to the ONNX model file
  /// [sampleRate] - Sample rate for audio processing (typically 16000)
  /// [isDebug] - Enable debug logging
  /// [onnxWASMBasePath] - Base URL for ONNX Runtime WASM files (Web only)
  /// [threadingConfig] - Threading configuration (Native only)
  /// [onLog] - Optional callback for routing model-init breadcrumb logs
  static Future<VadInference> create({
    required String model,
    required String modelPath,
    required int sampleRate,
    required bool isDebug,
    String? onnxWASMBasePath,
    dynamic threadingConfig,
    VadLogCallback? onLog,
  }) {
    return implementation.createVadInference(
      model: model,
      modelPath: modelPath,
      sampleRate: sampleRate,
      isDebug: isDebug,
      onnxWASMBasePath: onnxWASMBasePath,
      threadingConfig: threadingConfig,
      onLog: onLog,
    );
  }

  /// Get the underlying VAD model for processing
  VadModel get model;

  /// Release resources and cleanup
  Future<void> release();
}
