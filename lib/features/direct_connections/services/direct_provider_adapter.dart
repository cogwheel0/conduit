import '../models/direct_completion.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';

abstract interface class DirectProviderAdapter {
  String get key;

  /// Verifies the configured provider with provider-specific network I/O.
  ///
  /// This must not inherit [listModels]' manual-ID shortcut: Test Connection
  /// is a liveness check even when model discovery is intentionally disabled.
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile);

  Future<List<DirectRemoteModel>> listModels(DirectConnectionProfile profile);

  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  );
}

/// Builds the optimistic entries configured for providers without discovery.
///
/// Adapters must check this in [DirectProviderAdapter.listModels] before
/// constructing an HTTP client: a non-empty manual list is an explicit
/// no-discovery-network contract. It does not apply to
/// [DirectProviderAdapter.probe], which must still verify liveness.
List<DirectRemoteModel>? directManualModels(DirectConnectionProfile profile) =>
    profile.manualModelIds.isEmpty
    ? null
    : List.unmodifiable([
        for (final id in profile.manualModelIds)
          // Manual IDs currently carry no per-model modality metadata. Keep
          // direct v1's optimistic image support so manually configured vision
          // models remain usable; a future adapter/profile capability override
          // can make this conservative without changing the adapter contract.
          DirectRemoteModel(id: id, isMultimodal: true),
      ]);

/// Runtime-extensible adapter registry. Persisted profiles store [String] keys
/// so a future adapter can be added without a profile schema migration.
final class DirectProviderAdapterRegistry {
  DirectProviderAdapterRegistry([
    Iterable<DirectProviderAdapter> adapters = const [],
  ]) {
    for (final adapter in adapters) {
      register(adapter);
    }
  }

  final Map<String, DirectProviderAdapter> _adapters = {};

  Iterable<String> get keys => _adapters.keys;

  void register(DirectProviderAdapter adapter, {bool replace = false}) {
    final key = adapter.key.trim();
    if (key.isEmpty || key.contains(RegExp(r'\s'))) {
      throw ArgumentError.value(adapter.key, 'adapter.key');
    }
    if (!replace && _adapters.containsKey(key)) {
      throw StateError(
        'A direct provider adapter is already registered for $key.',
      );
    }
    _adapters[key] = adapter;
  }

  DirectProviderAdapter? lookup(String key) => _adapters[key.trim()];

  DirectProviderAdapter require(String key) =>
      lookup(key) ??
      (throw StateError('No direct provider adapter is registered for $key.'));

  bool unregister(String key) => _adapters.remove(key.trim()) != null;
}
