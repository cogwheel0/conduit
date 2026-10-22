import 'dart:async';

import 'package:conduit_core/features/hermes/services/hermes_read_cache.dart';
import 'package:test/test.dart';

void main() {
  test(
    'concurrent reads share work and subsequent reads reuse the value',
    () async {
      final cache = HermesReadCache();
      final pending = Completer<int>();
      var calls = 0;
      Future<int> load() {
        calls++;
        return pending.future;
      }

      final a = cache.read('profile:a', load);
      final b = cache.read('profile:a', load);
      pending.complete(7);
      expect(await a, 7);
      expect(await b, 7);
      expect(await cache.read('profile:a', load), 7);
      expect(calls, 1);
    },
  );

  test('invalidated late read cannot replace a newer result', () async {
    final cache = HermesReadCache();
    final old = Completer<int>();
    final first = cache.read('model:a', () => old.future);
    cache.invalidate('model:');
    expect(await cache.read('model:a', () async => 2), 2);
    old.complete(1);
    expect(await first, 1);
    expect(await cache.read('model:a', () async => 3), 2);
  });

  test('a failed read is retried and profiles do not share values', () async {
    final cache = HermesReadCache();
    await expectLater(
      cache.read<int>('a', () async => throw StateError('unavailable')),
      throwsStateError,
    );
    expect(await cache.read('a', () async => 1), 1);
    expect(await cache.read('b', () async => 2), 2);
    expect(await cache.read('a', () async => 3, refresh: true), 3);
  });

  test(
    'expired metadata is fetched again instead of remaining authoritative',
    () async {
      final cache = HermesReadCache();
      expect(await cache.read('a', () async => 1, ttl: Duration.zero), 1);
      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(await cache.read('a', () async => 2), 2);
    },
  );
}
