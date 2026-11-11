import 'package:meta/meta.dart';

import 'model.dart';

/// One choice a model's control offers: the value Open WebUI stores for it,
/// and the label to show.
@immutable
final class ModelControlOption {
  const ModelControlOption({required this.value, required this.label});

  final String value;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is ModelControlOption &&
      other.value == value &&
      other.label == label;

  @override
  int get hashCode => Object.hash(value, label);
}

/// A setting a model offers beside its name, such as a coding agent's
/// reasoning effort or service tier.
///
/// Open WebUI keeps them in the model's `info.params.model_controls`, keyed
/// by [key]; each option expands, on the server, into the parameters the
/// model takes. A user's pick is stored per model in their settings, at
/// `ui.params.model_controls.<model id>.<key>`, and sent with every turn.
@immutable
final class ModelControl {
  const ModelControl({
    required this.key,
    required this.label,
    required this.options,
    this.description,
    this.defaultValue,
  });

  final String key;
  final String label;
  final String? description;

  /// The choices, in the order the server lists them.
  final List<ModelControlOption> options;

  /// The option that applies while the user has picked none, if any.
  final String? defaultValue;

  /// The option with [value], or null when this control offers none.
  ModelControlOption? optionFor(String? value) {
    if (value == null) return null;
    for (final option in options) {
      if (option.value == value) return option;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is ModelControl &&
      other.key == key &&
      other.label == label &&
      other.description == description &&
      other.defaultValue == defaultValue &&
      _listEquals(other.options, options);

  @override
  int get hashCode => Object.hash(
    key,
    label,
    description,
    defaultValue,
    Object.hashAll(options),
  );
}

bool _listEquals(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The key Open WebUI uses for a reasoning-effort control.
const String kReasoningEffortModelControl = 'reasoning_effort';

/// The controls [model] offers, in the order the server lists them. Empty
/// for a model with none, and for one whose controls cannot be read.
List<ModelControl> modelControlsOf(Model? model) {
  final info = model?.metadata?['info'];
  final params = info is Map ? info['params'] : null;
  final raw = params is Map ? params['model_controls'] : null;
  if (raw is! Map) return const <ModelControl>[];
  final controls = <ModelControl>[];
  for (final entry in raw.entries) {
    final key = entry.key.toString().trim();
    final value = entry.value;
    if (key.isEmpty || value is! Map) continue;
    final rawOptions = value['options'];
    if (rawOptions is! Map) continue;
    final options = <ModelControlOption>[
      for (final option in rawOptions.entries)
        if (option.key.toString().isNotEmpty)
          ModelControlOption(
            value: option.key.toString(),
            label:
                _text(option.value is Map ? option.value['label'] : null) ??
                option.key.toString(),
          ),
    ];
    if (options.isEmpty) continue;
    final defaultValue = value['default']?.toString();
    controls.add(
      ModelControl(
        key: key,
        label: _text(value['label']) ?? key,
        description: _text(value['description']),
        options: List.unmodifiable(options),
        defaultValue: options.any((option) => option.value == defaultValue)
            ? defaultValue
            : null,
      ),
    );
  }
  return List.unmodifiable(controls);
}

/// Whether [model] has a control of its own for reasoning effort, which
/// then takes the place of the app's own effort picker.
bool modelHasReasoningEffortControl(Model? model) =>
    modelControlsOf(model)
        .any((control) => control.key == kReasoningEffortModelControl);

String? _text(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

/// The user's picks for every model's controls, as stored in their Open
/// WebUI settings: model id, then control key, then the option's value.
typedef ModelControlChoices = Map<String, Map<String, String>>;

/// The picks out of a settings document's `ui.params.model_controls`. A
/// document without them, or with a malformed entry, yields what it can.
ModelControlChoices modelControlChoicesFromSettings(
  Map<String, dynamic>? settings,
) {
  final ui = settings?['ui'];
  final params = ui is Map ? ui['params'] : null;
  final raw = params is Map ? params['model_controls'] : null;
  if (raw is! Map) return const <String, Map<String, String>>{};
  return Map.unmodifiable({
    for (final entry in raw.entries)
      if (entry.value is Map)
        entry.key.toString(): Map<String, String>.unmodifiable({
          for (final choice in (entry.value as Map).entries)
            if (choice.value is String)
              choice.key.toString(): choice.value as String,
        }),
  });
}

/// [settings] with the pick for [modelId]'s [controlKey] set to [value], or
/// removed when [value] is null, as the web client stores it.
///
/// The picks live in `ui.params`, which the server reads for every turn. A
/// document that still keeps its params only at the legacy root starts its
/// `ui.params` from a copy of them: a present `ui.params` replaces the root
/// one, and the account's other defaults must not drop out with this pick.
Map<String, dynamic> settingsWithModelControlChoice(
  Map<String, dynamic> settings, {
  required String modelId,
  required String controlKey,
  required String? value,
}) {
  final next = Map<String, dynamic>.of(settings);
  final ui = next['ui'] is Map
      ? Map<String, dynamic>.of(
          (next['ui'] as Map).map((k, v) => MapEntry(k.toString(), v)),
        )
      : <String, dynamic>{};
  final Map<String, dynamic> params;
  if (ui['params'] is Map) {
    params = Map<String, dynamic>.of(
      (ui['params'] as Map).map((k, v) => MapEntry(k.toString(), v)),
    );
  } else if (next['params'] is Map) {
    params = Map<String, dynamic>.of(
      (next['params'] as Map).map((k, v) => MapEntry(k.toString(), v)),
    );
  } else {
    params = <String, dynamic>{};
  }
  final controls = params['model_controls'] is Map
      ? Map<String, dynamic>.of(
          (params['model_controls'] as Map).map(
            (k, v) => MapEntry(k.toString(), v),
          ),
        )
      : <String, dynamic>{};
  final forModel = controls[modelId] is Map
      ? Map<String, dynamic>.of(
          (controls[modelId] as Map).map((k, v) => MapEntry(k.toString(), v)),
        )
      : <String, dynamic>{};
  if (value == null) {
    forModel.remove(controlKey);
  } else {
    forModel[controlKey] = value;
  }
  controls[modelId] = forModel;
  params['model_controls'] = controls;
  ui['params'] = params;
  next['ui'] = ui;
  return next;
}
