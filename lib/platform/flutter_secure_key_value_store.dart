import 'package:conduit_core/conduit_core.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The Flutter app's [SecureKeyValueStore].
///
/// Wraps `flutter_secure_storage` and pins the platform options that keep
/// existing installs readable. Those options are the reason this adapter
/// exists at all: they are meaningful to one plugin on two operating systems
/// and to nothing else, so they have no place in the core's contract.
class FlutterSecureKeyValueStore implements SecureKeyValueStore {
  FlutterSecureKeyValueStore([FlutterSecureStorage? delegate])
    : _delegate = delegate ?? _defaultStorage;

  final FlutterSecureStorage _delegate;

  static const FlutterSecureStorage _defaultStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      // Same name as the pre-v11 sharedPreferencesName so the plugin's
      // LegacyNamespaceKeyRecovery keeps existing Android data readable.
      storageNamespace: 'conduit_secure_prefs',
      preferencesKeyPrefix: 'conduit_',
      // Avoid auto-wipe on transient errors; handled at call sites instead.
      resetOnError: false,
    ),
    iOptions: IOSOptions(
      accountName: 'conduit_secure_storage',
      synchronizable: false,
    ),
  );

  @override
  Future<String?> read({required String key}) => _delegate.read(key: key);

  @override
  Future<void> write({required String key, required String? value}) =>
      _delegate.write(key: key, value: value);

  @override
  Future<void> delete({required String key}) => _delegate.delete(key: key);

  @override
  Future<bool> containsKey({required String key}) =>
      _delegate.containsKey(key: key);

  @override
  Future<Map<String, String>> readAll() => _delegate.readAll();

  @override
  Future<void> deleteAll() => _delegate.deleteAll();
}
