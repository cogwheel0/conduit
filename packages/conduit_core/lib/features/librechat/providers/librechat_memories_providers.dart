import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/librechat/models/librechat_prompts.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_api_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';

/// The signed-in LibreChat user's memories and whether the assistant may use
/// them.
@immutable
final class LibreChatMemoryState {
  const LibreChatMemoryState({required this.memories, required this.enabled});

  final LibreChatMemories memories;

  /// The user's own switch (`personalization.memories`), on unless they
  /// turned it off.
  final bool enabled;
}

final libreChatMemoriesProvider =
    AsyncNotifierProvider<LibreChatMemoriesController, LibreChatMemoryState>(
      LibreChatMemoriesController.new,
    );

/// Reads and edits the signed-in LibreChat user's memories. Every change is
/// read back from the server, which owns the token budget and the keys.
class LibreChatMemoriesController extends AsyncNotifier<LibreChatMemoryState> {
  @override
  Future<LibreChatMemoryState> build() async {
    final api = ref.watch(libreChatApiServiceProvider);
    if (api == null) {
      return const LibreChatMemoryState(
        memories: LibreChatMemories(),
        enabled: true,
      );
    }
    final results = await Future.wait<Object?>([
      api.memories(),
      api.currentUser(),
    ]);
    final personalization = (results[1]! as LibreChatUser)
        .raw['personalization'];
    return LibreChatMemoryState(
      memories: LibreChatMemories.fromJson(results[0]! as Map<String, dynamic>),
      enabled: personalization is! Map || personalization['memories'] != false,
    );
  }

  /// Saves the memory [key] with [value]. [originalKey] names the memory
  /// being edited, which may be renamed to [key]; null adds a new one.
  /// Throws what the server said when it refuses (a duplicate key, the token
  /// limit).
  Future<void> save({
    String? originalKey,
    required String key,
    required String value,
  }) async {
    final api = _requireApi();
    final trimmedKey = key.trim();
    final trimmedValue = value.trim();
    if (originalKey == null) {
      await api.createMemory(trimmedKey, trimmedValue);
    } else {
      await api.updateMemory(
        originalKey,
        trimmedValue,
        newKey: trimmedKey == originalKey ? null : trimmedKey,
      );
    }
    await _reload();
  }

  Future<void> delete(String key) async {
    await _requireApi().deleteMemory(key);
    await _reload();
  }

  Future<void> setEnabled(bool enabled) async {
    await _requireApi().setMemoriesEnabled(enabled);
    final current = state.asData?.value;
    if (current != null) {
      state = AsyncData(
        LibreChatMemoryState(memories: current.memories, enabled: enabled),
      );
    }
    // A read a save or delete started before this may still be on its way
    // with the old setting: read again, after the change, in its place.
    await _reload();
  }

  /// Reads the list again after a write the server accepted, without
  /// waiting on it: a read that fails (and is retried) shows on the page,
  /// while the write itself reports success, so it is not tried again.
  Future<void> _reload() async {
    ref.invalidateSelf();
    future.ignore();
  }

  LibreChatApiService _requireApi() =>
      ref.read(libreChatApiServiceProvider) ??
      (throw const LibreChatApiException(
        message: 'The LibreChat account is not signed in.',
      ));
}
