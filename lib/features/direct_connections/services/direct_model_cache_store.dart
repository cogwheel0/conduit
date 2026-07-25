import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';

const String kDirectModelCacheKey = 'direct_model_cache_v1';
const int _kDirectModelCacheVersion = 1;
const int _kMaxDirectModelCacheCharacters = 8 * 1024 * 1024;
const int _kMaxDirectModelCacheProfiles = 64;
const int _kMaxDirectModelsPerProfile = 4096;
const int _kMaxDirectModelIdCharacters = 1024;
const int _kMaxDirectModelNameCharacters = 2048;
const int _kMaxDirectModelDescriptionCharacters = 32 * 1024;
const int _kMaxDirectCapabilityDepth = 12;
const int _kMaxDirectCapabilityContainerEntries = 1024;
const int _kMaxDirectCapabilityNodes = 8192;
const int _kMaxDirectCapabilityStringCharacters = 128 * 1024;

typedef DirectModelCacheRead = Future<String?> Function();
typedef DirectModelCacheWrite = Future<void> Function(String value);
typedef DirectModelCacheDelete = Future<void> Function();

/// Durable cache of provider-owned model summaries.
///
/// Cached entries are authenticated against the device trust key and the exact
/// transport-affecting profile values. The cache therefore cannot rebind a
/// model catalog across changed endpoints, credentials, headers, or mTLS
/// material, even though the catalog itself lives in the app-owned Direct
/// database rather than secure storage.
final class DirectModelCacheStore {
  DirectModelCacheStore({
    required DirectModelCacheRead read,
    required DirectModelCacheWrite write,
    required DirectModelCacheDelete delete,
  }) : _read = read,
       _write = write,
       _delete = delete;

  final DirectModelCacheRead _read;
  final DirectModelCacheWrite _write;
  final DirectModelCacheDelete _delete;
  Future<void> _writeQueue = Future<void>.value();

  Future<Map<String, List<DirectRemoteModel>>> load({
    required Iterable<DirectConnectionProfile> profiles,
    required List<int> authenticationKey,
  }) async {
    final raw = await _read();
    if (raw == null || raw.isEmpty) return const {};
    try {
      return _decode(
        raw,
        profiles: profiles,
        authenticationKey: authenticationKey,
      );
    } on FormatException {
      await _delete();
      return const {};
    }
  }

  Future<void> save({
    required Map<DirectConnectionProfile, List<DirectRemoteModel>> models,
    required List<int> authenticationKey,
    required bool Function() canWrite,
  }) {
    final encoded = _encode(models, authenticationKey: authenticationKey);
    final operation = _writeQueue.then<void>(
      (_) async {
        if (!canWrite()) return;
        await _write(encoded);
      },
      onError: (Object _, StackTrace _) async {
        if (!canWrite()) return;
        await _write(encoded);
      },
    );
    _writeQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  String _encode(
    Map<DirectConnectionProfile, List<DirectRemoteModel>> entries, {
    required List<int> authenticationKey,
  }) {
    if (authenticationKey.length < 32) {
      throw const FormatException('Direct model cache key is invalid.');
    }
    final profiles = <Map<String, dynamic>>[];
    var encodedDocumentLength = jsonEncode({
      'version': _kDirectModelCacheVersion,
      'profiles': const <Map<String, dynamic>>[],
    }).length;
    for (final entry in entries.entries) {
      if (profiles.length >= _kMaxDirectModelCacheProfiles) break;
      try {
        if (entry.value.length > _kMaxDirectModelsPerProfile) {
          continue;
        }
        final binding = _profileBinding(entry.key, authenticationKey);
        final models = [for (final model in entry.value) _encodeModel(model)];
        final encodedProfile = <String, dynamic>{
          'profileId': entry.key.id,
          'binding': binding,
          'models': models,
          'signature': _cacheEntrySignature(
            profileId: entry.key.id,
            binding: binding,
            models: models,
            authenticationKey: authenticationKey,
          ),
        };
        final encodedProfileLength = jsonEncode(encodedProfile).length;
        final candidateLength =
            encodedDocumentLength +
            encodedProfileLength +
            (profiles.isEmpty ? 0 : 1);
        if (candidateLength > _kMaxDirectModelCacheCharacters) continue;
        profiles.add(encodedProfile);
        encodedDocumentLength = candidateLength;
      } on FormatException {
        // One provider-owned catalog must not prevent healthy profiles from
        // hydrating after restart.
      }
    }
    return jsonEncode({
      'version': _kDirectModelCacheVersion,
      'profiles': profiles,
    });
  }

  Map<String, List<DirectRemoteModel>> _decode(
    String source, {
    required Iterable<DirectConnectionProfile> profiles,
    required List<int> authenticationKey,
  }) {
    if (source.length > _kMaxDirectModelCacheCharacters) {
      throw const FormatException('Direct model cache is too large.');
    }
    final decoded = jsonDecode(source);
    if (decoded is! Map ||
        decoded['version'] != _kDirectModelCacheVersion ||
        decoded['profiles'] is! List) {
      throw const FormatException('Direct model cache document is invalid.');
    }
    final rawProfiles = decoded['profiles'] as List;
    if (rawProfiles.length > _kMaxDirectModelCacheProfiles) {
      throw const FormatException('Too many Direct model cache profiles.');
    }
    final currentProfiles = <String, DirectConnectionProfile>{
      for (final profile in profiles) profile.id: profile,
    };
    final result = <String, List<DirectRemoteModel>>{};
    final seen = <String>{};
    for (final rawProfile in rawProfiles) {
      if (rawProfile is! Map) {
        throw const FormatException('Direct model cache profile is invalid.');
      }
      final profileId = rawProfile['profileId'];
      final binding = rawProfile['binding'];
      final rawModels = rawProfile['models'];
      final signature = rawProfile['signature'];
      if (profileId is! String ||
          profileId.isEmpty ||
          binding is! String ||
          rawModels is! List ||
          signature is! String ||
          !seen.add(profileId)) {
        throw const FormatException('Direct model cache profile is invalid.');
      }
      if (rawModels.length > _kMaxDirectModelsPerProfile) {
        throw const FormatException('Direct model cache has too many models.');
      }
      final profile = currentProfiles[profileId];
      if (profile == null ||
          !_constantTimeEquals(
            binding,
            _profileBinding(profile, authenticationKey),
          )) {
        continue;
      }
      final expectedSignature = _cacheEntrySignature(
        profileId: profileId,
        binding: binding,
        models: rawModels,
        authenticationKey: authenticationKey,
      );
      if (!_constantTimeEquals(signature, expectedSignature)) {
        throw const FormatException('Direct model cache signature is invalid.');
      }
      result[profileId] = List<DirectRemoteModel>.unmodifiable([
        for (final rawModel in rawModels) _decodeModel(rawModel),
      ]);
    }
    return Map<String, List<DirectRemoteModel>>.unmodifiable(result);
  }
}

Map<String, dynamic> _encodeModel(DirectRemoteModel model) {
  _validateModelText(model.id, _kMaxDirectModelIdCharacters);
  _validateModelText(model.name, _kMaxDirectModelNameCharacters);
  final description = model.description;
  if (description != null) {
    _validateModelText(description, _kMaxDirectModelDescriptionCharacters);
  }
  final capabilities = _normalizeCapabilities(model.capabilities);
  return {
    'id': model.id,
    'name': model.name,
    'description': ?description,
    'isMultimodal': model.isMultimodal,
    if (capabilities.isNotEmpty) 'capabilities': capabilities,
  };
}

DirectRemoteModel _decodeModel(Object? value) {
  if (value is! Map) {
    throw const FormatException('Direct cached model is invalid.');
  }
  final id = value['id'];
  final name = value['name'];
  final description = value['description'];
  final isMultimodal = value['isMultimodal'];
  if (id is! String ||
      id.trim().isEmpty ||
      name is! String ||
      (description != null && description is! String) ||
      isMultimodal is! bool) {
    throw const FormatException('Direct cached model is invalid.');
  }
  _validateModelText(id, _kMaxDirectModelIdCharacters);
  _validateModelText(name, _kMaxDirectModelNameCharacters);
  if (description is String) {
    _validateModelText(description, _kMaxDirectModelDescriptionCharacters);
  }
  final rawCapabilities = value['capabilities'];
  if (rawCapabilities != null && rawCapabilities is! Map) {
    throw const FormatException(
      'Direct cached model capabilities are invalid.',
    );
  }
  return DirectRemoteModel(
    id: id,
    name: name,
    description: description as String?,
    isMultimodal: isMultimodal,
    capabilities: rawCapabilities == null
        ? const {}
        : _normalizeCapabilities(rawCapabilities),
  );
}

Map<String, dynamic> _normalizeCapabilities(Map<dynamic, dynamic> source) {
  var nodes = 0;
  var stringCharacters = 0;

  Object? visit(Object? value, int depth) {
    nodes++;
    if (nodes > _kMaxDirectCapabilityNodes ||
        depth > _kMaxDirectCapabilityDepth) {
      throw const FormatException(
        'Direct cached model capabilities are excessive.',
      );
    }
    if (value == null || value is bool) return value;
    if (value is num) {
      if (!value.isFinite) {
        throw const FormatException(
          'Direct cached model capabilities are invalid.',
        );
      }
      return value;
    }
    if (value is String) {
      stringCharacters += value.length;
      if (stringCharacters > _kMaxDirectCapabilityStringCharacters) {
        throw const FormatException(
          'Direct cached model capabilities are excessive.',
        );
      }
      return value;
    }
    if (value is List) {
      if (value.length > _kMaxDirectCapabilityContainerEntries) {
        throw const FormatException(
          'Direct cached model capabilities are excessive.',
        );
      }
      return <Object?>[for (final item in value) visit(item, depth + 1)];
    }
    if (value is Map) {
      if (value.length > _kMaxDirectCapabilityContainerEntries) {
        throw const FormatException(
          'Direct cached model capabilities are excessive.',
        );
      }
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String || key.isEmpty) {
          throw const FormatException(
            'Direct cached model capabilities are invalid.',
          );
        }
        stringCharacters += key.length;
        if (stringCharacters > _kMaxDirectCapabilityStringCharacters) {
          throw const FormatException(
            'Direct cached model capabilities are excessive.',
          );
        }
        result[key] = visit(entry.value, depth + 1);
      }
      return result;
    }
    throw const FormatException(
      'Direct cached model capabilities are invalid.',
    );
  }

  return (visit(source, 0) as Map).cast<String, dynamic>();
}

void _validateModelText(String value, int maxCharacters) {
  if (value.length > maxCharacters || value.contains('\u0000')) {
    throw const FormatException('Direct cached model text is invalid.');
  }
}

String _profileBinding(
  DirectConnectionProfile profile,
  List<int> authenticationKey,
) {
  if (authenticationKey.length < 32) {
    throw const FormatException('Direct model cache key is invalid.');
  }
  final headers = profile.customHeaders.entries.toList(growable: false)
    ..sort((left, right) {
      final byName = left.key.compareTo(right.key);
      return byName != 0 ? byName : left.value.compareTo(right.value);
    });
  final canonical = jsonEncode([
    'conduit.direct-model-cache.profile.v1',
    profile.id,
    profile.adapterKey,
    profile.baseUrl,
    profile.openAiApiMode.name,
    profile.apiKeyAuthMode.name,
    profile.apiVersion,
    profile.modelIdPrefix,
    profile.tags,
    profile.apiKey,
    [
      for (final entry in headers) [entry.key, entry.value],
    ],
    profile.manualModelIds,
    profile.allowSelfSignedCertificates,
    profile.mtlsCertificateChainPem,
    profile.mtlsPrivateKeyPem,
    profile.mtlsPrivateKeyPassword,
  ]);
  return Hmac(
    sha256,
    authenticationKey,
  ).convert(utf8.encode(canonical)).toString();
}

String _cacheEntrySignature({
  required String profileId,
  required String binding,
  required Object models,
  required List<int> authenticationKey,
}) {
  final canonical = jsonEncode([
    'conduit.direct-model-cache.entry.v1',
    profileId,
    binding,
    models,
  ]);
  return Hmac(
    sha256,
    authenticationKey,
  ).convert(utf8.encode(canonical)).toString();
}

bool _constantTimeEquals(String left, String right) {
  var mismatch = left.length ^ right.length;
  final length = left.length > right.length ? left.length : right.length;
  for (var index = 0; index < length; index++) {
    final leftCode = index < left.length ? left.codeUnitAt(index) : 0;
    final rightCode = index < right.length ? right.codeUnitAt(index) : 0;
    mismatch |= leftCode ^ rightCode;
  }
  return mismatch == 0;
}
