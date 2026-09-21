import 'package:freezed_annotation/freezed_annotation.dart';

part 'user.freezed.dart';

bool? _safeBool(dynamic value) {
  if (value == null) return null;
  if (value is bool) return value;
  if (value is String) {
    final lower = value.toLowerCase();
    if (lower == 'true' || lower == '1') return true;
    if (lower == 'false' || lower == '0') return false;
  }
  if (value is num) return value != 0;
  return null;
}

@freezed
sealed class User with _$User {
  const User._();

  const factory User({
    required String id,
    required String username,
    required String email,
    String? name,
    String? profileImage,
    required String role,
    @Default(true) bool isActive,
  }) = _User;

  factory User.fromJson(Map<String, dynamic> json) {
    // Handle different field names from OpenWebUI API
    return User(
      id: json['id'] as String? ?? '',
      username: json['username'] as String? ?? json['name'] as String? ?? '',
      email: json['email'] as String? ?? '',
      name: json['name'] as String?,
      profileImage:
          json['profile_image_url'] as String? ??
          json['profileImage'] as String?,
      role: json['role'] as String? ?? 'user',
      isActive:
          _safeBool(json['is_active']) ?? _safeBool(json['isActive']) ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'email': email,
      'name': name,
      'profile_image_url': profileImage,
      'role': role,
      'is_active': isActive,
    };
  }
}
