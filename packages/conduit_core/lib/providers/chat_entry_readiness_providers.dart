import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';

/// Whether the preferred backend is an accountless transport (Direct or
/// Hermes) that is usable right now.
///
/// Such installs reach chat without an Open WebUI session. The router owns
/// that rule; external entry points read the same signal so a share, widget,
/// shortcut, or assistant launch never waits for a sign-in that cannot come.
final accountlessPrimaryBackendUsableProvider = Provider<bool>((ref) {
  switch (ref.watch(preferredBackendProvider)) {
    case PreferredBackend.direct:
      final profiles = ref.watch(effectiveDirectConnectionProfilesProvider);
      return !profiles.isLoading &&
          !profiles.hasError &&
          (profiles.value?.any((profile) => profile.isUsable) ?? false);
    case PreferredBackend.hermes:
      return ref.watch(hermesConfigProvider).isUsable;
    case PreferredBackend.owui:
    case PreferredBackend.unset:
      return false;
  }
});

/// Whether chat can accept externally delivered work (shared content, home
/// widget and app shortcut actions, Siri/Shortcuts, Android assistant).
///
/// True with an authenticated Open WebUI session, or when a usable accountless
/// primary backend makes chat reachable without one.
final chatEntryReadyProvider = Provider<bool>((ref) {
  if (ref.watch(authNavigationStateProvider) ==
      AuthNavigationState.authenticated) {
    return true;
  }
  return ref.watch(accountlessPrimaryBackendUsableProvider);
});
