part of 'app_providers.dart';

typedef _ModelAuthReadiness = ({
  bool authenticated,
  bool loading,
  AuthStatus status,
});

/// Rebuilds every long-lived provider that mirrors data removed by the broad
/// sign-out wipe.
void _resetProvidersAfterFullAppDataClear(Ref ref) {
  ref.read(activeConversationProvider.notifier).set(null);
  ref.invalidate(directLocalDatabaseProvider);
  ref.invalidate(conversationsProvider);

  ref.invalidate(appSettingsProvider);
  ref.invalidate(reviewerModeProvider);
  // Theme and locale live in the app, so the host registers them rather than
  // the core reaching upward for them.
  for (final target in ref.read(signOutResetTargetsProvider)) {
    ref.invalidate(target);
  }
  ref.invalidate(preferredBackendProvider);

  ref.invalidate(directConnectionProfilesProvider);
  ref.invalidate(directMcpServerStoreProvider);
  ref.invalidate(directMcpServersProvider);
  ref.invalidate(directMcpOAuthCoordinatorProvider);
  ref.invalidate(directHistoryPolicyProvider);
  ref.invalidate(directDeviceTrustKeyProvider);
  ref.invalidate(directRunRegistryProvider);
  ref.invalidate(directModelRegistryProvider);
  ref.invalidate(directProviderAdapterRegistryProvider);
  ref.invalidate(directHttpClientPoolProvider);

  ref.invalidate(hermesConfigProvider);
  ref.invalidate(hermesSecretsLoadingProvider);
  ref.invalidate(hermesSecretsErrorProvider);
  ref.invalidate(hermesActiveSessionProvider);
  ref.invalidate(hermesApiServiceProvider);
}

final signOutCoordinatorProvider = Provider<SignOutCoordinator>(
  SignOutCoordinator.new,
);

enum SignOutRequestResult { completed, conflictingRequestIgnored }

/// Coordinates a user-requested full local-data sign-out across auth and
/// backend providers. Connection mutation barriers are installed only after
/// auth ownership is confirmed, then held until the wipe commits or aborts.
final class SignOutCoordinator {
  SignOutCoordinator(this._ref);

  final Ref _ref;
  Future<SignOutRequestResult>? _activeSignOut;
  bool? _activeKeepServerDetails;

  Future<SignOutRequestResult> signOut({required bool keepServerDetails}) {
    final active = _activeSignOut;
    if (active != null) {
      if (_activeKeepServerDetails == keepServerDetails) return active;
      return Future<SignOutRequestResult>.value(
        SignOutRequestResult.conflictingRequestIgnored,
      );
    }
    late final Future<SignOutRequestResult> operation;
    operation = _signOut(keepServerDetails: keepServerDetails)
        .then((_) => SignOutRequestResult.completed)
        .whenComplete(() {
          if (identical(_activeSignOut, operation)) {
            _activeSignOut = null;
            _activeKeepServerDetails = null;
          }
        });
    _activeKeepServerDetails = keepServerDetails;
    _activeSignOut = operation;
    return operation;
  }

  Future<void> _signOut({required bool keepServerDetails}) async {
    final directProfiles = _ref.read(directConnectionProfilesProvider.notifier);
    final directMcpServers = _ref.read(directMcpServersProvider.notifier);
    final hermesConfig = _ref.read(hermesConfigProvider.notifier);
    final directRuns = _ref.read(directRunRegistryProvider);
    FullAppDataClearOutcome? outcome;
    var directLocalPurgeCompleted = false;

    void resumeGlobalAdmission() {
      directRuns.resumeAdmissionAfterAppDataClearAbort();
      PreferencesStore.resumeWritesAfterAppDataClear();
      SecureCredentialStorage.resumeDirectIdentityWritesAfterAppDataClear();
    }

    Future<void> prepareForClear() async {
      directRuns.blockAdmissionForAppDataClear();
      try {
        await Future.wait<void>([
          PreferencesStore.blockWritesForAppDataClear(),
          SecureCredentialStorage.blockDirectIdentityWritesForAppDataClear(),
          directProfiles.blockMutationsForAppDataClear(),
          directMcpServers.blockMutationsForAppDataClear(),
          hermesConfig.blockMutationsForAppDataClear(),
        ]);
        // Armed before anything is wiped: a process death mid-clear must not
        // bring surviving Direct profiles back on restart. Failing to arm it
        // aborts the clear through the catch below.
        await armIncompleteAppDataClearMarker();
        _ref.invalidate(directProviderAdapterRegistryProvider);
        _ref.invalidate(directModelDiscoveryProvider);
        _ref.invalidate(directHttpClientPoolProvider);
        final directCleanup = directRuns.cancelAll();
        await Future.wait<void>([
          for (final cleanup in directCleanup)
            cleanup.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        ]);
      } catch (_) {
        resumeGlobalAdmission();
        directProfiles.resumeMutationsAfterAppDataClearAbort();
        directMcpServers.resumeMutationsAfterAppDataClearAbort();
        hermesConfig.resumeMutationsAfterAppDataClearAbort();
        rethrow;
      }
    }

    try {
      outcome = await _ref
          .read(authStateManagerProvider.notifier)
          .logoutAndClearAppData(
            keepServerDetails: keepServerDetails,
            beforeClear: prepareForClear,
          );
      switch (outcome) {
        case FullAppDataClearOutcome.cleared ||
            FullAppDataClearOutcome.localDataClearedSessionCleanupIncomplete:
          directRuns.commitAppDataClear();
          // The auth transaction has committed and did not yield to a newer
          // session. Only now is it safe to destructively remove the
          // app-global direct-local database; beforeClear is a reversible
          // admission barrier and may still lose auth ownership.
          await _ref.read(directLocalDatabasePurgeProvider)();
          directLocalPurgeCompleted = true;
          await disarmIncompleteAppDataClearMarker();
          _resetProvidersAfterFullAppDataClear(_ref);
        case FullAppDataClearOutcome.incomplete:
          directRuns.commitAppDataClear();
          await Future.wait<void>([
            directProfiles.blockMutationsForAppDataClear(),
            directMcpServers.blockMutationsForAppDataClear(),
            hermesConfig.blockMutationsForAppDataClear(),
          ]);
          directMcpServers.revokeRuntimeAfterIncompleteAppDataClear();
          hermesConfig.revokeRuntimeAfterIncompleteAppDataClear();
          // Awaited last: it persists the restart marker that keeps surviving
          // Direct profiles hidden, and must be durable before returning.
          await directProfiles.revokeRuntimeAfterIncompleteAppDataClear();
        case FullAppDataClearOutcome.ownershipYielded:
          await disarmIncompleteAppDataClearMarker();
          resumeGlobalAdmission();
          directProfiles.resumeMutationsAfterAppDataClearAbort();
          directMcpServers.resumeMutationsAfterAppDataClearAbort();
          hermesConfig.resumeMutationsAfterAppDataClearAbort();
      }
    } finally {
      final committedClearStillNeedsDirectPurge =
          (outcome == FullAppDataClearOutcome.cleared ||
              outcome ==
                  FullAppDataClearOutcome
                      .localDataClearedSessionCleanupIncomplete) &&
          !directLocalPurgeCompleted;
      if (!committedClearStillNeedsDirectPurge) {
        PreferencesStore.resumeWritesAfterAppDataClear();
        SecureCredentialStorage.resumeDirectIdentityWritesAfterAppDataClear();
      }
      if (outcome == null) {
        resumeGlobalAdmission();
        directProfiles.resumeMutationsAfterAppDataClearAbort();
        directMcpServers.resumeMutationsAfterAppDataClearAbort();
        hermesConfig.resumeMutationsAfterAppDataClearAbort();
      }
    }
  }
}

/// A single, value-deduplicated auth dependency for model resolution. Watching
/// the three public derivations independently can restart an async provider
/// several times while one AuthState transition is being published.
final _modelAuthReadinessProvider = Provider<_ModelAuthReadiness>((ref) {
  return (
    authenticated: ref.watch(isAuthenticatedProvider2),
    loading: ref.watch(isAuthLoadingProvider2),
    status: ref.watch(authStatusProvider),
  );
});

bool _modelAuthRetainsOpenWebUiSession(_ModelAuthReadiness auth) =>
    auth.authenticated;

bool _modelAuthIsPending(_ModelAuthReadiness auth) =>
    auth.loading ||
    auth.status == AuthStatus.initial ||
    auth.status == AuthStatus.loading;
