import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';
import '../../../core/services/secure_credential_storage.dart';
import '../models/direct_connection_profile.dart';

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
    final ids = <String>{};
    for (final profile in list) {
      profile.validate();
      if (!ids.add(profile.id)) {
        throw StateError('Direct connection profile ids must be unique.');
      }
    }
    await _storage.saveDirectConnectionProfiles(
      DirectConnectionProfilesDocument(list).encode(),
    );
    await PreferencesStore.put(
      PreferenceKeys.directConnectionsConfigured,
      list.isNotEmpty,
    );
    return List.unmodifiable(list);
  });

  Future<void> clear() => _serializeMutation(() async {
    await _storage.deleteDirectConnectionProfiles();
    await PreferencesStore.put(
      PreferenceKeys.directConnectionsConfigured,
      false,
    );
  });

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
