import 'dart:convert';

import 'package:synchronized/synchronized.dart';

import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// The saved LibreChat accounts, in secure storage under
/// `librechat_registry_v1`. Their sessions sit beside it, one entry per
/// account (`librechat_session_v1:<accountId>`).
final class LibreChatRegistryStore {
  LibreChatRegistryStore(this._store);

  final SecureKeyValueStore _store;
  final Lock _lock = Lock();

  static const String key = 'librechat_registry_v1';

  Future<LibreChatRegistry> read() => _lock.synchronized(_read);

  Future<LibreChatRegistry> _read() async {
    final raw = await _store.read(key: key);
    if (raw == null || raw.isEmpty) return const LibreChatRegistry();
    try {
      return LibreChatRegistry.fromJson(jsonDecode(raw));
    } on FormatException {
      DebugLogger.warning('registry-unreadable', scope: 'librechat/registry');
      return const LibreChatRegistry();
    }
  }

  /// Applies [change] to the saved registry and saves the result, one change
  /// at a time.
  Future<LibreChatRegistry> update(
    LibreChatRegistry Function(LibreChatRegistry current) change,
  ) => _lock.synchronized(() async {
    final next = change(await _read());
    await _store.write(key: key, value: jsonEncode(next.toJson()));
    return next;
  });

  /// The session store of account [accountId].
  LibreChatSessionStore sessionStore(String accountId) =>
      SecureLibreChatSessionStore(_store, accountId);

  /// Removes the registry and every LibreChat session, including any left
  /// behind by an account no longer in the registry.
  Future<void> deleteAll() => _lock.synchronized(() async {
    final all = await _store.readAll();
    for (final entry in all.keys) {
      if (entry == key ||
          entry.startsWith(SecureLibreChatSessionStore.keyPrefix)) {
        await _store.delete(key: entry);
      }
    }
  });
}
