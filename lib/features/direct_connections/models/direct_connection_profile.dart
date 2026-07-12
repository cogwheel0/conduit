import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// Built-in adapter key for OpenAI-compatible APIs.
const String kOpenAiCompatibleAdapterKey = 'openai-compatible';

/// Built-in adapter key for Ollama's native HTTP API.
const String kOllamaAdapterKey = 'ollama';

/// OpenAI-family completion protocol selected for one connection profile.
///
/// This remains profile data rather than a separate adapter key so OpenAI,
/// Azure OpenAI, LM Studio, vLLM, LocalAI, OpenRouter, and similar providers
/// can share the same adapter implementation while choosing the API shape
/// their endpoint supports.
enum DirectOpenAiApiMode {
  chatCompletions('chat-completions'),
  responses('responses');

  const DirectOpenAiApiMode(this.storageValue);

  final String storageValue;

  static DirectOpenAiApiMode fromStorage(Object? value) {
    if (value == null) return chatCompletions;
    final mode = values
        .where((candidate) => candidate.storageValue == value)
        .firstOrNull;
    if (mode == null) {
      throw const FormatException('Unsupported OpenAI completion API mode.');
    }
    return mode;
  }
}

/// Header convention used when a profile has an API key.
enum DirectApiKeyAuthMode {
  bearer('bearer'),
  apiKeyHeader('api-key-header');

  const DirectApiKeyAuthMode(this.storageValue);

  final String storageValue;

  static DirectApiKeyAuthMode fromStorage(Object? value) {
    if (value == null) return bearer;
    final mode = values
        .where((candidate) => candidate.storageValue == value)
        .firstOrNull;
    if (mode == null) {
      throw const FormatException('Unsupported direct API-key auth mode.');
    }
    return mode;
  }
}

/// A direct backend connection, including its credentials.
///
/// The complete object is persisted only in secure storage. Do not copy this
/// object, its JSON, or its [apiKey]/[customHeaders] into logs, preferences, or
/// model metadata.
final class DirectConnectionProfile {
  DirectConnectionProfile({
    this.schemaVersion = currentSchemaVersion,
    required this.id,
    required this.name,
    required this.adapterKey,
    required this.baseUrl,
    this.openAiApiMode = DirectOpenAiApiMode.chatCompletions,
    this.apiKeyAuthMode = DirectApiKeyAuthMode.bearer,
    String? apiVersion,
    String? modelIdPrefix,
    List<String> tags = const [],
    this.enabled = true,
    this.apiKey,
    Map<String, String> customHeaders = const {},
    List<String> manualModelIds = const [],
    this.allowSelfSignedCertificates = false,
    this.mtlsCertificateChainPem,
    this.mtlsCertificateLabel,
    this.mtlsPrivateKeyPem,
    this.mtlsPrivateKeyLabel,
    this.mtlsPrivateKeyPassword,
  }) : apiVersion = _trimmedOrNull(apiVersion),
       modelIdPrefix = _trimmedOrNull(modelIdPrefix),
       customHeaders = UnmodifiableMapView(Map.of(customHeaders)),
       tags = List.unmodifiable(_deduplicateNonEmpty(tags)),
       manualModelIds = List.unmodifiable(_deduplicateNonEmpty(manualModelIds));

  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final String id;
  final String name;

  /// String registry key, intentionally not an enum so plugins can add
  /// adapters without changing the persisted schema.
  final String adapterKey;
  final String baseUrl;
  final DirectOpenAiApiMode openAiApiMode;
  final DirectApiKeyAuthMode apiKeyAuthMode;

  /// Optional `api-version` query value, primarily for Azure OpenAI endpoints.
  final String? apiVersion;

  /// Optional display namespace for models from this profile.
  final String? modelIdPrefix;
  final List<String> tags;
  final bool enabled;
  final String? apiKey;
  final Map<String, String> customHeaders;

  /// Explicit model ids for servers that do not implement model discovery.
  /// When non-empty, discovery must not make a network request.
  final List<String> manualModelIds;
  final bool allowSelfSignedCertificates;
  final String? mtlsCertificateChainPem;
  final String? mtlsCertificateLabel;
  final String? mtlsPrivateKeyPem;
  final String? mtlsPrivateKeyLabel;
  final String? mtlsPrivateKeyPassword;

  bool get isUsable => enabled && validateOrNull() == null;

  bool get hasMutualTlsCredentials =>
      (mtlsCertificateChainPem?.trim().isNotEmpty ?? false) &&
      (mtlsPrivateKeyPem?.trim().isNotEmpty ?? false);

  /// Canonical scheme/host/port used to bind credentials to an origin.
  String? get origin => originOf(baseUrl);

  /// Validates persisted/user-entered fields without exposing their values.
  void validate() {
    final error = validateOrNull();
    if (error != null) throw FormatException(error);
  }

  String? validateOrNull() {
    if (schemaVersion != currentSchemaVersion) {
      return 'Unsupported direct connection profile version.';
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
      return 'Profile id must contain only letters, numbers, underscores, or dashes.';
    }
    if (name.trim().isEmpty) return 'Profile name is required.';
    if (adapterKey.trim().isEmpty || adapterKey.contains(RegExp(r'\s'))) {
      return 'Adapter key is invalid.';
    }
    if (originOf(baseUrl) == null) return 'Use a valid http(s) URL.';
    final uri = Uri.parse(baseUrl.trim());

    final normalizedApiVersion = apiVersion?.trim();
    if (normalizedApiVersion != null &&
        normalizedApiVersion.isNotEmpty &&
        !RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(normalizedApiVersion)) {
      return 'API version contains unsupported characters.';
    }
    final normalizedPrefix = modelIdPrefix?.trim();
    if (normalizedPrefix != null &&
        normalizedPrefix.isNotEmpty &&
        !RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(normalizedPrefix)) {
      return 'Model prefix must contain only letters, numbers, periods, underscores, or dashes.';
    }
    if (tags.any(
      (tag) =>
          tag.length > 64 || _containsLineBreak(tag) || tag.contains('\u0000'),
    )) {
      return 'A model tag is invalid.';
    }

    if (uri.scheme.toLowerCase() == 'http') {
      if (_hasTlsCredentialMaterial) {
        return 'TLS client credentials require an HTTPS URL.';
      }
      if (!_isSafePlaintextCredentialHost(uri.host)) {
        return 'Plaintext HTTP is only allowed for localhost or a private IP address. Use HTTPS.';
      }
    }

    for (final entry in customHeaders.entries) {
      if (!_isValidHeaderName(entry.key) || _containsLineBreak(entry.value)) {
        return 'A custom header is invalid.';
      }
      if (reservedHeaderNames.contains(entry.key.trim().toLowerCase())) {
        return 'Authorization, Host, and Content-Length cannot be custom headers.';
      }
    }
    if (apiKeyAuthMode == DirectApiKeyAuthMode.apiKeyHeader &&
        (apiKey ?? '').trim().isNotEmpty &&
        customHeaders.keys.any(
          (name) => name.trim().toLowerCase() == 'api-key',
        )) {
      return 'Remove the duplicate api-key custom header.';
    }
    if (_containsLineBreak(apiKey ?? '') ||
        _containsLineBreak(mtlsPrivateKeyPassword ?? '')) {
      return 'A credential contains an invalid line break.';
    }
    return null;
  }

  bool get _hasTlsCredentialMaterial => [
    mtlsCertificateChainPem,
    mtlsPrivateKeyPem,
    mtlsPrivateKeyPassword,
  ].any((value) => value?.trim().isNotEmpty ?? false);

  /// Returns a copy with all origin-bound secrets removed.
  DirectConnectionProfile withoutSecrets({String? baseUrl}) =>
      DirectConnectionProfile(
        schemaVersion: schemaVersion,
        id: id,
        name: name,
        adapterKey: adapterKey,
        baseUrl: baseUrl ?? this.baseUrl,
        openAiApiMode: openAiApiMode,
        apiKeyAuthMode: apiKeyAuthMode,
        apiVersion: apiVersion,
        modelIdPrefix: modelIdPrefix,
        tags: tags,
        enabled: enabled,
        manualModelIds: manualModelIds,
      );

  /// Retains bearer/custom-header edits but clears TLS trust and client-key
  /// material. TLS settings require a separate future re-entry flow and must
  /// never be inferred from bearer/header confirmation.
  DirectConnectionProfile withoutTlsSettings() => DirectConnectionProfile(
    schemaVersion: schemaVersion,
    id: id,
    name: name,
    adapterKey: adapterKey,
    baseUrl: baseUrl,
    openAiApiMode: openAiApiMode,
    apiKeyAuthMode: apiKeyAuthMode,
    apiVersion: apiVersion,
    modelIdPrefix: modelIdPrefix,
    tags: tags,
    enabled: enabled,
    apiKey: apiKey,
    customHeaders: customHeaders,
    manualModelIds: manualModelIds,
  );

  /// Applies an edit while preventing credentials from silently moving to a
  /// different origin. Callers may set [secretsConfirmedForNewOrigin] only
  /// after the user has explicitly supplied/confirmed the replacement values.
  static DirectConnectionProfile secureUpdate({
    required DirectConnectionProfile previous,
    required DirectConnectionProfile next,
    bool secretsConfirmedForNewOrigin = false,
  }) {
    if (previous.origin == next.origin) {
      return next;
    }
    if (!secretsConfirmedForNewOrigin) return next.withoutSecrets();
    return next.withoutTlsSettings();
  }

  DirectConnectionProfile copyWith({
    String? name,
    String? adapterKey,
    String? baseUrl,
    DirectOpenAiApiMode? openAiApiMode,
    DirectApiKeyAuthMode? apiKeyAuthMode,
    Object? apiVersion = _keep,
    Object? modelIdPrefix = _keep,
    List<String>? tags,
    bool? enabled,
    Object? apiKey = _keep,
    Map<String, String>? customHeaders,
    List<String>? manualModelIds,
    bool? allowSelfSignedCertificates,
    Object? mtlsCertificateChainPem = _keep,
    Object? mtlsCertificateLabel = _keep,
    Object? mtlsPrivateKeyPem = _keep,
    Object? mtlsPrivateKeyLabel = _keep,
    Object? mtlsPrivateKeyPassword = _keep,
  }) => DirectConnectionProfile(
    schemaVersion: schemaVersion,
    id: id,
    name: name ?? this.name,
    adapterKey: adapterKey ?? this.adapterKey,
    baseUrl: baseUrl ?? this.baseUrl,
    openAiApiMode: openAiApiMode ?? this.openAiApiMode,
    apiKeyAuthMode: apiKeyAuthMode ?? this.apiKeyAuthMode,
    apiVersion: identical(apiVersion, _keep)
        ? this.apiVersion
        : apiVersion as String?,
    modelIdPrefix: identical(modelIdPrefix, _keep)
        ? this.modelIdPrefix
        : modelIdPrefix as String?,
    tags: tags ?? this.tags,
    enabled: enabled ?? this.enabled,
    apiKey: identical(apiKey, _keep) ? this.apiKey : apiKey as String?,
    customHeaders: customHeaders ?? this.customHeaders,
    manualModelIds: manualModelIds ?? this.manualModelIds,
    allowSelfSignedCertificates:
        allowSelfSignedCertificates ?? this.allowSelfSignedCertificates,
    mtlsCertificateChainPem: identical(mtlsCertificateChainPem, _keep)
        ? this.mtlsCertificateChainPem
        : mtlsCertificateChainPem as String?,
    mtlsCertificateLabel: identical(mtlsCertificateLabel, _keep)
        ? this.mtlsCertificateLabel
        : mtlsCertificateLabel as String?,
    mtlsPrivateKeyPem: identical(mtlsPrivateKeyPem, _keep)
        ? this.mtlsPrivateKeyPem
        : mtlsPrivateKeyPem as String?,
    mtlsPrivateKeyLabel: identical(mtlsPrivateKeyLabel, _keep)
        ? this.mtlsPrivateKeyLabel
        : mtlsPrivateKeyLabel as String?,
    mtlsPrivateKeyPassword: identical(mtlsPrivateKeyPassword, _keep)
        ? this.mtlsPrivateKeyPassword
        : mtlsPrivateKeyPassword as String?,
  );

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'id': id,
    'name': name,
    'adapterKey': adapterKey,
    'baseUrl': baseUrl,
    'openAiApiMode': openAiApiMode.storageValue,
    'apiKeyAuthMode': apiKeyAuthMode.storageValue,
    'apiVersion': apiVersion,
    'modelIdPrefix': modelIdPrefix,
    'tags': tags,
    'enabled': enabled,
    'apiKey': apiKey,
    'customHeaders': customHeaders,
    'manualModelIds': manualModelIds,
    'allowSelfSignedCertificates': allowSelfSignedCertificates,
    'mtlsCertificateChainPem': mtlsCertificateChainPem,
    'mtlsCertificateLabel': mtlsCertificateLabel,
    'mtlsPrivateKeyPem': mtlsPrivateKeyPem,
    'mtlsPrivateKeyLabel': mtlsPrivateKeyLabel,
    'mtlsPrivateKeyPassword': mtlsPrivateKeyPassword,
  };

  factory DirectConnectionProfile.fromJson(Map<String, dynamic> json) {
    final version = _int(json['schemaVersion']) ?? currentSchemaVersion;
    if (version != currentSchemaVersion) {
      throw const FormatException(
        'Unsupported direct connection profile version.',
      );
    }
    final profile = DirectConnectionProfile(
      schemaVersion: version,
      id: _requiredString(json, 'id'),
      name: _requiredString(json, 'name'),
      adapterKey: _requiredString(json, 'adapterKey'),
      baseUrl: _requiredString(json, 'baseUrl'),
      openAiApiMode: DirectOpenAiApiMode.fromStorage(json['openAiApiMode']),
      apiKeyAuthMode: DirectApiKeyAuthMode.fromStorage(json['apiKeyAuthMode']),
      apiVersion: _optionalString(json['apiVersion']),
      modelIdPrefix: _optionalString(json['modelIdPrefix']),
      tags: _stringList(json['tags']),
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      apiKey: _optionalString(json['apiKey']),
      customHeaders: _stringMap(json['customHeaders']),
      manualModelIds: _stringList(json['manualModelIds']),
      allowSelfSignedCertificates: json['allowSelfSignedCertificates'] == true,
      mtlsCertificateChainPem: _optionalString(json['mtlsCertificateChainPem']),
      mtlsCertificateLabel: _optionalString(json['mtlsCertificateLabel']),
      mtlsPrivateKeyPem: _optionalString(json['mtlsPrivateKeyPem']),
      mtlsPrivateKeyLabel: _optionalString(json['mtlsPrivateKeyLabel']),
      mtlsPrivateKeyPassword: _optionalString(json['mtlsPrivateKeyPassword']),
    );
    profile.validate();
    return profile;
  }

  static String? originOf(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        (uri.scheme.toLowerCase() != 'http' &&
            uri.scheme.toLowerCase() != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    final scheme = uri.scheme.toLowerCase();
    final port = uri.hasPort ? uri.port : (scheme == 'https' ? 443 : 80);
    return '$scheme://${uri.host.toLowerCase()}:$port';
  }

  /// URI used as Dio's exact request root. A trailing slash ensures relative
  /// adapter paths preserve an endpoint prefix such as `/v1`.
  Uri requestBaseUri() {
    validate();
    final uri = Uri.parse(baseUrl.trim());
    final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
    return uri.replace(path: path);
  }

  static const Set<String> reservedHeaderNames = {
    'authorization',
    'host',
    'content-length',
  };

  static const Object _keep = Object();
}

/// Versioned envelope used for the single secure-storage profile document.
final class DirectConnectionProfilesDocument {
  DirectConnectionProfilesDocument(Iterable<DirectConnectionProfile> profiles)
    : profiles = List.unmodifiable(profiles);

  static const int currentVersion = 1;
  final List<DirectConnectionProfile> profiles;

  String encode() => jsonEncode({
    'version': currentVersion,
    'profiles': [for (final profile in profiles) profile.toJson()],
  });

  factory DirectConnectionProfilesDocument.decode(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException(
        'Direct connection document is not an object.',
      );
    }
    final map = decoded.cast<Object?, Object?>();
    if (_int(map['version']) != currentVersion) {
      throw const FormatException(
        'Unsupported direct connection document version.',
      );
    }
    final rawProfiles = map['profiles'];
    if (rawProfiles is! List) {
      throw const FormatException('Direct connection profiles are missing.');
    }
    final profiles = <DirectConnectionProfile>[];
    final ids = <String>{};
    for (final raw in rawProfiles) {
      if (raw is! Map) {
        throw const FormatException('A direct connection profile is invalid.');
      }
      final profile = DirectConnectionProfile.fromJson(
        raw.cast<String, dynamic>(),
      );
      if (!ids.add(profile.id)) {
        throw const FormatException(
          'Direct connection profile ids must be unique.',
        );
      }
      profiles.add(profile);
    }
    return DirectConnectionProfilesDocument(profiles);
  }
}

List<String> _deduplicateNonEmpty(Iterable<String> values) {
  final result = <String>[];
  final seen = <String>{};
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty && seen.add(trimmed)) result.add(trimmed);
  }
  return result;
}

String? _trimmedOrNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key]?.toString().trim() ?? '';
  if (value.isEmpty) throw FormatException('Direct profile is missing $key.');
  return value;
}

String? _optionalString(Object? value) {
  if (value == null) return null;
  final string = value.toString();
  return string.isEmpty ? null : string;
}

int? _int(Object? value) => switch (value) {
  int() => value,
  num() => value.toInt(),
  String() => int.tryParse(value),
  _ => null,
};

Map<String, String> _stringMap(Object? value) {
  if (value == null) return const {};
  if (value is! Map) throw const FormatException('Custom headers are invalid.');
  return value.map((key, item) => MapEntry(key.toString(), item.toString()));
}

List<String> _stringList(Object? value) {
  if (value == null) return const [];
  if (value is! Iterable) {
    throw const FormatException('Manual model ids are invalid.');
  }
  return value.map((item) => item.toString()).toList(growable: false);
}

bool _isValidHeaderName(String value) =>
    RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(value.trim());

bool _containsLineBreak(String value) =>
    value.contains('\r') || value.contains('\n');

bool _isSafePlaintextCredentialHost(String host) {
  final normalized = host.trim().toLowerCase();
  if (normalized == 'localhost' || normalized.endsWith('.localhost')) {
    return true;
  }

  final address = InternetAddress.tryParse(normalized);
  if (address == null) return false;
  final bytes = address.rawAddress;
  if (bytes.length == 4) return _isPrivateOrLoopbackIpv4(bytes);
  if (bytes.length != 16) return false;

  // IPv4-mapped IPv6 addresses retain the IPv4 security classification.
  final isIpv4Mapped =
      bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff;
  if (isIpv4Mapped) {
    return _isPrivateOrLoopbackIpv4(bytes.sublist(12));
  }

  final isLoopback =
      bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1;
  final isUniqueLocal = (bytes[0] & 0xfe) == 0xfc;
  final isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
  return isLoopback || isUniqueLocal || isLinkLocal;
}

bool _isPrivateOrLoopbackIpv4(List<int> bytes) {
  final first = bytes[0];
  final second = bytes[1];
  return first == 10 ||
      first == 127 ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 168) ||
      (first == 169 && second == 254);
}
