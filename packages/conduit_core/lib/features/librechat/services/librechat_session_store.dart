import 'dart:convert';

import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Where one LibreChat account's session lives between launches.
abstract interface class LibreChatSessionStore {
  Future<LibreChatSession?> read();

  Future<void> write(LibreChatSession session);

  Future<void> clear();
}

/// A [LibreChatSessionStore] in the platform keychain or keystore, one entry
/// per account: `librechat_session_v1:<accountId>`.
final class SecureLibreChatSessionStore implements LibreChatSessionStore {
  SecureLibreChatSessionStore(this._store, String accountId)
    : _key = keyFor(accountId);

  final SecureKeyValueStore _store;
  final String _key;

  static const String keyPrefix = 'librechat_session_v1:';

  static String keyFor(String accountId) {
    if (accountId.isEmpty || accountId.length > 128) {
      throw ArgumentError.value(accountId, 'accountId', 'Invalid id');
    }
    return '$keyPrefix$accountId';
  }

  @override
  Future<LibreChatSession?> read() async {
    final raw = await _store.read(key: _key);
    if (raw == null || raw.isEmpty) return null;
    try {
      return LibreChatSession.fromJson(jsonDecode(raw));
    } on FormatException {
      DebugLogger.warning('session-unreadable', scope: 'librechat/session');
      return null;
    }
  }

  @override
  Future<void> write(LibreChatSession session) =>
      _store.write(key: _key, value: jsonEncode(session.toJson()));

  @override
  Future<void> clear() => _store.delete(key: _key);
}

/// A [LibreChatSessionStore] that keeps the session in memory only.
final class InMemoryLibreChatSessionStore implements LibreChatSessionStore {
  InMemoryLibreChatSessionStore([this.session]);

  LibreChatSession? session;
  int writes = 0;

  @override
  Future<LibreChatSession?> read() async => session;

  @override
  Future<void> write(LibreChatSession session) async {
    writes++;
    this.session = session;
  }

  @override
  Future<void> clear() async => session = null;
}
