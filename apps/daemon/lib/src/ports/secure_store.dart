import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:cryptography/cryptography.dart';

/// The desktop [SecureKeyValueStore]: one AES-256-GCM file under `userData`.
///
/// The mobile app has a keychain to put credentials in. The desktop does not
/// have one the daemon can reach -- it is a headless child process, and the
/// OS keychains want a user session and a UI. So Electron holds the master
/// key in `safeStorage` (which *is* keychain-backed) and hands it to the
/// daemon on stdin at startup. The key exists on disk only inside Electron's
/// own encrypted blob; this file holds nothing that is useful without it.
///
/// The whole map is re-encrypted on every write. That is not a concern at
/// this size -- a handful of tokens and cookie jars -- and it keeps the file
/// format trivially verifiable: one nonce, one ciphertext, no per-entry
/// framing to get wrong.
final class DaemonSecureStore implements SecureKeyValueStore {
  DaemonSecureStore._(this._file, this._key, this._values);

  /// Opens, or starts empty if [file] does not exist yet.
  ///
  /// Throws [SecureStoreCorruptException] if the file exists but will not
  /// decrypt, which is the one case that must not be papered over: it means
  /// either the master key changed or the file was tampered with, and
  /// silently starting empty would sign the user out while looking like a
  /// fresh install.
  static Future<DaemonSecureStore> open({
    required File file,
    required List<int> masterKey,
  }) async {
    if (masterKey.length != 32) {
      throw ArgumentError.value(
        masterKey.length,
        'masterKey',
        'AES-256 needs exactly 32 bytes',
      );
    }
    final key = await _algorithm.newSecretKeyFromBytes(masterKey);
    final values = file.existsSync()
        ? await _decrypt(await file.readAsBytes(), key, file.path)
        : <String, String>{};
    return DaemonSecureStore._(file, key, values);
  }

  static final AesGcm _algorithm = AesGcm.with256bits();
  static final Random _random = Random.secure();

  /// Bumped if the framing below ever changes. Readers check it first so an
  /// older daemon fails with a clear error instead of a MAC failure.
  static const int _formatVersion = 1;
  static const int _nonceLength = 12;

  final File _file;
  final SecretKey _key;
  final Map<String, String> _values;

  /// Serialises writes. Two concurrent `write` calls would otherwise both
  /// read-modify-write the same file and one would lose its entry.
  Future<void> _pending = Future<void>.value();

  @override
  Future<String?> read({required String key}) async => _values[key];

  @override
  Future<bool> containsKey({required String key}) async =>
      _values.containsKey(key);

  @override
  Future<Map<String, String>> readAll() async =>
      Map<String, String>.unmodifiable(_values);

  @override
  Future<void> write({required String key, required String? value}) {
    // The interface treats a null value as a delete; matching
    // `InMemorySecureKeyValueStore` rather than storing the string "null".
    if (value == null) return delete(key: key);
    return _mutate(() => _values[key] = value);
  }

  @override
  Future<void> delete({required String key}) =>
      _mutate(() => _values.remove(key));

  @override
  Future<void> deleteAll() => _mutate(_values.clear);

  Future<void> _mutate(void Function() change) {
    change();
    return _pending = _pending.then((_) => _flush());
  }

  /// Writes via a temporary file and a rename.
  ///
  /// A partial write here is a signed-out user, so the file is never
  /// truncated in place: `rename` is atomic within a filesystem, so a crash
  /// mid-flush leaves the previous store intact.
  Future<void> _flush() async {
    final nonce = Uint8List.fromList(
      List<int>.generate(_nonceLength, (_) => _random.nextInt(256)),
    );
    final box = await _algorithm.encrypt(
      utf8.encode(jsonEncode(_values)),
      secretKey: _key,
      nonce: nonce,
    );
    final framed = Uint8List.fromList(<int>[
      _formatVersion,
      ...nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);

    final directory = _file.parent;
    if (!directory.existsSync()) directory.createSync(recursive: true);
    final temporary = File('${_file.path}.tmp');
    await temporary.writeAsBytes(framed, flush: true);
    await temporary.rename(_file.path);
  }

  static Future<Map<String, String>> _decrypt(
    Uint8List bytes,
    SecretKey key,
    String path,
  ) async {
    final macLength = _algorithm.macAlgorithm.macLength;
    if (bytes.isEmpty) return <String, String>{};
    if (bytes.first != _formatVersion) {
      throw SecureStoreCorruptException(
        path,
        'unknown format version ${bytes.first}',
      );
    }
    if (bytes.length < 1 + _nonceLength + macLength) {
      throw SecureStoreCorruptException(path, 'truncated');
    }

    final macStart = bytes.length - macLength;
    final box = SecretBox(
      bytes.sublist(1 + _nonceLength, macStart),
      nonce: bytes.sublist(1, 1 + _nonceLength),
      mac: Mac(bytes.sublist(macStart)),
    );
    final List<int> clear;
    try {
      clear = await _algorithm.decrypt(box, secretKey: key);
    } on SecretBoxAuthenticationError {
      throw SecureStoreCorruptException(
        path,
        'authentication failed - wrong master key, or the file was modified',
      );
    }
    final decoded = jsonDecode(utf8.decode(clear));
    if (decoded is! Map) {
      throw SecureStoreCorruptException(path, 'contents are not a JSON object');
    }
    return <String, String>{
      for (final entry in decoded.entries)
        entry.key as String: entry.value as String,
    };
  }
}

/// The secure store exists but cannot be read.
///
/// Deliberately not a "start empty" path: that would present a signed-in
/// user with onboarding and quietly discard their saved servers.
class SecureStoreCorruptException implements Exception {
  const SecureStoreCorruptException(this.path, this.reason);

  final String path;
  final String reason;

  @override
  String toString() => 'secure store at $path cannot be read: $reason';
}
