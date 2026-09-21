part of 'app_providers.dart';

/// Tracks a pending folder ID for the next new conversation.
///
/// When a user starts a new chat from within a folder context menu,
/// this provider holds the folder ID so that the conversation is
/// automatically placed in that folder upon creation.
@Riverpod(keepAlive: true)
class PendingFolderId extends _$PendingFolderId {
  @override
  String? build() => null;

  void set(String? folderId) => state = folderId;

  void clear() => state = null;
}

// Track if the current model selection is manual (user-selected) or automatic (default)
@Riverpod(keepAlive: true)
class IsManualModelSelection extends _$IsManualModelSelection {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

// Auto-apply model-specific tools when model changes or tools load
final modelToolsAutoSelectionProvider = Provider<void>((ref) {
  // Prevent disposal so listeners remain active throughout app lifecycle
  ref.keepAlive();

  Future<void> applyTools(Model? model) async {
    List<String> preserveDirectServerSelections(List<String> ids) {
      return ids
          .where(
            (id) =>
                id.startsWith('direct_server:') ||
                id.startsWith(kDirectMcpToolIdPrefix),
          )
          .toList();
    }

    // Skip if not authenticated - prevents API calls after logout
    final authState = ref.read(authStateManagerProvider).asData?.value;
    if (authState == null || !authState.isAuthenticated) {
      final current = ref.read(selectedToolIdsProvider);
      final preserved = preserveDirectServerSelections(current);
      if (!const ListEquality<Object?>().equals(current, preserved)) {
        ref.read(selectedToolIdsProvider.notifier).set(preserved);
      }
      return;
    }

    if (model == null) {
      final current = ref.read(selectedToolIdsProvider);
      final preserved = preserveDirectServerSelections(current);
      if (!const ListEquality<Object?>().equals(current, preserved)) {
        ref.read(selectedToolIdsProvider.notifier).set(preserved);
      }
      return;
    }

    final modelToolIds = model.toolIds ?? [];
    if (modelToolIds.isEmpty) {
      final current = ref.read(selectedToolIdsProvider);
      final preserved = preserveDirectServerSelections(current);
      if (!const ListEquality<Object?>().equals(current, preserved)) {
        ref.read(selectedToolIdsProvider.notifier).set(preserved);
      }
      return;
    }

    void updateSelection(List<Tool> availableTools) {
      final validToolIds = modelToolIds
          .where((id) => availableTools.any((tool) => tool.id == id))
          .toList();

      final currentSelection = ref.read(selectedToolIdsProvider);
      final preserved = preserveDirectServerSelections(currentSelection);
      final nextSelection = [...validToolIds, ...preserved];
      if (validToolIds.isEmpty) {
        if (!const ListEquality<Object?>().equals(
          currentSelection,
          preserved,
        )) {
          ref.read(selectedToolIdsProvider.notifier).set(preserved);
        }
        return;
      }
      if (const ListEquality<Object?>().equals(
        currentSelection,
        nextSelection,
      )) {
        return;
      }

      ref.read(selectedToolIdsProvider.notifier).set(nextSelection);
      DebugLogger.log(
        'auto-apply-tools',
        scope: 'models/tools',
        data: {
          'backend': _modelBackendForDiagnostics(model),
          'toolCount': validToolIds.length,
          'source': 'selection',
        },
      );
    }

    final toolsAsync = ref.read(toolsListProvider);
    if (toolsAsync.hasValue) {
      updateSelection(toolsAsync.value ?? const <Tool>[]);
      return;
    }

    try {
      final availableTools = await ref.read(toolsListProvider.future);
      if (!ref.mounted) return;
      updateSelection(availableTools);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'auto-apply-tools-failed',
        scope: 'models/tools',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> scheduleApply(Model? model) async {
    await applyTools(model);
  }

  Future.microtask(() => scheduleApply(ref.read(selectedModelProvider)));

  ref.listen<Model?>(selectedModelProvider, (previous, next) {
    if (previous?.id == next?.id && previous != null) {
      return;
    }
    Future.microtask(() => scheduleApply(next));
  });

  ref.listen(toolsListProvider, (previous, next) {
    if (!next.hasValue) return;
    Future.microtask(() => scheduleApply(ref.read(selectedModelProvider)));
  });
});

// Auto-apply model-specific terminal defaults when model changes.
final modelTerminalAutoSelectionProvider = Provider<void>((ref) {
  ref.keepAlive();

  String? extractModelTerminalId(Model? model) {
    final info = model?.metadata?['info'];
    if (info is! Map) {
      return null;
    }

    final infoMeta = info['meta'];
    if (infoMeta is! Map) {
      return null;
    }

    final terminalId = infoMeta['terminalId']?.toString().trim();
    if (terminalId == null || terminalId.isEmpty) {
      return null;
    }

    return terminalId;
  }

  void applyTerminalSelection(Model? model) {
    final terminalId = extractModelTerminalId(model);
    if (terminalId == null) {
      return;
    }

    if (ref.read(selectedTerminalIdProvider) == terminalId) {
      return;
    }

    ref.read(selectedTerminalIdProvider.notifier).set(terminalId);
    DebugLogger.log(
      'auto-apply-terminal',
      scope: 'models/terminal',
      data: {
        'backend': _modelBackendForDiagnostics(model),
        'source': 'selection',
      },
    );
  }

  Future.microtask(
    () => applyTerminalSelection(ref.read(selectedModelProvider)),
  );

  ref.listen<Model?>(selectedModelProvider, (previous, next) {
    Future.microtask(() => applyTerminalSelection(next));
  });
});

// Auto-clear invalid filter selections when model changes
// Filters are model-specific, so we need to validate selections against new model
final modelFiltersAutoSelectionProvider = Provider<void>((ref) {
  // Prevent disposal so listeners remain active throughout app lifecycle
  ref.keepAlive();

  void validateFilters(Model? model) {
    final currentFilterIds = ref.read(selectedFilterIdsProvider);
    if (currentFilterIds.isEmpty) return;

    // Get available filters from the model
    final availableFilters = model?.filters ?? const [];
    final validFilterIds = availableFilters.map((f) => f.id).toSet();

    // Filter out any selected IDs that aren't valid for this model
    final validSelection = currentFilterIds
        .where((id) => validFilterIds.contains(id))
        .toList();

    // Only update if something changed
    if (validSelection.length != currentFilterIds.length) {
      ref.read(selectedFilterIdsProvider.notifier).set(validSelection);
      DebugLogger.log(
        'filter-selection-validated',
        scope: 'models/filters',
        data: {
          'backend': _modelBackendForDiagnostics(model),
          'previousCount': currentFilterIds.length,
          'validCount': validSelection.length,
          'source': 'selection',
        },
      );
    }
  }

  // Validate on model change
  ref.listen<Model?>(selectedModelProvider, (previous, next) {
    if (previous?.id == next?.id && previous != null) {
      return;
    }
    Future.microtask(() => validateFilters(next));
  });
});

// Auto-apply default model from settings when it changes (and not manually overridden)
// keepAlive to maintain listener throughout app lifecycle
final defaultModelAutoSelectionProvider = Provider<void>((ref) {
  // Prevent disposal so listeners remain active throughout app lifecycle
  ref.keepAlive();

  // Initialize the model tools and filters auto-selection
  ref.watch(modelToolsAutoSelectionProvider);
  ref.watch(modelTerminalAutoSelectionProvider);
  ref.watch(modelFiltersAutoSelectionProvider);
  ref.watch(modelsProvider);
  ref.watch(defaultModelProvider);

  ref.listen<AppSettings>(appSettingsProvider, (previous, next) {
    // Only react when default model value changes
    if (previous?.defaultModel == next.defaultModel) return;

    // Reset manual selection flag when default model setting changes
    ref.read(isManualModelSelectionProvider.notifier).set(false);

    final desired = next.defaultModel;

    // If auto-select (null), invalidate defaultModelProvider to re-fetch server default
    if (desired == null || desired.isEmpty) {
      DebugLogger.log('auto-select-enabled', scope: 'models/default');
      ref.invalidate(defaultModelProvider);
      // Trigger re-read to apply server default
      Future(() async {
        try {
          await ref.read(defaultModelProvider.future);
        } catch (e) {
          DebugLogger.error(
            'auto-select-failed',
            scope: 'models/default',
            error: e,
          );
        }
      });
      return;
    }

    // Resolve the desired model against available models (by ID only)
    Future(() async {
      try {
        // Prefer already-loaded models to avoid unnecessary fetches
        List<Model> models;
        final modelsAsync = ref.read(modelsProvider);
        if (modelsAsync.hasValue) {
          models = modelsAsync.value!;
        } else {
          models = await ref.read(modelsProvider.future);
        }
        Model? selected;
        try {
          selected = ref
              .read(directModelRegistryProvider)
              .resolveOpenWebUiWireModel(models, desired);
          selected ??= models.firstWhere((model) => model.id == desired);
        } catch (_) {
          selected = null;
        }

        final current = ref.read(selectedModelProvider);
        if (selected == null &&
            current != null &&
            !current.isHidden &&
            models.any((model) => model.id == current.id)) {
          selected = models.firstWhere((model) => model.id == current.id);
        }

        selected ??= models.isNotEmpty ? models.first : null;

        if (selected != null) {
          ref.read(selectedModelProvider.notifier).set(selected);
          DebugLogger.log(
            'auto-apply',
            scope: 'models/default',
            data: {
              'backend': _modelBackendForDiagnostics(selected),
              'source': 'preference',
            },
          );
        }
      } catch (e) {
        DebugLogger.error(
          'auto-select-failed',
          scope: 'models/default',
          error: e,
        );
      }
    });
  });
});
