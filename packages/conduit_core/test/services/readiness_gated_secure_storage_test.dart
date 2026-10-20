import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/services/readiness_gated_secure_storage.dart';
import 'package:test/test.dart';
import 'package:conduit_core/conduit_core.dart';

void main() {
  test(
    'startup deadline returns while later reads retain the warmup barrier',
    () async {
      final readiness = Completer<void>();
      final delegate = _RecordingSecureStorage();
      final storage = ReadinessGatedSecureStorage(
        delegate: delegate,
        readiness: readiness.future,
      );

      await waitForSecureStorageStartupDeadline(
        readiness.future,
        timeout: const Duration(milliseconds: 1),
      );

      final read = storage.read(key: 'token');
      await Future<void>.delayed(Duration.zero);
      check(delegate.readCount).equals(0);

      readiness.complete();
      check(await read).equals('stored-token');
      check(delegate.readCount).equals(1);
    },
  );
}

/// Counts reads; everything else behaves like an ordinary empty store.
///
/// It used to extend `FlutterSecureStorage` and inherit the rest. The port
/// has no implementation to inherit, so it builds on the in-memory one the
/// core ships for exactly this.
final class _RecordingSecureStorage extends InMemorySecureKeyValueStore {
  var readCount = 0;

  @override
  Future<String?> read({required String key}) async {
    readCount++;
    return 'stored-token';
  }
}
