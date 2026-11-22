// ignore_for_file: public_member_api_docs

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:vad/src/platform/native/bindings/onnxruntime_bindings_generated.dart'
    as bg;
import 'package:vad/src/platform/native/onnxruntime/ort_env.dart';
import 'package:vad/src/platform/native/onnxruntime/ort_status.dart';
import 'package:vad/src/platform/native/utils/list_shape_extension.dart';

abstract class OrtValue {
  late ffi.Pointer<bg.OrtValue> _ptr;
  bool _released = false;

  ffi.Pointer<bg.OrtValue> get ptr => _ptr;
  int get address => _ptr.address;

  Object? get value;

  void release() {
    if (_released) return;
    _released = true;
    OrtEnv.instance.api.releaseValue(_ptr);
  }
}

class OrtValueTensor extends OrtValue {
  OrtTensorTypeAndShapeInfo? _info;
  ffi.Pointer<ffi.Void> _dataPtr = ffi.nullptr;

  OrtValueTensor(ffi.Pointer<bg.OrtValue> ptr,
      [ffi.Pointer<ffi.Void>? dataPtr]) {
    _ptr = ptr;
    if (dataPtr != null) {
      _dataPtr = dataPtr;
    }
  }

  factory OrtValueTensor.fromAddress(int address) {
    return OrtValueTensor(ffi.Pointer.fromAddress(address));
  }

  OrtTensorTypeAndShapeInfo get _tensorInfo =>
      _info ??= OrtTensorTypeAndShapeInfo(_ptr);

  static OrtValueTensor createTensorWithData(dynamic data) {
    if (data is int) {
      final int64Ptr = calloc<ffi.Int64>(1);
      int64Ptr.value = data;
      return _createTensorWithNativeData(
        int64Ptr.cast(),
        8,
        const <int>[],
        ONNXTensorElementDataType.int64,
      );
    }
    throw Exception(
        'Invalid element type - VAD only supports int for single values');
  }

  static OrtValueTensor createTensorWithDataList(List data,
      [List<int>? shape]) {
    if (data is Float32List) {
      final dataSize = data.length;
      final floatPtr = calloc<ffi.Float>(dataSize);
      try {
        floatPtr.asTypedList(dataSize).setAll(0, data);
      } catch (_) {
        calloc.free(floatPtr);
        rethrow;
      }
      return _createTensorWithNativeData(
        floatPtr.cast(),
        dataSize * 4,
        shape ?? <int>[dataSize],
        ONNXTensorElementDataType.float,
      );
    }

    if (data is Int64List) {
      final dataSize = data.length;
      final int64Ptr = calloc<ffi.Int64>(dataSize);
      try {
        int64Ptr.asTypedList(dataSize).setAll(0, data);
      } catch (_) {
        calloc.free(int64Ptr);
        rethrow;
      }
      return _createTensorWithNativeData(
        int64Ptr.cast(),
        dataSize * 8,
        shape ?? <int>[dataSize],
        ONNXTensorElementDataType.int64,
      );
    }

    shape ??= data.shape;
    final element = data.element();

    if (element is Int64List || element is int) {
      final flattenData = data.flatten<int>();
      final dataSize = flattenData.length;
      final int64Ptr = calloc<ffi.Int64>(dataSize);
      try {
        int64Ptr.asTypedList(dataSize).setRange(0, dataSize, flattenData);
      } catch (_) {
        calloc.free(int64Ptr);
        rethrow;
      }
      return _createTensorWithNativeData(
        int64Ptr.cast(),
        dataSize * 8,
        shape,
        ONNXTensorElementDataType.int64,
      );
    } else if (element is Float32List || element is double) {
      final flattenData = data.flatten<double>();
      final dataSize = flattenData.length;
      final floatPtr = calloc<ffi.Float>(dataSize);
      try {
        floatPtr.asTypedList(dataSize).setRange(0, dataSize, flattenData);
      } catch (_) {
        calloc.free(floatPtr);
        rethrow;
      }
      return _createTensorWithNativeData(
        floatPtr.cast(),
        dataSize * 4,
        shape,
        ONNXTensorElementDataType.float,
      );
    } else {
      throw Exception('Invalid inputTensor element type.');
    }
  }

  static OrtValueTensor _createTensorWithNativeData(
    ffi.Pointer<ffi.Void> dataPtr,
    int dataByteCount,
    List<int> shape,
    ONNXTensorElementDataType dataType,
  ) {
    final shapeSize = shape.length;
    ffi.Pointer<ffi.Int64> shapePtr = ffi.nullptr;
    ffi.Pointer<ffi.Pointer<bg.OrtValue>>? ortValuePtrPtr;
    ffi.Pointer<bg.OrtValue> ortValuePtr = ffi.nullptr;
    var handedOff = false;
    try {
      if (shapeSize > 0) {
        shapePtr = calloc<ffi.Int64>(shapeSize);
        shapePtr.asTypedList(shapeSize).setRange(0, shapeSize, shape);
      }
      ortValuePtrPtr = calloc<ffi.Pointer<bg.OrtValue>>();
      final statusPtr = OrtEnv.instance.api.createTensorWithDataAsOrtValue(
        OrtAllocator.instance.memoryInfoPtr,
        dataPtr,
        dataByteCount,
        shapePtr,
        shapeSize,
        dataType.value,
        ortValuePtrPtr,
      );
      OrtStatus.checkOrtStatus(statusPtr);

      ortValuePtr = ortValuePtrPtr.value;
      final tensor = OrtValueTensor(ortValuePtr, dataPtr);
      handedOff = true;
      return tensor;
    } finally {
      if (shapePtr != ffi.nullptr) {
        calloc.free(shapePtr);
      }
      if (ortValuePtrPtr != null) {
        calloc.free(ortValuePtrPtr);
      }
      if (!handedOff) {
        if (ortValuePtr != ffi.nullptr) {
          OrtEnv.instance.api.releaseValue(ortValuePtr);
        }
        if (dataPtr != ffi.nullptr) {
          calloc.free(dataPtr);
        }
      }
    }
  }

  /// Reads the first float32 element without allocating a boxed list.
  double firstFloatValue() {
    final info = _tensorInfo;
    if (info._tensorElementType !=
        bg.ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
      throw StateError(
          'Expected float32 tensor, got ${info._tensorElementType}');
    }
    if (info._tensorShapeElementCount < 1) {
      throw StateError('Tensor has no elements');
    }
    final dataPtrPtr = calloc<ffi.Pointer<ffi.Float>>();
    try {
      final dataPtr = _getTensorMutableData(dataPtrPtr);
      return dataPtr[0];
    } finally {
      calloc.free(dataPtrPtr);
    }
  }

  /// Copies float32 tensor elements directly into [target] without boxing.
  void copyFloatDataInto(Float32List target) {
    final info = _tensorInfo;
    if (info._tensorElementType !=
        bg.ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
      throw StateError(
          'Expected float32 tensor, got ${info._tensorElementType}');
    }
    final count = info._tensorShapeElementCount;
    if (count != target.length) {
      throw StateError(
          'Tensor element count ($count) does not match target length (${target.length})');
    }
    final dataPtrPtr = calloc<ffi.Pointer<ffi.Float>>();
    try {
      final dataPtr = _getTensorMutableData(dataPtrPtr);
      target.setRange(0, count, dataPtr.asTypedList(count));
    } finally {
      calloc.free(dataPtrPtr);
    }
  }

  /// Returns float32 tensor elements as a flat [Float32List] copy.
  Float32List toFloat32List() {
    final info = _tensorInfo;
    if (info._tensorElementType !=
        bg.ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
      throw StateError(
          'Expected float32 tensor, got ${info._tensorElementType}');
    }
    final count = info._tensorShapeElementCount;
    final result = Float32List(count);
    final dataPtrPtr = calloc<ffi.Pointer<ffi.Float>>();
    try {
      final dataPtr = _getTensorMutableData(dataPtrPtr);
      result.setRange(0, count, dataPtr.asTypedList(count));
    } finally {
      calloc.free(dataPtrPtr);
    }
    return result;
  }

  @override
  dynamic get value {
    final info = _tensorInfo;
    final elementType = info._tensorElementType;

    if (elementType ==
        bg.ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64) {
      final dataPtrPtr = calloc<ffi.Pointer<ffi.Int64>>();
      try {
        final statusPtr = OrtEnv.instance.api
            .getTensorMutableData(_ptr, dataPtrPtr.cast());
        OrtStatus.checkOrtStatus(statusPtr);
        final dataPtr = dataPtrPtr.value;

        final tensorShapeElementCount = info._tensorShapeElementCount;
        final data = <int>[];
        for (int i = 0; i < tensorShapeElementCount; ++i) {
          data.add(dataPtr[i]);
        }

        if (info._dimensionsCount == 0) {
          return data[0];
        } else {
          return data.reshape<int>(info._tensorShape);
        }
      } finally {
        calloc.free(dataPtrPtr);
      }
    } else {
      final dataPtrPtr = calloc<ffi.Pointer<ffi.Float>>();
      try {
        final dataPtr = _getTensorMutableData(dataPtrPtr);
        final tensorShapeElementCount = info._tensorShapeElementCount;
        final data = <double>[];
        for (int i = 0; i < tensorShapeElementCount; ++i) {
          data.add(dataPtr[i]);
        }

        if (info._dimensionsCount == 0) {
          return data[0];
        } else {
          return data.reshape<double>(info._tensorShape);
        }
      } finally {
        calloc.free(dataPtrPtr);
      }
    }
  }

  ffi.Pointer<ffi.Float> _getTensorMutableData(
      ffi.Pointer<ffi.Pointer<ffi.Float>> dataPtrPtr) {
    final statusPtr =
        OrtEnv.instance.api.getTensorMutableData(_ptr, dataPtrPtr.cast());
    OrtStatus.checkOrtStatus(statusPtr);
    return dataPtrPtr.value;
  }

  @override
  void release() {
    super.release();
    if (_dataPtr != ffi.nullptr) {
      calloc.free(_dataPtr);
      _dataPtr = ffi.nullptr;
    }
  }
}

class OrtTensorTypeAndShapeInfo {
  int _dimensionsCount = 0;
  int _tensorShapeElementCount = 0;
  List<int> _tensorShape = [];
  bg.ONNXTensorElementDataType _tensorElementType =
      bg.ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;

  OrtTensorTypeAndShapeInfo(ffi.Pointer<bg.OrtValue> ortValuePtr) {
    final infoPtrPtr = calloc<ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>>();
    ffi.Pointer<bg.OrtTensorTypeAndShapeInfo> infoPtr = ffi.nullptr;
    try {
      final statusPtr =
          OrtEnv.instance.api.getTensorTypeAndShape(ortValuePtr, infoPtrPtr);
      OrtStatus.checkOrtStatus(statusPtr);
      infoPtr = infoPtrPtr.value;

      _dimensionsCount = _getDimensionsCount(infoPtr);
      _tensorShape = _getDimensions(infoPtr, _dimensionsCount);
      _tensorShapeElementCount = _getTensorShapeElementCount(infoPtr);
      _tensorElementType = _getTensorElementType(infoPtr);
    } finally {
      if (infoPtr != ffi.nullptr) {
        _releaseTensorTypeAndShapeInfo(infoPtr);
      }
      calloc.free(infoPtrPtr);
    }
  }

  static void _releaseTensorTypeAndShapeInfo(
      ffi.Pointer<bg.OrtTensorTypeAndShapeInfo> infoPtr) {
    OrtEnv.instance.api.releaseTensorTypeAndShapeInfo(infoPtr);
  }

  static int _getDimensionsCount(
      ffi.Pointer<bg.OrtTensorTypeAndShapeInfo> infoPtr) {
    final countPtr = calloc<ffi.Size>();
    try {
      final statusPtr =
          OrtEnv.instance.api.getDimensionsCount(infoPtr, countPtr);
      OrtStatus.checkOrtStatus(statusPtr);
      return countPtr.value;
    } finally {
      calloc.free(countPtr);
    }
  }

  static List<int> _getDimensions(
      ffi.Pointer<bg.OrtTensorTypeAndShapeInfo> infoPtr, int length) {
    if (length == 0) {
      return const <int>[];
    }
    final dimensionsPtr = calloc<ffi.Int64>(length);
    try {
      final statusPtr =
          OrtEnv.instance.api.getDimensions(infoPtr, dimensionsPtr, length);
      OrtStatus.checkOrtStatus(statusPtr);
      return List<int>.generate(length, (index) => dimensionsPtr[index]);
    } finally {
      calloc.free(dimensionsPtr);
    }
  }

  static int _getTensorShapeElementCount(
      ffi.Pointer<bg.OrtTensorTypeAndShapeInfo> infoPtr) {
    final countPtr = calloc<ffi.Size>();
    try {
      final statusPtr =
          OrtEnv.instance.api.getTensorShapeElementCount(infoPtr, countPtr);
      OrtStatus.checkOrtStatus(statusPtr);
      return countPtr.value;
    } finally {
      calloc.free(countPtr);
    }
  }

  static bg.ONNXTensorElementDataType _getTensorElementType(
      ffi.Pointer<bg.OrtTensorTypeAndShapeInfo> infoPtr) {
    final typePtr = calloc<ffi.UnsignedInt>();
    try {
      final statusPtr =
          OrtEnv.instance.api.getTensorElementType(infoPtr, typePtr);
      OrtStatus.checkOrtStatus(statusPtr);
      final type = typePtr.value;
      return bg.ONNXTensorElementDataType.values.firstWhere(
        (e) => e.value == type,
        orElse: () => bg
            .ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED,
      );
    } finally {
      calloc.free(typePtr);
    }
  }
}

enum ONNXTensorElementDataType {
  undefined(0),
  float(1),
  int64(7);

  final int value;
  const ONNXTensorElementDataType(this.value);

  static ONNXTensorElementDataType valueOf(int type) {
    switch (type) {
      case 1:
        return ONNXTensorElementDataType.float;
      case 7:
        return ONNXTensorElementDataType.int64;
      default:
        return ONNXTensorElementDataType.undefined;
    }
  }
}

enum ONNXType {
  unknown(0),
  tensor(1);

  final int value;
  const ONNXType(this.value);

  static ONNXType valueOf(int type) {
    return type == 1 ? ONNXType.tensor : ONNXType.unknown;
  }
}
