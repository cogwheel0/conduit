part of 'app_providers.dart';

// Provider to automatically load and set the default model from user settings or OpenWebUI
@Riverpod(keepAlive: true)
Future<Model?> defaultModel(Ref ref) async {
  Model? resolved;
  while (true) {
    final reviewerAtStart = ref.read(reviewerModeProvider);
    final selectedAtStart = ref.read(selectedModelProvider);
    final manualAtStart = ref.read(isManualModelSelectionProvider);
    final candidate = await _resolveDefaultModel(ref);
    if (!ref.mounted) return null;

    if (ref.read(reviewerModeProvider) != reviewerAtStart) {
      final latestSelected = ref.read(selectedModelProvider);
      final latestManual = ref.read(isManualModelSelectionProvider);
      final hasNewManualSelection =
          latestSelected != null &&
          latestManual &&
          (!manualAtStart || !identical(latestSelected, selectedAtStart));
      if (hasNewManualSelection) {
        resolved = latestSelected;
        break;
      }
      // The mode may change after the resolver's final internal checkpoint but
      // before this provider resumes its await. Loop once more so the cached
      // value and dependency watches belong to the current reviewer universe.
      continue;
    }
    resolved = candidate;
    break;
  }

  // Register reactive dependencies only after async resolution settles. A
  // later input change invalidates the cached result, while a change during an
  // in-flight one-shot `.future` read cannot cancel and orphan that read.
  ref.watch(preferredBackendProvider);
  ref.watch(hermesConfigProvider);
  ref.watch(apiServiceProvider);
  ref.watch(_modelAuthReadinessProvider);
  ref.watch(reviewerModeProvider);
  ref.watch(modelsProvider);
  return resolved;
}

Future<Model?> _resolveDefaultModel(Ref ref) async {
  DebugLogger.log('provider-called', scope: 'models/default');

  final storage = ref.read(optimizedStorageServiceProvider);
  // This provider is commonly consumed through a one-shot `.future` read.
  // Snapshot mutable inputs instead of subscribing across awaits: invalidating
  // an in-flight build can otherwise orphan the caller's future. SelectedModel
  // owns reconciliation, and the post-await checks below reject stale
  // snapshots.
  final preferredBackend = ref.read(preferredBackendProvider);
  final hermesConfig = ref.read(hermesConfigProvider);
  final reviewerMode = ref.read(reviewerModeProvider);
  final selectedAtResolutionStart = ref.read(selectedModelProvider);
  final manualAtResolutionStart = ref.read(isManualModelSelectionProvider);

  bool isGenuinelyNewManualSelection(
    Model? latestSelected,
    bool latestManual,
  ) =>
      latestSelected != null &&
      latestManual &&
      (!manualAtResolutionStart ||
          !identical(latestSelected, selectedAtResolutionStart));

  Future<Model?>? reviewerRedirectAfterAwait() {
    if (ref.read(reviewerModeProvider) == reviewerMode) return null;
    final latestSelected = ref.read(selectedModelProvider);
    final latestManual = ref.read(isManualModelSelectionProvider);
    if (isGenuinelyNewManualSelection(latestSelected, latestManual)) {
      return Future<Model?>.value(latestSelected);
    }
    // Re-enter from the current reviewer state instead of caching an automatic
    // selection from the backend universe that owned the completed await.
    return _resolveDefaultModel(ref);
  }

  if (reviewerMode) {
    DebugLogger.log('reviewer-mode', scope: 'models/default');
    // Check if a model is manually selected
    final currentSelected = selectedAtResolutionStart;
    final isManualSelection = manualAtResolutionStart;

    if (currentSelected != null && isManualSelection) {
      DebugLogger.log(
        'manual',
        scope: 'models/default',
        data: {
          'backend': _modelBackendForDiagnostics(currentSelected),
          'source': 'user',
        },
      );
      return currentSelected;
    }

    // Get demo models and select the first one
    final models = await ref.read(modelsProvider.future);
    if (!ref.mounted) return null;
    final reviewerRedirect = reviewerRedirectAfterAwait();
    if (reviewerRedirect != null) return await reviewerRedirect;
    final latestSelected = ref.read(selectedModelProvider);
    final latestManual = ref.read(isManualModelSelectionProvider);
    if (isGenuinelyNewManualSelection(latestSelected, latestManual)) {
      return latestSelected;
    }
    if (!identical(latestSelected, currentSelected) ||
        latestManual != isManualSelection) {
      return _resolveDefaultModel(ref);
    }
    if (models.isNotEmpty) {
      final defaultModel = models.first;
      if (!isManualSelection) {
        ref.read(selectedModelProvider.notifier).set(defaultModel);
        DebugLogger.log(
          'auto-select',
          scope: 'models/default',
          data: {
            'backend': _modelBackendForDiagnostics(defaultModel),
            'source': 'reviewer',
          },
        );
      }
      return defaultModel;
    }
    DebugLogger.warning('no-demo-models', scope: 'models/default');
    return null;
  }

  final api = ref.read(apiServiceProvider);
  var modelAuth = ref.read(_modelAuthReadinessProvider);
  final selectedBeforeAuthSettles = ref.read(selectedModelProvider);
  final authBuildFuture =
      !modelAuth.authenticated &&
          modelAuth.loading &&
          selectedBeforeAuthSettles == null
      ? ref.read(authStateManagerProvider.future)
      : null;
  if (authBuildFuture != null) {
    // A cold-start chat may ask for its default before the initial secure
    // storage read resolves. If this invocation completes with null, there may
    // be no remaining listener to retry when auth settles. Wait for that first
    // AuthStateManager build; inner token refreshes already have AsyncData and
    // return immediately.
    final settledAuth = await authBuildFuture;
    if (!ref.mounted) return null;
    final reviewerRedirect = reviewerRedirectAfterAwait();
    if (reviewerRedirect != null) return await reviewerRedirect;
    modelAuth = (
      authenticated: settledAuth.isAuthenticated,
      loading:
          settledAuth.isLoading ||
          settledAuth.status == AuthStatus.initial ||
          settledAuth.status == AuthStatus.loading,
      status: settledAuth.status,
    );
  }
  if (!modelAuth.authenticated) {
    if (!_shouldUseAccountlessModelSelection(
      isAuthenticated: false,
      isAuthLoading: modelAuth.loading,
      authStatus: modelAuth.status,
      preferredBackend: preferredBackend,
      hasApiService: api != null,
    )) {
      // Authentication hydration/revalidation is not logout. Keep the current
      // model and avoid protected OpenWebUI calls until auth settles.
      return await Future<Model?>.value(ref.read(selectedModelProvider));
    }

    final currentSelected = ref.read(selectedModelProvider);
    final configuredDefaultId =
        currentSelected != null && ref.read(isManualModelSelectionProvider)
        ? null
        : ref.read(appSettingsProvider).defaultModel;
    final Model? standalone;
    if (preferredBackend == PreferredBackend.hermes) {
      standalone = hermesConfig.isUsable
          ? (currentSelected != null && isHermesModel(currentSelected)
                ? currentSelected
                : hermesSyntheticModel())
          : null;
    } else if (preferredBackend == PreferredBackend.direct) {
      final discovery = await ref.read(directModelDiscoveryProvider.future);
      if (!ref.mounted) return null;
      final reviewerRedirect = reviewerRedirectAfterAwait();
      if (reviewerRedirect != null) return await reviewerRedirect;
      final registry = ref.read(directModelRegistryProvider);
      standalone = _accountlessSelection(
        models: discovery.models.where(
          (model) => registry.resolve(model) != null,
        ),
        current: currentSelected,
        preferredBackend: preferredBackend,
        preferredModelId: configuredDefaultId,
      );
    } else {
      final models = await ref.read(modelsProvider.future);
      if (!ref.mounted) return null;
      final reviewerRedirect = reviewerRedirectAfterAwait();
      if (reviewerRedirect != null) return await reviewerRedirect;
      standalone = _accountlessSelection(
        models: models,
        current: currentSelected,
        preferredBackend: preferredBackend,
        preferredModelId: configuredDefaultId,
      );
    }
    // Provider initialization may not synchronously mutate another provider.
    // The remote/default paths already cross an async boundary; keep the
    // locally minted Hermes fast path under the same Riverpod contract.
    await Future<void>.delayed(Duration.zero);
    if (!ref.mounted) return null;
    final reviewerRedirect = reviewerRedirectAfterAwait();
    if (reviewerRedirect != null) return await reviewerRedirect;
    final latestSelected = ref.read(selectedModelProvider);
    final latestAuth = ref.read(_modelAuthReadinessProvider);
    final preferenceIsCurrent =
        ref.read(preferredBackendProvider) == preferredBackend;
    final authStillAllowsAccountless = _shouldUseAccountlessModelSelection(
      isAuthenticated: latestAuth.authenticated,
      isAuthLoading: latestAuth.loading,
      authStatus: latestAuth.status,
      preferredBackend: preferredBackend,
      hasApiService: ref.read(apiServiceProvider) != null,
    );
    final hermesSnapshotIsCurrent =
        preferredBackend != PreferredBackend.hermes ||
        ref.read(hermesConfigProvider).isUsable;
    final directBindingIsCurrent =
        standalone == null ||
        !isLocallyMintedDirectModel(standalone) ||
        ref.read(directModelRegistryProvider).resolve(standalone) != null;
    if (!preferenceIsCurrent ||
        !authStillAllowsAccountless ||
        !hermesSnapshotIsCurrent ||
        !directBindingIsCurrent ||
        !identical(latestSelected, currentSelected)) {
      return latestSelected;
    }
    if (!identical(currentSelected, standalone)) {
      if (currentSelected?.id != standalone?.id) {
        ref.read(isManualModelSelectionProvider.notifier).set(false);
      }
      ref.read(selectedModelProvider.notifier).set(standalone);
    }
    if (standalone != null) return standalone;
    DebugLogger.warning('no-accountless-model', scope: 'models/default');
    return null;
  }

  // Accountless Direct/Hermes selection is independent from the optional
  // OpenWebUI server. Authenticated work captures a point-in-time ownership
  // token below; startup/account listeners invalidate this provider when a
  // fresh resolution is required, so no server dependency needs to be watched
  // across the authentication await above.
  final authenticatedTokenSnapshot = ref.read(authTokenProvider3);
  final apiSnapshot = api;
  final authenticatedOwnershipSnapshot = api == null
      ? null
      : captureOpenWebUiCacheOwnership(
          ref,
          api: api,
          requireAuthenticated: false,
        );

  bool authenticatedResolutionIsCurrent(Model? selectionSnapshot) {
    if (!ref.mounted) return false;
    final latestAuth = ref.read(_modelAuthReadinessProvider);
    final ownershipIsCurrent = apiSnapshot == null
        ? authenticatedOwnershipSnapshot == null
        : authenticatedOwnershipSnapshot != null &&
              openWebUiCacheOwnershipIsCurrent(
                ref,
                authenticatedOwnershipSnapshot,
              );
    return latestAuth.authenticated &&
        ownershipIsCurrent &&
        ref.read(authTokenProvider3) == authenticatedTokenSnapshot &&
        identical(ref.read(apiServiceProvider), apiSnapshot) &&
        ref.read(preferredBackendProvider) == preferredBackend &&
        identical(ref.read(selectedModelProvider), selectionSnapshot);
  }

  if (api == null) {
    final manuallySelected = ref.read(selectedModelProvider);
    if (ref.read(isManualModelSelectionProvider) &&
        manuallySelected != null &&
        _matchesPreferredBackend(manuallySelected, preferredBackend) &&
        (isHermesModel(manuallySelected) ||
            ref.read(directModelRegistryProvider).resolve(manuallySelected) !=
                null)) {
      return manuallySelected;
    }

    final selectionSnapshot = ref.read(selectedModelProvider);
    final models = await ref.read(modelsProvider.future);
    if (!ref.mounted) return null;
    final reviewerRedirect = reviewerRedirectAfterAwait();
    if (reviewerRedirect != null) return await reviewerRedirect;
    if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
      return await Future<Model?>.value(ref.read(selectedModelProvider));
    }
    final standalone =
        _modelForPreferredBackend(models, preferredBackend) ??
        models.firstOrNull;
    if (standalone != null && !ref.read(isManualModelSelectionProvider)) {
      ref.read(selectedModelProvider.notifier).set(standalone);
      return standalone;
    }
    DebugLogger.warning('no-api', scope: 'models/default');
    return null;
  }

  DebugLogger.log('api-available', scope: 'models/default');

  try {
    // Respect manual selection if present
    if (ref.read(isManualModelSelectionProvider)) {
      final current = ref.read(selectedModelProvider);
      if (current != null && !current.isHidden) return current;
      ref.read(isManualModelSelectionProvider.notifier).set(false);
      ref.read(selectedModelProvider.notifier).clear();
    }
    final selectionSnapshot = ref.read(selectedModelProvider);

    // 1) Priority: app-local default model preference.
    final settingsDefaultId = ref.read(appSettingsProvider).defaultModel;
    final storedDefaultId =
        settingsDefaultId ??
        await SettingsService.getDefaultModel().catchError((_) => null);
    if (!ref.mounted) return null;
    var reviewerRedirect = reviewerRedirectAfterAwait();
    if (reviewerRedirect != null) return await reviewerRedirect;
    if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
      return await Future<Model?>.value(ref.read(selectedModelProvider));
    }

    if (storedDefaultId != null && storedDefaultId.isNotEmpty) {
      final availableModels = await ref.read(modelsProvider.future);
      if (!ref.mounted) return null;
      reviewerRedirect = reviewerRedirectAfterAwait();
      if (reviewerRedirect != null) return await reviewerRedirect;
      if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
        return await Future<Model?>.value(ref.read(selectedModelProvider));
      }
      final availableMatch =
          ref
              .read(directModelRegistryProvider)
              .resolveOpenWebUiWireModel(availableModels, storedDefaultId) ??
          availableModels
              .where((model) => model.id == storedDefaultId)
              .firstOrNull;
      if (availableMatch != null && !ref.read(isManualModelSelectionProvider)) {
        ref.read(selectedModelProvider.notifier).set(availableMatch);
        if (!isLocallyMintedDirectModel(availableMatch) &&
            !isHermesModel(availableMatch)) {
          unawaited(
            storage.saveLocalDefaultModel(availableMatch).onError((
              error,
              stack,
            ) {
              DebugLogger.error(
                'Failed to save default model to cache',
                scope: 'models/default',
                error: error,
                stackTrace: stack,
              );
            }),
          );
        }
        DebugLogger.log(
          'settings-default',
          scope: 'models/default',
          data: {
            'backend': _modelBackendForDiagnostics(availableMatch),
            'source': 'available',
          },
        );
        return availableMatch;
      }
      final cachedMatch = await selectCachedModel(storage, storedDefaultId);
      if (!ref.mounted) return null;
      reviewerRedirect = reviewerRedirectAfterAwait();
      if (reviewerRedirect != null) return await reviewerRedirect;
      if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
        return await Future<Model?>.value(ref.read(selectedModelProvider));
      }
      if (cachedMatch != null && !ref.read(isManualModelSelectionProvider)) {
        ref.read(selectedModelProvider.notifier).set(cachedMatch);
        unawaited(
          storage.saveLocalDefaultModel(cachedMatch).catchError((_) {}),
        );
        DebugLogger.log(
          'settings-default',
          scope: 'models/default',
          data: {
            'backend': _modelBackendForDiagnostics(cachedMatch),
            'source': 'settings',
          },
        );
        return cachedMatch;
      }
    }

    // Onboarding into a direct backend should not be silently replaced by an
    // Open WebUI server default merely because both are configured.
    if (preferredBackend == PreferredBackend.direct) {
      final availableModels = await ref.read(modelsProvider.future);
      if (!ref.mounted) return null;
      reviewerRedirect = reviewerRedirectAfterAwait();
      if (reviewerRedirect != null) return await reviewerRedirect;
      if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
        return await Future<Model?>.value(ref.read(selectedModelProvider));
      }
      final preferred = _modelForPreferredBackend(
        availableModels,
        preferredBackend,
      );
      if (preferred != null && !ref.read(isManualModelSelectionProvider)) {
        ref.read(selectedModelProvider.notifier).set(preferred);
        return preferred;
      }
    }

    // 2) Fallback: cached resolved default model (offline/fast startup).
    try {
      final cached = await storage.getLocalDefaultModel();
      if (!ref.mounted) return null;
      reviewerRedirect = reviewerRedirectAfterAwait();
      if (reviewerRedirect != null) return await reviewerRedirect;
      if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
        return await Future<Model?>.value(ref.read(selectedModelProvider));
      }
      if (cached != null && !ref.read(isManualModelSelectionProvider)) {
        final cachedMatch = await selectCachedModel(storage, cached.id);
        if (!ref.mounted) return null;
        reviewerRedirect = reviewerRedirectAfterAwait();
        if (reviewerRedirect != null) return await reviewerRedirect;
        if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
          return await Future<Model?>.value(ref.read(selectedModelProvider));
        }
        if (cachedMatch == null) {
          await storage.saveLocalDefaultModel(null);
          if (!ref.mounted) return null;
          reviewerRedirect = reviewerRedirectAfterAwait();
          if (reviewerRedirect != null) return await reviewerRedirect;
          if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
            return await Future<Model?>.value(ref.read(selectedModelProvider));
          }
        } else {
          ref.read(selectedModelProvider.notifier).set(cachedMatch);
          DebugLogger.log(
            'cached-default',
            scope: 'models/default',
            data: {
              'backend': _modelBackendForDiagnostics(cachedMatch),
              'source': 'cache',
            },
          );
          return cachedMatch;
        }
      }
    } catch (_) {
      if (!ref.mounted) return null;
      reviewerRedirect = reviewerRedirectAfterAwait();
      if (reviewerRedirect != null) return await reviewerRedirect;
      if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
        return await Future<Model?>.value(ref.read(selectedModelProvider));
      }
    }

    // 3) Fallback: server-provided automatic resolution when no app-local
    // preference exists.
    try {
      final serverDefault = await api.getDefaultModel();
      if (!ref.mounted) return null;
      reviewerRedirect = reviewerRedirectAfterAwait();
      if (reviewerRedirect != null) return await reviewerRedirect;
      if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
        return await Future<Model?>.value(ref.read(selectedModelProvider));
      }
      if (serverDefault != null && serverDefault.isNotEmpty) {
        final availableModels = await ref.read(modelsProvider.future);
        if (!ref.mounted) return null;
        reviewerRedirect = reviewerRedirectAfterAwait();
        if (reviewerRedirect != null) return await reviewerRedirect;
        if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
          return await Future<Model?>.value(ref.read(selectedModelProvider));
        }
        Model? resolved = ref
            .read(directModelRegistryProvider)
            .resolveOpenWebUiWireModel(availableModels, serverDefault);
        if (resolved == null) {
          final models = await api.getModels();
          if (!ref.mounted) return null;
          reviewerRedirect = reviewerRedirectAfterAwait();
          if (reviewerRedirect != null) return await reviewerRedirect;
          if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
            return await Future<Model?>.value(ref.read(selectedModelProvider));
          }
          resolved = resolveSafeRemoteDefaultModel(models, serverDefault);
        }

        if (resolved != null && !ref.read(isManualModelSelectionProvider)) {
          ref.read(selectedModelProvider.notifier).set(resolved);
          if (!isLocallyMintedDirectModel(resolved) &&
              !isHermesModel(resolved)) {
            unawaited(
              storage.saveLocalDefaultModel(resolved).onError((error, stack) {
                DebugLogger.error(
                  'Failed to save default model to cache',
                  scope: 'models/default',
                  error: error,
                  stackTrace: stack,
                );
              }),
            );
          }
          DebugLogger.log(
            'server-default',
            scope: 'models/default',
            data: {
              'backend': _modelBackendForDiagnostics(resolved),
              'source': 'server',
            },
          );
          return resolved;
        }
      }
    } catch (_) {
      if (!ref.mounted) return null;
      reviewerRedirect = reviewerRedirectAfterAwait();
      if (reviewerRedirect != null) return await reviewerRedirect;
    }

    // 4) Fallback: fetch models and pick first available
    DebugLogger.log('fallback-path', scope: 'models/default');
    final models = await ref.read(modelsProvider.future);
    if (!ref.mounted) return null;
    reviewerRedirect = reviewerRedirectAfterAwait();
    if (reviewerRedirect != null) return await reviewerRedirect;
    if (!authenticatedResolutionIsCurrent(selectionSnapshot)) {
      return await Future<Model?>.value(ref.read(selectedModelProvider));
    }
    DebugLogger.log(
      'models-loaded',
      scope: 'models/default',
      data: {'count': models.length},
    );
    if (models.isEmpty) {
      DebugLogger.warning('no-models', scope: 'models/default');
      return null;
    }
    final selectedModel =
        _modelForPreferredBackend(models, preferredBackend) ?? models.first;
    if (!ref.read(isManualModelSelectionProvider)) {
      ref.read(selectedModelProvider.notifier).set(selectedModel);
      if (!isLocallyMintedDirectModel(selectedModel) &&
          !isHermesModel(selectedModel)) {
        unawaited(
          storage.saveLocalDefaultModel(selectedModel).onError((error, stack) {
            DebugLogger.error(
              'Failed to save default model to cache',
              scope: 'models/default',
              error: error,
              stackTrace: stack,
            );
          }),
        );
      }
      DebugLogger.log(
        'fallback-selected',
        scope: 'models/default',
        data: {
          'backend': _modelBackendForDiagnostics(selectedModel),
          'source': 'fallback',
        },
      );
    } else {
      DebugLogger.log('skip-manual-override', scope: 'models/default');
    }
    return selectedModel;
  } catch (e) {
    if (!ref.mounted) return null;
    final reviewerRedirect = reviewerRedirectAfterAwait();
    if (reviewerRedirect != null) return await reviewerRedirect;
    DebugLogger.error('set-default-failed', scope: 'models/default', error: e);
    return null;
  }
}

Model? _modelForPreferredBackend(
  Iterable<Model> models,
  PreferredBackend preferredBackend,
) {
  return switch (preferredBackend) {
    PreferredBackend.direct =>
      models.where(isLocallyMintedDirectModel).firstOrNull,
    PreferredBackend.hermes => models.where(isHermesModel).firstOrNull,
    PreferredBackend.owui || PreferredBackend.unset => null,
  };
}

Model? _accountlessSelection({
  required Iterable<Model> models,
  required Model? current,
  required PreferredBackend preferredBackend,
  String? preferredModelId,
}) {
  final available = models.toList(growable: false);

  final preferredMatch = preferredModelId == null || preferredModelId.isEmpty
      ? null
      : available
            .where(
              (model) =>
                  model.id == preferredModelId &&
                  _matchesPreferredBackend(model, preferredBackend),
            )
            .firstOrNull;
  if (preferredMatch != null) return preferredMatch;

  final currentMatch = current == null
      ? null
      : available.where((model) => model.id == current.id).firstOrNull;
  if (currentMatch != null &&
      _matchesPreferredBackend(currentMatch, preferredBackend)) {
    return currentMatch;
  }
  return _modelForPreferredBackend(available, preferredBackend) ??
      switch (preferredBackend) {
        PreferredBackend.owui ||
        PreferredBackend.unset => available.firstOrNull,
        PreferredBackend.direct || PreferredBackend.hermes => null,
      };
}

bool _matchesPreferredBackend(Model model, PreferredBackend preferredBackend) =>
    switch (preferredBackend) {
      PreferredBackend.direct => isLocallyMintedDirectModel(model),
      PreferredBackend.hermes => isHermesModel(model),
      PreferredBackend.owui || PreferredBackend.unset =>
        isLocallyMintedDirectModel(model) || isHermesModel(model),
    };

bool _shouldUseAccountlessModelSelection({
  required bool isAuthenticated,
  required bool isAuthLoading,
  required AuthStatus authStatus,
  required PreferredBackend preferredBackend,
  required bool hasApiService,
}) {
  if (isAuthenticated || isAuthLoading) return false;
  return switch (authStatus) {
    AuthStatus.unauthenticated ||
    AuthStatus.tokenExpired ||
    AuthStatus.credentialError => true,
    AuthStatus.error || AuthStatus.initial || AuthStatus.loading =>
      preferredBackend == PreferredBackend.direct ||
          preferredBackend == PreferredBackend.hermes ||
          !hasApiService,
    AuthStatus.authenticated => false,
  };
}

/// Resolves a server-provided default only after removing identities reserved
/// for Conduit's locally minted Hermes transport.
@visibleForTesting
Model? resolveSafeRemoteDefaultModel(
  List<Model> remoteModels,
  String? serverDefault,
) {
  final models = sanitizeRemoteHermesModels(
    sanitizeRemoteDirectModels(remoteModels),
  );
  if (models.isEmpty) return null;

  if (serverDefault != null && serverDefault.isNotEmpty) {
    for (final model in models) {
      if (model.id == serverDefault) return model;
    }
    final byName = models.where((m) => m.name == serverDefault).toList();
    if (byName.length == 1) return byName.first;
  }
  return models.first;
}
