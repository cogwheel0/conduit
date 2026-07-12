import 'dart:convert';

import '../../../core/models/model.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';

const String kDirectModelIdPrefix = 'direct:';

final class DirectModelId {
  const DirectModelId._();

  static String encode(String profileId, String remoteModelId) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(profileId)) {
      throw ArgumentError.value(profileId, 'profileId');
    }
    if (remoteModelId.trim().isEmpty) {
      throw ArgumentError.value(remoteModelId, 'remoteModelId');
    }
    final encoded = base64Url
        .encode(utf8.encode(remoteModelId))
        .replaceAll('=', '');
    return '$kDirectModelIdPrefix$profileId:$encoded';
  }

  static ({String profileId, String remoteModelId})? decode(String stableId) {
    if (!stableId.startsWith(kDirectModelIdPrefix)) return null;
    final remainder = stableId.substring(kDirectModelIdPrefix.length);
    final separator = remainder.indexOf(':');
    if (separator <= 0 || separator == remainder.length - 1) return null;
    final profileId = remainder.substring(0, separator);
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(profileId)) return null;
    final encoded = remainder.substring(separator + 1);
    try {
      final padded = encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=');
      final remoteModelId = utf8.decode(base64Url.decode(padded));
      if (remoteModelId.isEmpty) return null;
      return (profileId: profileId, remoteModelId: remoteModelId);
    } catch (_) {
      return null;
    }
  }
}

final class DirectModelBinding {
  const DirectModelBinding({
    required this.profileId,
    required this.adapterKey,
    required this.remoteModelId,
  });

  final String profileId;
  final String adapterKey;
  final String remoteModelId;

  String get stableId => DirectModelId.encode(profileId, remoteModelId);

  @override
  bool operator ==(Object other) =>
      other is DirectModelBinding &&
      profileId == other.profileId &&
      adapterKey == other.adapterKey &&
      remoteModelId == other.remoteModelId;

  @override
  int get hashCode => Object.hash(profileId, adapterKey, remoteModelId);
}

final Expando<DirectModelBinding> _trustedBindings =
    Expando<DirectModelBinding>('locally-minted-direct-model');

/// Whether this exact object was minted locally. Routing must additionally use
/// [DirectModelRegistry.resolve] so deleted/stale profiles cannot be selected.
bool isLocallyMintedDirectModel(Model model) => _trustedBindings[model] != null;

bool hasReservedDirectIdentity(Model model) =>
    model.id.startsWith(kDirectModelIdPrefix) ||
    model.metadata?['backend'] == 'direct' ||
    model.metadata?['direct'] == true ||
    model.metadata?['directProvider'] != null;

List<Model> sanitizeRemoteDirectModels(Iterable<Model> models) => models
    .where(
      (model) =>
          !isLocallyMintedDirectModel(model) &&
          !hasReservedDirectIdentity(model),
    )
    .toList(growable: false);

/// Builds the display-only model list without mutating/persisting the
/// OpenWebUI model cache. Remote attempts to claim Conduit's reserved direct
/// namespace are removed before locally minted entries are appended.
List<Model> reconcileDirectModelsForDisplay({
  required Iterable<Model> remoteModels,
  required Iterable<Model> directModels,
  required DirectModelRegistry registry,
}) => List.unmodifiable([
  ...sanitizeRemoteDirectModels(remoteModels),
  ...directModels.where((model) => registry.resolve(model) != null),
]);

/// Trusted binding table for discovered/manual direct models.
final class DirectModelRegistry {
  final Map<String, DirectModelBinding> _registered = {};
  final Map<String, Set<String>> _idsByProfile = {};

  DirectModelBinding? resolve(Model model) {
    final minted = _trustedBindings[model];
    if (minted == null) return null;
    final registered = _registered[model.id];
    // Value equality is not sufficient here. If a profile is deleted and then
    // recreated with the same id/model, an old Model object has the same
    // binding values but must not gain authority over the new endpoint.
    return identical(registered, minted) ? registered : null;
  }

  /// Resolves only ids that were registered from current local profiles. A
  /// decodable `direct:` string by itself is never routing authority.
  DirectModelBinding? resolveRegisteredId(String stableId) =>
      _registered[stableId];

  List<Model> replaceProfileModels(
    DirectConnectionProfile profile,
    Iterable<DirectRemoteModel> remoteModels,
  ) {
    removeProfile(profile.id);
    final ids = <String>{};
    final models = <Model>[];
    for (final remote in remoteModels) {
      final prefix = profile.modelIdPrefix?.trim();
      final displayModelId = prefix == null || prefix.isEmpty
          ? remote.id
          : '$prefix.${remote.id}';
      final displayName = prefix == null || prefix.isEmpty
          ? remote.name
          : '$prefix.${remote.name}';
      final binding = DirectModelBinding(
        profileId: profile.id,
        adapterKey: profile.adapterKey,
        remoteModelId: remote.id,
      );
      final id = binding.stableId;
      if (!ids.add(id)) continue;
      final model = Model(
        id: id,
        name: displayName,
        description: remote.description,
        isMultimodal: remote.isMultimodal,
        supportsStreaming: true,
        capabilities: remote.capabilities,
        metadata: {
          'backend': 'direct',
          'direct': true,
          'directProvider': profile.adapterKey,
          'directProfileName': profile.name,
          'profileId': profile.id,
          'profileName': profile.name,
          'adapterKey': profile.adapterKey,
          'remoteModelId': remote.id,
          'remoteModelDisplayId': displayModelId,
          if (prefix != null && prefix.isNotEmpty) 'prefixId': prefix,
          if (profile.tags.isNotEmpty) 'tags': profile.tags,
        },
      );
      _trustedBindings[model] = binding;
      _registered[id] = binding;
      models.add(model);
    }
    _idsByProfile[profile.id] = ids;
    return List.unmodifiable(models);
  }

  void removeProfile(String profileId) {
    final ids = _idsByProfile.remove(profileId);
    if (ids == null) return;
    for (final id in ids) {
      _registered.remove(id);
    }
  }

  void retainProfiles(Iterable<String> profileIds) {
    final retained = profileIds.toSet();
    for (final id in _idsByProfile.keys.toList(growable: false)) {
      if (!retained.contains(id)) removeProfile(id);
    }
  }

  void clear() {
    _registered.clear();
    _idsByProfile.clear();
  }
}
