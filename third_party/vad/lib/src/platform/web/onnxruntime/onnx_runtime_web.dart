// lib/src/web/onnx_runtime_web.dart

// ignore_for_file: public_member_api_docs, avoid_print

// Dart imports:
import 'dart:js_interop';

@JS('ort')
external OrtGlobal get ort;

@JS()
extension type OrtGlobal._(JSObject _) implements JSObject {
  external EnvNamespace get env;
  // ignore: non_constant_identifier_names
  external InferenceSessionConstructor get InferenceSession;
  // ignore: non_constant_identifier_names
  external TensorConstructor get Tensor;
}

@JS()
extension type EnvNamespace._(JSObject _) implements JSObject {
  external WasmNamespace get wasm;
}

@JS()
extension type WasmNamespace._(JSObject _) implements JSObject {
  external set wasmPaths(String paths);
}

@JS()
extension type InferenceSessionConstructor._(JSObject _) implements JSObject {
  external JSPromise<InferenceSession> create(JSAny modelData);
}

@JS()
extension type TensorConstructor._(JSObject _) implements JSObject {
  external Tensor create(
      String type, JSFloat32Array data, JSArray<JSNumber> dims);
}

@JS()
extension type InferenceSession._(JSObject _) implements JSObject {
  external JSPromise<RunResult> run(JSObject feeds);
  external JSPromise<JSAny?> release();
}

@JS()
extension type Tensor._(JSObject _) implements JSObject {
  external JSFloat32Array get data;
  external JSArray<JSNumber> get dims;
}

@JS()
extension type RunResult._(JSObject _) implements JSObject {
  external Tensor operator [](String key);
}
