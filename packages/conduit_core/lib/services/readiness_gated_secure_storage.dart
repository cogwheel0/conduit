import 'dart:async';

import 'package:conduit_core/conduit_core.dart';

/// Allows first paint to honor a short startup deadline while keeping every
/// later secure-storage operation behind the original in-flight Keychain call.
///
/// `Future.timeout` does not cancel its source. Without this barrier, timing
/// out the warmup and constructing providers can start a second iOS Keychain
/// operation concurrently with the still-running first access.
///
/// This decorates a [SecureKeyValueStore] rather than extending
/// `FlutterSecureStorage`. The gating is ordering logic that belongs to the
/// core; the six platform option bags it used to forward were plugin
/// configuration it never read.
final class ReadinessGatedSecureStorage implements SecureKeyValueStore {
  ReadinessGatedSecureStorage({
    required SecureKeyValueStore delegate,
    required Future<void> readiness,
  }) : _delegate = delegate,
       _readiness = readiness;

  final SecureKeyValueStore _delegate;
  final Future<void> _readiness;

  Future<T> _whenReady<T>(Future<T> Function() operation) async {
    await _readiness;
    return operation();
  }

  @override
  Future<void> write({required String key, required String? value}) =>
      _whenReady(() => _delegate.write(key: key, value: value));

  @override
  Future<String?> read({required String key}) =>
      _whenReady(() => _delegate.read(key: key));

  @override
  Future<bool> containsKey({required String key}) =>
      _whenReady(() => _delegate.containsKey(key: key));

  @override
  Future<void> delete({required String key}) =>
      _whenReady(() => _delegate.delete(key: key));

  @override
  Future<Map<String, String>> readAll() => _whenReady(_delegate.readAll);

  @override
  Future<void> deleteAll() => _whenReady(_delegate.deleteAll);
}

/// Returns at the startup deadline without cancelling [readiness]. Callers can
/// pass that same future to [ReadinessGatedSecureStorage] as the post-paint
/// concurrency barrier.
Future<void> waitForSecureStorageStartupDeadline(
  Future<void> readiness, {
  Duration timeout = const Duration(milliseconds: 500),
}) => readiness.timeout(timeout, onTimeout: () {});
