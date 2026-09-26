import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
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

/// Waits up to [timeout] for [chatEntryReadyProvider] (and, with
/// [requireModel], a selected model) during a cold launch.
///
/// Native entry points can arrive while auth, Direct profiles, Hermes
/// secrets, or model discovery are still hydrating. Returns immediately when
/// nothing is loading, so a signed-out Open WebUI install is not delayed.
/// Model discovery can be slow on a cold start, so [requireModel] callers
/// get the same 30 s window as the home widget's cold-start wait.
Future<bool> waitForChatEntryReady(
  Ref ref, {
  bool requireModel = false,
  Duration? timeout,
  Duration pollInterval = const Duration(milliseconds: 100),
}) async {
  final deadline = DateTime.now().add(
    timeout ?? Duration(seconds: requireModel ? 30 : 5),
  );
  while (true) {
    if (!ref.mounted) return false;
    final ready = ref.read(chatEntryReadyProvider);
    final hasModel = !requireModel || ref.read(selectedModelProvider) != null;
    if (ready && hasModel) return true;
    if (!ready && !_chatEntryReadinessPending(ref)) return false;
    if (!DateTime.now().isBefore(deadline)) return false;
    await Future<void>.delayed(pollInterval);
  }
}

bool _chatEntryReadinessPending(Ref ref) {
  if (ref.read(authNavigationStateProvider) == AuthNavigationState.loading) {
    return true;
  }
  return switch (ref.read(preferredBackendProvider)) {
    PreferredBackend.direct =>
      ref.read(effectiveDirectConnectionProfilesProvider).isLoading,
    PreferredBackend.hermes => ref.read(hermesSecretsLoadingProvider),
    PreferredBackend.owui || PreferredBackend.unset => false,
  };
}
