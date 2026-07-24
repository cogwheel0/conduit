import 'package:flutter/foundation.dart';

/// Server-backed user settings loaded from OpenWebUI.
@immutable
class ServerUserSettings {
  const ServerUserSettings({
    this.systemPrompt,
    this.memoryEnabled = false,
    this.defaultModelIds = const <String>[],
    this.pinnedModelIds = const <String>[],
    this.reasoningEffort,
    this.notificationEnabled,
    this.notificationSound,
    this.notificationSoundAlways,
  });

  final String? systemPrompt;
  final bool memoryEnabled;
  final List<String> defaultModelIds;
  final List<String> pinnedModelIds;
  final String? reasoningEffort;

  /// Open WebUI notification preferences. Stored at the top level of the user
  /// settings object (not nested under `ui`). Null means the server has no
  /// stored value yet, so the client default applies.
  final bool? notificationEnabled;
  final bool? notificationSound;
  final bool? notificationSoundAlways;

  /// The user's preferred default model, if one is configured.
  String? get defaultModelId =>
      defaultModelIds.isEmpty ? null : defaultModelIds.first;

  factory ServerUserSettings.fromJson(Map<String, dynamic> json) {
    final ui = _coerceJsonMap(json['ui']);
    final uiSystem = _normalizeString(ui?['system']);
    final rootSystem = _normalizeString(json['system']);
    final params = _coerceJsonMap(json['params']);

    return ServerUserSettings(
      systemPrompt: uiSystem ?? rootSystem,
      memoryEnabled: _coerceBool(ui?['memory']) ?? false,
      defaultModelIds: _coerceStringList(ui?['models']),
      pinnedModelIds: _coerceUniqueStringList(ui?['pinnedModels']),
      reasoningEffort: _normalizeString(params?['reasoning_effort']),
      notificationEnabled: _coerceBool(json['notificationEnabled']),
      notificationSound: _coerceBool(json['notificationSound']),
      notificationSoundAlways: _coerceBool(json['notificationSoundAlways']),
    );
  }

  ServerUserSettings copyWith({
    Object? systemPrompt = _serverUserSettingsUnset,
    bool? memoryEnabled,
    List<String>? defaultModelIds,
    List<String>? pinnedModelIds,
    Object? reasoningEffort = _serverUserSettingsUnset,
    bool? notificationEnabled,
    bool? notificationSound,
    bool? notificationSoundAlways,
  }) {
    return ServerUserSettings(
      systemPrompt: systemPrompt == _serverUserSettingsUnset
          ? this.systemPrompt
          : systemPrompt as String?,
      memoryEnabled: memoryEnabled ?? this.memoryEnabled,
      defaultModelIds: defaultModelIds ?? this.defaultModelIds,
      pinnedModelIds: pinnedModelIds ?? this.pinnedModelIds,
      reasoningEffort: reasoningEffort == _serverUserSettingsUnset
          ? this.reasoningEffort
          : reasoningEffort as String?,
      notificationEnabled: notificationEnabled ?? this.notificationEnabled,
      notificationSound: notificationSound ?? this.notificationSound,
      notificationSoundAlways:
          notificationSoundAlways ?? this.notificationSoundAlways,
    );
  }
}

const Object _serverUserSettingsUnset = Object();

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

List<String> _coerceUniqueStringList(dynamic value) {
  final entries = _coerceStringList(value);
  if (entries.isEmpty) {
    return const <String>[];
  }

  final uniqueEntries = <String>[];
  final seen = <String>{};
  for (final entry in entries) {
    if (seen.add(entry)) {
      uniqueEntries.add(entry);
    }
  }
  return List<String>.unmodifiable(uniqueEntries);
}
