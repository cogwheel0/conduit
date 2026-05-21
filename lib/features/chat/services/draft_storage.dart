import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/persistence/persistence_providers.dart';

/// Per-conversation draft text persistence.
///
/// Pillar #2 of the local-first thesis: what the user typed must survive an
/// app close or crash. Persisted to the existing Hive `caches` box; never
/// touches the server.
class DraftStorage {
  DraftStorage(this._ref);

  final Ref _ref;

  static const String _prefix = 'draft::';
  static String _key(String? conversationId) =>
      '$_prefix${(conversationId == null || conversationId.isEmpty) ? 'new' : conversationId}';

  String? load(String? conversationId) {
    final box = _ref.read(hiveBoxesProvider).caches;
    final raw = box.get(_key(conversationId));
    if (raw is String && raw.isNotEmpty) return raw;
    return null;
  }

  Future<void> save(String? conversationId, String text) async {
    final box = _ref.read(hiveBoxesProvider).caches;
    final key = _key(conversationId);
    if (text.isEmpty) {
      await box.delete(key);
    } else {
      await box.put(key, text);
    }
  }

  Future<void> clear(String? conversationId) =>
      save(conversationId, '');
}

final draftStorageProvider = Provider<DraftStorage>(DraftStorage.new);
