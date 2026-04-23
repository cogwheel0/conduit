// ignore_for_file: invalid_annotation_target

import 'package:freezed_annotation/freezed_annotation.dart';

part 'file_info.freezed.dart';
part 'file_info.g.dart';

Object? _readFileMeta(Map<dynamic, dynamic> json, String key) =>
    json['meta'] ?? json['metadata'];

Object? _readOriginalFilename(Map<dynamic, dynamic> json, String key) {
  final meta = _readFileMeta(json, key);
  if (meta is Map) {
    final name = meta['name'];
    if (name is String && name.trim().isNotEmpty) {
      return name.trim();
    }
  }

  final snakeCase = json['original_filename'];
  if (snakeCase is String && snakeCase.trim().isNotEmpty) {
    return snakeCase.trim();
  }

  final camelCase = json['originalFilename'];
  if (camelCase is String && camelCase.trim().isNotEmpty) {
    return camelCase.trim();
  }

  return json['filename'];
}

Object? _readFileSize(Map<dynamic, dynamic> json, String key) {
  final meta = _readFileMeta(json, key);
  if (meta is Map && meta['size'] != null) {
    return meta['size'];
  }
  return json['size'];
}

Object? _readMimeType(Map<dynamic, dynamic> json, String key) {
  final meta = _readFileMeta(json, key);
  if (meta is Map && meta['content_type'] != null) {
    return meta['content_type'];
  }

  return json['content_type'] ?? json['mimeType'];
}

Object? _readCreatedAt(Map<dynamic, dynamic> json, String key) =>
    json['created_at'] ?? json['createdAt'];

Object? _readUpdatedAt(Map<dynamic, dynamic> json, String key) =>
    json['updated_at'] ?? json['updatedAt'] ?? json['created_at'];

int _safeInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    return int.tryParse(value) ?? 0;
  }
  return 0;
}

String _safeString(Object? value) => value?.toString().trim() ?? '';

DateTime _dateTimeFromOpenWebUiTimestamp(Object? value) {
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) {
      return parsed;
    }
  }

  final timestamp = switch (value) {
    int raw => raw,
    num raw => raw.toInt(),
    String raw => int.tryParse(raw) ?? 0,
    _ => 0,
  };

  if (timestamp <= 0) {
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  if (timestamp >= 1000000000000000000) {
    return DateTime.fromMicrosecondsSinceEpoch(timestamp ~/ 1000);
  }

  if (timestamp >= 1000000000000000) {
    return DateTime.fromMicrosecondsSinceEpoch(timestamp);
  }

  if (timestamp >= 1000000000000) {
    return DateTime.fromMillisecondsSinceEpoch(timestamp);
  }

  return DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
}

Map<String, dynamic>? _safeMetadataMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, val) => MapEntry(key.toString(), val));
  }
  return null;
}

@freezed
sealed class FileInfo with _$FileInfo {
  const FileInfo._();

  const factory FileInfo({
    required String id,
    required String filename,
    @JsonKey(readValue: _readOriginalFilename, fromJson: _safeString)
    required String originalFilename,
    @JsonKey(readValue: _readFileSize, fromJson: _safeInt) required int size,
    @JsonKey(readValue: _readMimeType, fromJson: _safeString)
    required String mimeType,
    @JsonKey(
      readValue: _readCreatedAt,
      fromJson: _dateTimeFromOpenWebUiTimestamp,
    )
    required DateTime createdAt,
    @JsonKey(
      readValue: _readUpdatedAt,
      fromJson: _dateTimeFromOpenWebUiTimestamp,
    )
    required DateTime updatedAt,
    @JsonKey(name: 'user_id') String? userId,
    String? hash,
    @JsonKey(readValue: _readFileMeta, fromJson: _safeMetadataMap)
    Map<String, dynamic>? metadata,
  }) = _FileInfo;

  String get displayName =>
      originalFilename.isNotEmpty ? originalFilename : filename;

  String get extension {
    final dotIndex = displayName.lastIndexOf('.');
    if (dotIndex < 0 || dotIndex == displayName.length - 1) {
      return '';
    }
    return displayName.substring(dotIndex).toLowerCase();
  }

  bool get isImage => mimeType.startsWith('image/');

  factory FileInfo.fromJson(Map<String, dynamic> json) =>
      _$FileInfoFromJson(json);
}
