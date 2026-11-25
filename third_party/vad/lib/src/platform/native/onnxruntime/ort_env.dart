// ignore_for_file: public_member_api_docs

import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:vad/src/platform/native/bindings/bindings.dart';
import 'package:vad/src/platform/native/bindings/onnxruntime_bindings_generated.dart'
    as bg;
import 'package:vad/src/platform/native/onnxruntime/ort_status.dart';

/// Cached FFI function bindings looked up once from [bg.OrtApi].
class OrtApiFunctions {
  final ffi.Pointer<bg.OrtApi> _apiPtr;

  OrtApiFunctions(this._apiPtr);

  late final bg.OrtStatusPtr Function(
          int, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Pointer<bg.OrtEnv>>)
      createEnv = _apiPtr.ref.CreateEnv.asFunction();

  late final void Function(ffi.Pointer<bg.OrtEnv>) releaseEnv =
      _apiPtr.ref.ReleaseEnv.asFunction();

  late final bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtEnv>, int)
      setLanguageProjection = _apiPtr.ref.SetLanguageProjection.asFunction();

  late final bg.OrtStatusPtr Function(ffi.Pointer<ffi.Pointer<bg.OrtAllocator>>)
      getAllocatorWithDefaultOptions =
      _apiPtr.ref.GetAllocatorWithDefaultOptions.asFunction();

  late final bg.OrtStatusPtr Function(
          ffi.Pointer<bg.OrtAllocator>, ffi.Pointer<ffi.Pointer<bg.OrtMemoryInfo>>)
      allocatorGetInfo = _apiPtr.ref.AllocatorGetInfo.asFunction();

  late final bg.OrtStatusPtr Function(
          ffi.Pointer<bg.OrtAllocator>, ffi.Pointer<ffi.Void>) allocatorFree =
      _apiPtr.ref.AllocatorFree.asFunction();

  late final ffi.Pointer<ffi.Char> Function(bg.OrtStatusPtr) getErrorMessage =
      _apiPtr.ref.GetErrorMessage.asFunction();

  late final int Function(bg.OrtStatusPtr) getErrorCode =
      _apiPtr.ref.GetErrorCode.asFunction();

  late final void Function(bg.OrtStatusPtr) releaseStatus =
      _apiPtr.ref.ReleaseStatus.asFunction();

  late final bg.OrtStatusPtr Function(
      ffi.Pointer<bg.OrtEnv>,
      ffi.Pointer<ffi.Void>,
      int,
      ffi.Pointer<bg.OrtSessionOptions>,
      ffi.Pointer<ffi.Pointer<bg.OrtSession>>) createSessionFromArray =
      _apiPtr.ref.CreateSessionFromArray.asFunction();

  late final bg.OrtStatusPtr Function(
          ffi.Pointer<bg.OrtSession>, ffi.Pointer<ffi.Size>)
      sessionGetInputCount = _apiPtr.ref.SessionGetInputCount.asFunction();

  late final bg.OrtStatusPtr Function(
          ffi.Pointer<bg.OrtSession>, ffi.Pointer<ffi.Size>)
      sessionGetOutputCount = _apiPtr.ref.SessionGetOutputCount.asFunction();

  late final bg.OrtStatusPtr Function(
      ffi.Pointer<bg.OrtSession>,
      int,
      ffi.Pointer<bg.OrtAllocator>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>) sessionGetInputName =
      _apiPtr.ref.SessionGetInputName.asFunction();

  late final bg.OrtStatusPtr Function(
      ffi.Pointer<bg.OrtSession>,
      int,
      ffi.Pointer<bg.OrtAllocator>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>) sessionGetOutputName =
      _apiPtr.ref.SessionGetOutputName.asFunction();

  late final bg.OrtStatusPtr Function(
      ffi.Pointer<bg.OrtSession>,
      ffi.Pointer<bg.OrtRunOptions>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
      ffi.Pointer<ffi.Pointer<bg.OrtValue>>,
      int,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
      int,
      ffi.Pointer<ffi.Pointer<bg.OrtValue>>) run = _apiPtr.ref.Run.asFunction();

  late final bg.OrtStatusPtr Function(
          ffi.Pointer<bg.OrtValue>, ffi.Pointer<ffi.UnsignedInt>) getValueType =
      _apiPtr.ref.GetValueType.asFunction();

  late final void Function(ffi.Pointer<bg.OrtSession>) releaseSession =
      _apiPtr.ref.ReleaseSession.asFunction();

  late final bg.OrtStatusPtr Function(
          ffi.Pointer<ffi.Pointer<bg.OrtSessionOptions>>) createSessionOptions =
      _apiPtr.ref.CreateSessionOptions.asFunction();

  late final void Function(ffi.Pointer<bg.OrtSessionOptions>)
      releaseSessionOptions = _apiPtr.ref.ReleaseSessionOptions.asFunction();

  late final bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>, int)
      setIntraOpNumThreads = _apiPtr.ref.SetIntraOpNumThreads.asFunction();

  late final bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>, int)
      setInterOpNumThreads = _apiPtr.ref.SetInterOpNumThreads.asFunction();

  late final bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>, int)
      setSessionGraphOptimizationLevel =
      _apiPtr.ref.SetSessionGraphOptimizationLevel.asFunction();

  late final bg.OrtStatusPtr Function(
          ffi.Pointer<ffi.Pointer<bg.OrtRunOptions>>) createRunOptions =
      _apiPtr.ref.CreateRunOptions.asFunction();

  late final void Function(ffi.Pointer<bg.OrtRunOptions>) releaseRunOptions =
      _apiPtr.ref.ReleaseRunOptions.asFunction();

  late final void Function(ffi.Pointer<bg.OrtValue>) releaseValue =
      _apiPtr.ref.ReleaseValue.asFunction();

  late final bg.OrtStatusPtr Function(
      ffi.Pointer<bg.OrtMemoryInfo>,
      ffi.Pointer<ffi.Void>,
      int,
      ffi.Pointer<ffi.Int64>,
      int,
      int,
      ffi.Pointer<ffi.Pointer<bg.OrtValue>>) createTensorWithDataAsOrtValue =
      _apiPtr.ref.CreateTensorWithDataAsOrtValue.asFunction();

  late final bg.OrtStatusPtr Function(
          ffi.Pointer<bg.OrtValue>, ffi.Pointer<ffi.Pointer<ffi.Void>>)
      getTensorMutableData = _apiPtr.ref.GetTensorMutableData.asFunction();

  late final bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtValue>,
          ffi.Pointer<ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>>)
      getTensorTypeAndShape = _apiPtr.ref.GetTensorTypeAndShape.asFunction();

  late final void Function(ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>)
      releaseTensorTypeAndShapeInfo =
      _apiPtr.ref.ReleaseTensorTypeAndShapeInfo.asFunction();

  late final bg.OrtStatusPtr Function(
          ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>, ffi.Pointer<ffi.Size>)
      getDimensionsCount = _apiPtr.ref.GetDimensionsCount.asFunction();

  late final bg.OrtStatusPtr Function(
          ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>, ffi.Pointer<ffi.Int64>, int)
      getDimensions = _apiPtr.ref.GetDimensions.asFunction();

  late final bg.OrtStatusPtr Function(
          ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>, ffi.Pointer<ffi.Size>)
      getTensorShapeElementCount =
      _apiPtr.ref.GetTensorShapeElementCount.asFunction();

  late final bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>,
          ffi.Pointer<ffi.UnsignedInt>) getTensorElementType =
      _apiPtr.ref.GetTensorElementType.asFunction();
}

/// A class about onnx runtime environment.
class OrtEnv {
  static final OrtEnv _instance = OrtEnv._();

  static OrtEnv get instance => _instance;

  ffi.Pointer<bg.OrtEnv>? _ptr;

  late final ffi.Pointer<bg.OrtApi> _ortApiPtr;
  late final OrtApiFunctions _api;

  static OrtApiVersion _apiVersion = OrtApiVersion.api14;

  OrtEnv._() {
    _ortApiPtr = onnxRuntimeBinding.OrtGetApiBase()
        .ref
        .GetApi
        .asFunction<ffi.Pointer<bg.OrtApi> Function(int)>()(_apiVersion.value);
    _api = OrtApiFunctions(_ortApiPtr);
  }

  /// Set ort's api version.
  static void setApiVersion(OrtApiVersion apiVersion) {
    _apiVersion = apiVersion;
  }

  /// Initialize the onnx runtime environment.
  void init(
      {OrtLoggingLevel level = OrtLoggingLevel.warning,
      String logId = 'DartOnnxRuntime'}) {
    final pp = calloc<ffi.Pointer<bg.OrtEnv>>();
    final logIdPtr = logId.toNativeUtf8();
    try {
      // CreateEnv copies logid into an internal std::string, so logIdPtr is
      // safe to free immediately after the call returns.
      final statusPtr = _api.createEnv(
        level.value,
        logIdPtr.cast<ffi.Char>(),
        pp,
      );
      OrtStatus.checkOrtStatus(statusPtr);
      _ptr = pp.value;
      try {
        _setLanguageProjection();
      } catch (_) {
        release();
        rethrow;
      }
    } finally {
      malloc.free(logIdPtr);
      calloc.free(pp);
    }
  }

  /// Release the onnx runtime environment.
  void release() {
    if (_ptr == null) {
      return;
    }
    _api.releaseEnv(_ptr!);
    _ptr = null;
  }

  /// Gets the version of onnx runtime.
  static String get version => onnxRuntimeBinding.OrtGetApiBase()
      .ref
      .GetVersionString
      .asFunction<ffi.Pointer<ffi.Char> Function()>()()
      .cast<Utf8>()
      .toDartString();

  ffi.Pointer<bg.OrtApi> get ortApiPtr => _ortApiPtr;

  OrtApiFunctions get api => _api;

  ffi.Pointer<bg.OrtEnv> get ptr {
    if (_ptr == null) {
      init();
    }
    return _ptr!;
  }

  void _setLanguageProjection() {
    if (_ptr == null) {
      init();
    }
    final status = _api.setLanguageProjection(_ptr!, 0); // ORT_PROJECTION_C
    OrtStatus.checkOrtStatus(status);
  }
}

/// An enumerated value of api's version.
enum OrtApiVersion {
  /// The initial release of the ORT API.
  api1(1),

  /// Post 1.0 builds of the ORT API.
  api2(2),

  /// Post 1.3 builds of the ORT API.
  api3(3),

  /// Post 1.6 builds of the ORT API.
  api7(7),

  /// Post 1.7 builds of the ORT API.
  api8(8),

  /// Post 1.10 builds of the ORT API.
  api11(11),

  /// Post 1.12 builds of the ORT API.
  api13(13),

  /// Post 1.13 builds of the ORT API.
  api14(14),

  /// The initial release of the ORT training API.
  trainingApi1(1);

  final int value;

  const OrtApiVersion(this.value);
}

/// An enumerated value of log's level.
enum OrtLoggingLevel {
  verbose(0),
  info(1),
  warning(2),
  error(3),
  fatal(4);

  final int value;

  const OrtLoggingLevel(this.value);
}

class OrtAllocator {
  late final ffi.Pointer<bg.OrtAllocator> _ptr;
  late final ffi.Pointer<bg.OrtMemoryInfo> _memoryInfoPtr;

  static final OrtAllocator _instance = OrtAllocator._();

  static OrtAllocator get instance => _instance;

  ffi.Pointer<bg.OrtAllocator> get ptr => _ptr;

  /// Borrowed [bg.OrtMemoryInfo] owned by the default allocator.
  ffi.Pointer<bg.OrtMemoryInfo> get memoryInfoPtr => _memoryInfoPtr;

  OrtAllocator._() {
    final api = OrtEnv.instance.api;
    final pp = calloc<ffi.Pointer<bg.OrtAllocator>>();
    try {
      final statusPtr = api.getAllocatorWithDefaultOptions(pp);
      OrtStatus.checkOrtStatus(statusPtr);
      _ptr = pp.value;
    } finally {
      calloc.free(pp);
    }

    final infoPtrPtr = calloc<ffi.Pointer<bg.OrtMemoryInfo>>();
    try {
      final statusPtr = api.allocatorGetInfo(_ptr, infoPtrPtr);
      OrtStatus.checkOrtStatus(statusPtr);
      _memoryInfoPtr = infoPtrPtr.value;
    } finally {
      calloc.free(infoPtrPtr);
    }
  }
}
