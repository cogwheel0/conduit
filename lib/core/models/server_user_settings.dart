import 'package:flutter/foundation.dart';

/// Server-backed user settings loaded from OpenWebUI.
@immutable
class ServerUserSettings {
  const ServerUserSettings({
    this.systemPrompt,
    this.memoryEnabled = false,
    this.defaultModelIds = const <String>[],
  });

  final String? systemPrompt;
  final bool memoryEnabled;
  final List<String> defaultModelIds;

  /// The user's preferred default model, if one is configured.
  String? get defaultModelId =>
      defaultModelIds.isEmpty ? null : defaultModelIds.first;

  factory ServerUserSettings.fromJson(Map<String, dynamic> json) {
    final ui = _coerceJsonMap(json['ui']);
    final uiSystem = _normalizeString(ui?['system']);
    final rootSystem = _normalizeString(json['system']);

    return ServerUserSettings(
      systemPrompt: uiSystem ?? rootSystem,
      memoryEnabled: _coerceBool(ui?['memory']) ?? false,
      defaultModelIds: _coerceStringList(ui?['models']),
    );
  }
}

Map<String, dynamic>? _coerceJsonMap(dynamic value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, entryValue) => MapEntry(key.toString(), entryValue));
  }
  return null;
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

List<String> _coerceStringList(dynamic value) {
  if (value is! List) {
    return const <String>[];
  }
  return List<String>.unmodifiable(
    value
        .map((entry) => entry.toString().trim())
        .where((entry) => entry.isNotEmpty),
  );
}
