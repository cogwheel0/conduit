part of 'app_providers.dart';

// Model providers
@visibleForTesting
List<Model> appendHermesModelIfUsable(
  List<Model> models, {
  required bool hermesUsable,
  bool allowSyntheticHermesModel = true,
  List<Model> hermesModels = const [],
}) {
  final directModels = models.where(isLocallyMintedDirectModel);
  final safeModels = sanitizeRemoteHermesModels(
    sanitizeRemoteDirectModels(models),
  );
  return hermesUsable
      ? <Model>[
          ...safeModels,
          ...directModels,
          if (allowSyntheticHermesModel) hermesSyntheticModel(),
          ...hermesModels,
        ]
      : <Model>[...safeModels, ...directModels];
}

bool _sameModelCacheOwnership(
  OpenWebUiCacheOwnershipSnapshot? previous,
  OpenWebUiCacheOwnershipSnapshot next,
) =>
    previous != null &&
    identical(previous.api, next.api) &&
    previous.serverId == next.serverId &&
    previous.activeServerId == next.activeServerId &&
    identical(previous.authSessionEpoch, next.authSessionEpoch) &&
    previous.authToken == next.authToken &&
    previous.authenticated == next.authenticated &&
    previous.databaseAccessPhase == next.databaseAccessPhase &&
    previous.certifiedDatabaseServerId == next.certifiedDatabaseServerId &&
    previous.rawActiveServerId == next.rawActiveServerId;

String _modelBackendForDiagnostics(Model? model) {
  if (model == null) return 'none';
  if (isLocallyMintedDirectModel(model)) return 'direct';
  if (isHermesModel(model)) return 'hermes';
  return 'openwebui';
}

@Riverpod(keepAlive: true)
class Models extends _$Models {
  bool _terminalDirectDiscoveryNeedsReconciliation = false;
  Future<void>? _refreshInFlight;
  OpenWebUiCacheOwnershipSnapshot? _warmRefreshOwnership;

  @override
  Future<List<Model>> build() async {
    // Reviewer mode returns mock models
    if (ref.watch(reviewerModeProvider)) {
      return _demoModels();
    }

    final hermesUsable = ref.watch(
      hermesConfigProvider.select((config) => config.isUsable),
    );
    final hermesMode = ref.watch(
      hermesConfigProvider.select((config) => config.mode),
    );
    if (hermesUsable && hermesMode == HermesBackendMode.desktopGateway) {
      try {
        await ref.watch(hermesDesktopModelsProvider.future);
      } catch (error, stackTrace) {
        DebugLogger.error(
          'desktop-discovery-failed',
          scope: 'models/hermes',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    final directModels = ref.watch(
      directModelDiscoveryProvider.select((value) {
        final models = value.value?.models;
        // Keep loading -> empty discovery transitions referentially stable.
        // Otherwise an empty, newly wrapped list can cancel a concurrent
        // modelsProvider rebuild and leave callers awaiting its old future.
        return models == null || models.isEmpty ? const <Model>[] : models;
      }),
    );
    // Initial discovery loading is reconciliation context, not a model-list
    // dependency. Watching it would turn loading -> empty into an otherwise
    // spurious rebuild and could cancel a concurrent Hermes/auth rebuild.
    final directDiscovery = ref.read(directModelDiscoveryProvider);
    final deferDirectSelectionReconciliation =
        directDiscovery.isLoading && !directDiscovery.hasValue;
    // A backend switch must also reconcile a keepAlive model selection. This
    // is especially important after OpenWebUI logout, where the old remote
    // model can otherwise survive while the retained server remains present.
    ref.watch(preferredBackendProvider);
    ref.listen<AsyncValue<DirectModelDiscoveryState>>(
      directModelDiscoveryProvider,
      _handleDirectDiscoveryTransition,
    );
    ref.listen<bool>(hermesConfigProvider.select((config) => config.isUsable), (
      previous,
      next,
    ) {
      if (!next) _clearHermesSelection();
    });
    if (!hermesUsable) {
      // A build cannot synchronously mutate another provider. Queue the clear
      // before any model fetch so a failed cache/API load still fails closed.
      unawaited(
        Future<void>(() {
          if (ref.mounted && !ref.read(hermesConfigProvider).isUsable) {
            _clearHermesSelection();
          }
        }),
      );
    }

    final modelAuth = ref.watch(_modelAuthReadinessProvider);
    // `isAuthenticated` is false during a token-preserving refresh too. Watch
    // the richer auth signals so loading -> terminal sign-out triggers a
    // second reconciliation without clobbering a live mixed-mode selection in
    // the transient loading state.
    if (!modelAuth.authenticated && _modelAuthIsPending(modelAuth)) {
      // Pending credentials are not authority for cache/API work. Preserve an
      // already-rendered in-memory list until auth reaches a terminal state;
      // on cold start, expose only app-owned transports without mutating the
      // persisted OpenWebUI cache.
      final previous = state.value;
      if (previous != null) return previous;
      return _returnWithSelectionReconciliation(
        _withLocalModels(const <Model>[], directModels: directModels),
        deferDirectSelection: deferDirectSelectionReconciliation,
      );
    }
    if (!_modelAuthRetainsOpenWebUiSession(modelAuth)) {
      // Standalone mode surfaces app-owned transports without requiring an
      // Open WebUI session.
      final localModels = _withLocalModels(
        const <Model>[],
        directModels: directModels,
      );
      if (localModels.isNotEmpty) {
        return _returnWithSelectionReconciliation(
          localModels,
          deferDirectSelection: deferDirectSelectionReconciliation,
        );
      }
      DebugLogger.log('skip-unauthed', scope: 'models');
      _persistModelsAsync(const <Model>[]);
      return _returnWithSelectionReconciliation(
        const <Model>[],
        deferDirectSelection: deferDirectSelectionReconciliation,
      );
    }

    // These ownership dependencies fence only OpenWebUI cache/API work. Do
    // not initialize or subscribe to server storage in accountless
    // Direct/Hermes mode: doing so can repeatedly cancel the otherwise
    // synchronous local-model build while an optional retained server settles.
    ref.watch(openWebUiAuthSessionEpochProvider);
    ref.watch(openWebUiDatabaseAccessProvider);
    ref.watch(openWebUiCertifiedDatabaseServerProvider);
    ref.watch(activeServerProvider.select((value) => value.value?.id));

    // Re-run whenever Hermes connection usability changes so the synthetic
    // model cannot outlive (or appear before) its configured service.
    final api = ref.watch(apiServiceProvider);
    final cacheOwnership = api == null
        ? null
        : captureOpenWebUiCacheOwnership(
            ref,
            api: api,
            requireAuthenticated: false,
          );
    if (api != null && cacheOwnership == null) {
      return _returnWithSelectionReconciliation(
        _withLocalModels(const <Model>[], directModels: directModels),
        deferDirectSelection: deferDirectSelectionReconciliation,
      );
    }
    final storage = ref.watch(optimizedStorageServiceProvider);
    try {
      final cached = await storage.getLocalModels();
      if (cacheOwnership != null &&
          !openWebUiCacheOwnershipIsCurrent(ref, cacheOwnership)) {
        return _returnWithSelectionReconciliation(
          _withLocalModels(const <Model>[], directModels: directModels),
          deferDirectSelection: deferDirectSelectionReconciliation,
        );
      }
      if (cached.isNotEmpty) {
        final visibleCached = sanitizeRemoteHermesModels(
          sanitizeRemoteDirectModels(_visibleModels(cached)),
        );
        DebugLogger.log(
          'cache-restored',
          scope: 'models/cache',
          data: {
            'count': visibleCached.length,
            'hidden': cached.length - visibleCached.length,
          },
        );
        if (visibleCached.length != cached.length && cacheOwnership != null) {
          _persistModelsAsync(visibleCached, ownership: cacheOwnership);
        }
        if (cacheOwnership != null &&
            !_sameModelCacheOwnership(_warmRefreshOwnership, cacheOwnership)) {
          _warmRefreshOwnership = cacheOwnership;
          Future.microtask(() async {
            if (!ref.mounted) return;
            try {
              await refresh();
            } catch (error, stackTrace) {
              DebugLogger.error(
                'warm-refresh-failed',
                scope: 'models/cache',
                error: error,
                stackTrace: stackTrace,
              );
            }
          });
        }
        return _returnWithSelectionReconciliation(
          _withLocalModels(visibleCached, directModels: directModels),
          deferDirectSelection: deferDirectSelectionReconciliation,
        );
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'cache-load-failed',
        scope: 'models/cache',
        error: error,
        stackTrace: stackTrace,
      );
    }

    if (api == null) {
      DebugLogger.warning('api-missing', scope: 'models');
      _persistModelsAsync(const <Model>[]);
      return _returnWithSelectionReconciliation(
        _withLocalModels(const <Model>[], directModels: directModels),
        deferDirectSelection: deferDirectSelectionReconciliation,
      );
    }

    try {
      final loaded = await _load(api);
      if (loaded == null ||
          !openWebUiCacheOwnershipIsCurrent(ref, loaded.ownership)) {
        return _returnWithSelectionReconciliation(
          _withLocalModels(const <Model>[], directModels: directModels),
          deferDirectSelection: deferDirectSelectionReconciliation,
        );
      }
      return _returnWithSelectionReconciliation(
        _withLocalModels(loaded.models, directModels: directModels),
        deferDirectSelection: deferDirectSelectionReconciliation,
      );
    } catch (_) {
      final localModels = _withLocalModels(
        const <Model>[],
        directModels: directModels,
      );
      if (localModels.isNotEmpty) {
        return _returnWithSelectionReconciliation(
          localModels,
          deferDirectSelection: deferDirectSelectionReconciliation,
        );
      }
      _returnWithSelectionReconciliation(
        localModels,
        deferDirectSelection: deferDirectSelectionReconciliation,
      );
      rethrow;
    }
  }

  List<Model> _returnWithSelectionReconciliation(
    List<Model> models, {
    bool deferDirectSelection = false,
  }) {
    unawaited(
      Future<void>(() {
        if (ref.mounted) {
          final reconcileTerminalDiscovery =
              _terminalDirectDiscoveryNeedsReconciliation;
          if (reconcileTerminalDiscovery) {
            _terminalDirectDiscoveryNeedsReconciliation = false;
          }
          _reconcileLocalSelection(
            models,
            deferDirectSelection:
                deferDirectSelection && !reconcileTerminalDiscovery,
          );
        }
      }),
    );
    return models;
  }

  void _handleDirectDiscoveryTransition(
    AsyncValue<DirectModelDiscoveryState>? previous,
    AsyncValue<DirectModelDiscoveryState> next,
  ) {
    final isInitialLoading = next.isLoading && !next.hasValue;
    if (isInitialLoading) {
      _terminalDirectDiscoveryNeedsReconciliation = false;
      return;
    }
    final wasInitialLoading =
        previous?.isLoading == true && previous?.hasValue == false;
    if (!wasInitialLoading) return;

    final discoveredModels = next.value?.models ?? const <Model>[];
    if (discoveredModels.isNotEmpty) {
      _terminalDirectDiscoveryNeedsReconciliation = false;
      return;
    }

    _terminalDirectDiscoveryNeedsReconciliation = true;
    unawaited(
      Future<void>(() {
        if (!ref.mounted ||
            !_terminalDirectDiscoveryNeedsReconciliation ||
            (state.isLoading && !state.hasValue)) {
          return;
        }
        _terminalDirectDiscoveryNeedsReconciliation = false;
        _reconcileLocalSelection(state.value ?? const <Model>[]);
      }),
    );
  }

  /// Appends locally minted direct/Hermes models after the OpenWebUI list has
  /// been sanitized and persisted. Local transport models remain runtime-only.
  List<Model> _withLocalModels(
    List<Model> models, {
    List<Model>? directModels,
  }) {
    final withDirect = reconcileDirectModelsForDisplay(
      remoteModels: models,
      directModels:
          directModels ??
          ref.read(directModelDiscoveryProvider).value?.models ??
          const <Model>[],
      registry: ref.read(directModelRegistryProvider),
    );
    final hermesConfig = ref.read(hermesConfigProvider);
    return appendHermesModelIfUsable(
      withDirect,
      hermesUsable: hermesConfig.isUsable,
      allowSyntheticHermesModel: true,
      hermesModels: hermesConfig.mode == HermesBackendMode.desktopGateway
          ? ref.read(hermesDesktopModelsProvider).asData?.value ?? const []
          : const [],
    );
  }

  /// Prevents a disabled or incomplete Hermes connection from leaving the
  /// composer bound to a transport that can no longer handle the selection.
  /// Prefer the first available OpenWebUI model; Hermes-only mode clears it.
  List<Model> _reconcileLocalSelection(
    List<Model> models, {
    bool deferDirectSelection = false,
  }) {
    final currentSelected = ref.read(selectedModelProvider);
    final modelAuth = ref.read(_modelAuthReadinessProvider);
    if (!modelAuth.authenticated) {
      final shouldReconcile = _shouldUseAccountlessModelSelection(
        isAuthenticated: false,
        isAuthLoading: modelAuth.loading,
        authStatus: modelAuth.status,
        preferredBackend: ref.read(preferredBackendProvider),
        hasApiService: ref.read(apiServiceProvider) != null,
      );
      if (!shouldReconcile) return models;

      if (deferDirectSelection &&
          currentSelected != null &&
          isLocallyMintedDirectModel(currentSelected)) {
        return models;
      }

      final replacement = _accountlessSelection(
        models: models,
        current: currentSelected,
        preferredBackend: ref.read(preferredBackendProvider),
        preferredModelId:
            currentSelected != null && ref.read(isManualModelSelectionProvider)
            ? null
            : ref.read(appSettingsProvider).defaultModel,
      );
      if (identical(currentSelected, replacement)) return models;

      // Rebinding the same trusted model id after discovery should preserve a
      // deliberate manual selection. Crossing transports (or clearing a stale
      // remote selection) restores automatic selection semantics.
      if (currentSelected?.id != replacement?.id) {
        ref.read(isManualModelSelectionProvider.notifier).set(false);
      }
      ref.read(selectedModelProvider.notifier).set(replacement);
      DebugLogger.warning(
        'accountless-selection-reconciled',
        scope: 'models',
        data: {
          'previousBackend': _modelBackendForDiagnostics(currentSelected),
          'replacementBackend': _modelBackendForDiagnostics(replacement),
          'source': 'reconciliation',
        },
      );
      return models;
    }

    final isLocalTransport =
        currentSelected != null &&
        (isHermesModel(currentSelected) ||
            isLocallyMintedDirectModel(currentSelected));
    if (currentSelected == null || !isLocalTransport) {
      return models;
    }
    if (deferDirectSelection && isLocallyMintedDirectModel(currentSelected)) {
      return models;
    }

    final matching = models
        .where((model) => model.id == currentSelected.id)
        .firstOrNull;
    if (matching != null) {
      if (isLocallyMintedDirectModel(currentSelected)) {
        final registry = ref.read(directModelRegistryProvider);
        if (!identical(matching, currentSelected) ||
            registry.resolve(currentSelected) == null) {
          ref.read(selectedModelProvider.notifier).set(matching);
          DebugLogger.log(
            'direct-selection-rebound',
            scope: 'models',
            data: {'backend': 'direct', 'source': 'discovery'},
          );
        }
      }
      return models;
    }

    final replacement = replacementForUnavailableLocalModel(
      models: models,
      current: currentSelected,
    );
    ref.read(isManualModelSelectionProvider.notifier).set(false);
    ref.read(selectedModelProvider.notifier).set(replacement);
    DebugLogger.warning(
      'local-selection-unavailable',
      scope: 'models',
      data: {
        'replacementBackend': _modelBackendForDiagnostics(replacement),
        'source': 'reconciliation',
      },
    );
    return models;
  }

  void _clearHermesSelection() {
    final currentSelected = ref.read(selectedModelProvider);
    if (currentSelected == null || !isHermesModel(currentSelected)) return;

    ref.read(isManualModelSelectionProvider.notifier).set(false);
    ref.read(selectedModelProvider.notifier).clear();
    DebugLogger.warning('hermes-selection-unavailable', scope: 'models');
  }

  Future<void> refresh() {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;

    late final Future<void> operation;
    operation = _refresh().whenComplete(() {
      if (identical(_refreshInFlight, operation)) {
        _refreshInFlight = null;
      }
    });
    _refreshInFlight = operation;
    return operation;
  }

  Future<void> _refresh() async {
    if (ref.read(reviewerModeProvider)) {
      state = AsyncData<List<Model>>(_reconcileLocalSelection(_demoModels()));
      return;
    }
    await ref.read(directModelDiscoveryProvider.notifier).refresh();
    if (!ref.mounted) return;
    final hermesConfig = ref.read(hermesConfigProvider);
    if (hermesConfig.isUsable &&
        hermesConfig.mode == HermesBackendMode.desktopGateway) {
      ref.invalidate(hermesDesktopModelsProvider);
      try {
        await ref.read(hermesDesktopModelsProvider.future);
      } catch (error, stackTrace) {
        DebugLogger.error(
          'desktop-discovery-refresh-failed',
          scope: 'models/hermes',
          error: error,
          stackTrace: stackTrace,
        );
      }
      if (!ref.mounted) return;
    }
    final modelAuth = ref.read(_modelAuthReadinessProvider);
    if (!modelAuth.authenticated && _modelAuthIsPending(modelAuth)) {
      // An explicit refresh during login/revalidation is deferred. This keeps
      // the current in-memory list intact without treating retained or
      // candidate credentials as permission to touch OpenWebUI cache/API data.
      return;
    }
    if (!_modelAuthRetainsOpenWebUiSession(modelAuth)) {
      final models = _withLocalModels(const <Model>[]);
      state = AsyncData<List<Model>>(_reconcileLocalSelection(models));
      // Keep locally minted transport models runtime-only.
      _persistModelsAsync(const <Model>[]);
      return;
    }
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      state = AsyncData<List<Model>>(
        _reconcileLocalSelection(_withLocalModels(const <Model>[])),
      );
      _persistModelsAsync(const <Model>[]);
      return;
    }
    final result = await AsyncValue.guard(() => _load(api));
    if (!ref.mounted) return;
    final loaded = result.value;
    if (result.hasValue &&
        (loaded == null ||
            !openWebUiCacheOwnershipIsCurrent(ref, loaded.ownership))) {
      return;
    }
    final withLocal = result.whenData(
      (owned) => _reconcileLocalSelection(_withLocalModels(owned!.models)),
    );
    if (withLocal.hasError) {
      final selected = ref.read(selectedModelProvider);
      final preserveRemoteSelection =
          selected != null &&
          !isHermesModel(selected) &&
          !isLocallyMintedDirectModel(selected);
      if (preserveRemoteSelection) {
        // A transient OpenWebUI refresh failure must not replace an active
        // server model with the first standalone transport model.
        state = withLocal;
      } else {
        final localModels = _reconcileLocalSelection(
          _withLocalModels(const <Model>[]),
        );
        state = localModels.isEmpty
            ? withLocal
            : AsyncData<List<Model>>(localModels);
      }
    } else {
      state = withLocal;
    }

    // Update selected model with fresh data (e.g., filters) if it exists
    // in the new models list
    final currentState = state;
    if (currentState.hasValue) {
      final freshModels = currentState.value!;
      final currentSelected = ref.read(selectedModelProvider);
      if (currentSelected != null) {
        if (currentSelected.isHidden) {
          return;
        }
        try {
          final freshModel = freshModels.firstWhere(
            (m) => m.id == currentSelected.id,
          );
          // Update selected model with fresh data (filters, etc.)
          if (freshModel != currentSelected) {
            ref.read(selectedModelProvider.notifier).set(freshModel);
            DebugLogger.log(
              'selected-model-refreshed',
              scope: 'models',
              data: {
                'backend': _modelBackendForDiagnostics(freshModel),
                'filters': freshModel.filters?.length ?? 0,
                'source': 'refresh',
              },
            );
          }
        } catch (_) {
          final replacement = replacementForUnavailableLocalModel(
            models: freshModels,
            current: currentSelected,
          );
          ref.read(isManualModelSelectionProvider.notifier).set(false);
          ref.read(selectedModelProvider.notifier).set(replacement);
          DebugLogger.warning(
            'selected-model-unavailable',
            scope: 'models',
            data: {
              'previousBackend': _modelBackendForDiagnostics(currentSelected),
              'replacementBackend': _modelBackendForDiagnostics(replacement),
              'source': 'refresh',
            },
          );
        }
      }
    }
  }

  Future<_OwnedModels?> _load(ApiService api) async {
    final ownership = captureOpenWebUiCacheOwnership(
      ref,
      api: api,
      requireAuthenticated: false,
    );
    if (ownership == null) return null;
    try {
      DebugLogger.log('fetch-start', scope: 'models');
      final models = await api.getModels();
      if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) return null;
      final visibleModels = sanitizeRemoteHermesModels(
        sanitizeRemoteDirectModels(_visibleModels(models)),
      );
      DebugLogger.log(
        'fetch-ok',
        scope: 'models',
        data: {
          'count': visibleModels.length,
          'hidden': models.length - visibleModels.length,
        },
      );
      _warmRefreshOwnership = ownership;
      _persistModelsAsync(visibleModels, ownership: ownership);
      return (models: visibleModels, ownership: ownership);
    } catch (e, stackTrace) {
      DebugLogger.error(
        'fetch-failed',
        scope: 'models',
        error: e,
        stackTrace: stackTrace,
      );

      // If models endpoint returns 403, this should now clear auth token
      // and redirect user to login since it's marked as a core endpoint
      if (e.toString().contains('403')) {
        DebugLogger.warning('endpoint-403', scope: 'models');
      }
      // Preserve an existing selection on transient refresh failures. Returning
      // an empty list here makes the synthetic Hermes model look like the only
      // successful result and can silently switch an OpenWebUI conversation.
      rethrow;
    }
  }

  List<Model> _visibleModels(List<Model> models) {
    if (models.isEmpty) return const <Model>[];
    return models.where((model) => !model.isHidden).toList();
  }

  void _persistModelsAsync(
    List<Model> models, {
    OpenWebUiCacheOwnershipSnapshot? ownership,
  }) {
    if (ownership != null &&
        !openWebUiCacheOwnershipIsCurrent(ref, ownership)) {
      return;
    }
    final storage = ref.read(optimizedStorageServiceProvider);
    unawaited(
      storage.saveLocalModels(models).onError((error, stack) {
        DebugLogger.error(
          'Failed to persist models to cache',
          scope: 'models/cache',
          error: error,
          stackTrace: stack,
        );
      }),
    );
  }

  List<Model> _demoModels() => const [
    Model(
      id: 'demo/gemma-2-mini',
      name: 'Gemma 2 Mini (Demo)',
      description: 'Demo model for reviewer mode',
      isMultimodal: true,
      supportsStreaming: true,
      supportedParameters: ['max_tokens', 'stream'],
    ),
    Model(
      id: 'demo/llama-3-8b',
      name: 'Llama 3 8B (Demo)',
      description: 'Fast text model for demo',
      isMultimodal: false,
      supportsStreaming: true,
      supportedParameters: ['max_tokens', 'stream'],
    ),
  ];
}

@visibleForTesting
Model? replacementForUnavailableLocalModel({
  required Iterable<Model> models,
  required Model current,
}) {
  if (isHermesModel(current)) {
    return models.where(isHermesModel).firstOrNull ?? models.firstOrNull;
  }
  if (isLocallyMintedDirectModel(current)) {
    return models.where(isLocallyMintedDirectModel).firstOrNull ??
        models.firstOrNull;
  }
  return models.firstOrNull;
}

typedef _OwnedModels = ({
  List<Model> models,
  OpenWebUiCacheOwnershipSnapshot ownership,
});

@Riverpod(keepAlive: true)
class SelectedModel extends _$SelectedModel {
  bool _authenticatedDefaultRestoreScheduled = false;
  bool _accountlessBackendReconciliationPending = false;

  @override
  Model? build() {
    // This provider is consumed before auth and secure Hermes secrets finish
    // hydrating on a cold start. Reconcile again when either one settles;
    // callers such as the chat page only await defaultModelProvider once.
    ref.listen<_ModelAuthReadiness>(_modelAuthReadinessProvider, (
      previous,
      next,
    ) {
      if (next.authenticated) {
        _scheduleAuthenticatedDefaultRestore();
      } else {
        _restorePrimaryAccountlessSelection();
      }
    });
    ref.listen<PreferredBackend>(preferredBackendProvider, (previous, next) {
      _accountlessBackendReconciliationPending =
          next == PreferredBackend.direct || next == PreferredBackend.hermes;
      _schedulePrimaryAccountlessRestore();
    });
    ref.listen<bool>(
      hermesConfigProvider.select((config) => config.isUsable),
      (previous, next) => _schedulePrimaryAccountlessRestore(),
    );
    ref.listen<AsyncValue<DirectModelDiscoveryState>>(
      directModelDiscoveryProvider,
      (previous, next) => _schedulePrimaryAccountlessRestore(),
    );
    ref.listen<ApiService?>(apiServiceProvider, (previous, next) {
      if (next != null) _scheduleAuthenticatedDefaultRestore();
    });
    ref.listen<String?>(authTokenProvider3, (previous, next) {
      if (previous != next &&
          ref.read(_modelAuthReadinessProvider).authenticated) {
        _scheduleAuthenticatedDefaultRestore();
      }
    });

    final initialDecision = _primaryAccountlessDecision(current: null);
    if (initialDecision.shouldReconcile &&
        ref.read(isManualModelSelectionProvider)) {
      // User-scoped sign-out cleanup invalidates the selected model but not the
      // manual-selection bit. Once selection is rebuilt automatically, that
      // bit must not later suppress an authenticated OpenWebUI default.
      unawaited(
        Future<void>.microtask(() {
          if (ref.mounted) {
            ref.read(isManualModelSelectionProvider.notifier).set(false);
          }
        }),
      );
    }
    return initialDecision.model;
  }

  ({bool shouldReconcile, Model? model}) _primaryAccountlessDecision({
    required Model? current,
  }) {
    // Sign-out cleanup invalidates user-scoped model state after auth settles.
    // A retained OpenWebUI server must not make that cleanup erase the primary
    // accountless transport that the router has already admitted to chat.
    final preferredBackend = ref.read(preferredBackendProvider);
    if (preferredBackend != PreferredBackend.hermes &&
        preferredBackend != PreferredBackend.direct) {
      return (shouldReconcile: false, model: null);
    }

    final modelAuth = ref.read(_modelAuthReadinessProvider);
    if (modelAuth.authenticated || modelAuth.loading) {
      return (shouldReconcile: false, model: null);
    }
    if (modelAuth.status == AuthStatus.initial ||
        modelAuth.status == AuthStatus.loading ||
        modelAuth.status == AuthStatus.authenticated) {
      return (shouldReconcile: false, model: null);
    }

    if (preferredBackend == PreferredBackend.hermes) {
      if (!ref.read(hermesConfigProvider).isUsable) {
        // A false value can be the initial secure-secret hydration state.
        // Models owns clearing a connection that is definitively unusable.
        return (shouldReconcile: false, model: null);
      }
      return (
        shouldReconcile: true,
        model: current != null && isHermesModel(current)
            ? current
            : hermesSyntheticModel(),
      );
    }

    final discovery = ref.read(directModelDiscoveryProvider);
    if (discovery.isLoading && !discovery.hasValue) {
      return (shouldReconcile: false, model: null);
    }
    final registry = ref.read(directModelRegistryProvider);
    final trustedModels = (discovery.value?.models ?? const <Model>[])
        .where((model) => registry.resolve(model) != null)
        .toList(growable: false);
    return (
      shouldReconcile: true,
      model: _accountlessSelection(
        models: trustedModels,
        current: current,
        preferredBackend: preferredBackend,
        preferredModelId:
            current != null && ref.read(isManualModelSelectionProvider)
            ? null
            : ref.read(appSettingsProvider).defaultModel,
      ),
    );
  }

  void _schedulePrimaryAccountlessRestore() {
    unawaited(
      Future<void>.microtask(() {
        if (!ref.mounted) return;
        _restorePrimaryAccountlessSelection();
      }),
    );
  }

  void _restorePrimaryAccountlessSelection() {
    if (!ref.mounted) return;
    final current = state;
    if (current != null && ref.read(isManualModelSelectionProvider)) {
      final preferredBackend = ref.read(preferredBackendProvider);
      final manualSelectionIsUsable =
          ref.read(reviewerModeProvider) ||
          switch (preferredBackend) {
            PreferredBackend.direct =>
              isLocallyMintedDirectModel(current) &&
                  ref.read(directModelRegistryProvider).resolve(current) !=
                      null,
            PreferredBackend.hermes =>
              isHermesModel(current) && ref.read(hermesConfigProvider).isUsable,
            _ => false,
          };
      if (manualSelectionIsUsable &&
          (!_accountlessBackendReconciliationPending ||
              _matchesPreferredBackend(current, preferredBackend))) {
        _accountlessBackendReconciliationPending = false;
        return;
      }
    }
    final decision = _primaryAccountlessDecision(current: current);
    if (!decision.shouldReconcile) return;
    final replacement = decision.model;
    final currentBindingIsValid =
        current != null &&
        isLocallyMintedDirectModel(current) &&
        ref.read(directModelRegistryProvider).resolve(current) != null;
    if (current == null && replacement == null) return;
    if (current != null &&
        replacement != null &&
        current.id == replacement.id &&
        (!isLocallyMintedDirectModel(replacement) || currentBindingIsValid)) {
      _accountlessBackendReconciliationPending = false;
      return;
    }

    if (current?.id != replacement?.id) {
      ref.read(isManualModelSelectionProvider.notifier).set(false);
    }
    state = replacement;
    _accountlessBackendReconciliationPending = false;
    DebugLogger.warning(
      'primary-accountless-selection-restored',
      scope: 'models/default',
      data: {
        'previousBackend': _modelBackendForDiagnostics(current),
        'replacementBackend': _modelBackendForDiagnostics(replacement),
        'source': 'reconciliation',
      },
    );
  }

  void _scheduleAuthenticatedDefaultRestore() {
    if (_authenticatedDefaultRestoreScheduled) return;
    _authenticatedDefaultRestoreScheduled = true;
    unawaited(
      Future<void>.microtask(() {
        _authenticatedDefaultRestoreScheduled = false;
        if (!ref.mounted) return;
        final current = state;
        final staleLocalTransport =
            current != null &&
            (isHermesModel(current) || isLocallyMintedDirectModel(current));
        if (current != null && !staleLocalTransport) return;
        final auth = ref.read(_modelAuthReadinessProvider);
        if (!auth.authenticated || ref.read(apiServiceProvider) == null) return;

        // A background saved-credential login can finish after an earlier
        // one-shot read cached null. Force a fresh authenticated resolution.
        // Dispatch instead of awaiting so a later token/session transition can
        // invalidate this attempt and immediately start the authoritative one.
        ref.invalidate(defaultModelProvider);
        final restore = ref.read(defaultModelProvider.future);
        unawaited(
          restore.then<void>(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {
              if (!ref.mounted) return;
              DebugLogger.error(
                'authenticated-default-restore-failed',
                scope: 'models/default',
                error: error,
                stackTrace: stackTrace,
              );
            },
          ),
        );
      }),
    );
  }

  void set(Model? model, {bool allowHidden = false}) {
    if (model?.isHidden == true && !allowHidden) {
      state = null;
      return;
    }
    state = model;
  }

  void clear() => state = null;
}
