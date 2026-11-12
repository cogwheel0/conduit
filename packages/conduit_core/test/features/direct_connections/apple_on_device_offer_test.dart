import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/apple_pcc_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/apple_pcc_host.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/storage_providers.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// Answers each Apple model's status as the test sets it. [onDeviceAnswer],
/// when set, holds the on-device answer until it completes.
final class _AppleHost extends UnavailableApplePccHost {
  PlatformPccAvailability onDevice = PlatformPccAvailability.unavailable;
  PlatformPccAvailability pcc = PlatformPccAvailability.unavailable;
  Completer<void>? onDeviceAnswer;
  int onDeviceAsked = 0;

  @override
  Future<PlatformPccStatus> getStatus(PlatformAppleModel model) async {
    if (model == PlatformAppleModel.onDevice) {
      onDeviceAsked++;
      await onDeviceAnswer?.future;
    }
    return PlatformPccStatus(
      availability: model == PlatformAppleModel.onDevice ? onDevice : pcc,
      quotaStatus: PlatformPccQuotaStatus.unknown,
      quotaLimitReached: false,
      canIncreaseQuota: false,
      message: 'Apple Intelligence is still getting ready.',
    );
  }
}

void main() {
  late _AppleHost host;

  setUp(() async {
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
    host = _AppleHost();
  });

  tearDown(PreferencesStore.debugReset);

  /// An iPhone where Apple's models can exist, with Apple On-Device on (its
  /// default) and Private Cloud Compute as [pccEnabled] says.
  Future<ProviderContainer> iPhone({bool pccEnabled = false}) async {
    await PreferencesStore.put(PreferenceKeys.applePccEnabled, pccEnabled);
    final container = ProviderContainer(
      overrides: [
        applePccPlatformSupportedProvider.overrideWithValue(true),
        applePccHostProvider.overrideWithValue(host),
        hostDirectProviderAdaptersProvider.overrideWith(
          (ref) => [ref.watch(applePccAdapterProvider)],
        ),
        secureStorageProvider.overrideWithValue(InMemorySecureKeyValueStore()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(directConnectionProfilesProvider.future);
    return container;
  }

  Future<List<DirectConnectionProfile>> effective(ProviderContainer c) =>
      c.read(effectiveDirectConnectionProfilesFutureProvider.future);

  test('Apple On-Device whose model is not ready is no usable Direct '
      'connection, so signing out of the last account does not fall back to '
      'it', () async {
    final container = await iPhone();

    final profiles = await effective(container);

    check(profiles.where((p) => p.isAppleOnDevice)).isEmpty();
    check(profiles.any((p) => p.isUsable)).isFalse();
    check(container.read(effectiveDirectConnectionProfilesProvider).value)
        .isNotNull()
        .isEmpty();
  });

  test('Apple On-Device is offered once its model answers', () async {
    host.onDevice = PlatformPccAvailability.available;
    final container = await iPhone();

    final profiles = await effective(container);

    check(profiles).length.equals(1);
    check(profiles.single.isAppleOnDevice).isTrue();
    check(profiles.single.isUsable).isTrue();
  });

  test(
    'nothing routes on a guess while the model has not yet answered',
    () async {
      host
        ..onDevice = PlatformPccAvailability.available
        ..onDeviceAnswer = Completer<void>();
      final container = await iPhone();
      final subscription = container.listen(
        effectiveDirectConnectionProfilesProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);

      check(container.read(effectiveDirectConnectionProfilesProvider).isLoading)
          .isTrue();

      host.onDeviceAnswer!.complete();
      await container.read(appleOnDeviceStatusProvider.future);
      final profiles = container
          .read(effectiveDirectConnectionProfilesProvider)
          .requireValue;
      check(profiles.single.isAppleOnDevice).isTrue();
    },
  );

  test('a model refresh asks a model that was not ready again', () async {
    final container = await iPhone();
    final subscription = container.listen(
      effectiveDirectConnectionProfilesProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);
    check(await effective(container)).isEmpty();
    final asked = host.onDeviceAsked;

    // The model finishes downloading while the app runs.
    host.onDevice = PlatformPccAvailability.available;
    unawaited(container.read(directModelDiscoveryProvider.notifier).refresh());
    await container.read(appleOnDeviceStatusProvider.future);

    check(host.onDeviceAsked).isGreaterThan(asked);
    check(
      container.read(effectiveDirectConnectionProfilesProvider).requireValue,
    ).any((it) => it.has((p) => p.isAppleOnDevice, 'isAppleOnDevice').isTrue());
  });

  test('a model refresh finishes with the model\'s new answer', () async {
    final container = await iPhone();
    final subscription = container.listen(
      effectiveDirectConnectionProfilesProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);
    check(await effective(container)).isEmpty();

    // The model finished downloading, and takes a moment to say so.
    host
      ..onDevice = PlatformPccAvailability.available
      ..onDeviceAnswer = Completer<void>();
    final asked = host.onDeviceAsked;
    List<DirectConnectionProfile>? whenRefreshed;
    final refreshed = container
        .read(directModelDiscoveryProvider.notifier)
        .refresh()
        .then(
          (_) => whenRefreshed = container
              .read(effectiveDirectConnectionProfilesProvider)
              .value,
        );
    while (host.onDeviceAsked == asked) {
      await Future<void>.delayed(Duration.zero);
    }
    for (var turn = 0; turn < 20; turn++) {
      await Future<void>.delayed(Duration.zero);
    }
    host.onDeviceAnswer!.complete();
    await refreshed;

    check(whenRefreshed).isNotNull().any(
      (it) => it.has((p) => p.isAppleOnDevice, 'isAppleOnDevice').isTrue(),
    );
  });

  test('turning Apple On-Device back on asks its model again', () async {
    host.onDevice = PlatformPccAvailability.available;
    final container = await iPhone();
    final subscription = container.listen(
      effectiveDirectConnectionProfilesProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);
    check(await effective(container)).any(
      (it) => it.has((p) => p.isAppleOnDevice, 'isAppleOnDevice').isTrue(),
    );
    final enabled = container.read(appleOnDeviceEnabledProvider.notifier);
    await enabled.setEnabled(false);
    check(await effective(container)).isEmpty();

    // Apple Intelligence is turned off while Apple On-Device is off.
    host.onDevice = PlatformPccAvailability.unavailable;
    final asked = host.onDeviceAsked;
    await enabled.setEnabled(true);

    check(host.onDeviceAsked).isGreaterThan(asked);
    check(container.read(appleOnDeviceOfferedProvider)).equals(false);
    check(await effective(container)).isEmpty();
  });

  test('Private Cloud Compute is offered as before, whatever the on-device '
      'model says', () async {
    final container = await iPhone(pccEnabled: true);

    final profiles = await effective(container);

    check(profiles).length.equals(1);
    check(profiles.single.isApplePrivateCloudCompute).isTrue();
  });
}
