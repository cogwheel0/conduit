// ignore_for_file: public_member_api_docs

import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:vad/src/platform/native/bindings/bindings.dart';
import 'package:vad/src/platform/native/bindings/onnxruntime_bindings_generated.dart'
    as bg;
import 'package:vad/src/platform/native/onnxruntime/ort_status.dart';

/// A class about onnx runtime environment.
class OrtEnv {
  static final OrtEnv _instance = OrtEnv._();

  static OrtEnv get instance => _instance;

  ffi.Pointer<bg.OrtEnv>? _ptr;

  late ffi.Pointer<bg.OrtApi> _ortApiPtr;

  static OrtApiVersion _apiVersion = OrtApiVersion.api14;

  OrtEnv._() {
    _ortApiPtr = onnxRuntimeBinding.OrtGetApiBase()
        .ref
        .GetApi
        .asFunction<ffi.Pointer<bg.OrtApi> Function(int)>()(_apiVersion.value);
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
    final statusPtr = _ortApiPtr.ref.CreateEnv.asFunction<
            bg.OrtStatusPtr Function(int, ffi.Pointer<ffi.Char>,
                ffi.Pointer<ffi.Pointer<bg.OrtEnv>>)>()(
        level.value, logId.toNativeUtf8().cast<ffi.Char>(), pp);
    OrtStatus.checkOrtStatus(statusPtr);
    _ptr = pp.value;
    _setLanguageProjection();
    calloc.free(pp);
  }

  /// Release the onnx runtime environment.
  void release() {
    if (_ptr == null) {
      return;
    }
    _ortApiPtr.ref.ReleaseEnv
        .asFunction<void Function(ffi.Pointer<bg.OrtEnv>)>()(_ptr!);
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
    final status = _ortApiPtr.ref.SetLanguageProjection.asFunction<
        bg.OrtStatusPtr Function(
            ffi.Pointer<bg.OrtEnv>, int)>()(_ptr!, 0); // ORT_PROJECTION_C
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
  late ffi.Pointer<bg.OrtAllocator> _ptr;

  static final OrtAllocator _instance = OrtAllocator._();

  static OrtAllocator get instance => _instance;

  ffi.Pointer<bg.OrtAllocator> get ptr => _ptr;

  OrtAllocator._() {
    final pp = calloc<ffi.Pointer<bg.OrtAllocator>>();
    final statusPtr =
        OrtEnv.instance.ortApiPtr.ref.GetAllocatorWithDefaultOptions.asFunction<
            bg.OrtStatusPtr Function(
                ffi.Pointer<ffi.Pointer<bg.OrtAllocator>>)>()(pp);
    OrtStatus.checkOrtStatus(statusPtr);
    _ptr = pp.value;
    calloc.free(pp);
  }
}
