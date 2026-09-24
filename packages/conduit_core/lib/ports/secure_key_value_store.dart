/// Credential-grade key/value storage.
///
/// Server tokens, API keys and the cookie jar live here, never in the
/// ordinary preferences store. The backing store differs sharply by host:
/// Keychain and the Android keystore on mobile, an AES-256-GCM file on
/// desktop whose key comes from Electron's `safeStorage`.
///
/// The named-parameter shape mirrors how every existing call site already
/// reads, so adopting the port is a change of declared type rather than a
/// rewrite of 40-odd call sites. Plugin-specific option arguments are
/// deliberately absent: those configure one implementation and have no
/// meaning in the contract.
abstract interface class SecureKeyValueStore {
  /// The stored value, or null when absent or unreadable.
  ///
  /// Implementations must not throw on a locked or unavailable store — a
  /// missing credential and an unreadable one lead to the same place, which
  /// is asking the user to sign in again.
  Future<String?> read({required String key});

  /// Writes [value], or removes the entry when [value] is null.
  Future<void> write({required String key, required String? value});

  Future<void> delete({required String key});

  Future<bool> containsKey({required String key});

  Future<Map<String, String>> readAll();

  /// Removes everything this app owns.
  ///
  /// The "clear everything" half of sign-out depends on this completing; a
  /// partial wipe is what leaves a credential behind that silently
  /// re-authenticates the next session.
  Future<void> deleteAll();
}

/// An always-empty store that discards writes.
///
/// For tests and for a host with no credential storage at all. Not a
/// fallback for production: silently dropping a token would log the user out
/// on every launch with no explanation.
class InMemorySecureKeyValueStore implements SecureKeyValueStore {
  InMemorySecureKeyValueStore([Map<String, String>? seed])
    : _values = <String, String>{...?seed};

  final Map<String, String> _values;

  @override
  Future<String?> read({required String key}) async => _values[key];

  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }

  @override
  Future<void> delete({required String key}) async => _values.remove(key);

  @override
  Future<bool> containsKey({required String key}) async =>
      _values.containsKey(key);

  @override
  Future<Map<String, String>> readAll() async =>
      Map<String, String>.from(_values);

  @override
  Future<void> deleteAll() async => _values.clear();
}
