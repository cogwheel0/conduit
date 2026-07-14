import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/storage_providers.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.hermesEnabled: true,
      PreferenceKeys.hermesBaseUrl: 'https://one.example/v1',
    });
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    FlutterSecureStorage.setMockInitialValues({
      'hermes_api_key_v1': 'key-for-one',
      'hermes_session_key_v1': 'memory-for-one',
    });
  });

  tearDown(PreferencesStore.debugReset);

  test('connection URLs reject query strings and fragments', () async {
    check(
      HermesConfigController.connectionOrigin(
        'https://one.example/v1?api_key=secret',
      ),
    ).isNull();
    check(
      HermesConfigController.connectionOrigin(
        'https://one.example/v1#credentials',
      ),
    ).isNull();

    final container = ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(hermesConfigProvider.notifier);

    await expectLater(
      controller.saveConnection(
        baseUrl: 'https://one.example/v1?api_key=secret',
      ),
      throwsArgumentError,
    );
    await expectLater(
      controller.saveConnection(baseUrl: 'https://one.example/v1#credentials'),
      throwsArgumentError,
    );

    check(
      container.read(hermesConfigProvider).baseUrl,
    ).equals('https://one.example/v1');
  });

  test(
    'changing origin stops owner-bound runs before rotating credentials',
    () async {
      const storage = FlutterSecureStorage();
      final container = await _readyHermesContainer(storage);
      addTearDown(container.dispose);

      check(container.read(hermesConfigProvider).apiKey).equals('key-for-one');
      container.read(hermesActiveSessionProvider.notifier).set('session-one');

      final stopStarted = Completer<void>();
      final stopGate = Completer<void>();
      final registry = container.read(hermesRunRegistryProvider);
      final runToken = registry.registerPending(
        legacyHermesRunKey('message-one'),
        cancelToken: CancelToken(),
        onCancelled: () {},
      );
      registry.attachRun(
        legacyHermesRunKey('message-one'),
        cancelToken: runToken,
        runId: 'run-one',
        subscription: const Stream<void>.empty().listen((_) {}),
        stopRemote: (runId) {
          check(runId).equals('run-one');
          check(
            container.read(hermesConfigProvider).baseUrl,
          ).equals('https://one.example/v1');
          stopStarted.complete();
          return stopGate.future;
        },
      );

      final save = container
          .read(hermesConfigProvider.notifier)
          .saveConnection(baseUrl: 'https://two.example/v1');
      await stopStarted.future;

      // The old client config remains alive until its owner-bound stop settles.
      check(
        container.read(hermesConfigProvider).baseUrl,
      ).equals('https://one.example/v1');
      check(container.read(hermesActiveSessionProvider)).equals('session-one');
      stopGate.complete();
      await save;

      final config = container.read(hermesConfigProvider);
      check(config.baseUrl).equals('https://two.example/v1');
      check(config.apiKey).isNull();
      check(config.sessionKey).isNull();
      check(container.read(hermesActiveSessionProvider)).isNull();
      check(await storage.read(key: 'hermes_api_key_v1')).isNull();
      check(await storage.read(key: 'hermes_session_key_v1')).isNull();
    },
  );

  test(
    'same-origin endpoint change stops runs but retains credentials',
    () async {
      const storage = FlutterSecureStorage();
      final container = await _readyHermesContainer(storage);
      addTearDown(container.dispose);

      container.read(hermesActiveSessionProvider.notifier).set('session-one');
      final stoppedRuns = <String>[];
      final registry = container.read(hermesRunRegistryProvider);
      final runToken = registry.registerPending(
        legacyHermesRunKey('message-one'),
        cancelToken: CancelToken(),
        onCancelled: () {},
      );
      registry.attachRun(
        legacyHermesRunKey('message-one'),
        cancelToken: runToken,
        runId: 'run-one',
        subscription: const Stream<void>.empty().listen((_) {}),
        stopRemote: (runId) async => stoppedRuns.add(runId),
      );

      await container
          .read(hermesConfigProvider.notifier)
          .saveConnection(baseUrl: 'https://one.example/custom/v1');

      check(container.read(hermesConfigProvider).apiKey).equals('key-for-one');
      check(await storage.read(key: 'hermes_api_key_v1')).equals('key-for-one');
      check(container.read(hermesActiveSessionProvider)).isNull();
      check(stoppedRuns).deepEquals(['run-one']);
    },
  );

  test('equivalent root and v1 endpoint do not reset the session', () async {
    const storage = FlutterSecureStorage();
    final container = await _readyHermesContainer(storage);
    addTearDown(container.dispose);

    container.read(hermesActiveSessionProvider.notifier).set('session-one');

    await container
        .read(hermesConfigProvider.notifier)
        .saveConnection(baseUrl: 'https://one.example/');

    check(container.read(hermesActiveSessionProvider)).equals('session-one');
    check(container.read(hermesConfigProvider).apiKey).equals('key-for-one');
  });

  test('same-endpoint secret change stops runs and unbinds session', () async {
    const storage = FlutterSecureStorage();
    final container = await _readyHermesContainer(storage);
    addTearDown(container.dispose);

    container.read(hermesActiveSessionProvider.notifier).set('session-one');
    final stoppedRuns = <String>[];
    final registry = container.read(hermesRunRegistryProvider);
    final runToken = registry.registerPending(
      legacyHermesRunKey('message-one'),
      onCancelled: () {},
    );
    registry.attachRun(
      legacyHermesRunKey('message-one'),
      cancelToken: runToken,
      runId: 'run-one',
      subscription: const Stream<void>.empty().listen((_) {}),
      stopRemote: (runId) async => stoppedRuns.add(runId),
    );

    await container
        .read(hermesConfigProvider.notifier)
        .saveConnection(
          baseUrl: 'https://one.example/v1',
          apiKeyChanged: true,
          apiKey: 'key-for-one-replacement',
          sessionKeyChanged: true,
          sessionKey: 'memory-for-one-replacement',
        );

    final config = container.read(hermesConfigProvider);
    check(stoppedRuns).deepEquals(['run-one']);
    check(container.read(hermesActiveSessionProvider)).isNull();
    check(config.apiKey).equals('key-for-one-replacement');
    check(config.sessionKey).equals('memory-for-one-replacement');
  });

  test('endpoint rotation waits for an in-flight create to settle', () async {
    const storage = FlutterSecureStorage();
    final container = await _readyHermesContainer(storage);
    addTearDown(container.dispose);

    final settlement = Completer<void>();
    final token = container
        .read(hermesRunRegistryProvider)
        .registerPending(
          legacyHermesRunKey('message-one'),
          cancellationSettled: settlement.future,
          onCancelled: () {},
        );

    final save = container
        .read(hermesConfigProvider.notifier)
        .saveConnection(baseUrl: 'https://two.example/v1');
    while (!token.isCancelled) {
      await Future<void>.delayed(Duration.zero);
    }

    check(
      container.read(hermesConfigProvider).baseUrl,
    ).equals('https://one.example/v1');
    settlement.complete();
    await save;
    check(
      container.read(hermesConfigProvider).baseUrl,
    ).equals('https://two.example/v1');
  });

  test('disable interrupts hydrating and late session-key requests', () async {
    final storage = _GatedSecureStorage({
      'hermes_api_key_v1': 'key-for-one',
    }, gatedReadKey: 'hermes_api_key_v1');
    addTearDown(storage.releaseAll);
    final container = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    final controller = container.read(hermesConfigProvider.notifier);
    await storage.readStarted.future.timeout(const Duration(seconds: 1));

    final registry = container.read(hermesRunRegistryProvider);
    late CancelToken hydratingToken;
    Object? hydratingError;
    bool? hydratingTokenWasCancelled;
    final hydratingSettlement = () async {
      try {
        await controller.ensureSessionKey();
      } catch (error) {
        hydratingError = error;
        hydratingTokenWasCancelled = hydratingToken.isCancelled;
      }
    }();
    hydratingToken = registry.registerPending(
      legacyHermesRunKey('hydrating-session-key'),
      cancellationSettled: hydratingSettlement,
      onCancelled: () {},
    );

    // Keep one additional cancellation unsettled so the controller remains
    // inside _stopActiveRuns after interrupting the hydrating request. A new
    // ensure call in that window must fail immediately instead of queueing a
    // second mutation behind the disable operation.
    final lateSettlement = Completer<void>();
    final lateToken = registry.registerPending(
      legacyHermesRunKey('late-session-key'),
      cancellationSettled: lateSettlement.future,
      onCancelled: () {},
    );

    final disable = controller.setEnabled(false);
    await _waitUntil(() => hydratingToken.isCancelled && lateToken.isCancelled);
    await hydratingSettlement.timeout(const Duration(seconds: 1));

    Object? lateError;
    bool? lateTokenWasCancelled;
    try {
      await controller.ensureSessionKey();
    } catch (error) {
      lateError = error;
      lateTokenWasCancelled = lateToken.isCancelled;
    } finally {
      lateSettlement.complete();
    }

    await disable.timeout(const Duration(seconds: 1));

    check(hydratingError).isA<StateError>();
    check(hydratingTokenWasCancelled).equals(true);
    check(lateError).isA<StateError>();
    check(lateTokenWasCancelled).equals(true);
    check(container.read(hermesConfigProvider).enabled).isFalse();
    check(storage.writeCount('hermes_session_key_v1')).equals(0);

    // Let cold-start hydration finish, then prove the interrupted request did
    // not poison the controller's single-flight slot for a later retry.
    storage.releaseRead();
    await _waitForHermesSecrets(container);
    await controller.setEnabled(true);
    final retry = await controller.ensureSessionKey().timeout(
      const Duration(seconds: 1),
    );
    check(retry).isNotEmpty();
    check(storage.values['hermes_session_key_v1']).equals(retry);
    check(storage.writeCount('hermes_session_key_v1')).equals(1);
  });

  test('disable interrupts a session-key request without active runs', () async {
    final storage = _GatedSecureStorage({
      'hermes_api_key_v1': 'key-for-one',
    }, gatedReadKey: 'hermes_api_key_v1');
    addTearDown(storage.releaseAll);
    final container = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    final controller = container.read(hermesConfigProvider.notifier);
    await storage.readStarted.future.timeout(const Duration(seconds: 1));

    // This setup/settings request has no HermesRunRegistry entry. A
    // configuration stop must still revoke it instead of leaving it blocked on
    // cold-start hydration and later generating a key for stale state.
    final sessionKey = controller.ensureSessionKey();
    final disable = controller.setEnabled(false);

    await expectLater(
      sessionKey.timeout(const Duration(seconds: 1)),
      throwsA(isA<StateError>()),
    );
    await disable.timeout(const Duration(seconds: 1));
    check(container.read(hermesConfigProvider).enabled).isFalse();
    check(storage.writeCount('hermes_session_key_v1')).equals(0);

    storage.releaseRead();
    await _waitForHermesSecrets(container);
    await Future<void>.delayed(Duration.zero);
    check(container.read(hermesConfigProvider).sessionKey).isNull();
    check(storage.writeCount('hermes_session_key_v1')).equals(0);
  });

  test('connection rotation interrupts queued session-key generation', () async {
    final storage = _GatedSecureStorage({
      'hermes_api_key_v1': 'key-for-one',
    }, gatedWriteKey: 'hermes_api_key_v1');
    addTearDown(storage.releaseAll);
    final container = await _readyHermesContainer(storage);
    addTearDown(container.dispose);
    final controller = container.read(hermesConfigProvider.notifier);
    check(container.read(hermesConfigProvider).sessionKey).isNull();

    final cancellationSettlement = Completer<void>();
    final token = container
        .read(hermesRunRegistryProvider)
        .registerPending(
          legacyHermesRunKey('queued-session-key'),
          cancellationSettled: cancellationSettlement.future,
          onCancelled: () {},
        );

    // Hold saveConnection inside its serialized secure-storage write, then
    // request a generated key. The unfixed implementation queues generation
    // behind saveConnection while saveConnection waits for this run to settle.
    final save = controller.saveConnection(
      baseUrl: 'https://one.example/v1',
      apiKeyChanged: true,
      apiKey: 'key-for-one-replacement',
    );
    await storage.writeStarted.future.timeout(const Duration(seconds: 1));

    Object? ensureError;
    bool? tokenWasCancelled;
    final ensureSettlement = () async {
      try {
        await controller.ensureSessionKey();
      } catch (error) {
        ensureError = error;
        tokenWasCancelled = token.isCancelled;
      } finally {
        cancellationSettlement.complete();
      }
    }();

    storage.releaseWrite();
    await save.timeout(const Duration(seconds: 1));
    await ensureSettlement.timeout(const Duration(seconds: 1));

    check(ensureError).isA<StateError>();
    check(tokenWasCancelled).equals(true);
    check(token.isCancelled).isTrue();
    check(
      container.read(hermesConfigProvider).apiKey,
    ).equals('key-for-one-replacement');
    check(container.read(hermesConfigProvider).sessionKey).isNull();
    check(storage.values['hermes_session_key_v1']).isNull();
    check(storage.writeCount('hermes_session_key_v1')).equals(0);

    final retry = await controller.ensureSessionKey().timeout(
      const Duration(seconds: 1),
    );
    check(retry).isNotEmpty();
    check(storage.values['hermes_session_key_v1']).equals(retry);
    check(storage.writeCount('hermes_session_key_v1')).equals(1);
  });

  test(
    'failed mutation does not prevent the next mutation from running',
    () async {
      final storage = _FailOnceSecureStorage({
        'hermes_api_key_v1': 'key-for-one',
        'hermes_session_key_v1': 'memory-for-one',
      });
      final container = await _readyHermesContainer(storage);
      addTearDown(container.dispose);

      storage.failNextWriteFor = 'hermes_api_key_v1';
      final controller = container.read(hermesConfigProvider.notifier);

      await expectLater(
        controller.setApiKey('first-replacement'),
        throwsA(isA<StateError>()),
      );
      await controller
          .setApiKey('second-replacement')
          .timeout(const Duration(seconds: 1));

      check(
        container.read(hermesConfigProvider).apiKey,
      ).equals('second-replacement');
      check(storage.values['hermes_api_key_v1']).equals('second-replacement');
    },
  );

  test(
    'failed server-switch replacement restores old origin credentials',
    () async {
      final storage = _FailOnceSecureStorage({
        'hermes_api_key_v1': 'key-for-one',
        'hermes_session_key_v1': 'memory-for-one',
      });
      final container = await _readyHermesContainer(storage);
      addTearDown(container.dispose);

      final activeToken = container
          .read(hermesRunRegistryProvider)
          .registerPending(
            legacyHermesRunKey('active-run'),
            onCancelled: () {},
          );
      // Fail the second secure write after the replacement API key has landed,
      // exercising rollback of a genuinely partial server switch.
      storage.failNextWriteFor = 'hermes_session_key_v1';

      await expectLater(
        container
            .read(hermesConfigProvider.notifier)
            .saveConnection(
              baseUrl: 'https://two.example/v1',
              apiKeyChanged: true,
              apiKey: 'key-for-two',
              sessionKeyChanged: true,
              sessionKey: 'memory-for-two',
            ),
        throwsA(isA<StateError>()),
      );

      final config = container.read(hermesConfigProvider);
      check(config.baseUrl).equals('https://one.example/v1');
      check(config.apiKey).equals('key-for-one');
      check(config.sessionKey).equals('memory-for-one');
      check(storage.values['hermes_api_key_v1']).equals('key-for-one');
      check(storage.values['hermes_session_key_v1']).equals('memory-for-one');
      check(
        PreferencesStore.getString(PreferenceKeys.hermesBaseUrl),
      ).equals('https://one.example/v1');
      check(activeToken.isCancelled).isFalse();
    },
  );

  test('secret read failure is exposed and can be retried', () async {
    final storage = _FailOnceSecureStorage({
      'hermes_api_key_v1': 'key-for-one',
      'hermes_session_key_v1': 'memory-for-one',
    })..failReads = true;
    final container = await _readyHermesContainer(storage);
    addTearDown(container.dispose);

    check(container.read(hermesSecretsErrorProvider)).isNotNull();
    check(container.read(hermesConfigProvider).apiKey).isNull();
    await expectLater(
      container
          .read(hermesConfigProvider.notifier)
          .saveConnection(baseUrl: 'https://one.example/v1'),
      throwsStateError,
    );
    await expectLater(
      container.read(hermesConfigProvider.notifier).ensureSessionKey(),
      throwsStateError,
    );

    storage.failReads = false;
    await container.read(hermesConfigProvider.notifier).retrySecrets();

    check(container.read(hermesSecretsErrorProvider)).isNull();
    check(container.read(hermesConfigProvider).apiKey).equals('key-for-one');
    check(
      container.read(hermesConfigProvider).sessionKey,
    ).equals('memory-for-one');
  });

  test(
    'registry cancellation invokes the stop operation owned by the run',
    () async {
      final registry = HermesRunRegistry();
      final stopGate = Completer<void>();
      var cancelled = false;
      var subscriptionCancelled = false;
      final controller = StreamController<void>(
        onCancel: () => subscriptionCancelled = true,
      );
      addTearDown(controller.close);

      final token = registry.registerPending(
        legacyHermesRunKey('message-one'),
        onCancelled: () => cancelled = true,
      );
      registry.attachRun(
        legacyHermesRunKey('message-one'),
        cancelToken: token,
        runId: 'run-one',
        subscription: controller.stream.listen((_) {}),
        stopRemote: (runId) {
          check(runId).equals('run-one');
          return stopGate.future;
        },
      );

      final stop = registry.cancel(legacyHermesRunKey('message-one'));
      check(stop).isNotNull();
      check(token.isCancelled).isTrue();
      check(cancelled).isTrue();
      await Future<void>.delayed(Duration.zero);
      check(subscriptionCancelled).isTrue();
      check(registry.runIdFor(legacyHermesRunKey('message-one'))).isNull();

      stopGate.complete();
      await stop!;
    },
  );

  test(
    'pending cancellation waits for the original same-token settlement',
    () async {
      final registry = HermesRunRegistry();
      final originalSettlement = Completer<void>();
      final replacementSettlement = Completer<void>();
      var stopCompleted = false;

      final token = registry.registerPending(
        legacyHermesRunKey('message-one'),
        cancellationSettled: originalSettlement.future,
        onCancelled: () {},
      );
      registry.registerPending(
        legacyHermesRunKey('message-one'),
        cancelToken: token,
        cancellationSettled: replacementSettlement.future,
        onCancelled: () {},
      );

      final stop = registry.cancel(legacyHermesRunKey('message-one'));
      check(stop).isNotNull();
      unawaited(stop!.then((_) => stopCompleted = true));
      replacementSettlement.complete();
      await Future<void>.delayed(Duration.zero);
      check(stopCompleted).isFalse();

      originalSettlement.complete();
      await stop;
      check(stopCompleted).isTrue();
    },
  );

  test('stale token cannot attach to or complete a replacement run', () {
    final registry = HermesRunRegistry();
    final oldToken = registry.registerPending(
      legacyHermesRunKey('message-one'),
      onCancelled: () {},
    );
    final newToken = registry.registerPending(
      legacyHermesRunKey('message-one'),
      onCancelled: () {},
    );
    check(oldToken.isCancelled).isTrue();

    final staleAttached = registry.attachRun(
      legacyHermesRunKey('message-one'),
      cancelToken: oldToken,
      runId: 'stale-run',
      subscription: const Stream<void>.empty().listen((_) {}),
      stopRemote: (_) async {},
    );
    check(staleAttached).isFalse();

    final currentAttached = registry.attachRun(
      legacyHermesRunKey('message-one'),
      cancelToken: newToken,
      runId: 'current-run',
      subscription: const Stream<void>.empty().listen((_) {}),
      stopRemote: (_) async {},
    );
    check(currentAttached).isTrue();
    check(
      registry.complete(
        legacyHermesRunKey('message-one'),
        cancelToken: oldToken,
      ),
    ).isFalse();
    check(
      registry.runIdFor(legacyHermesRunKey('message-one')),
    ).equals('current-run');
    check(
      registry.complete(
        legacyHermesRunKey('message-one'),
        cancelToken: newToken,
      ),
    ).isTrue();
    check(registry.runIdFor(legacyHermesRunKey('message-one'))).isNull();
  });

  test(
    'detached registry cleanup observes failures without leaking provider data',
    () async {
      const errorSecret = 'provider-cleanup-error-secret';
      const stackSecret = 'provider-cleanup-stack-secret';
      final capturedLogs = <String>[];
      final uncaughtErrors = <Object>[];
      final previousDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) capturedLogs.add(message);
      };

      try {
        await runZonedGuarded(() async {
          final registry = HermesRunRegistry();
          final displacedSettlement = Completer<void>();
          registry.registerPending(
            legacyHermesRunKey('register-displaced'),
            cancellationSettled: displacedSettlement.future,
            onCancelled: () {},
          );
          registry.registerPending(
            legacyHermesRunKey('register-displaced'),
            onCancelled: () {},
          );
          displacedSettlement.completeError(
            StateError(errorSecret),
            StackTrace.fromString(stackSecret),
          );

          final rebindSettlement = Completer<void>();
          final fromKey = legacyHermesRunKey('rebind-from');
          final toKey = legacyHermesRunKey('rebind-to');
          final movingToken = registry.registerPending(
            fromKey,
            onCancelled: () {},
          );
          registry.registerPending(
            toKey,
            cancellationSettled: rebindSettlement.future,
            onCancelled: () {},
          );
          check(
            registry.rebind(fromKey, toKey, cancelToken: movingToken),
          ).isTrue();
          rebindSettlement.completeError(
            StateError(errorSecret),
            StackTrace.fromString(stackSecret),
          );

          Future<void> rejectCancellation() => Future<void>.error(
            StateError(errorSecret),
            StackTrace.fromString(stackSecret),
          );

          final staleRunController = StreamController<void>(
            onCancel: rejectCancellation,
          );
          final staleStreamController = StreamController<void>(
            onCancel: rejectCancellation,
          );
          addTearDown(staleRunController.close);
          addTearDown(staleStreamController.close);
          final staleToken = CancelToken();
          check(
            registry.attachRun(
              legacyHermesRunKey('missing-run'),
              cancelToken: staleToken,
              runId: 'provider-run-id',
              subscription: staleRunController.stream.listen((_) {}),
              stopRemote: (_) async {},
            ),
          ).isFalse();
          check(
            registry.attachStream(
              legacyHermesRunKey('missing-stream'),
              cancelToken: staleToken,
              subscription: staleStreamController.stream.listen((_) {}),
            ),
          ).isFalse();

          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);
          for (final cancellation in registry.cancelAll()) {
            await cancellation.catchError((_) {});
          }
        }, (error, stackTrace) => uncaughtErrors.add(error));
      } finally {
        debugPrint = previousDebugPrint;
      }

      check(uncaughtErrors).isEmpty();
      final logs = capturedLogs.join('\n');
      check(logs).contains('displaced-run-cleanup-failed');
      check(logs).contains('rebind-displaced-run-cleanup-failed');
      check(logs).contains('stale-run-subscription-cleanup-failed');
      check(logs).contains('stale-stream-subscription-cleanup-failed');
      check(logs).not((subject) => subject.contains(errorSecret));
      check(logs).not((subject) => subject.contains(stackSecret));
    },
  );
}

Future<ProviderContainer> _readyHermesContainer(
  FlutterSecureStorage storage,
) async {
  final container = ProviderContainer(
    overrides: [secureStorageProvider.overrideWithValue(storage)],
  );
  container.read(hermesConfigProvider);
  try {
    await _waitForHermesSecrets(container);
    return container;
  } catch (_) {
    container.dispose();
    rethrow;
  }
}

Future<void> _waitForHermesSecrets(ProviderContainer container) async {
  for (
    var i = 0;
    i < 100 && container.read(hermesSecretsLoadingProvider);
    i++
  ) {
    await Future<void>.delayed(Duration.zero);
  }
  if (container.read(hermesSecretsLoadingProvider)) {
    throw StateError('Hermes secrets did not finish loading');
  }
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var i = 0; i < 100 && !predicate(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  if (!predicate()) {
    throw StateError('Condition did not become true');
  }
}

class _GatedSecureStorage implements FlutterSecureStorage {
  _GatedSecureStorage(
    Map<String, String> initialValues, {
    this.gatedReadKey,
    this.gatedWriteKey,
  }) : values = Map<String, String>.from(initialValues);

  final Map<String, String> values;
  final String? gatedReadKey;
  final String? gatedWriteKey;
  final Completer<void> readStarted = Completer<void>();
  final Completer<void> writeStarted = Completer<void>();
  final Completer<void> _readRelease = Completer<void>();
  final Completer<void> _writeRelease = Completer<void>();
  final Map<String, int> _writeCounts = <String, int>{};

  int writeCount(String key) => _writeCounts[key] ?? 0;

  void releaseRead() {
    if (!_readRelease.isCompleted) _readRelease.complete();
  }

  void releaseWrite() {
    if (!_writeRelease.isCompleted) _writeRelease.complete();
  }

  void releaseAll() {
    releaseRead();
    releaseWrite();
  }

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
    if (key == gatedReadKey) {
      if (!readStarted.isCompleted) readStarted.complete();
      await _readRelease.future;
    }
    return values[key];
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
  }) async {
    if (key == gatedWriteKey) {
      if (!writeStarted.isCompleted) writeStarted.complete();
      await _writeRelease.future;
    }
    _writeCounts[key] = (_writeCounts[key] ?? 0) + 1;
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailOnceSecureStorage implements FlutterSecureStorage {
  _FailOnceSecureStorage(Map<String, String> initialValues)
    : values = Map<String, String>.from(initialValues);

  final Map<String, String> values;
  String? failNextWriteFor;
  bool failReads = false;

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
    if (failReads) throw StateError('secure storage unavailable');
    return values[key];
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
  }) async {
    if (failNextWriteFor == key) {
      failNextWriteFor = null;
      throw StateError('write failed for $key');
    }
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
