import 'package:riverpod/misc.dart' show ProviderListenable;

import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/apple_pcc_host.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';

/// Whether the backend chooser may choose the Apple model whose status is
/// [status]: it answers now, with quota left.
bool appleModelChoosable(PlatformPccStatus status) =>
    status.availability == PlatformPccAvailability.available &&
    !status.quotaLimitReached;

/// The backend chooser's Apple rows, once [appleModelChoosable] said yes:
/// [model] is turned on, Direct history stays on the device unless a
/// policy was chosen before, and Direct becomes the preferred backend, so
/// the app opens on chat.
Future<void> chooseAppleModelBackend(
  T Function<T>(ProviderListenable<T> provider) read,
  PlatformAppleModel model,
) async {
  if (model == PlatformAppleModel.onDevice) {
    await read(appleOnDeviceEnabledProvider.notifier).setEnabled(true);
  } else {
    await read(applePccEnabledProvider.notifier).setEnabled(true);
  }
  if (PreferencesStore.getString(PreferenceKeys.directHistoryPolicy) == null) {
    await read(directHistoryPolicyProvider.notifier)
        .setPolicy(DirectHistoryPolicy.localOnly);
  }
  await read(preferredBackendProvider.notifier).set(PreferredBackend.direct);
}
