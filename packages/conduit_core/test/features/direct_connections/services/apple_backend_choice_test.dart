import 'package:checks/checks.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/apple_backend_choice.dart';
import 'package:conduit_core/features/direct_connections/services/apple_pcc_host.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

PlatformPccStatus _status(
  PlatformPccAvailability availability, {
  bool quotaLimitReached = false,
}) => PlatformPccStatus(
  availability: availability,
  quotaStatus: PlatformPccQuotaStatus.unknown,
  quotaLimitReached: quotaLimitReached,
  canIncreaseQuota: false,
);

void main() {
  setUp(() async {
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
  });
  tearDown(PreferencesStore.debugReset);

  test('only a model that answers with quota left can be chosen', () {
    check(appleModelChoosable(_status(PlatformPccAvailability.available)))
        .isTrue();
    check(
      appleModelChoosable(
        _status(PlatformPccAvailability.available, quotaLimitReached: true),
      ),
    ).isFalse();
    for (final other in PlatformPccAvailability.values.where(
      (a) => a != PlatformPccAvailability.available,
    )) {
      check(appleModelChoosable(_status(other))).isFalse();
    }
  });

  test('choosing Apple On-Device turns it on, keeps history on the device and '
      'prefers Direct', () async {
    await PreferencesStore.put(PreferenceKeys.appleOnDeviceEnabled, false);
    await PreferencesStore.put(PreferenceKeys.applePccEnabled, false);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await chooseAppleModelBackend(container.read, PlatformAppleModel.onDevice);

    check(container.read(appleOnDeviceEnabledProvider)).isTrue();
    check(container.read(applePccEnabledProvider)).isFalse();
    check(container.read(directHistoryPolicyProvider))
        .equals(DirectHistoryPolicy.localOnly);
    check(container.read(preferredBackendProvider))
        .equals(PreferredBackend.direct);
  });

  test('a history policy chosen before is kept', () async {
    await PreferencesStore.put(
      PreferenceKeys.directHistoryPolicy,
      DirectHistoryPolicy.syncWithOpenWebUI.storageValue,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await chooseAppleModelBackend(
      container.read,
      PlatformAppleModel.privateCloudCompute,
    );

    check(container.read(applePccEnabledProvider)).isTrue();
    check(container.read(directHistoryPolicyProvider))
        .equals(DirectHistoryPolicy.syncWithOpenWebUI);
    check(container.read(preferredBackendProvider))
        .equals(PreferredBackend.direct);
  });
}
