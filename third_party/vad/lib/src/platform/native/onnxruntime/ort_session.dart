// ignore_for_file: public_member_api_docs

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:vad/src/platform/native/bindings/onnxruntime_bindings_generated.dart'
    as bg;
import 'package:vad/src/platform/native/onnxruntime/ort_env.dart';
import 'package:vad/src/platform/native/onnxruntime/ort_isolate_session.dart';
import 'package:vad/src/platform/native/onnxruntime/ort_status.dart';
import 'package:vad/src/platform/native/onnxruntime/ort_value.dart';

/// Pre-allocated native run options, UTF-8 name arrays, and pointer buffers
/// reused across repeated [OrtSession.runPrepared] calls.
class OrtPreparedRun {
  late final OrtRunOptions _runOptions;
  late final ffi.Pointer<ffi.Pointer<ffi.Char>> _inputNamePtrs;
  late final ffi.Pointer<ffi.Pointer<bg.OrtValue>> _inputPtrs;
  late final int _inputLength;
  late final ffi.Pointer<ffi.Pointer<ffi.Char>> _outputNamePtrs;
  late final ffi.Pointer<ffi.Pointer<bg.OrtValue>> _outputPtrs;
  late final int _outputLength;
  late final ffi.Pointer<ffi.UnsignedInt> _onnxTypePtr;
  bool _released = false;

  OrtPreparedRun(List<String> inputNames, List<String> outputNames) {
    final inputLength = inputNames.length;
    final outputLength = outputNames.length;
    OrtRunOptions? runOptions;
    ffi.Pointer<ffi.Pointer<ffi.Char>>? inputNamePtrs;
    ffi.Pointer<ffi.Pointer<bg.OrtValue>>? inputPtrs;
    ffi.Pointer<ffi.Pointer<ffi.Char>>? outputNamePtrs;
    ffi.Pointer<ffi.Pointer<bg.OrtValue>>? outputPtrs;
    ffi.Pointer<ffi.UnsignedInt>? onnxTypePtr;
    var committed = false;

    try {
      runOptions = OrtRunOptions();
      inputNamePtrs = calloc<ffi.Pointer<ffi.Char>>(inputLength);
      for (var i = 0; i < inputLength; ++i) {
        inputNamePtrs[i] = inputNames[i].toNativeUtf8().cast<ffi.Char>();
      }
      inputPtrs = calloc<ffi.Pointer<bg.OrtValue>>(inputLength);

      outputNamePtrs = calloc<ffi.Pointer<ffi.Char>>(outputLength);
      for (var i = 0; i < outputLength; ++i) {
        outputNamePtrs[i] = outputNames[i].toNativeUtf8().cast<ffi.Char>();
      }
      outputPtrs = calloc<ffi.Pointer<bg.OrtValue>>(outputLength);
      onnxTypePtr = calloc<ffi.UnsignedInt>();

      _runOptions = runOptions;
      _inputNamePtrs = inputNamePtrs;
      _inputPtrs = inputPtrs;
      _inputLength = inputLength;
      _outputNamePtrs = outputNamePtrs;
      _outputPtrs = outputPtrs;
      _outputLength = outputLength;
      _onnxTypePtr = onnxTypePtr;
      committed = true;
    } finally {
      if (!committed) {
        if (onnxTypePtr != null) calloc.free(onnxTypePtr);
        if (outputPtrs != null) calloc.free(outputPtrs);
        if (outputNamePtrs != null) {
          for (var i = 0; i < outputLength; ++i) {
            if (outputNamePtrs[i] != ffi.nullptr) {
              malloc.free(outputNamePtrs[i]);
            }
          }
          calloc.free(outputNamePtrs);
        }
        if (inputPtrs != null) calloc.free(inputPtrs);
        if (inputNamePtrs != null) {
          for (var i = 0; i < inputLength; ++i) {
            if (inputNamePtrs[i] != ffi.nullptr) {
              malloc.free(inputNamePtrs[i]);
            }
          }
          calloc.free(inputNamePtrs);
        }
        runOptions?.release();
      }
    }
  }

  void release() {
    if (_released) return;
    _released = true;
    for (var i = 0; i < _inputLength; ++i) {
      malloc.free(_inputNamePtrs[i]);
    }
    for (var i = 0; i < _outputLength; ++i) {
      malloc.free(_outputNamePtrs[i]);
    }
    calloc.free(_inputNamePtrs);
    calloc.free(_inputPtrs);
    calloc.free(_outputNamePtrs);
    calloc.free(_outputPtrs);
    calloc.free(_onnxTypePtr);
    _runOptions.release();
  }
}

class OrtSession {
  late ffi.Pointer<bg.OrtSession> _ptr;
  late int _inputCount;
  late List<String> _inputNames;
  late int _outputCount;
  late List<String> _outputNames;
  OrtIsolateSession? _isolateSession;
  bool _released = false;

  int get address => _ptr.address;
  int get inputCount => _inputCount;
  List<String> get inputNames => _inputNames;
  int get outputCount => _outputCount;
  List<String> get outputNames => _outputNames;

  /// Creates a session from buffer.
  OrtSession.fromBuffer(Uint8List modelBuffer, OrtSessionOptions options) {
    final pp = calloc<ffi.Pointer<bg.OrtSession>>();
    final size = modelBuffer.length;
    final bufferPtr = calloc<ffi.Uint8>(size);
    try {
      bufferPtr.asTypedList(size).setRange(0, size, modelBuffer);
      final statusPtr = OrtEnv.instance.api.createSessionFromArray(
        OrtEnv.instance.ptr,
        bufferPtr.cast(),
        size,
        options._ptr,
        pp,
      );
      OrtStatus.checkOrtStatus(statusPtr);
      _ptr = pp.value;
    } finally {
      calloc.free(pp);
      calloc.free(bufferPtr);
    }

    try {
      _init();
    } catch (_) {
      OrtEnv.instance.api.releaseSession(_ptr);
      _released = true;
      rethrow;
    }
  }

  /// Creates a session from a pointer's address.
  OrtSession.fromAddress(int address) {
    _ptr = ffi.Pointer.fromAddress(address);
    _init();
  }

  void _init() {
    _inputCount = _getInputCount();
    _inputNames = _getInputNames();
    _outputCount = _getOutputCount();
    _outputNames = _getOutputNames();
  }

  int _getInputCount() {
    final countPtr = calloc<ffi.Size>();
    try {
      final statusPtr =
          OrtEnv.instance.api.sessionGetInputCount(_ptr, countPtr);
      OrtStatus.checkOrtStatus(statusPtr);
      return countPtr.value;
    } finally {
      calloc.free(countPtr);
    }
  }

  int _getOutputCount() {
    final countPtr = calloc<ffi.Size>();
    try {
      final statusPtr =
          OrtEnv.instance.api.sessionGetOutputCount(_ptr, countPtr);
      OrtStatus.checkOrtStatus(statusPtr);
      return countPtr.value;
    } finally {
      calloc.free(countPtr);
    }
  }

  List<String> _getInputNames() {
    final api = OrtEnv.instance.api;
    final allocator = OrtAllocator.instance.ptr;
    final list = <String>[];
    for (var i = 0; i < _inputCount; ++i) {
      final namePtrPtr = calloc<ffi.Pointer<ffi.Char>>();
      ffi.Pointer<ffi.Char> namePtr = ffi.nullptr;
      try {
        final statusPtr =
            api.sessionGetInputName(_ptr, i, allocator, namePtrPtr);
        OrtStatus.checkOrtStatus(statusPtr);
        namePtr = namePtrPtr.value;
        list.add(namePtr.cast<Utf8>().toDartString());
      } finally {
        if (namePtr != ffi.nullptr) {
          final freeStatus = api.allocatorFree(allocator, namePtr.cast());
          if (freeStatus != ffi.nullptr) {
            api.releaseStatus(freeStatus);
          }
        }
        calloc.free(namePtrPtr);
      }
    }
    return list;
  }

  List<String> _getOutputNames() {
    final api = OrtEnv.instance.api;
    final allocator = OrtAllocator.instance.ptr;
    final list = <String>[];
    for (var i = 0; i < _outputCount; ++i) {
      final namePtrPtr = calloc<ffi.Pointer<ffi.Char>>();
      ffi.Pointer<ffi.Char> namePtr = ffi.nullptr;
      try {
        final statusPtr =
            api.sessionGetOutputName(_ptr, i, allocator, namePtrPtr);
        OrtStatus.checkOrtStatus(statusPtr);
        namePtr = namePtrPtr.value;
        list.add(namePtr.cast<Utf8>().toDartString());
      } finally {
        if (namePtr != ffi.nullptr) {
          final freeStatus = api.allocatorFree(allocator, namePtr.cast());
          if (freeStatus != ffi.nullptr) {
            api.releaseStatus(freeStatus);
          }
        }
        calloc.free(namePtrPtr);
      }
    }
    return list;
  }

  /// Performs inference synchronously using pre-allocated native run buffers.
  List<OrtValueTensor> runPrepared(
    OrtPreparedRun prepared,
    List<OrtValue> inputs,
  ) {
    if (prepared._released) {
      throw StateError('OrtPreparedRun has been released');
    }
    if (inputs.length != prepared._inputLength) {
      throw ArgumentError.value(
        inputs.length,
        'inputs.length',
        'Expected ${prepared._inputLength} inputs',
      );
    }
    for (var i = 0; i < prepared._inputLength; ++i) {
      prepared._inputPtrs[i] = inputs[i].ptr;
    }
    return _runNative(
      prepared._runOptions,
      prepared._inputNamePtrs,
      prepared._inputPtrs,
      prepared._inputLength,
      prepared._outputNamePtrs,
      prepared._outputPtrs,
      prepared._outputLength,
      prepared._onnxTypePtr,
    );
  }

  /// Performs inference synchronously.
  List<OrtValue?> run(OrtRunOptions runOptions, Map<String, OrtValue> inputs,
      [List<String>? outputNames]) {
    final inputLength = inputs.length;
    outputNames ??= _outputNames;
    final outputLength = outputNames.length;
    final inputNamePtrs = calloc<ffi.Pointer<ffi.Char>>(inputLength);
    final inputPtrs = calloc<ffi.Pointer<bg.OrtValue>>(inputLength);
    final outputNamePtrs = calloc<ffi.Pointer<ffi.Char>>(outputLength);
    final outputPtrs = calloc<ffi.Pointer<bg.OrtValue>>(outputLength);
    final onnxTypePtr = calloc<ffi.UnsignedInt>();
    try {
      var i = 0;
      for (final entry in inputs.entries) {
        inputNamePtrs[i] = entry.key.toNativeUtf8().cast<ffi.Char>();
        inputPtrs[i] = entry.value.ptr;
        ++i;
      }
      for (var j = 0; j < outputLength; ++j) {
        outputNamePtrs[j] = outputNames[j].toNativeUtf8().cast<ffi.Char>();
      }
      return _runNative(
        runOptions,
        inputNamePtrs,
        inputPtrs,
        inputLength,
        outputNamePtrs,
        outputPtrs,
        outputLength,
        onnxTypePtr,
      );
    } finally {
      // toNativeUtf8 allocates each name with malloc; Run only reads them.
      for (var j = 0; j < inputLength; ++j) {
        if (inputNamePtrs[j] != ffi.nullptr) {
          malloc.free(inputNamePtrs[j]);
        }
      }
      for (var j = 0; j < outputLength; ++j) {
        if (outputNamePtrs[j] != ffi.nullptr) {
          malloc.free(outputNamePtrs[j]);
        }
      }
      calloc.free(onnxTypePtr);
      calloc.free(inputNamePtrs);
      calloc.free(inputPtrs);
      calloc.free(outputNamePtrs);
      calloc.free(outputPtrs);
    }
  }

  List<OrtValueTensor> _runNative(
    OrtRunOptions runOptions,
    ffi.Pointer<ffi.Pointer<ffi.Char>> inputNamePtrs,
    ffi.Pointer<ffi.Pointer<bg.OrtValue>> inputPtrs,
    int inputLength,
    ffi.Pointer<ffi.Pointer<ffi.Char>> outputNamePtrs,
    ffi.Pointer<ffi.Pointer<bg.OrtValue>> outputPtrs,
    int outputLength,
    ffi.Pointer<ffi.UnsignedInt> onnxTypePtr,
  ) {
    if (_released) {
      throw StateError('OrtSession has been released');
    }
    final api = OrtEnv.instance.api;
    for (var i = 0; i < outputLength; ++i) {
      outputPtrs[i] = ffi.nullptr;
    }

    final outputs = <OrtValueTensor>[];
    var wrappedCount = 0;
    try {
      final statusPtr = api.run(
        _ptr,
        runOptions._ptr,
        inputNamePtrs,
        inputPtrs,
        inputLength,
        outputNamePtrs,
        outputLength,
        outputPtrs,
      );
      OrtStatus.checkOrtStatus(statusPtr);

      for (var index = 0; index < outputLength; ++index) {
        final ortValuePtr = outputPtrs[index];
        final typeStatus = api.getValueType(ortValuePtr, onnxTypePtr);
        OrtStatus.checkOrtStatus(typeStatus);
        final onnxType = ONNXType.valueOf(onnxTypePtr.value);
        if (onnxType == ONNXType.tensor) {
          outputs.add(OrtValueTensor(ortValuePtr));
          wrappedCount = index + 1;
        } else {
          // This should never happen with VAD models
          throw Exception(
              'Unexpected output type: $onnxType. VAD only produces tensors.');
        }
      }
      return outputs;
    } catch (_) {
      for (final output in outputs) {
        output.release();
      }
      for (var index = wrappedCount; index < outputLength; ++index) {
        final rawPtr = outputPtrs[index];
        if (rawPtr != ffi.nullptr) {
          api.releaseValue(rawPtr);
        }
      }
      rethrow;
    }
  }

  /// Performs inference asynchronously.
  Future<List<OrtValue?>>? runAsync(
      OrtRunOptions runOptions, Map<String, OrtValue> inputs,
      [List<String>? outputNames]) {
    _isolateSession ??= OrtIsolateSession(this);
    return _isolateSession?.run(runOptions, inputs, outputNames);
  }

  void release() {
    if (_released) return;
    _released = true;
    _isolateSession?.release();
    _isolateSession = null;
    OrtEnv.instance.api.releaseSession(_ptr);
  }
}

class OrtSessionOptions {
  late ffi.Pointer<bg.OrtSessionOptions> _ptr;
  bool _released = false;

  OrtSessionOptions() {
    _create();
  }

  void _create() {
    final pp = calloc<ffi.Pointer<bg.OrtSessionOptions>>();
    try {
      final statusPtr = OrtEnv.instance.api.createSessionOptions(pp);
      OrtStatus.checkOrtStatus(statusPtr);
      _ptr = pp.value;
    } finally {
      calloc.free(pp);
    }
  }

  void release() {
    if (_released) return;
    _released = true;
    OrtEnv.instance.api.releaseSessionOptions(_ptr);
  }

  /// Sets the number of intra op threads.
  void setIntraOpNumThreads(int numThreads) {
    final statusPtr =
        OrtEnv.instance.api.setIntraOpNumThreads(_ptr, numThreads);
    OrtStatus.checkOrtStatus(statusPtr);
  }

  /// Sets the number of inter op threads.
  void setInterOpNumThreads(int numThreads) {
    final statusPtr =
        OrtEnv.instance.api.setInterOpNumThreads(_ptr, numThreads);
    OrtStatus.checkOrtStatus(statusPtr);
  }

  /// Sets the level of session graph optimization.
  void setSessionGraphOptimizationLevel(GraphOptimizationLevel level) {
    final statusPtr =
        OrtEnv.instance.api.setSessionGraphOptimizationLevel(_ptr, level.value);
    OrtStatus.checkOrtStatus(statusPtr);
  }
}

class OrtRunOptions {
  late ffi.Pointer<bg.OrtRunOptions> _ptr;
  bool _released = false;

  int get address => _ptr.address;

  OrtRunOptions() {
    _create();
  }

  OrtRunOptions.fromAddress(int address) {
    _ptr = ffi.Pointer.fromAddress(address);
  }

  void _create() {
    final pp = calloc<ffi.Pointer<bg.OrtRunOptions>>();
    try {
      final statusPtr = OrtEnv.instance.api.createRunOptions(pp);
      OrtStatus.checkOrtStatus(statusPtr);
      _ptr = pp.value;
    } finally {
      calloc.free(pp);
    }
  }

  void release() {
    if (_released) return;
    _released = true;
    OrtEnv.instance.api.releaseRunOptions(_ptr);
  }
}

enum GraphOptimizationLevel {
  ortDisableAll(0),
  ortEnableBasic(1),
  ortEnableExtended(2),
  ortEnableAll(99);

  final int value;

  const GraphOptimizationLevel(this.value);
}
