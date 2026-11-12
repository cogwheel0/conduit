import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/direct_connections/services/apple_pcc_adapter.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';

/// Apple Intelligence providers (moved from the app).
///
/// The app binds [applePccHostProvider] to its Pigeon bridge
/// (`PigeonApplePccHost`). `hostDirectProviderAdaptersProvider` is the seam
/// the adapter comes back through; the app's startup registers it.

/// The native Foundation Models bridge. Unbound, both Apple models report
/// unsupported.
final applePccHostProvider = Provider<ApplePccHost>(
  (ref) => const UnavailableApplePccHost(),
);

final applePccAdapterProvider = Provider<ApplePccAdapter>(
  (ref) => ApplePccAdapter(
    host: ref.watch(applePccHostProvider),
    allowOnDeviceFallback: () => ref.read(applePccOnDeviceFallbackProvider),
  ),
);

/// Apple Intelligence never exists off iOS, so status probes must not reach
/// the platform channel there. Returning [PlatformPccAvailability.unsupported]
/// keeps every consumer on the same "not on this device" path.
PlatformPccStatus _unsupportedApplePlatformStatus() => PlatformPccStatus(
  availability: PlatformPccAvailability.unsupported,
  quotaStatus: PlatformPccQuotaStatus.unknown,
  quotaLimitReached: false,
  canIncreaseQuota: false,
);

final applePccStatusProvider = FutureProvider<PlatformPccStatus>((ref) {
  if (!ref.watch(applePccPlatformSupportedProvider)) {
    return _unsupportedApplePlatformStatus();
  }
  return ref
      .watch(applePccAdapterProvider)
      .status(PlatformAppleModel.privateCloudCompute);
});

final appleOnDeviceStatusProvider = FutureProvider<PlatformPccStatus>((ref) {
  if (!ref.watch(applePccPlatformSupportedProvider)) {
    return _unsupportedApplePlatformStatus();
  }
  return ref.watch(applePccAdapterProvider).status(PlatformAppleModel.onDevice);
});

/// Whether Apple On-Device is offered as a Direct connection: turned on,
/// where Apple's models can exist, and its model said it can answer when
/// last asked. Null while the first answer is awaited.
///
/// A device whose model is not ready (still downloading, Apple Intelligence
/// off, an ineligible device) is not offered it: the default-on connection
/// would otherwise count as a usable Direct connection, so signing out of
/// the last account would land on a Direct app whose only model cannot
/// answer. Asking again keeps the last answer until the new one comes.
final appleOnDeviceOfferedProvider = Provider<bool?>((ref) {
  if (!ref.watch(applePccPlatformSupportedProvider) ||
      !ref.watch(appleOnDeviceEnabledProvider)) {
    return false;
  }
  final status = ref.watch(appleOnDeviceStatusProvider);
  if (status.hasError && !status.isLoading) return false;
  final current = status.value;
  if (current == null) return status.isLoading ? null : false;
  return current.availability == PlatformPccAvailability.available;
});
