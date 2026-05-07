import 'package:flutter/foundation.dart';

/// A memory row persisted by the OpenWebUI backend.
@immutable
class ServerMemory {
  const ServerMemory({
    required this.id,
    required this.userId,
    required this.content,
    required this.updatedAtEpoch,
    required this.createdAtEpoch,
  });

  final String id;
  final String userId;
  final String content;
  final int updatedAtEpoch;
  final int createdAtEpoch;

  DateTime get updatedAt => _epochToDateTime(updatedAtEpoch);
  DateTime get createdAt => _epochToDateTime(createdAtEpoch);

  factory ServerMemory.fromJson(Map<String, dynamic> json) {
    return ServerMemory(
      id: (json['id'] ?? '').toString(),
      userId: (json['user_id'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
      updatedAtEpoch: _coerceEpoch(json['updated_at']),
      createdAtEpoch: _coerceEpoch(json['created_at']),
    );
  }
}

int _coerceEpoch(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? 0;
  }
  return 0;
}

DateTime _epochToDateTime(int value) {
  final milliseconds = value > 1000000000000 ? value : value * 1000;
  return DateTime.fromMillisecondsSinceEpoch(
    milliseconds,
    isUtc: true,
  ).toLocal();
}
