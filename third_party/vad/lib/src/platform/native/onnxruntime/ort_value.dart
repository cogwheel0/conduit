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

  ffi.Pointer<bg.OrtValue> get ptr => _ptr;
  int get address => _ptr.address;

  Object? get value;

  void release() {
    OrtEnv.instance.ortApiPtr.ref.ReleaseValue
        .asFunction<void Function(ffi.Pointer<bg.OrtValue>)>()(_ptr);
  }
}

class OrtValueTensor extends OrtValue {
  late OrtTensorTypeAndShapeInfo _info;
  ffi.Pointer<ffi.Void> _dataPtr = ffi.nullptr;

  OrtValueTensor(ffi.Pointer<bg.OrtValue> ptr,
      [ffi.Pointer<ffi.Void>? dataPtr]) {
    _ptr = ptr;
    try {
      _info = OrtTensorTypeAndShapeInfo(ptr);
    } catch (e) {
      throw Exception(
          'Failed to get tensor info from pointer ${ptr.address}: $e');
    }
    if (dataPtr != null) {
      _dataPtr = dataPtr;
    }
  }

  factory OrtValueTensor.fromAddress(int address) {
    return OrtValueTensor(ffi.Pointer.fromAddress(address));
  }

  static OrtValueTensor createTensorWithData(dynamic data) {
    if (data is int) {
      return createTensorWithDataList(<int>[data], []);
    }
    throw Exception(
        'Invalid element type - VAD only supports int for single values');
  }

  static OrtValueTensor createTensorWithDataList(List data,
      [List<int>? shape]) {
    shape ??= data.shape;
    final element = data.element();
    var dataType = ONNXTensorElementDataType.undefined;
    ffi.Pointer<ffi.Void> dataPtr = ffi.nullptr;
    int dataSize = 0;
    int dataByteCount = 0;

    if (element is Int64List || element is int) {
      final flattenData = data.flatten<int>();
      dataSize = flattenData.length;
      dataType = ONNXTensorElementDataType.int64;
      dataPtr = (calloc<ffi.Int64>(dataSize)
            ..asTypedList(dataSize).setRange(0, dataSize, flattenData))
          .cast();
      dataByteCount = dataSize * 8;
    } else if (element is Float32List || element is double) {
      final flattenData = data.flatten<double>();
      dataSize = flattenData.length;
      dataType = ONNXTensorElementDataType.float;
      dataPtr = (calloc<ffi.Float>(dataSize)
            ..asTypedList(dataSize).setRange(0, dataSize, flattenData))
          .cast();
      dataByteCount = dataSize * 4;
    } else {
      throw Exception('Invalid inputTensor element type.');
    }

    final shapeSize = shape.length;
    final shapePtr = calloc<ffi.Int64>(shapeSize);
    shapePtr.asTypedList(shapeSize).setRange(0, shapeSize, shape);

    final ortMemoryInfoPtrPtr = calloc<ffi.Pointer<bg.OrtMemoryInfo>>();
    var statusPtr = OrtEnv.instance.ortApiPtr.ref.AllocatorGetInfo.asFunction<
            bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtAllocator>,
                ffi.Pointer<ffi.Pointer<bg.OrtMemoryInfo>>)>()(
        OrtAllocator.instance.ptr, ortMemoryInfoPtrPtr);
    OrtStatus.checkOrtStatus(statusPtr);

    final ortMemoryInfoPtr = ortMemoryInfoPtrPtr.value;
    final ortValuePtrPtr = calloc<ffi.Pointer<bg.OrtValue>>();
    statusPtr = OrtEnv.instance.ortApiPtr.ref.CreateTensorWithDataAsOrtValue
            .asFunction<
                bg.OrtStatusPtr Function(
                    ffi.Pointer<bg.OrtMemoryInfo>,
                    ffi.Pointer<ffi.Void>,
                    int,
                    ffi.Pointer<ffi.Int64>,
                    int,
                    int,
                    ffi.Pointer<ffi.Pointer<bg.OrtValue>>)>()(
        ortMemoryInfoPtr,
        dataPtr,
        dataByteCount,
        shapePtr,
        shapeSize,
        dataType.value,
        ortValuePtrPtr);
    OrtStatus.checkOrtStatus(statusPtr);

    final ortValuePtr = ortValuePtrPtr.value;
    calloc.free(shapePtr);
    calloc.free(ortValuePtrPtr);
    calloc.free(ortMemoryInfoPtrPtr);
    return OrtValueTensor(ortValuePtr, dataPtr);
  }

  @override
  dynamic get value {
    final elementType = _info._tensorElementType;

    if (elementType ==
        bg.ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64) {
      final dataPtrPtr = calloc<ffi.Pointer<ffi.Int64>>();
      final statusPtr = OrtEnv.instance.ortApiPtr.ref.GetTensorMutableData
              .asFunction<
                  bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtValue>,
                      ffi.Pointer<ffi.Pointer<ffi.Void>>)>()(
          _ptr, dataPtrPtr.cast());
      OrtStatus.checkOrtStatus(statusPtr);
      final dataPtr = dataPtrPtr.value;

      final tensorShapeElementCount = _info._tensorShapeElementCount;
      final data = <int>[];

      for (int i = 0; i < tensorShapeElementCount; ++i) {
        data.add(dataPtr[i]);
      }
      calloc.free(dataPtrPtr);

      if (_info._dimensionsCount == 0) {
        return data[0];
      } else {
        return data.reshape<int>(_info._tensorShape);
      }
    } else {
      final dataPtrPtr = calloc<ffi.Pointer<ffi.Float>>();
      final dataPtr = _getTensorMutableData(dataPtrPtr);
      final tensorShapeElementCount = _info._tensorShapeElementCount;
      final data = <double>[];

      for (int i = 0; i < tensorShapeElementCount; ++i) {
        data.add(dataPtr[i]);
      }
      calloc.free(dataPtrPtr);

      if (_info._dimensionsCount == 0) {
        return data[0];
      } else {
        return data.reshape<double>(_info._tensorShape);
      }
    }
  }

  ffi.Pointer<ffi.Float> _getTensorMutableData(
      ffi.Pointer<ffi.Pointer<ffi.Float>> dataPtrPtr) {
    final statusPtr = OrtEnv.instance.ortApiPtr.ref.GetTensorMutableData
        .asFunction<
            bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtValue>,
                ffi.Pointer<ffi.Pointer<ffi.Void>>)>()(_ptr, dataPtrPtr.cast());
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
    final statusPtr = OrtEnv.instance.ortApiPtr.ref.GetTensorTypeAndShape
            .asFunction<
                bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtValue>,
                    ffi.Pointer<ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>>)>()(
        ortValuePtr, infoPtrPtr);
    OrtStatus.checkOrtStatus(statusPtr);
    final infoPtr = infoPtrPtr.value;

    _dimensionsCount = _getDimensionsCount(infoPtr);
    _tensorShape = _getDimensions(infoPtr, _dimensionsCount);
    _tensorShapeElementCount = _getTensorShapeElementCount(infoPtr);
    _tensorElementType = _getTensorElementType(infoPtr);

    _releaseTensorTypeAndShapeInfo(infoPtr);
    calloc.free(infoPtrPtr);
  }

  static void _releaseTensorTypeAndShapeInfo(
      ffi.Pointer<bg.OrtTensorTypeAndShapeInfo> infoPtr) {
    OrtEnv.instance.ortApiPtr.ref.ReleaseTensorTypeAndShapeInfo.asFunction<
        void Function(ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>)>()(infoPtr);
  }

  static int _getDimensionsCount(
      ffi.Pointer<bg.OrtTensorTypeAndShapeInfo> infoPtr) {
    final countPtr = calloc<ffi.Size>();
    final statusPtr = OrtEnv.instance.ortApiPtr.ref.GetDimensionsCount
        .asFunction<
            bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>,
                ffi.Pointer<ffi.Size>)>()(infoPtr, countPtr);
    OrtStatus.checkOrtStatus(statusPtr);
    final count = countPtr.value;
    calloc.free(countPtr);
    return count;
  }

  static List<int> _getDimensions(
      ffi.Pointer<bg.OrtTensorTypeAndShapeInfo> infoPtr, int length) {
    final dimensionsPtr = calloc<ffi.Int64>(length);
    final statusPtr = OrtEnv.instance.ortApiPtr.ref.GetDimensions.asFunction<
        bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>,
            ffi.Pointer<ffi.Int64>, int)>()(infoPtr, dimensionsPtr, length);
    OrtStatus.checkOrtStatus(statusPtr);
    final dimensions =
        List<int>.generate(length, (index) => dimensionsPtr[index]);
    calloc.free(dimensionsPtr);
    return dimensions;
  }

  static int _getTensorShapeElementCount(
      ffi.Pointer<bg.OrtTensorTypeAndShapeInfo> infoPtr) {
    final countPtr = calloc<ffi.Size>();
    final statusPtr = OrtEnv.instance.ortApiPtr.ref.GetTensorShapeElementCount
        .asFunction<
            bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>,
                ffi.Pointer<ffi.Size>)>()(infoPtr, countPtr);
    OrtStatus.checkOrtStatus(statusPtr);
    final count = countPtr.value;
    calloc.free(countPtr);
    return count;
  }

  static bg.ONNXTensorElementDataType _getTensorElementType(
      ffi.Pointer<bg.OrtTensorTypeAndShapeInfo> infoPtr) {
    final typePtr = calloc<ffi.UnsignedInt>();
    final statusPtr = OrtEnv.instance.ortApiPtr.ref.GetTensorElementType
        .asFunction<
            bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>,
                ffi.Pointer<ffi.UnsignedInt>)>()(infoPtr, typePtr);
    OrtStatus.checkOrtStatus(statusPtr);
    final type = typePtr.value;
    calloc.free(typePtr);
    return bg.ONNXTensorElementDataType.values.firstWhere(
      (e) => e.value == type,
      orElse: () =>
          bg.ONNXTensorElementDataType.ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED,
    );
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
