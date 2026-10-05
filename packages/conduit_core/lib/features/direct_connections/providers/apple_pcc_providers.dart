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
