// lib/src/web/inference/silero_v5_model.dart

// ignore_for_file: public_member_api_docs, avoid_print

// Dart imports:
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

// Project imports:
import 'package:vad/src/platform/web/onnxruntime/onnx_runtime_web.dart';
import 'package:vad/src/utils/model_utils.dart';
import 'package:vad/src/core/vad_event.dart';
import 'package:vad/src/core/vad_log.dart';
import 'package:vad/src/core/vad_model.dart';

class SileroV5Model implements VadModel {
  final InferenceSession _session;
  final Map<String, String> _inputNames;
  final Map<String, String> _outputNames;
  final VadLogCallback? _onLog;
  Tensor? _state;
  Tensor? _sr;
  Future<void>? _currentProcessing;
  int _processCount = 0;

  SileroV5Model._(
      this._session, this._inputNames, this._outputNames, this._onLog) {
    resetState();
  }

  void _log(String message) => (_onLog ?? print)(message);

  static Future<SileroV5Model> create(
    String modelUrl, [
    String? onnxWASMBasePath,
    VadLogCallback? onLog,
  ]) async {
    final log = onLog ?? print;
    try {
      final wasmPath = onnxWASMBasePath ??
          'https://cdn.jsdelivr.net/npm/onnxruntime-web@1.22.0/dist/';
      final normalizedWasmPath =
          wasmPath.endsWith('/') ? wasmPath : '$wasmPath/';
      ort.env.wasm.wasmPaths = normalizedWasmPath;
      final session = await ort.InferenceSession.create(modelUrl.toJS).toDart;
      final inputNames = getModelInputNames('v5');
      final outputNames = getModelOutputNames('v5');

      return SileroV5Model._(session, inputNames, outputNames, onLog);
    } catch (e) {
      log('VadModel: web SileroV5 session creation failed: $e');
      rethrow;
    }
  }

  @override
  void resetState() {
    final zeroes = Float32List(2 * 1 * 128);
    _state = (ort.Tensor as JSFunction).callAsConstructor(
      'float32'.toJS,
      zeroes.toJS,
      [2, 1, 128].map((e) => e.toJS).toList().toJS,
    ) as Tensor;

    final srArray = [16000].map((e) => e.toJS).toList().toJS;
    _sr = (ort.Tensor as JSFunction).callAsConstructor(
      'int64'.toJS,
      srArray,
      [1].map((e) => e.toJS).toList().toJS,
    ) as Tensor;
  }

  @override
  Future<SpeechProbabilities> process(Float32List frame) async {
    await _currentProcessing;
    final processingFuture = _processFrameInternal(frame);
    _currentProcessing = processingFuture.then((_) {});
    return processingFuture;
  }

  Future<SpeechProbabilities> _processFrameInternal(Float32List frame) async {
    try {
      _processCount++;

      final inputTensor = (ort.Tensor as JSFunction).callAsConstructor(
        'float32'.toJS,
        frame.toJS,
        [1, frame.length].map((e) => e.toJS).toList().toJS,
      ) as Tensor;

      final feeds = {
        _inputNames['input']!: inputTensor,
        _inputNames['state']!: _state!,
        _inputNames['sr']!: _sr!,
      }.jsify()! as JSObject;

      final results = await _session.run(feeds).toDart;

      final output = results[_outputNames['output']!];
      final newState = results[_outputNames['state']!];

      _state = newState;

      final prob = (output.data.toDart)[0];
      return SpeechProbabilities(
        isSpeech: prob,
        notSpeech: 1.0 - prob,
      );
    } catch (e) {
      _log(
          'VadModel: web SileroV5 inference failed (processCount=$_processCount): $e');
      rethrow;
    }
  }

  @override
  Future<void> release() async {
    await _session.release().toDart;
  }
}
