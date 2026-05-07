import 'package:flutter/foundation.dart';

/// Combined server about/config metadata shown in the About screen.
@immutable
class ServerAboutInfo {
  const ServerAboutInfo({
    required this.name,
    required this.version,
    this.latestVersion,
    this.deploymentId,
    this.defaultLocale,
    this.userCount,
    this.defaultModels = const <String>[],
    this.licenseMetadata = const <String, dynamic>{},
    this.changelog = const <String, dynamic>{},
    this.enableLoginForm,
    this.enablePasswordChangeForm,
    this.enableApiKeys,
    this.enableAudioInput,
    this.enableAudioOutput,
    this.sttEngine,
    this.ttsEngine,
  });

  final String name;
  final String version;
  final String? latestVersion;
  final String? deploymentId;
  final String? defaultLocale;
  final int? userCount;
  final List<String> defaultModels;
  final Map<String, dynamic> licenseMetadata;
  final Map<String, dynamic> changelog;
  final bool? enableLoginForm;
  final bool? enablePasswordChangeForm;
  final bool? enableApiKeys;
  final bool? enableAudioInput;
  final bool? enableAudioOutput;
  final String? sttEngine;
  final String? ttsEngine;

  bool get hasAvailableUpdate =>
      latestVersion != null &&
      latestVersion!.trim().isNotEmpty &&
      latestVersion != version;

  bool get hasLicenseMetadata => licenseMetadata.isNotEmpty;

  factory ServerAboutInfo.fromJson(
    Map<String, dynamic> config, {
    Map<String, dynamic>? versionData,
    Map<String, dynamic>? updateData,
    Map<String, dynamic>? changelog,
  }) {
    final features = _coerceJsonMap(config['features']) ?? const {};
    final audio = _coerceJsonMap(config['audio']) ?? const {};
    final audioTts = _coerceJsonMap(audio['tts']) ?? const {};
    final audioStt = _coerceJsonMap(audio['stt']) ?? const {};

    return ServerAboutInfo(
      name: (config['name'] ?? 'Open WebUI').toString(),
      version:
          _normalizeString(versionData?['version']) ??
          _normalizeString(config['version']) ??
          'Unknown',
      latestVersion: _normalizeString(updateData?['latest']),
      deploymentId: _normalizeString(versionData?['deployment_id']),
      defaultLocale: _normalizeString(config['default_locale']),
      userCount: _coerceInt(config['user_count']),
      defaultModels: _coerceStringList(config['default_models']),
      licenseMetadata: Map<String, dynamic>.unmodifiable(
        _coerceJsonMap(config['license_metadata']) ?? const {},
      ),
      changelog: Map<String, dynamic>.unmodifiable(changelog ?? const {}),
      enableLoginForm: _coerceBool(features['enable_login_form']),
      enablePasswordChangeForm: _coerceBool(
        features['enable_password_change_form'],
      ),
      enableApiKeys: _coerceBool(features['enable_api_keys']),
      enableAudioInput: _coerceBool(features['enable_audio_input']),
      enableAudioOutput: _coerceBool(features['enable_audio_output']),
      sttEngine: _normalizeString(audioStt['engine']),
      ttsEngine: _normalizeString(audioTts['engine']),
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
