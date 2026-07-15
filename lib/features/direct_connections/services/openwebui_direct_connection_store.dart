import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/direct_connection_profile.dart';
import '../models/openwebui_direct_connection.dart';

typedef OpenWebUiUserSettingsReader = Future<Map<String, dynamic>> Function();
typedef OpenWebUiUserSettingsWriter =
    Future<void> Function(Map<String, dynamic> settings);
typedef OpenWebUiUserSettingsMutationSerializer =
    Future<T> Function<T>(Future<T> Function() operation);

/// Raised when a server-backed record changed after an editor loaded it.
final class OpenWebUiDirectConnectionConflictException implements Exception {
  const OpenWebUiDirectConnectionConflictException(this.currentSnapshot);

  /// The freshly fetched settings that won the compare-and-swap.
  final OpenWebUiDirectConnectionsSnapshot currentSnapshot;

  @override
  String toString() => 'Open WebUI direct connection changed concurrently.';
}

/// The server accepted a settings write, but its authoritative state could not
/// be fetched afterward. Callers must reload instead of replaying the mutation.
final class OpenWebUiDirectConnectionCommitUncertainException
    implements Exception {
  const OpenWebUiDirectConnectionCommitUncertainException();

  @override
  String toString() =>
      'Open WebUI settings may have been saved, but could not be reloaded.';
}

/// Codec for Open WebUI's indexed `ui.directConnections` settings document.
///
/// Open WebUI stores three parallel collections: URLs, keys, and per-index
/// config maps. The runtime profile id therefore deliberately identifies the
/// owner and index, rather than any URL or credential value.
final class OpenWebUiDirectConnectionsCodec {
  OpenWebUiDirectConnectionsCodec({
    required String serverId,
    required String accountId,
  }) : serverId = serverId.trim(),
       accountId = accountId.trim() {
    if (this.serverId.isEmpty || this.accountId.isEmpty) {
      throw ArgumentError('A server and account owner are required.');
    }
  }

  final String serverId;
  final String accountId;

  OpenWebUiDirectConnectionsSnapshot decode(Map<String, dynamic> settings) {
    final ui = _jsonMap(settings['ui']) ?? <String, dynamic>{};
    final rawDirectConnections = ui['directConnections'];
    final directConnections =
        _jsonMap(rawDirectConnections) ?? <String, dynamic>{};
    final urls = _jsonList(directConnections['OPENAI_API_BASE_URLS']);
    final keys = _jsonList(directConnections['OPENAI_API_KEYS']);
    final configs = _jsonMap(directConnections['OPENAI_API_CONFIGS']);

    final records = <OpenWebUiDirectConnectionRecord>[];
    for (var index = 0; index < urls.length; index++) {
      final rawUrl = _stringValue(urls[index]);
      final rawKey = index < keys.length ? _stringValue(keys[index]) : '';
      final configKey = '$index';
      final hasIndexedConfig = configs?.containsKey(configKey) ?? false;
      final rawConfigValue = configs?[configKey];
      final rawConfig = _jsonMap(rawConfigValue) ?? <String, dynamic>{};
      final authType = _decodeAuthType(rawConfig);
      final supportedAuth = authType == 'bearer' || authType == 'none';
      final profile = _decodeProfile(
        index: index,
        rawUrl: rawUrl,
        rawKey: rawKey,
        rawConfig: rawConfig,
        authType: authType,
      );
      // Open WebUI skips URL entries that have no matching indexed config.
      // Keep the record visible for repair/deletion, but never execute it.
      final compatibility = !hasIndexedConfig
          ? OpenWebUiDirectConnectionCompatibility.invalidProfile
          : !supportedAuth
          ? OpenWebUiDirectConnectionCompatibility.unsupportedAuthentication
          : profile.validateOrNull() == null
          ? OpenWebUiDirectConnectionCompatibility.compatible
          : OpenWebUiDirectConnectionCompatibility.invalidProfile;

      records.add(
        OpenWebUiDirectConnectionRecord(
          index: index,
          profile: profile,
          revision: _fingerprint(<String, Object?>{
            'index': index,
            'url': urls[index],
            'key': index < keys.length ? keys[index] : null,
            'config': rawConfigValue,
          }),
          rawConfig: rawConfig,
          authType: authType,
          compatibility: compatibility,
        ),
      );
    }

    return OpenWebUiDirectConnectionsSnapshot(
      serverId: serverId,
      accountId: accountId,
      records: records,
      ui: ui,
      documentRevision: _fingerprint(rawDirectConnections),
    );
  }

  /// Appends a profile with the same parallel-array semantics as Open WebUI.
  Map<String, dynamic> addProfileToUi(
    Map<String, dynamic> ui,
    DirectConnectionProfile profile, {
    String? authType,
  }) {
    _validateWritableProfile(profile);
    final document = _mutableDirectConnections(ui);
    final urls = document.urls;
    final keys = document.keys;
    _alignKeys(keys, urls.length);
    urls.add(profile.baseUrl);
    final effectiveAuthType = authType == null
        ? _authTypeForNewProfile(profile)
        : _normalizeSupportedAuthType(authType);
    keys.add(effectiveAuthType == 'bearer' ? profile.apiKey ?? '' : '');
    document.configs['${urls.length - 1}'] = _configForProfile(
      profile,
      rawConfig: const <String, dynamic>{'connection_type': 'external'},
      authType: effectiveAuthType,
    );
    return _finishMutation(document, urls: urls, keys: keys);
  }

  /// Replaces one indexed profile while retaining its unknown config fields.
  Map<String, dynamic> updateProfileInUi(
    Map<String, dynamic> ui, {
    required int index,
    required DirectConnectionProfile profile,
    required Map<String, dynamic> rawConfig,
    required String authType,
  }) {
    _validateWritableProfile(profile);
    final document = _mutableDirectConnections(ui);
    if (index < 0 || index >= document.urls.length) {
      throw RangeError.range(
        index,
        0,
        document.urls.isEmpty ? 0 : document.urls.length - 1,
        'index',
        'Open WebUI direct connection index is out of range.',
      );
    }

    document.urls[index] = profile.baseUrl;
    while (document.keys.length <= index) {
      document.keys.add('');
    }
    if (authType == 'bearer') {
      document.keys[index] = profile.apiKey ?? '';
    } else if (authType == 'none') {
      document.keys[index] = '';
    }
    document.configs['$index'] = _configForProfile(
      profile,
      rawConfig: rawConfig,
      authType: authType,
    );
    return _finishMutation(document, urls: document.urls, keys: document.keys);
  }

  /// Deletes one index and shifts later configs exactly with their URL/key.
  Map<String, dynamic> deleteProfileFromUi(
    Map<String, dynamic> ui, {
    required int index,
  }) {
    final document = _mutableDirectConnections(ui);
    if (index < 0 || index >= document.urls.length) {
      throw RangeError.range(
        index,
        0,
        document.urls.isEmpty ? 0 : document.urls.length - 1,
        'index',
        'Open WebUI direct connection index is out of range.',
      );
    }

    final urls = <String>[
      for (var oldIndex = 0; oldIndex < document.urls.length; oldIndex++)
        if (oldIndex != index) document.urls[oldIndex],
    ];
    final keys = <String>[
      for (var oldIndex = 0; oldIndex < document.keys.length; oldIndex++)
        if (oldIndex != index) document.keys[oldIndex],
    ];
    final configs = <String, dynamic>{};
    for (var newIndex = 0; newIndex < urls.length; newIndex++) {
      final oldIndex = newIndex < index ? newIndex : newIndex + 1;
      final oldKey = '$oldIndex';
      if (document.configs.containsKey(oldKey)) {
        configs['$newIndex'] = _mutableJsonValue(document.configs[oldKey]);
      }
    }
    document.configs
      ..clear()
      ..addAll(configs);
    return _finishMutation(document, urls: urls, keys: keys);
  }

  DirectConnectionProfile _decodeProfile({
    required int index,
    required String rawUrl,
    required String rawKey,
    required Map<String, dynamic> rawConfig,
    required String authType,
  }) {
    final apiType = _optionalString(rawConfig['api_type']);
    final key = authType == 'bearer' && rawKey.isNotEmpty ? rawKey : null;
    return DirectConnectionProfile(
      id: _runtimeProfileId(index),
      name: _displayName(rawUrl, index),
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: rawUrl.trim(),
      openAiApiMode: apiType == DirectOpenAiApiMode.responses.storageValue
          ? DirectOpenAiApiMode.responses
          : DirectOpenAiApiMode.chatCompletions,
      apiKeyAuthMode: DirectApiKeyAuthMode.bearer,
      apiVersion: _optionalString(rawConfig['api_version']),
      modelIdPrefix: _optionalString(rawConfig['prefix_id']),
      tags: _decodeTags(rawConfig['tags']),
      enabled: rawConfig['enable'] is bool ? rawConfig['enable'] as bool : true,
      apiKey: key,
      customHeaders: _decodeHeaders(rawConfig['headers']),
      manualModelIds: _decodeStringList(rawConfig['model_ids']),
    );
  }

  String _runtimeProfileId(int index) {
    final ownerIndexDigest = _fingerprint(<String, Object>{
      'kind': 'openwebui-direct-profile',
      'serverId': serverId,
      'accountId': accountId,
      'index': index,
    });
    return 'owui_$ownerIndexDigest';
  }

  static String _displayName(String rawUrl, int index) {
    final uri = Uri.tryParse(rawUrl.trim());
    final host = uri?.host.trim() ?? '';
    if (host.isEmpty) return 'Open WebUI connection ${index + 1}';
    final hostAndPort = uri!.hasPort ? '$host:${uri.port}' : host;
    return '$hostAndPort · ${index + 1}';
  }

  static String _decodeAuthType(Map<String, dynamic> rawConfig) {
    if (!rawConfig.containsKey('auth_type') || rawConfig['auth_type'] == null) {
      return 'bearer';
    }
    return _stringValue(rawConfig['auth_type']).trim().toLowerCase();
  }

  static String _authTypeForNewProfile(DirectConnectionProfile profile) =>
      (profile.apiKey ?? '').trim().isEmpty ? 'none' : 'bearer';

  static List<String> _decodeTags(Object? rawTags) {
    if (rawTags is! Iterable) return const <String>[];
    final tags = <String>[];
    for (final rawTag in rawTags) {
      final name = switch (rawTag) {
        String() => rawTag,
        Map() => _optionalString(rawTag['name']) ?? '',
        _ => '',
      };
      if (name.trim().isNotEmpty) tags.add(name);
    }
    return tags;
  }

  static Map<String, String> _decodeHeaders(Object? rawHeaders) {
    if (rawHeaders is! Map) return const <String, String>{};
    return rawHeaders.map<String, String>(
      (key, value) => MapEntry(key.toString(), _stringValue(value)),
    );
  }

  static List<String> _decodeStringList(Object? rawValues) {
    if (rawValues is! Iterable || rawValues is String) {
      return const <String>[];
    }
    return rawValues.map(_stringValue).toList(growable: false);
  }

  static void _validateWritableProfile(DirectConnectionProfile profile) {
    if (profile.adapterKey != kOpenAiCompatibleAdapterKey) {
      throw const FormatException(
        'Only OpenAI-compatible server connections are supported.',
      );
    }
    profile.validate();
  }

  static Map<String, dynamic> _configForProfile(
    DirectConnectionProfile profile, {
    required Map<String, dynamic> rawConfig,
    required String authType,
  }) {
    final config = _mutableJsonMap(rawConfig);
    config['enable'] = profile.enabled;
    config['tags'] = <Map<String, String>>[
      for (final tag in profile.tags) <String, String>{'name': tag},
    ];
    config['prefix_id'] = profile.modelIdPrefix ?? '';
    config['model_ids'] = <String>[...profile.manualModelIds];
    config['auth_type'] = authType;

    if (profile.customHeaders.isEmpty) {
      config.remove('headers');
    } else {
      config['headers'] = <String, String>{...profile.customHeaders};
    }
    if (profile.apiVersion == null) {
      config.remove('api_version');
    } else {
      config['api_version'] = profile.apiVersion;
    }
    if (profile.openAiApiMode == DirectOpenAiApiMode.responses) {
      config['api_type'] = DirectOpenAiApiMode.responses.storageValue;
    } else {
      config.remove('api_type');
    }
    return config;
  }

  static _MutableDirectConnections _mutableDirectConnections(
    Map<String, dynamic> sourceUi,
  ) {
    final ui = _mutableJsonMap(sourceUi);
    final directConnections =
        _jsonMap(ui['directConnections']) ?? <String, dynamic>{};
    final mutableDirectConnections = _mutableJsonMap(directConnections);
    ui['directConnections'] = mutableDirectConnections;

    final urls = _jsonList(
      mutableDirectConnections['OPENAI_API_BASE_URLS'],
    ).map(_stringValue).toList(growable: true);
    final keys = _jsonList(
      mutableDirectConnections['OPENAI_API_KEYS'],
    ).map(_stringValue).toList(growable: true);
    final configs = _mutableJsonMap(
      _jsonMap(mutableDirectConnections['OPENAI_API_CONFIGS']) ??
          const <String, dynamic>{},
    );
    return _MutableDirectConnections(
      ui: ui,
      directConnections: mutableDirectConnections,
      urls: urls,
      keys: keys,
      configs: configs,
    );
  }

  static Map<String, dynamic> _finishMutation(
    _MutableDirectConnections document, {
    required List<String> urls,
    required List<String> keys,
  }) {
    final normalizedUrls = <String>[
      for (final url in urls) _removeTrailingSlashes(url),
    ];
    final alignedKeys = <String>[...keys];
    _alignKeys(alignedKeys, normalizedUrls.length);

    document.directConnections['OPENAI_API_BASE_URLS'] = normalizedUrls;
    document.directConnections['OPENAI_API_KEYS'] = alignedKeys;
    document.directConnections['OPENAI_API_CONFIGS'] = document.configs;
    return document.ui;
  }

  static void _alignKeys(List<String> keys, int urlCount) {
    if (keys.length > urlCount) {
      keys.removeRange(urlCount, keys.length);
    }
    while (keys.length < urlCount) {
      keys.add('');
    }
  }
}

/// Ephemeral repository for the current Open WebUI account's direct settings.
///
/// Every mutation begins with a fresh GET, performs an expected-revision check,
/// POSTs the complete freshly-read settings document with only `ui` replaced by
/// the merged value, then performs another GET so callers receive the server's
/// authoritative records.
final class OpenWebUiDirectConnectionStore {
  OpenWebUiDirectConnectionStore({
    required String serverId,
    required String accountId,
    required OpenWebUiUserSettingsReader readSettings,
    required OpenWebUiUserSettingsWriter writeSettings,
    OpenWebUiUserSettingsMutationSerializer? serializeSettingsMutation,
  }) : serverId = serverId.trim(),
       accountId = accountId.trim(),
       _readSettings = readSettings,
       _writeSettings = writeSettings,
       _serializeSettingsMutation = serializeSettingsMutation,
       _codec = OpenWebUiDirectConnectionsCodec(
         serverId: serverId,
         accountId: accountId,
       );

  final String serverId;
  final String accountId;
  final OpenWebUiUserSettingsReader _readSettings;
  final OpenWebUiUserSettingsWriter _writeSettings;
  final OpenWebUiUserSettingsMutationSerializer? _serializeSettingsMutation;
  final OpenWebUiDirectConnectionsCodec _codec;
  Future<void> _mutationQueue = Future<void>.value();

  Future<OpenWebUiDirectConnectionsSnapshot> load() async =>
      (await _loadDocument()).snapshot;

  Future<
    ({
      Map<String, dynamic> settings,
      OpenWebUiDirectConnectionsSnapshot snapshot,
    })
  >
  _loadDocument() async {
    final settings = _mutableJsonMap(await _readSettings());
    return (settings: settings, snapshot: _codec.decode(settings));
  }

  Future<OpenWebUiDirectConnectionsSnapshot> add(
    DirectConnectionProfile profile, {
    String? authType,
    String? expectedDocumentRevision,
  }) => _serializeMutation(() async {
    final normalizedAuthType = authType == null
        ? null
        : _normalizeSupportedAuthType(authType);
    final document = await _loadDocument();
    final current = document.snapshot;
    if (expectedDocumentRevision != null &&
        current.documentRevision != expectedDocumentRevision) {
      throw OpenWebUiDirectConnectionConflictException(current);
    }
    final updatedUi = _codec.addProfileToUi(
      current.ui,
      profile,
      authType: normalizedAuthType,
    );
    return _commitUi(document.settings, updatedUi);
  });

  Future<OpenWebUiDirectConnectionsSnapshot> update(
    OpenWebUiDirectConnectionRecord record,
    DirectConnectionProfile profile, {
    String? authType,
    String? expectedRevision,
  }) => _serializeMutation(() async {
    final normalizedAuthType = authType == null
        ? null
        : _normalizeSupportedAuthType(authType);
    final document = await _loadDocument();
    final current = document.snapshot;
    final authoritative = _recordAt(current, record.index);
    if (authoritative == null ||
        authoritative.profile.id != record.profile.id ||
        authoritative.revision != (expectedRevision ?? record.revision)) {
      throw OpenWebUiDirectConnectionConflictException(current);
    }
    final updatedUi = _codec.updateProfileInUi(
      current.ui,
      index: authoritative.index,
      profile: profile,
      rawConfig: authoritative.rawConfig,
      // A null selection is a lossless round-trip. Unsupported existing auth
      // remains compatibility-filtered and its key was never put in [profile].
      authType: normalizedAuthType ?? authoritative.authType,
    );
    return _commitUi(document.settings, updatedUi);
  });

  Future<OpenWebUiDirectConnectionsSnapshot> delete(
    OpenWebUiDirectConnectionRecord record, {
    String? expectedRevision,
  }) => _serializeMutation(() async {
    final document = await _loadDocument();
    final current = document.snapshot;
    final authoritative = _recordAt(current, record.index);
    if (authoritative == null ||
        authoritative.profile.id != record.profile.id ||
        authoritative.revision != (expectedRevision ?? record.revision)) {
      throw OpenWebUiDirectConnectionConflictException(current);
    }
    final updatedUi = _codec.deleteProfileFromUi(
      current.ui,
      index: authoritative.index,
    );
    return _commitUi(document.settings, updatedUi);
  });

  Future<OpenWebUiDirectConnectionsSnapshot> _commitUi(
    Map<String, dynamic> currentSettings,
    Map<String, dynamic> updatedUi,
  ) async {
    final payload = _mutableJsonMap(currentSettings);
    payload['ui'] = _mutableJsonMap(updatedUi);
    try {
      await _writeSettings(payload);
    } catch (_) {
      // Once dispatch begins, a timeout, disconnect, or post-response
      // ownership rejection cannot prove that the server did not commit.
      // Replaying an add could duplicate it, so require an authoritative GET.
      throw const OpenWebUiDirectConnectionCommitUncertainException();
    }
    return _loadAfterCommittedWrite();
  }

  Future<OpenWebUiDirectConnectionsSnapshot> _loadAfterCommittedWrite() async {
    try {
      return await load();
    } catch (_) {
      throw const OpenWebUiDirectConnectionCommitUncertainException();
    }
  }

  static OpenWebUiDirectConnectionRecord? _recordAt(
    OpenWebUiDirectConnectionsSnapshot snapshot,
    int index,
  ) {
    if (index < 0 || index >= snapshot.records.length) return null;
    return snapshot.records[index];
  }

  Future<T> _serializeMutation<T>(Future<T> Function() operation) {
    Future<T> run() {
      final serializer = _serializeSettingsMutation;
      return serializer == null ? operation() : serializer<T>(operation);
    }

    final result = _mutationQueue.then<T>(
      (_) => run(),
      onError: (Object _, StackTrace _) => run(),
    );
    _mutationQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}

final class _MutableDirectConnections {
  const _MutableDirectConnections({
    required this.ui,
    required this.directConnections,
    required this.urls,
    required this.keys,
    required this.configs,
  });

  final Map<String, dynamic> ui;
  final Map<String, dynamic> directConnections;
  final List<String> urls;
  final List<String> keys;
  final Map<String, dynamic> configs;
}

Map<String, dynamic>? _jsonMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is! Map) return null;
  return value.map<String, dynamic>(
    (key, item) => MapEntry(key.toString(), item),
  );
}

List<dynamic> _jsonList(Object? value) =>
    value is List ? value : const <dynamic>[];

Map<String, dynamic> _mutableJsonMap(Map<String, dynamic> source) =>
    source.map((key, value) => MapEntry(key, _mutableJsonValue(value)));

Object? _mutableJsonValue(Object? value) => switch (value) {
  Map<String, dynamic>() => _mutableJsonMap(value),
  Map() => value.map<String, dynamic>(
    (key, item) => MapEntry(key.toString(), _mutableJsonValue(item)),
  ),
  List() => value.map(_mutableJsonValue).toList(growable: true),
  _ => value,
};

String _stringValue(Object? value) => value is String
    ? value
    : value == null
    ? ''
    : value.toString();

String? _optionalString(Object? value) {
  final normalized = _stringValue(value).trim();
  return normalized.isEmpty ? null : normalized;
}

String _normalizeSupportedAuthType(String authType) {
  final normalized = authType.trim().toLowerCase();
  if (normalized != 'bearer' && normalized != 'none') {
    throw const FormatException(
      'Only bearer and no-auth server connections are supported.',
    );
  }
  return normalized;
}

String _removeTrailingSlashes(String value) =>
    value.replaceFirst(RegExp(r'/+$'), '');

String _fingerprint(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(_canonicalJson(value)))).toString();

Object? _canonicalJson(Object? value) => switch (value) {
  Map() => _canonicalJsonMap(value),
  Iterable() => value.map(_canonicalJson).toList(growable: false),
  num() when !value.isFinite => value.toString(),
  String() || num() || bool() || null => value,
  _ => value.toString(),
};

Map<String, Object?> _canonicalJsonMap(Map<dynamic, dynamic> value) {
  final entries = <MapEntry<String, Object?>>[
    for (final entry in value.entries)
      MapEntry(entry.key.toString(), entry.value),
  ]..sort((left, right) => left.key.compareTo(right.key));
  return <String, Object?>{
    for (final entry in entries) entry.key: _canonicalJson(entry.value),
  };
}
