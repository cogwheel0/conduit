import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Allows first paint to honor a short startup deadline while keeping every
/// later secure-storage operation behind the original in-flight Keychain call.
///
/// `Future.timeout` does not cancel its source. Without this barrier, timing
/// out the warmup and constructing providers can start a second iOS Keychain
/// operation concurrently with the still-running first access.
final class ReadinessGatedSecureStorage extends FlutterSecureStorage {
  ReadinessGatedSecureStorage({
    required FlutterSecureStorage delegate,
    required Future<void> readiness,
  }) : _delegate = delegate,
       _readiness = readiness,
       super(
         iOptions: delegate.iOptions,
         aOptions: delegate.aOptions,
         lOptions: delegate.lOptions,
         wOptions: delegate.wOptions,
         webOptions: delegate.webOptions,
         mOptions: delegate.mOptions,
       );

  final FlutterSecureStorage _delegate;
  final Future<void> _readiness;

  Future<T> _whenReady<T>(Future<T> Function() operation) async {
    await _readiness;
    return operation();
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _whenReady(
    () => _delegate.write(
      key: key,
      value: value,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    ),
  );

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _whenReady(
    () => _delegate.read(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    ),
  );

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _whenReady(
    () => _delegate.containsKey(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    ),
  );

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _whenReady(
    () => _delegate.delete(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    ),
  );

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _whenReady(
    () => _delegate.readAll(
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    ),
  );

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _whenReady(
    () => _delegate.deleteAll(
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    ),
  );

  @override
  Stream<bool>? get onCupertinoProtectedDataAvailabilityChanged =>
      _delegate.onCupertinoProtectedDataAvailabilityChanged;

  @override
  Future<bool?> isCupertinoProtectedDataAvailable() =>
      _whenReady(_delegate.isCupertinoProtectedDataAvailable);
}

/// Returns at the startup deadline without cancelling [readiness]. Callers can
/// pass that same future to [ReadinessGatedSecureStorage] as the post-paint
/// concurrency barrier.
Future<void> waitForSecureStorageStartupDeadline(
  Future<void> readiness, {
  Duration timeout = const Duration(milliseconds: 500),
}) => readiness.timeout(timeout, onTimeout: () {});
