import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:vad/src/platform/native/bindings/onnxruntime_bindings_generated.dart'
    as bg;
import 'package:vad/src/platform/native/onnxruntime/ort_env.dart';

/// Description of the ort status.
class OrtStatus {
  OrtStatus._();

  /// Check ort status.
  static void checkOrtStatus(bg.OrtStatusPtr? ptr) {
    if (ptr == null || ptr == ffi.nullptr) {
      return;
    }
    final errorMessage = OrtEnv.instance.ortApiPtr.ref.GetErrorMessage
        .asFunction<ffi.Pointer<ffi.Char> Function(bg.OrtStatusPtr)>()(ptr)
        .cast<Utf8>()
        .toDartString();
    final errorCode = OrtEnv.instance.ortApiPtr.ref.GetErrorCode
        .asFunction<int Function(bg.OrtStatusPtr)>()(ptr);
    final ortErrorCode = _OrtErrorCode.valueOf(errorCode);
    OrtEnv.instance.ortApiPtr.ref.ReleaseStatus
        .asFunction<void Function(bg.OrtStatusPtr)>()(ptr);
    if (ortErrorCode == _OrtErrorCode.ok) {
      return;
    }
    throw _OrtException(ortErrorCode, errorMessage);
  }
}

class _OrtException implements Exception {
  final String? message;
  final _OrtErrorCode code;

  const _OrtException([this.code = _OrtErrorCode.unknown, this.message]);

  @override
  String toString() {
    return 'code=${code.value}, message=$message';
  }
}

enum _OrtErrorCode {
  unknown(-1),
  ok(0),
  fail(1),
  invalidArgument(2),
  noSuchFile(3),
  noModel(4),
  engineError(5),
  runtimeException(6),
  invalidProtobuf(7),
  modelLoaded(8),
  notImplemented(9),
  invalidGraph(10),
  epFail(11);

  final int value;

  const _OrtErrorCode(this.value);

  static _OrtErrorCode valueOf(int type) {
    switch (type) {
      case 0:
        return ok;
      case 1:
        return fail;
      case 2:
        return invalidArgument;
      case 3:
        return noSuchFile;
      case 4:
        return noModel;
      case 5:
        return engineError;
      case 6:
        return runtimeException;
      case 7:
        return invalidProtobuf;
      case 8:
        return modelLoaded;
      case 9:
        return notImplemented;
      case 10:
        return invalidGraph;
      case 11:
        return epFail;
      default:
        return unknown;
    }
  }
}
