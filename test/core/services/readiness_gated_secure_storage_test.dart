import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/readiness_gated_secure_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

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

final class _RecordingSecureStorage extends FlutterSecureStorage {
  var readCount = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    readCount++;
    return 'stored-token';
  }
}
