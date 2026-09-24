import 'package:freezed_annotation/freezed_annotation.dart';

part 'toggle_filter.freezed.dart';

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

/// Represents a toggleable filter that can be enabled/disabled per chat.
///
/// These filters are created by OpenWebUI when a filter function has
/// `toggle = True` set in its module. They appear as buttons next to
/// web search, image generation, and code interpreter buttons.
@freezed
sealed class ToggleFilter with _$ToggleFilter {
  const ToggleFilter._();

  const factory ToggleFilter({
    /// Unique identifier for the filter function.
    required String id,

    /// Display name for the filter.
    required String name,

    /// Optional description of what the filter does.
    String? description,

    /// Optional icon URL for the filter.
    String? icon,

    /// Whether this filter has user-configurable valves.
    @Default(false) bool hasUserValves,
  }) = _ToggleFilter;

  factory ToggleFilter.fromJson(Map<String, dynamic> json) {
    return ToggleFilter(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      icon: json['icon'] as String?,
      hasUserValves: _safeBool(json['has_user_valves']) ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (description != null) 'description': description,
    if (icon != null) 'icon': icon,
    'has_user_valves': hasUserValves,
  };
}
