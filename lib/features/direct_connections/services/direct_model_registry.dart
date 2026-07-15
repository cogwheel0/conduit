import 'dart:convert';

import '../../../core/models/model.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';

const String kDirectModelIdPrefix = 'direct:';

/// Runtime provenance for a locally minted direct model.
///
/// Device profiles use Conduit's native transport. Profiles projected from
/// Open WebUI settings use Open WebUI's server/Socket.IO direct transport.
/// This is trusted runtime state and is never inferred from model metadata.
enum DirectModelSource { device, openWebUi }

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
    this.source = DirectModelSource.device,
    this.openWebUiUrlIndex,
    this.openWebUiModelId,
  });

  final String profileId;
  final String adapterKey;
  final String remoteModelId;
  final DirectModelSource source;
  final int? openWebUiUrlIndex;
  final String? openWebUiModelId;

  String get stableId => DirectModelId.encode(profileId, remoteModelId);

  @override
  bool operator ==(Object other) =>
      other is DirectModelBinding &&
      profileId == other.profileId &&
      adapterKey == other.adapterKey &&
      remoteModelId == other.remoteModelId &&
      source == other.source &&
      openWebUiUrlIndex == other.openWebUiUrlIndex &&
      openWebUiModelId == other.openWebUiModelId;

  @override
  int get hashCode => Object.hash(
    profileId,
    adapterKey,
    remoteModelId,
    source,
    openWebUiUrlIndex,
    openWebUiModelId,
  );
}

final Expando<DirectModelBinding> _trustedBindings =
    Expando<DirectModelBinding>('locally-minted-direct-model');

/// Whether this exact object was minted locally. Routing must additionally use
/// [DirectModelRegistry.resolve] so deleted/stale profiles cannot be selected.
bool isLocallyMintedDirectModel(Model model) => _trustedBindings[model] != null;

/// Whether this exact object belongs to Conduit's local direct namespace.
/// Server-controlled ids and metadata are never provenance on their own.
bool hasReservedDirectIdentity(Model model) =>
    isLocallyMintedDirectModel(model);

/// Removes locally minted runtime models before persisting or reconciling a
/// server-owned model list. An id or metadata field that resembles Conduit's
/// direct namespace is not provenance and must not hide a valid server model.
List<Model> sanitizeRemoteDirectModels(Iterable<Model> models) => models
    .where((model) => !isLocallyMintedDirectModel(model))
    .toList(growable: false);

/// Builds the display-only model list without mutating/persisting the
/// OpenWebUI model cache. Server models that merely resemble the direct
/// namespace remain visible. An exact id collision with a live local binding
/// is reserved for that binding so id-based selectors cannot rebind the user
/// to an untrusted object with the wrong transport.
List<Model> reconcileDirectModelsForDisplay({
  required Iterable<Model> remoteModels,
  required Iterable<Model> directModels,
  required DirectModelRegistry registry,
}) {
  final activeDirectModels = directModels
      .where((model) => registry.resolve(model) != null)
      .toList(growable: false);
  final activeDirectIds = activeDirectModels.map((model) => model.id).toSet();
  return List.unmodifiable([
    ...sanitizeRemoteDirectModels(
      remoteModels,
    ).where((model) => !activeDirectIds.contains(model.id)),
    ...activeDirectModels,
  ]);
}

/// Trusted binding table for discovered/manual direct models.
final class DirectModelRegistry {
  final Map<String, DirectModelBinding> _registered = {};
  final Map<String, Set<String>> _idsByProfile = {};
  int _revision = 0;

  /// Monotonically increases whenever the trusted binding table changes.
  ///
  /// The registry is intentionally mutated in place, so consumers that cache
  /// derived presentation or routing data must include this value in their
  /// cache key rather than relying on the registry object's identity.
  int get revision => _revision;

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

  /// Resolves a provider-facing model id persisted by Open WebUI back to the
  /// current locally minted model object that carries routing authority.
  ///
  /// Open WebUI stores ids such as `prefix.gpt-4o` in chats and settings, while
  /// Conduit keeps a collision-resistant `direct:...` id internally. Iteration
  /// deliberately keeps the last match, mirroring Open WebUI's last-wins model
  /// de-duplication when multiple direct connections expose the same id.
  Model? resolveOpenWebUiWireModel(
    Iterable<Model> candidates,
    String wireModelId,
  ) {
    final normalized = wireModelId.trim();
    if (normalized.isEmpty) return null;
    Model? match;
    for (final candidate in candidates) {
      final binding = resolve(candidate);
      if (binding?.source == DirectModelSource.openWebUi &&
          binding?.openWebUiModelId == normalized) {
        match = candidate;
      }
    }
    return match;
  }

  bool hasOpenWebUiWireModel(String wireModelId) {
    final normalized = wireModelId.trim();
    return normalized.isNotEmpty &&
        _registered.values.any(
          (binding) =>
              binding.source == DirectModelSource.openWebUi &&
              binding.openWebUiModelId == normalized,
        );
  }

  DirectModelBinding? resolveOpenWebUiWireBinding({
    required String profileId,
    required int urlIndex,
    required String wireModelId,
  }) {
    final normalized = wireModelId.trim();
    if (normalized.isEmpty || urlIndex < 0) return null;
    for (final binding in _registered.values) {
      if (binding.source == DirectModelSource.openWebUi &&
          binding.profileId == profileId &&
          binding.openWebUiUrlIndex == urlIndex &&
          binding.openWebUiModelId == normalized) {
        return binding;
      }
    }
    return null;
  }

  List<Model> replaceProfileModels(
    DirectConnectionProfile profile,
    Iterable<DirectRemoteModel> remoteModels, {
    DirectModelSource source = DirectModelSource.device,
    int? openWebUiUrlIndex,
  }) {
    if (source == DirectModelSource.openWebUi && openWebUiUrlIndex == null) {
      throw ArgumentError.notNull('openWebUiUrlIndex');
    }
    if (source == DirectModelSource.openWebUi && openWebUiUrlIndex! < 0) {
      throw ArgumentError.value(
        openWebUiUrlIndex,
        'openWebUiUrlIndex',
        'Open WebUI URL indexes must be non-negative.',
      );
    }
    if (source == DirectModelSource.device && openWebUiUrlIndex != null) {
      throw ArgumentError.value(
        openWebUiUrlIndex,
        'openWebUiUrlIndex',
        'Device profiles do not have an Open WebUI URL index.',
      );
    }
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
        source: source,
        openWebUiUrlIndex: openWebUiUrlIndex,
        openWebUiModelId: source == DirectModelSource.openWebUi
            ? displayModelId
            : null,
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
          if (source == DirectModelSource.openWebUi)
            'openWebUiDirectConnection': true,
          'urlIdx': ?openWebUiUrlIndex,
          if (prefix != null && prefix.isNotEmpty) 'prefixId': prefix,
          if (profile.tags.isNotEmpty) 'tags': profile.tags,
        },
      );
      _trustedBindings[model] = binding;
      _registered[id] = binding;
      models.add(model);
    }
    _idsByProfile[profile.id] = ids;
    _revision += 1;
    return List.unmodifiable(models);
  }

  void removeProfile(String profileId) {
    final ids = _idsByProfile.remove(profileId);
    if (ids == null) return;
    for (final id in ids) {
      _registered.remove(id);
    }
    _revision += 1;
  }

  void retainProfiles(Iterable<String> profileIds) {
    final retained = profileIds.toSet();
    for (final id in _idsByProfile.keys.toList(growable: false)) {
      if (!retained.contains(id)) removeProfile(id);
    }
  }

  void clear() {
    if (_registered.isEmpty && _idsByProfile.isEmpty) return;
    _registered.clear();
    _idsByProfile.clear();
    _revision += 1;
  }
}
