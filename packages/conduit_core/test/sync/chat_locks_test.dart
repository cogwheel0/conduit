import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:test/test.dart';

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
      check(
        events,
      ).deepEquals(['first-start', 'first-end', 'second-start', 'second-end']);
    });

    test('concurrent pull-merge and manual write on one chat id cannot '
        'interleave', () async {
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
    });

    test(
      'errors propagate to the caller without poisoning the chain',
      () async {
        final failing = locks.runExclusive<void>('chat-a', () async {
          throw StateError('boom');
        });
        final after = locks.runExclusive('chat-a', () async => 'ran');

        await check(failing).throws<StateError>();
        check(await after).equals('ran');
        check(locks.isIdle).isTrue();
      },
    );

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

    test('queued waiter drains before target-key work after remap', () async {
      final events = <String>[];
      final localStarted = Completer<void>();
      final releaseLocal = Completer<void>();
      final serverStarted = Completer<void>();
      final releaseServer = Completer<void>();

      final local = locks.runExclusive('local:note', () async {
        events.add('local-start');
        localStarted.complete();
        await releaseLocal.future;
        events.add('local-end');
      });
      final queuedLocal = locks.runExclusive('local:note', () async {
        events.add('queued-local-start');
      });

      await localStarted.future;
      locks.remapKeyInPlace(fromId: 'local:note', toId: 'server-note');

      final server = locks.runExclusive('server-note', () async {
        events.add('server-start');
        serverStarted.complete();
        await releaseServer.future;
        events.add('server-end');
      });
      releaseLocal.complete();
      await local;
      await queuedLocal;
      await serverStarted.future;
      releaseServer.complete();
      await server;
      check(events).deepEquals([
        'local-start',
        'local-end',
        'queued-local-start',
        'server-start',
        'server-end',
      ]);
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

    test(
      'action queued behind a failing predecessor still gets the result',
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
      },
    );
  });

  group('ChatLocks.runBarrier', () {
    late ChatLocks locks;

    setUp(() {
      locks = ChatLocks();
    });

    test('waits for admitted work, holds back new work, then releases it in '
        'submission order', () async {
      final events = <String>[];
      final admittedRelease = Completer<void>();
      final admittedStarted = Completer<void>();

      final admitted = locks.runExclusive('chat-a', () async {
        events.add('admitted-start');
        admittedStarted.complete();
        await admittedRelease.future;
        events.add('admitted-end');
      });
      await admittedStarted.future;

      final barrier = locks.runBarrier(() async {
        events.add('barrier');
      });
      // New callers on a busy key, an idle key and a key that is queued.
      final late1 = locks.runExclusive('chat-a', () async {
        events.add('late-a');
      });
      final late2 = locks.runExclusive('chat-b', () async {
        events.add('late-b');
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Nothing entered, and the barrier has not run: it waits for the one
      // action that was admitted first.
      check(events).deepEquals(['admitted-start']);
      check(locks.barrierActive).isTrue();

      admittedRelease.complete();
      await Future.wait([admitted, barrier, late1, late2]);

      check(events).deepEquals([
        'admitted-start',
        'admitted-end',
        'barrier',
        'late-a',
        'late-b',
      ]);
      check(locks.barrierActive).isFalse();
      check(locks.isIdle).isTrue();
    });

    test(
      'bumps the generation when it ends, even if its action failed',
      () async {
        final before = locks.generation;

        await check(
          locks.runBarrier<void>(
            () async => throw StateError('server hung up'),
          ),
        ).throws<StateError>();

        check(locks.generation).equals(before + 1);
        // The barrier is gone: new work is admitted again.
        check(await locks.runExclusive('chat-a', () async => 'ran'))
            .equals('ran');
      },
    );

    test(
      'does not hold back the locks an admitted action takes itself',
      () async {
        // A create holds the local id and then takes the server id; a barrier
        // waiting on it must not block that second acquisition.
        final firstHeld = Completer<void>();
        final proceed = Completer<void>();
        final order = <String>[];

        final create = locks.runExclusive('local:1', () async {
          firstHeld.complete();
          await proceed.future;
          await locks.runExclusive('server-1', () async => order.add('nested'));
          order.add('create-done');
        });
        await firstHeld.future;
        final barrier = locks.runBarrier(() async => order.add('barrier'));
        await Future<void>.delayed(Duration.zero);

        proceed.complete();
        await Future.wait([create, barrier])
            .timeout(const Duration(seconds: 2));

        check(order).deepEquals(['nested', 'create-done', 'barrier']);
      },
    );

    test(
      'holds back work an admitted action left running after it returned',
      () async {
        final order = <String>[];
        final lateStarted = Completer<void>();
        final releaseLate = Completer<void>();
        Future<void>? leftRunning;

        await locks.runExclusive('chat-a', () async {
          // Started inside the lock, finishes after the action has returned.
          leftRunning = () async {
            await releaseLate.future;
            await locks.runExclusive('chat-a', () async => order.add('late'));
          }();
          lateStarted.complete();
        });
        await lateStarted.future;

        final barrier = locks.runBarrier(() async {
          order.add('barrier');
          await Future<void>.delayed(const Duration(milliseconds: 20));
          order.add('barrier-end');
        });
        await Future<void>.delayed(Duration.zero);
        releaseLate.complete();
        await Future.wait([barrier, leftRunning!]);

        check(order).deepEquals(['barrier', 'barrier-end', 'late']);
      },
    );

    test('barriers run one at a time', () async {
      final order = <String>[];
      final first = locks.runBarrier(() async {
        order.add('first-start');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        order.add('first-end');
      });
      final second = locks.runBarrier(() async {
        order.add('second-start');
      });

      await Future.wait([first, second]);

      check(order).deepEquals(['first-start', 'first-end', 'second-start']);
      check(locks.generation).equals(2);
    });

    test(
      'cannot be started from inside a lock, where it would wait on itself',
      () async {
        await check(
          locks.runExclusive('chat-a', () => locks.runBarrier(() async {})),
        ).throws<StateError>();
        check(locks.isIdle).isTrue();
      },
    );
  });
}
