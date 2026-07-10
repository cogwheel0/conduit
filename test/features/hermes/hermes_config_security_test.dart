import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/storage_providers.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:dio/dio.dart';
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

  test(
    'changing origin stops owner-bound runs before rotating credentials',
    () async {
      const storage = FlutterSecureStorage();
      final container = ProviderContainer(
        overrides: [secureStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);

      container.read(hermesConfigProvider);
      for (
        var i = 0;
        i < 20 && container.read(hermesSecretsLoadingProvider);
        i++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      check(container.read(hermesSecretsLoadingProvider)).isFalse();
      check(container.read(hermesConfigProvider).apiKey).equals('key-for-one');
      container.read(hermesActiveSessionProvider.notifier).set('session-one');

      final stopStarted = Completer<void>();
      final stopGate = Completer<void>();
      final registry = container.read(hermesRunRegistryProvider);
      final runToken = registry.registerPending(
        'message-one',
        cancelToken: CancelToken(),
        onCancelled: () {},
      );
      registry.attachRun(
        'message-one',
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
      final container = ProviderContainer(
        overrides: [secureStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);

      container.read(hermesConfigProvider);
      for (
        var i = 0;
        i < 20 && container.read(hermesSecretsLoadingProvider);
        i++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      check(container.read(hermesSecretsLoadingProvider)).isFalse();

      container.read(hermesActiveSessionProvider.notifier).set('session-one');
      final stoppedRuns = <String>[];
      final registry = container.read(hermesRunRegistryProvider);
      final runToken = registry.registerPending(
        'message-one',
        cancelToken: CancelToken(),
        onCancelled: () {},
      );
      registry.attachRun(
        'message-one',
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
    final container = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);

    container.read(hermesConfigProvider);
    while (container.read(hermesSecretsLoadingProvider)) {
      await Future<void>.delayed(Duration.zero);
    }
    container.read(hermesActiveSessionProvider.notifier).set('session-one');

    await container
        .read(hermesConfigProvider.notifier)
        .saveConnection(baseUrl: 'https://one.example/');

    check(container.read(hermesActiveSessionProvider)).equals('session-one');
    check(container.read(hermesConfigProvider).apiKey).equals('key-for-one');
  });

  test('same-endpoint secret change stops runs and unbinds session', () async {
    const storage = FlutterSecureStorage();
    final container = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);

    container.read(hermesConfigProvider);
    while (container.read(hermesSecretsLoadingProvider)) {
      await Future<void>.delayed(Duration.zero);
    }
    container.read(hermesActiveSessionProvider.notifier).set('session-one');
    final stoppedRuns = <String>[];
    final registry = container.read(hermesRunRegistryProvider);
    final runToken = registry.registerPending(
      'message-one',
      onCancelled: () {},
    );
    registry.attachRun(
      'message-one',
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
    final container = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);

    container.read(hermesConfigProvider);
    while (container.read(hermesSecretsLoadingProvider)) {
      await Future<void>.delayed(Duration.zero);
    }
    final settlement = Completer<void>();
    final token = container
        .read(hermesRunRegistryProvider)
        .registerPending(
          'message-one',
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
        'message-one',
        onCancelled: () => cancelled = true,
      );
      registry.attachRun(
        'message-one',
        cancelToken: token,
        runId: 'run-one',
        subscription: controller.stream.listen((_) {}),
        stopRemote: (runId) {
          check(runId).equals('run-one');
          return stopGate.future;
        },
      );

      final stop = registry.cancel('message-one');
      check(stop).isNotNull();
      check(token.isCancelled).isTrue();
      check(cancelled).isTrue();
      await Future<void>.delayed(Duration.zero);
      check(subscriptionCancelled).isTrue();
      check(registry.runIdFor('message-one')).isNull();

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
        'message-one',
        cancellationSettled: originalSettlement.future,
        onCancelled: () {},
      );
      registry.registerPending(
        'message-one',
        cancelToken: token,
        cancellationSettled: replacementSettlement.future,
        onCancelled: () {},
      );

      final stop = registry.cancel('message-one');
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
      'message-one',
      onCancelled: () {},
    );
    final newToken = registry.registerPending(
      'message-one',
      onCancelled: () {},
    );
    check(oldToken.isCancelled).isTrue();

    final staleAttached = registry.attachRun(
      'message-one',
      cancelToken: oldToken,
      runId: 'stale-run',
      subscription: const Stream<void>.empty().listen((_) {}),
      stopRemote: (_) async {},
    );
    check(staleAttached).isFalse();

    final currentAttached = registry.attachRun(
      'message-one',
      cancelToken: newToken,
      runId: 'current-run',
      subscription: const Stream<void>.empty().listen((_) {}),
      stopRemote: (_) async {},
    );
    check(currentAttached).isTrue();
    check(registry.complete('message-one', cancelToken: oldToken)).isFalse();
    check(registry.runIdFor('message-one')).equals('current-run');
    check(registry.complete('message-one', cancelToken: newToken)).isTrue();
    check(registry.runIdFor('message-one')).isNull();
  });
}
