part of 'chat_providers.dart';

/// A model's control and the option that applies to it now: the user's
/// pick, else the control's default, else none (null).
typedef ModelControlState = ({ModelControl control, String? value});

/// [model]'s controls with the option that applies to each under [choices].
/// A pick the control no longer offers counts as none.
List<ModelControlState> modelControlStates(
  Model? model,
  ModelControlChoices choices,
) {
  final controls = modelControlsOf(model);
  if (controls.isEmpty || model == null) return const <ModelControlState>[];
  final picked = choices[model.id] ?? const <String, String>{};
  return List.unmodifiable([
    for (final control in controls)
      (
        control: control,
        value:
            control.optionFor(picked[control.key])?.value ??
            control.defaultValue,
      ),
  ]);
}

/// The user's picks for model controls (a coding agent's reasoning effort
/// or service tier, say), as their Open WebUI settings hold them, so the web
/// client and this app share them.
///
/// Every turn is sent with the settings as stored on the server, so a pick
/// counts once it is saved. Empty without an Open WebUI account.
final modelControlChoicesProvider =
    AsyncNotifierProvider<ModelControlChoicesNotifier, ModelControlChoices>(
      ModelControlChoicesNotifier.new,
    );

class ModelControlChoicesNotifier extends AsyncNotifier<ModelControlChoices> {
  @override
  Future<ModelControlChoices> build() async {
    ref.watch(openWebUiAuthSessionEpochProvider);
    final api = ref.watch(apiServiceProvider);
    if (api == null || !ref.watch(openWebUiAccountAvailableProvider)) {
      return const <String, Map<String, String>>{};
    }
    // Open WebUI refuses a turn whose saved pick its model no longer offers.
    // Clear such a pick as soon as the model is chosen, rather than let the
    // next message fail.
    ref.listen<Model?>(selectedModelProvider, (previous, next) {
      if (next != null) unawaited(_clearStalePicks(next));
    });
    final settings = await api.getUserSettings();
    final choices = modelControlChoicesFromSettings(settings);
    final selected = ref.read(selectedModelProvider);
    if (selected != null) {
      // The choices become this notifier's state only after build returns,
      // so the check reads them as loaded.
      Future.microtask(() {
        if (ref.mounted) {
          unawaited(_clearStalePicks(selected, loaded: choices));
        }
      });
    }
    return choices;
  }

  /// Saves [value] as the pick for [model]'s [controlKey], or clears the
  /// pick when [value] is null. The pick shows at once and is taken back if
  /// the server refuses it; the error is rethrown for the caller to report.
  ///
  /// [loaded] stands in for the state while the first read has not become
  /// it yet.
  Future<void> choose(
    Model model,
    String controlKey,
    String? value, {
    ModelControlChoices? loaded,
  }) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      throw StateError('No Open WebUI account to save the choice to.');
    }
    final previous =
        state.asData?.value ?? loaded ?? const <String, Map<String, String>>{};
    state = AsyncData(_withChoice(previous, model.id, controlKey, value));
    try {
      final stored = await api.updateUserModelControlChoice(
        modelId: model.id,
        controlKey: controlKey,
        value: value,
      );
      if (ref.mounted) state = AsyncData(stored);
    } catch (_) {
      if (ref.mounted) state = AsyncData(previous);
      rethrow;
    }
  }

  Future<void> _clearStalePicks(
    Model model, {
    ModelControlChoices? loaded,
  }) async {
    final controls = modelControlsOf(model);
    if (controls.isEmpty) return;
    final picked = (state.asData?.value ?? loaded)?[model.id];
    if (picked == null) return;
    for (final control in controls) {
      final value = picked[control.key];
      if (value == null || control.optionFor(value) != null) continue;
      try {
        await choose(model, control.key, null, loaded: loaded);
      } catch (error) {
        DebugLogger.warning(
          'model-control-clear-failed',
          scope: 'chat/model-controls',
          data: {'error': error.runtimeType.toString()},
        );
      }
    }
  }
}

ModelControlChoices _withChoice(
  ModelControlChoices choices,
  String modelId,
  String controlKey,
  String? value,
) {
  final forModel = Map<String, String>.of(
    choices[modelId] ?? const <String, String>{},
  );
  if (value == null) {
    forModel.remove(controlKey);
  } else {
    forModel[controlKey] = value;
  }
  return Map.unmodifiable({
    ...choices,
    modelId: Map<String, String>.unmodifiable(forModel),
  });
}

/// The selected model's controls, each with the option that applies now.
/// Empty while the picks are loading or the model has no controls.
final selectedModelControlStatesProvider = Provider<List<ModelControlState>>((
  ref,
) {
  final model = ref.watch(selectedModelProvider);
  if (modelControlsOf(model).isEmpty) return const <ModelControlState>[];
  final choices =
      ref.watch(modelControlChoicesProvider).asData?.value ??
      const <String, Map<String, String>>{};
  return modelControlStates(model, choices);
});
