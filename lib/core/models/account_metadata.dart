import 'package:flutter/foundation.dart';

/// Editable account metadata returned by OpenWebUI session endpoints.
@immutable
class AccountMetadata {
  const AccountMetadata({
    required this.id,
    required this.email,
    required this.name,
    required this.role,
    required this.isActive,
    this.username,
    this.profileImageUrl,
    this.bio,
    this.gender,
    this.dateOfBirth,
    this.timezone,
    this.statusEmoji,
    this.statusMessage,
    this.statusExpiresAt,
    this.info = const <String, dynamic>{},
  });

  final String id;
  final String email;
  final String name;
  final String role;
  final bool isActive;
  final String? username;
  final String? profileImageUrl;
  final String? bio;
  final String? gender;
  final String? dateOfBirth;
  final String? timezone;
  final String? statusEmoji;
  final String? statusMessage;
  final int? statusExpiresAt;
  final Map<String, dynamic> info;

  String get displayName {
    if (name.trim().isNotEmpty) {
      return name.trim();
    }
    final fallback = username?.trim();
    return fallback != null && fallback.isNotEmpty ? fallback : email;
  }

  bool get hasStatus =>
      (statusEmoji?.trim().isNotEmpty ?? false) ||
      (statusMessage?.trim().isNotEmpty ?? false);

  factory AccountMetadata.fromJson(
    Map<String, dynamic> json, {
    Map<String, dynamic>? info,
  }) {
    final mergedInfo = Map<String, dynamic>.unmodifiable(info ?? const {});

    return AccountMetadata(
      id: (json['id'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      name: (json['name'] ?? json['username'] ?? '').toString(),
      role: (json['role'] ?? 'user').toString(),
      isActive: _coerceBool(json['is_active']) ?? true,
      username: _normalizeString(json['username']),
      profileImageUrl: _normalizeString(
        json['profile_image_url'] ?? json['profileImage'],
      ),
      bio: _normalizeString(json['bio']),
      gender: _normalizeString(json['gender']),
      dateOfBirth: _normalizeDate(json['date_of_birth']),
      timezone:
          _normalizeString(json['timezone']) ??
          _normalizeString(mergedInfo['timezone']),
      statusEmoji: _normalizeString(json['status_emoji']),
      statusMessage: _normalizeString(json['status_message']),
      statusExpiresAt: _coerceInt(json['status_expires_at']),
      info: mergedInfo,
    );
  }
}

String? _normalizeString(dynamic value) {
  if (value is! String) {
    return null;
  }
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

bool? _coerceBool(dynamic value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case 'true':
      case '1':
      case 'yes':
        return true;
      case 'false':
      case '0':
      case 'no':
        return false;
    }
  }
  return null;
}

int? _coerceInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}

String? _normalizeDate(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is DateTime) {
    return value.toIso8601String().split('T').first;
  }
  final raw = value.toString().trim();
  if (raw.isEmpty) {
    return null;
  }
  if (raw.contains('T')) {
    return raw.split('T').first;
  }
  return raw;
}
