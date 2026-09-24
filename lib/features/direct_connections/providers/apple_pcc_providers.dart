import 'package:riverpod/riverpod.dart';

import '../../../platform/conduit_platform_apis.g.dart';
import '../services/apple_pcc_adapter.dart';

import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';

/// Apple Intelligence providers.
///
/// Split out of `direct_connection_providers.dart` so that file could move
/// into `conduit_core`. These cannot follow it: `ApplePccAdapter` implements
/// a pigeon `PccFlutterApi` callback interface and the status types are
/// pigeon-generated, so the group is bound to the Flutter host.
///
/// `hostDirectProviderAdaptersProvider` is the seam the adapter comes back
/// through; `main.dart` registers it.

final applePccAdapterProvider = Provider<ApplePccAdapter>(
  (ref) => ApplePccAdapter(
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
