// lib/src/model_utils.dart

// ignore_for_file: public_member_api_docs

String getModelUrl(String baseAssetPath, String model) {
  final modelFile =
      model == 'v5' ? 'silero_vad_v5.onnx' : 'silero_vad_legacy.onnx';
  return '$baseAssetPath$modelFile';
}

Map<String, String> getModelInputNames(String model) {
  if (model == 'v5') {
    return {
      'input': 'input',
      'state': 'state',
      'sr': 'sr',
    };
  } else {
    return {
      'input': 'input',
      'h': 'h',
      'c': 'c',
      'sr': 'sr',
    };
  }
}

Map<String, String> getModelOutputNames(String model) {
  if (model == 'v5') {
    return {
      'output': 'output',
      'state': 'stateN',
    };
  } else {
    return {
      'output': 'output',
      'h': 'hn',
      'c': 'cn',
    };
  }
}

/// Get output indices for native platform (ONNX Runtime returns outputs as array)
Map<String, int> getModelOutputIndices(String model) {
  if (model == 'v5') {
    return {
      'output': 0, // Speech probability
      'state': 1, // State tensor
    };
  } else {
    return {
      'output': 0, // Speech probability
      'h': 1, // Hidden state
      'c': 2, // Cell state
    };
  }
}
