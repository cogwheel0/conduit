import '../models/direct_completion.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';

abstract interface class DirectProviderAdapter {
  String get key;

  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile);

  Future<List<DirectRemoteModel>> listModels(DirectConnectionProfile profile);

  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  );
}

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
