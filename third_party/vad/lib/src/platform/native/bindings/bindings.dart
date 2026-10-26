import 'dart:ffi';
import 'dart:io';
import 'package:vad/src/platform/native/bindings/onnxruntime_bindings_generated.dart';

final DynamicLibrary _dylib = () {
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libonnxruntime.so');
  }

  if (Platform.isIOS) {
    return DynamicLibrary.process();
  }

  if (Platform.isMacOS) {
    return DynamicLibrary.process();
  }

  if (Platform.isWindows) {
    return DynamicLibrary.open('onnxruntime.dll');
  }

  if (Platform.isLinux) {
    return DynamicLibrary.open('libonnxruntime.so.1.22.0');
  }

  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}();

/// ONNX Runtime Bindings for VAD
final onnxRuntimeBinding = OnnxRuntimeBindings(_dylib);
