import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/sync/chat_locks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatLocks', () {
    late ChatLocks locks;

    setUp(() {
      locks = ChatLocks();
    });

    test('serializes actions on the same key in submission order', () async {
      final events = <String>[];
      final firstStarted = Completer<void>();
      final release = Completer<void>();

      final first = locks.runExclusive('chat-a', () async {
        events.add('first-start');
        firstStarted.complete();
        await release.future;
        events.add('first-end');
        return 1;
      });
      final second = locks.runExclusive('chat-a', () async {
        events.add('second-start');
        await Future<void>.delayed(Duration.zero);
        events.add('second-end');
        return 2;
      });

      await firstStarted.future;
      // Give the second action every chance to (incorrectly) start.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      check(events).deepEquals(['first-start']);

      release.complete();
      check(await first).equals(1);
      check(await second).equals(2);
      check(events).deepEquals([
        'first-start',
        'first-end',
        'second-start',
        'second-end',
      ]);
    });

    test(
      'concurrent pull-merge and manual write on one chat id cannot '
      'interleave',
      () async {
        // Simulates REQ 3: a pull merge (multi-step, with internal awaits)
        // racing a manual write on the same chat. Steps from the two writers
        // must never alternate.
        final steps = <String>[];

        Future<void> writer(String name) {
          return locks.runExclusive('chat-1', () async {
            for (var i = 0; i < 3; i++) {
              steps.add('$name-$i');
              await Future<void>.delayed(Duration.zero);
            }
          });
        }

        await Future.wait([writer('pull'), writer('manual')]);

        check(steps).deepEquals([
          'pull-0',
          'pull-1',
          'pull-2',
          'manual-0',
          'manual-1',
          'manual-2',
        ]);
      },
    );

    test('errors propagate to the caller without poisoning the chain',
        () async {
      final failing = locks.runExclusive<void>('chat-a', () async {
        throw StateError('boom');
      });
      final after = locks.runExclusive('chat-a', () async => 'ran');

      await check(failing).throws<StateError>();
      check(await after).equals('ran');
      check(locks.isIdle).isTrue();
    });

    test('map entries are released once a key goes idle (no leak)', () async {
      check(locks.isIdle).isTrue();
      final pending = locks.runExclusive('chat-a', () async {
        await Future<void>.delayed(Duration.zero);
        return 0;
      });
      check(locks.isIdle).isFalse();
      await pending;
      check(locks.isIdle).isTrue();

      // Heavier churn across many keys still drains completely.
      await Future.wait([
        for (var i = 0; i < 50; i++)
          locks.runExclusive('chat-${i % 5}', () async {
            await Future<void>.delayed(Duration.zero);
          }),
      ]);
      check(locks.isIdle).isTrue();
    });

    test('independent keys run concurrently', () async {
      final blockA = Completer<void>();
      final events = <String>[];

      final a = locks.runExclusive('chat-a', () async {
        events.add('a-start');
        await blockA.future;
        events.add('a-end');
      });
      final b = locks.runExclusive('chat-b', () async {
        events.add('b-start');
        events.add('b-end');
      });

      await b;
      // B finished while A is still holding its own lock.
      check(events).deepEquals(['a-start', 'b-start', 'b-end']);
      blockA.complete();
      await a;
      check(locks.isIdle).isTrue();
    });

    test('action queued behind a failing predecessor still gets the result',
        () async {
      final results = <Object>[];
      final futures = <Future<void>>[];
      for (var i = 0; i < 4; i++) {
        futures.add(
          locks
              .runExclusive('chat-a', () async {
                if (i.isEven) throw StateError('boom $i');
                return i;
              })
              .then(results.add, onError: (Object e) => results.add('err')),
        );
      }
      await Future.wait(futures);
      check(results).deepEquals(['err', 1, 'err', 3]);
    });
  });
}
