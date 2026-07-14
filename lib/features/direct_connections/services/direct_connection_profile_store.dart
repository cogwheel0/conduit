import 'package:flutter/foundation.dart';

import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';
import '../../../core/services/secure_credential_storage.dart';
import '../models/direct_connection_profile.dart';

final class DirectConnectionProfileConflictException implements Exception {
  DirectConnectionProfileConflictException({
    Iterable<DirectConnectionProfile> currentProfiles = const [],
  }) : currentProfiles = List<DirectConnectionProfile>.unmodifiable(
         currentProfiles,
       );

  /// The durable document observed by the atomic compare-and-swap.
  ///
  /// Publishing this snapshot lets an editor reopen on the winning values
  /// without a second, potentially racy secure-storage read.
  final List<DirectConnectionProfile> currentProfiles;

  @override
  String toString() => 'Direct connection profile changed concurrently.';
}

/// Durable profile repository. The preference write is only a non-secret boot
/// hint; the complete document is committed to secure storage first.
final class DirectConnectionProfileStore {
  DirectConnectionProfileStore(this._storage);

  final SecureCredentialStorage _storage;
  Future<void> _mutationQueue = Future<void>.value();

  Future<List<DirectConnectionProfile>> load() async {
    final raw = await _storage.getDirectConnectionProfiles();
    if (raw == null || raw.trim().isEmpty) return const [];
    return DirectConnectionProfilesDocument.decode(raw).profiles;
  }

  /// Persists profiles after independently enforcing origin-bound credential
  /// safety against the currently durable document.
  ///
  /// Entries in [secretsConfirmedForNewOrigin] must represent an explicit user
  /// confirmation/re-entry for that profile's new origin. Controller-level
  /// checks are intentionally duplicated here so another caller cannot bypass
  /// the boundary by writing through this repository directly.
  Future<List<DirectConnectionProfile>> save(
    Iterable<DirectConnectionProfile> profiles, {
    Set<String> secretsConfirmedForNewOrigin = const {},
  }) => _serializeMutation(() async {
    final previousById = {
      for (final profile in await load()) profile.id: profile,
    };
    final list = <DirectConnectionProfile>[
      for (final profile in profiles)
        if (previousById[profile.id] case final previous?)
          DirectConnectionProfile.secureUpdate(
            previous: previous,
            next: profile,
            secretsConfirmedForNewOrigin: secretsConfirmedForNewOrigin.contains(
              profile.id,
            ),
          )
        else
          profile,
    ];
    return _persist(list);
  });

  /// Atomically inserts or replaces one profile against the currently durable
  /// document.
  ///
  /// The compare-and-swap check and the write share the repository mutation
  /// queue. Building the result from the freshly loaded document also keeps
  /// unrelated profiles and credentials written by an earlier mutation.
  Future<List<DirectConnectionProfile>> upsert(
    DirectConnectionProfile profile, {
    DirectConnectionProfile? expectedPrevious,
    bool secretsConfirmedForNewOrigin = false,
  }) => _serializeMutation(() async {
    profile.validate();
    final current = await load();
    final index = current.indexWhere((item) => item.id == profile.id);
    final previous = index < 0 ? null : current[index];
    if (expectedPrevious != null &&
        (previous == null ||
            !sameDirectConnectionProfileValues(previous, expectedPrevious))) {
      throw DirectConnectionProfileConflictException(currentProfiles: current);
    }

    final safeProfile = previous == null
        ? profile
        : DirectConnectionProfile.secureUpdate(
            previous: previous,
            next: profile,
            secretsConfirmedForNewOrigin: secretsConfirmedForNewOrigin,
          );
    safeProfile.validate();
    final updated = [...current];
    if (index < 0) {
      updated.add(safeProfile);
    } else {
      updated[index] = safeProfile;
    }
    return _persist(updated);
  });

  Future<void> clear() => _serializeMutation(() async {
    await _storage.deleteDirectConnectionProfiles();
    await PreferencesStore.put(
      PreferenceKeys.directConnectionsConfigured,
      false,
    );
  });

  Future<List<DirectConnectionProfile>> _persist(
    List<DirectConnectionProfile> profiles,
  ) async {
    final ids = <String>{};
    for (final profile in profiles) {
      profile.validate();
      if (!ids.add(profile.id)) {
        throw StateError('Direct connection profile ids must be unique.');
      }
    }
    await _storage.saveDirectConnectionProfiles(
      DirectConnectionProfilesDocument(profiles).encode(),
    );
    await PreferencesStore.put(
      PreferenceKeys.directConnectionsConfigured,
      profiles.isNotEmpty,
    );
    return List.unmodifiable(profiles);
  }

  Future<T> _serializeMutation<T>(Future<T> Function() operation) {
    final result = _mutationQueue.then<T>(
      (_) => operation(),
      onError: (Object _, StackTrace _) => operation(),
    );
    _mutationQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}

bool sameDirectConnectionProfileValues(
  DirectConnectionProfile left,
  DirectConnectionProfile right,
) =>
    left.schemaVersion == right.schemaVersion &&
    left.id == right.id &&
    left.name == right.name &&
    left.adapterKey == right.adapterKey &&
    left.baseUrl == right.baseUrl &&
    left.openAiApiMode == right.openAiApiMode &&
    left.apiKeyAuthMode == right.apiKeyAuthMode &&
    left.apiVersion == right.apiVersion &&
    left.modelIdPrefix == right.modelIdPrefix &&
    listEquals(left.tags, right.tags) &&
    left.enabled == right.enabled &&
    left.apiKey == right.apiKey &&
    mapEquals(left.customHeaders, right.customHeaders) &&
    listEquals(left.manualModelIds, right.manualModelIds) &&
    left.allowSelfSignedCertificates == right.allowSelfSignedCertificates &&
    left.mtlsCertificateChainPem == right.mtlsCertificateChainPem &&
    left.mtlsCertificateLabel == right.mtlsCertificateLabel &&
    left.mtlsPrivateKeyPem == right.mtlsPrivateKeyPem &&
    left.mtlsPrivateKeyLabel == right.mtlsPrivateKeyLabel &&
    left.mtlsPrivateKeyPassword == right.mtlsPrivateKeyPassword;
