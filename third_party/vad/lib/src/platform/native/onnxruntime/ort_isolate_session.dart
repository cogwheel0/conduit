// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:isolate';
import 'dart:ffi' as ffi;

import 'package:vad/src/platform/native/bindings/onnxruntime_bindings_generated.dart'
    as bg;
import 'package:vad/src/platform/native/onnxruntime/ort_session.dart';
import 'package:vad/src/platform/native/onnxruntime/ort_value.dart';

// Proxy class to hold extracted tensor values
class _OrtValueProxy implements OrtValue {
  final dynamic _extractedValue;

  _OrtValueProxy(this._extractedValue);

  @override
  ffi.Pointer<bg.OrtValue> get ptr => ffi.Pointer.fromAddress(0);

  @override
  int get address => 0;

  @override
  dynamic get value => _extractedValue;

  @override
  void release() {
    // No-op: value was already extracted
  }
}

class OrtIsolateSession {
  int address;
  final String debugName;
  late Isolate _newIsolate;
  late SendPort _newIsolateSendPort;
  late StreamSubscription _streamSubscription;
  final _outputController =
      StreamController<List<Map<String, dynamic>>>.broadcast();

  IsolateSessionState get state => _state;
  var _state = IsolateSessionState.idle;
  var _initialized = false;
  final _completer = Completer();
  Completer<void> _runLock = Completer<void>()..complete();

  OrtIsolateSession(
    OrtSession session, {
    this.debugName = 'OnnxRuntimeSessionIsolate',
  }) : address = session.address;

  Future<void> _init() async {
    final rootIsolateReceivePort = ReceivePort();
    final rootIsolateSendPort = rootIsolateReceivePort.sendPort;
    _newIsolate = await Isolate.spawn(
        createNewIsolateContext, rootIsolateSendPort,
        debugName: debugName);
    _streamSubscription = rootIsolateReceivePort.listen((message) {
      if (message is SendPort) {
        _newIsolateSendPort = message;
        _completer.complete();
      } else if (message is List &&
          message.isNotEmpty &&
          message[0] == 'error') {
        _outputController.addError(Exception(message[1]));
      } else if (message is List<Map<String, dynamic>>) {
        _outputController.add(message);
      }
    });
  }

  static Future<void> createNewIsolateContext(
      SendPort rootIsolateSendPort) async {
    final newIsolateReceivePort = ReceivePort();
    final newIsolateSendPort = newIsolateReceivePort.sendPort;
    rootIsolateSendPort.send(newIsolateSendPort);
    await for (final _IsolateSessionData data in newIsolateReceivePort) {
      try {
        final session = OrtSession.fromAddress(data.session);
        final runOptions = OrtRunOptions.fromAddress(data.runOptions);

        final inputs = <String, OrtValue>{};
        for (final entry in data.inputValues.entries) {
          final key = entry.key;
          final value = entry.value;

          try {
            if (value is int) {
              inputs[key] = OrtValueTensor.createTensorWithData(value);
            } else if (value is double) {
              inputs[key] = OrtValueTensor.createTensorWithData(value);
            } else if (value is List) {
              inputs[key] = OrtValueTensor.createTensorWithDataList(value);
            } else {
              throw Exception(
                  'Unexpected input type for $key: ${value.runtimeType} = $value');
            }
          } catch (e) {
            throw Exception('Failed to create tensor for input $key: $e');
          }
        }

        final outputNames = data.outputNames;
        final outputs = session.run(runOptions, inputs, outputNames);

        for (final input in inputs.values) {
          input.release();
        }

        final outputData = <Map<String, dynamic>>[];
        for (int i = 0; i < outputs.length; i++) {
          final output = outputs[i];
          if (output == null) {
            throw Exception('Null output tensor from ONNX Runtime at index $i');
          }

          try {
            final value = output.value;
            outputData.add({
              'address': output.address,
              'value': value,
            });
            output.release();
          } catch (e) {
            throw Exception('Failed to extract value from output $i: $e');
          }
        }

        rootIsolateSendPort.send(outputData);
      } catch (e) {
        // Send error back to main isolate
        rootIsolateSendPort.send(['error', e.toString()]);
      }
    }
  }

  Future<List<OrtValue?>> run(
      OrtRunOptions runOptions, Map<String, OrtValue> inputs,
      [List<String>? outputNames]) async {
    if (!_runLock.isCompleted) {
      await _runLock.future;
    }

    final currentRunLock = Completer<void>();
    _runLock = currentRunLock;

    try {
      if (!_initialized) {
        await _init();
        await _completer.future;
        _initialized = true;
      }

      final transformedInputs =
          inputs.map((key, value) => MapEntry(key, value.address));
      final inputValues =
          inputs.map((key, value) => MapEntry(key, value.value));
      _state = IsolateSessionState.loading;
      final data = _IsolateSessionData(
          session: address,
          runOptions: runOptions.address,
          inputs: transformedInputs,
          inputValues: inputValues,
          outputNames: outputNames);
      _newIsolateSendPort.send(data);

      await for (final result in _outputController.stream) {
        final outputs =
            result.map((map) => _OrtValueProxy(map['value'])).toList();
        _state = IsolateSessionState.idle;
        return outputs;
      }
      _state = IsolateSessionState.idle;
      throw Exception('No output received from isolate');
    } catch (e) {
      _state = IsolateSessionState.idle;
      rethrow;
    } finally {
      currentRunLock.complete();
    }
  }

  Future<void> release() async {
    await _streamSubscription.cancel();
    await _outputController.close();
    _newIsolate.kill();
  }
}

enum IsolateSessionState {
  idle,
  loading,
}

class _IsolateSessionData {
  _IsolateSessionData(
      {required this.session,
      required this.runOptions,
      required this.inputs,
      required this.inputValues,
      this.outputNames});

  final int session;
  final int runOptions;
  final Map<String, int> inputs;
  final Map<String, dynamic> inputValues;
  final List<String>? outputNames;
}
