import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/platform/conduit_platform_apis.g.dart';
import 'package:conduit/core/services/app_intents_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

void main() {
  test(
    'an older teardown cannot unregister a replacement intent handler',
    () async {
      final readinessEvents = <bool>[];
      final handlerEvents = <AppIntentFlutterApi?>[];
      final falseStarted = Completer<void>();
      final releaseFalse = Completer<void>();
      final lifecycle = AppIntentLifecycleCoordinator(
        setReady: (ready) async {
          readinessEvents.add(ready);
          if (!ready) {
            falseStarted.complete();
            await releaseFalse.future;
          }
        },
        setHandler: handlerEvents.add,
      );
      final older = _FakeAppIntentHandler();
      final replacement = _FakeAppIntentHandler();

      final olderRegistration = lifecycle.register(older);
      await lifecycle.settled;
      final olderTeardown = lifecycle.unregister(olderRegistration);
      final unavailable = handlerEvents.last;
      check(unavailable).isNotNull();
      check(unavailable).not((it) => it.identicalTo(older));
      await falseStarted.future;

      lifecycle.register(replacement);
      check(handlerEvents.last).identicalTo(replacement);
      releaseFalse.complete();
      await olderTeardown;
      await lifecycle.settled;

      check(readinessEvents).deepEquals([true, false, true]);
      check(handlerEvents).deepEquals([older, unavailable, replacement]);
      check(handlerEvents.last).identicalTo(replacement);
    },
  );

  test('current teardown marks native unready before unregistering', () async {
    final events = <String>[];
    final lifecycle = AppIntentLifecycleCoordinator(
      setReady: (ready) async => events.add('ready:$ready'),
      setHandler: (handler) =>
          events.add(handler == null ? 'handler:null' : 'handler:set'),
    );
    final handler = _FakeAppIntentHandler();

    final registration = lifecycle.register(handler);
    await lifecycle.settled;
    await lifecycle.unregister(registration);

    check(events).deepEquals([
      'handler:set',
      'ready:true',
      'handler:set',
      'ready:false',
      'handler:null',
    ]);
  });

  test('native readiness retries with bounded backoff', () async {
    var readyAttempts = 0;
    final observedDelays = <Duration>[];
    final lifecycle = AppIntentLifecycleCoordinator(
      setReady: (ready) async {
        if (!ready) return;
        readyAttempts += 1;
        if (readyAttempts < 3) {
          throw StateError('transient readiness failure');
        }
      },
      setHandler: (_) {},
      readinessRetryDelays: const [
        Duration(milliseconds: 10),
        Duration(milliseconds: 20),
      ],
      delay: (delay) async => observedDelays.add(delay),
    );

    lifecycle.register(_FakeAppIntentHandler());
    await lifecycle.settled;

    check(readyAttempts).equals(3);
    check(observedDelays).deepEquals(const [
      Duration(milliseconds: 10),
      Duration(milliseconds: 20),
    ]);
  });

  test('native unready retries stop at the configured bound', () async {
    var unreadyAttempts = 0;
    final handlerEvents = <AppIntentFlutterApi?>[];
    final lifecycle = AppIntentLifecycleCoordinator(
      setReady: (ready) async {
        if (ready) return;
        unreadyAttempts += 1;
        throw StateError('persistent readiness failure');
      },
      setHandler: handlerEvents.add,
      readinessRetryDelays: const [Duration.zero, Duration.zero],
    );
    final handler = _FakeAppIntentHandler();
    final registration = lifecycle.register(handler);
    await lifecycle.settled;

    await check(lifecycle.unregister(registration)).throws<StateError>();

    check(unreadyAttempts).equals(3);
    check(handlerEvents).length.equals(2);
    check(handlerEvents.first).identicalTo(handler);
    final fallback = handlerEvents.last;
    check(fallback).isNotNull();
    check(fallback).not((it) => it.identicalTo(handler));
    final response = await fallback!.askChat('unavailable-ask', null);
    check(response.success).isFalse();
    check(response.error).equals('App not ready');
  });

  test('unavailable handler cleans staged image before rejecting it', () async {
    final handlerEvents = <AppIntentFlutterApi?>[];
    final lifecycle = AppIntentLifecycleCoordinator(
      setReady: (_) async {},
      setHandler: handlerEvents.add,
    );
    final registration = lifecycle.register(_FakeAppIntentHandler());
    await lifecycle.settled;
    await lifecycle.unregister(registration);
    final stagedFile = await _createAppIntentStagingFile('unavailable.png');

    final response = await handlerEvents[1]!.sendImage(
      'unavailable-image',
      PlatformAppIntentImagePayload(
        filename: 'unavailable.png',
        filePath: stagedFile.path,
      ),
    );

    check(response.success).isFalse();
    check(response.error).equals('App not ready');
    check(await stagedFile.exists()).isFalse();
  });

  test('registration generations protect a reused handler instance', () async {
    final falseStarted = Completer<void>();
    final releaseFalse = Completer<void>();
    final handlerEvents = <AppIntentFlutterApi?>[];
    final lifecycle = AppIntentLifecycleCoordinator(
      setReady: (ready) async {
        if (!ready) {
          falseStarted.complete();
          await releaseFalse.future;
        }
      },
      setHandler: handlerEvents.add,
    );
    final handler = _FakeAppIntentHandler();
    final olderRegistration = lifecycle.register(handler);
    await lifecycle.settled;

    final olderTeardown = lifecycle.unregister(olderRegistration);
    await falseStarted.future;
    lifecycle.register(handler);
    releaseFalse.complete();
    await olderTeardown;
    await lifecycle.settled;

    check(handlerEvents).length.equals(3);
    check(handlerEvents.first).identicalTo(handler);
    check(handlerEvents[1]).not((it) => it.identicalTo(handler));
    check(handlerEvents.last).identicalTo(handler);
  });

  test('failed native unready transition releases the Dart handler', () async {
    final handlerEvents = <AppIntentFlutterApi?>[];
    final lifecycle = AppIntentLifecycleCoordinator(
      setReady: (ready) async {
        if (!ready) throw StateError('native readiness failed');
      },
      setHandler: handlerEvents.add,
      readinessRetryDelays: const [],
    );
    final handler = _FakeAppIntentHandler();
    final registration = lifecycle.register(handler);
    await lifecycle.settled;

    await check(lifecycle.unregister(registration)).throws<StateError>();

    check(handlerEvents).length.equals(2);
    check(handlerEvents.first).identicalTo(handler);
    check(handlerEvents.last).isNotNull();
    check(handlerEvents.last).not((it) => it.identicalTo(handler));
  });

  test(
    'synchronous fallback failure still disables native and detaches handler',
    () async {
      var handlerUpdates = 0;
      final readinessEvents = <bool>[];
      final lifecycle = AppIntentLifecycleCoordinator(
        setReady: (ready) async => readinessEvents.add(ready),
        setHandler: (_) {
          handlerUpdates++;
          if (handlerUpdates == 2) {
            throw StateError('handler teardown failed');
          }
        },
      );
      final registration = lifecycle.register(_FakeAppIntentHandler());
      await lifecycle.settled;

      final teardown = lifecycle.unregister(registration);

      await check(teardown).throws<StateError>();
      check(readinessEvents).deepEquals([true, false]);
      check(handlerUpdates).equals(3);
    },
  );

  test('failed native ready transition releases the Dart handler', () async {
    final handlerEvents = <AppIntentFlutterApi?>[];
    final lifecycle = AppIntentLifecycleCoordinator(
      setReady: (ready) async {
        if (ready) throw StateError('native readiness failed');
      },
      setHandler: handlerEvents.add,
      readinessRetryDelays: const [],
    );
    final handler = _FakeAppIntentHandler();

    lifecycle.register(handler);
    await lifecycle.settled;

    check(handlerEvents).length.equals(2);
    check(handlerEvents.first).identicalTo(handler);
    check(handlerEvents.last).isNotNull();
    check(handlerEvents.last).not((it) => it.identicalTo(handler));
  });

  test(
    'failed replacement setup restores the previous lifecycle owner',
    () async {
      var handlerInstallCount = 0;
      final events = <String>[];
      final lifecycle = AppIntentLifecycleCoordinator(
        setReady: (ready) async => events.add('ready:$ready'),
        setHandler: (handler) {
          handlerInstallCount++;
          events.add(handler == null ? 'handler:null' : 'handler:set');
          if (handlerInstallCount == 2) {
            throw StateError('replacement setup failed');
          }
        },
      );
      final original = lifecycle.register(_FakeAppIntentHandler());
      await lifecycle.settled;

      check(
        () => lifecycle.register(_FakeAppIntentHandler()),
      ).throws<StateError>();
      await lifecycle.unregister(original);

      check(events).deepEquals([
        'handler:set',
        'ready:true',
        'handler:set',
        'handler:set',
        'ready:false',
        'handler:null',
      ]);
    },
  );

  test('failed unavailable setup retains owner for a later teardown', () async {
    var handlerInstallCount = 0;
    final readinessEvents = <bool>[];
    final lifecycle = AppIntentLifecycleCoordinator(
      setReady: (ready) async {
        readinessEvents.add(ready);
        if (ready) throw StateError('native ready failed');
      },
      setHandler: (_) {
        handlerInstallCount++;
        if (handlerInstallCount == 2) {
          throw StateError('fallback setup failed');
        }
      },
      readinessRetryDelays: const [],
    );
    final registration = lifecycle.register(_FakeAppIntentHandler());
    await lifecycle.settled;

    await lifecycle.unregister(registration);

    check(readinessEvents).deepEquals([true, false]);
    check(handlerInstallCount).equals(4);
  });

  test('same invocation shares in-flight work and persists no input', () async {
    String? payload;
    var writes = 0;
    var executions = 0;
    final release = Completer<void>();
    final ledger = AppIntentInvocationLedger(
      readPayload: () => payload,
      writePayload: (next) async {
        writes++;
        payload = next;
      },
    );

    final first = ledger.dispatch('invocation-sensitive-input', () async {
      executions++;
      await release.future;
      return PlatformAppIntentResponse(
        success: true,
        value: 'original response',
        ownedFilePath: '/tmp/original-image',
      );
    });
    final duplicate = ledger.dispatch('invocation-sensitive-input', () async {
      executions++;
      return PlatformAppIntentResponse(success: false);
    });

    check(duplicate).identicalTo(first);
    release.complete();
    final responses = await Future.wait([first, duplicate]);

    check(executions).equals(1);
    check(writes).equals(2);
    check(responses[0].ownedFilePath).equals('/tmp/original-image');
    check(responses[1]).identicalTo(responses[0]);
    check(payload).isNotNull();
    check(payload!).not((it) => it.contains('invocation-sensitive-input'));
    check(payload!).not((it) => it.contains('/tmp/original-image'));
    check(payload!).not((it) => it.contains('original response'));
  });

  test('completed image retry reclaims its fresh staged file', () async {
    String? payload;
    var executions = 0;
    final ledger = AppIntentInvocationLedger(
      readPayload: () => payload,
      writePayload: (next) async => payload = next,
    );
    final original = await _createAppIntentStagingFile('original.png');
    final retry = await _createAppIntentStagingFile('retry.png');

    final first = await dispatchAppIntentInvocation(
      ledger: ledger,
      invocationId: 'completed-image-retry',
      ownedFilePathOnSuccess: original.path,
      execute: () async {
        executions++;
        return PlatformAppIntentResponse(success: true);
      },
    );
    final duplicate = await dispatchAppIntentInvocation(
      ledger: ledger,
      invocationId: 'completed-image-retry',
      ownedFilePathOnSuccess: retry.path,
      execute: () async {
        executions++;
        return PlatformAppIntentResponse(success: true);
      },
    );

    check(first.success).isTrue();
    check(first.ownedFilePath).equals(original.path);
    check(duplicate.success).isTrue();
    check(duplicate.ownedFilePath).isNull();
    check(executions).equals(1);
    check(await original.exists()).isTrue();
    check(await retry.exists()).isFalse();
  });

  test('join-only lookup never claims an unseen invocation', () {
    var reads = 0;
    var writes = 0;
    final ledger = AppIntentInvocationLedger(
      readPayload: () {
        reads++;
        return null;
      },
      writePayload: (_) async => writes++,
    );

    final joined = ledger.joinInFlight('unseen-invocation');

    check(joined).isNull();
    check(reads).equals(0);
    check(writes).equals(0);
  });

  test('join-only lookup shares already-admitted in-flight work', () async {
    String? payload;
    final claimWritten = Completer<void>();
    final release = Completer<void>();
    final ledger = AppIntentInvocationLedger(
      readPayload: () => payload,
      writePayload: (next) async {
        payload = next;
        if (!claimWritten.isCompleted) claimWritten.complete();
      },
    );
    final active = ledger.dispatch('active-invocation', () async {
      await release.future;
      return PlatformAppIntentResponse(
        success: true,
        ownedFilePath: '/tmp/adopted-image',
      );
    });
    await claimWritten.future;

    final joined = ledger.joinInFlight('active-invocation');

    check(joined).identicalTo(active);
    release.complete();
    check((await joined!).ownedFilePath).equals('/tmp/adopted-image');
  });

  test(
    'failed running-claim persistence never executes the side effect',
    () async {
      var executions = 0;
      final ledger = AppIntentInvocationLedger(
        readPayload: () => null,
        writePayload: (_) async => throw StateError('durable write failed'),
      );

      await check(
        ledger.dispatch('claim-write-failure', () async {
          executions++;
          return PlatformAppIntentResponse(success: true);
        }),
      ).throws<StateError>();

      check(executions).equals(0);
    },
  );

  for (final malformedRecord in <String, Object?>{
    'non-map record': 'invalid',
    'invalid state': <String, Object?>{'state': 'unknown', 'updatedAt': 1},
    'invalid timestamp': <String, Object?>{
      'state': 'running',
      'updatedAt': 'yesterday',
    },
    'invalid completion result': <String, Object?>{
      'state': 'completed',
      'success': 'yes',
      'updatedAt': 1,
    },
  }.entries) {
    test('${malformedRecord.key} fails closed before executing', () async {
      var executions = 0;
      final ledger = AppIntentInvocationLedger(
        readPayload: () => jsonEncode(<String, Object?>{
          'persisted-record': malformedRecord.value,
        }),
        writePayload: (_) async {},
      );

      await check(
        ledger.dispatch('new-invocation', () async {
          executions++;
          return PlatformAppIntentResponse(success: true);
        }),
      ).throws<FormatException>();

      check(executions).equals(0);
    });
  }

  test(
    'completed durable invocation is not executed after recreation',
    () async {
      String? payload;
      final firstLedger = AppIntentInvocationLedger(
        readPayload: () => payload,
        writePayload: (next) async => payload = next,
      );
      final first = await firstLedger.dispatch(
        'stable-invocation',
        () async => PlatformAppIntentResponse(
          success: true,
          ownedFilePath: '/tmp/accepted-original',
        ),
      );
      var retriedExecutions = 0;
      final recreatedLedger = AppIntentInvocationLedger(
        readPayload: () => payload,
        writePayload: (next) async => payload = next,
      );

      final retry = await recreatedLedger.dispatch(
        'stable-invocation',
        () async {
          retriedExecutions++;
          return PlatformAppIntentResponse(success: true);
        },
      );

      check(first.success).isTrue();
      check(retriedExecutions).equals(0);
      check(retry.success).isTrue();
      check(retry.ownedFilePath).isNull();
    },
  );

  test(
    'durable running claim reports indeterminate failure after recreation',
    () async {
      String? payload;
      final claimWritten = Completer<void>();
      final releaseOriginal = Completer<void>();
      final firstLedger = AppIntentInvocationLedger(
        readPayload: () => payload,
        writePayload: (next) async {
          payload = next;
          if (!claimWritten.isCompleted) claimWritten.complete();
        },
      );
      final original = firstLedger.dispatch(
        'indeterminate-invocation',
        () async {
          await releaseOriginal.future;
          return PlatformAppIntentResponse(success: true);
        },
      );
      await claimWritten.future;
      var retryExecutions = 0;
      final recreatedLedger = AppIntentInvocationLedger(
        readPayload: () => payload,
        writePayload: (next) async => payload = next,
      );

      final retry = await recreatedLedger.dispatch(
        'indeterminate-invocation',
        () async {
          retryExecutions++;
          return PlatformAppIntentResponse(success: true);
        },
      );

      check(retryExecutions).equals(0);
      check(retry.success).isFalse();
      check(
        retry.error,
      ).equals('The earlier request may not have completed. Please retry.');
      check(retry.ownedFilePath).isNull();
      releaseOriginal.complete();
      await original;
    },
  );

  test('capacity evicts completed records before a running claim', () async {
    String? payload;
    final activeStarted = Completer<void>();
    final releaseActive = Completer<void>();
    final ledger = AppIntentInvocationLedger(
      readPayload: () => payload,
      writePayload: (next) async => payload = next,
      maxRecords: 2,
    );
    final active = ledger.dispatch('active-invocation', () async {
      activeStarted.complete();
      await releaseActive.future;
      return PlatformAppIntentResponse(success: true);
    });
    await activeStarted.future;
    await ledger.dispatch(
      'completed-invocation',
      () async => PlatformAppIntentResponse(success: true),
    );

    var newestExecutions = 0;
    final newest = await ledger.dispatch('newest-invocation', () async {
      newestExecutions++;
      return PlatformAppIntentResponse(success: true);
    });
    check(newest.success).isTrue();
    check(newestExecutions).equals(1);

    var activeRetryExecutions = 0;
    final recreated = AppIntentInvocationLedger(
      readPayload: () => payload,
      writePayload: (next) async => payload = next,
      maxRecords: 2,
    );
    final activeRetry = await recreated.dispatch('active-invocation', () async {
      activeRetryExecutions++;
      return PlatformAppIntentResponse(success: true);
    });
    check(activeRetry.success).isFalse();
    check(
      activeRetry.error,
    ).equals('The earlier request may not have completed. Please retry.');
    check(activeRetryExecutions).equals(0);

    releaseActive.complete();
    await active;
  });

  test('all-running capacity rejects a new side effect fail closed', () async {
    String? payload;
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final release = Completer<void>();
    final ledger = AppIntentInvocationLedger(
      readPayload: () => payload,
      writePayload: (next) async => payload = next,
      maxRecords: 2,
    );
    final first = ledger.dispatch('running-one', () async {
      firstStarted.complete();
      await release.future;
      return PlatformAppIntentResponse(success: true);
    });
    final second = ledger.dispatch('running-two', () async {
      secondStarted.complete();
      await release.future;
      return PlatformAppIntentResponse(success: true);
    });
    await Future.wait([firstStarted.future, secondStarted.future]);

    var rejectedExecutions = 0;
    final rejected = await ledger.dispatch('over-capacity', () async {
      rejectedExecutions++;
      return PlatformAppIntentResponse(success: true);
    });
    check(rejected.success).isFalse();
    check(rejectedExecutions).equals(0);

    final recreated = AppIntentInvocationLedger(
      readPayload: () => payload,
      writePayload: (next) async => payload = next,
      maxRecords: 2,
    );
    var retryExecutions = 0;
    final retained = await recreated.dispatch('running-one', () async {
      retryExecutions++;
      return PlatformAppIntentResponse(success: true);
    });
    check(retained.success).isFalse();
    check(
      retained.error,
    ).equals('The earlier request may not have completed. Please retry.');
    check(retryExecutions).equals(0);

    release.complete();
    await Future.wait([first, second]);
  });

  test('expired running tombstone releases admission capacity', () async {
    final now = DateTime.utc(2026, 7, 18, 12);
    var payload = jsonEncode(<String, Object?>{
      'orphaned-running-claim': <String, Object?>{
        'state': 'running',
        'updatedAt': now
            .subtract(const Duration(hours: 2))
            .millisecondsSinceEpoch,
      },
    });
    var executions = 0;
    final ledger = AppIntentInvocationLedger(
      readPayload: () => payload,
      writePayload: (next) async => payload = next,
      now: () => now,
      runningClaimQuarantine: const Duration(hours: 1),
      maxRecords: 1,
    );

    final response = await ledger.dispatch('new-invocation', () async {
      executions++;
      return PlatformAppIntentResponse(success: true);
    });

    check(response.success).isTrue();
    check(executions).equals(1);
    check(payload).not((it) => it.contains('orphaned-running-claim'));
  });

  test('untransferred App Intent staging is deleted', () async {
    final file = await _createAppIntentStagingFile('untransferred.png');

    await AppIntentStagedFileOwnership(file.path).cleanupIfUntransferred();

    check(await file.exists()).isFalse();
  });

  test('untransferred file outside App Intent staging is preserved', () async {
    final directory = await Directory.systemTemp.createTemp(
      'conduit-app-intent-unowned-',
    );
    final file = File(p.join(directory.path, 'outside.png'));
    await file.writeAsBytes([1, 2, 3]);
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    await AppIntentStagedFileOwnership(file.path).cleanupIfUntransferred();

    check(await file.exists()).isTrue();
  });

  test('media upload ownership preserves App Intent staging', () async {
    final file = await _createAppIntentStagingFile('transferred.png');
    final ownership = AppIntentStagedFileOwnership(file.path)
      ..transferToMediaUploadController();

    await ownership.cleanupIfUntransferred();

    // Durable upload ownership, not age, determines whether the file lives.
    check(await file.exists()).isTrue();
  });
}

Future<File> _createAppIntentStagingFile(String suffix) async {
  final directory = Directory(
    p.join(Directory.systemTemp.path, 'conduit-app-intents'),
  );
  await directory.create();
  // Tests share the process-wide staging root required by production path
  // admission, so isolate each case with a fresh UUID-owned filename.
  final file = File(p.join(directory.path, '${const Uuid().v4()}-$suffix'));
  await file.writeAsBytes([1, 2, 3]);
  await file.setLastModified(DateTime.now().subtract(const Duration(days: 30)));
  addTearDown(() async {
    if (await file.exists()) await file.delete();
  });
  return file;
}

final class _FakeAppIntentHandler implements AppIntentFlutterApi {
  static PlatformAppIntentResponse get _response =>
      PlatformAppIntentResponse(success: true);

  @override
  Future<PlatformAppIntentResponse> askChat(
    String invocationId,
    String? prompt,
  ) async => _response;

  @override
  Future<PlatformAppIntentResponse> sendImage(
    String invocationId,
    PlatformAppIntentImagePayload payload,
  ) async => _response;

  @override
  Future<PlatformAppIntentResponse> sendText(
    String invocationId,
    String text,
  ) async => _response;

  @override
  Future<PlatformAppIntentResponse> sendUrl(
    String invocationId,
    String url,
  ) async => _response;

  @override
  Future<PlatformAppIntentResponse> startVoiceCall(String invocationId) async =>
      _response;
}
