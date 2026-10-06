import 'package:conduit_core/models/chat_comparison.dart';
import 'package:conduit_core/services/chat_completion_transport.dart';

/// What the group-wide settings check needs to know about one selected model.
///
/// Open WebUI copies one `params` object to every answer of a multi-model
/// request, so a model-specific parameter is only meaningful when every
/// selected model would read it the same way.
final class ComparisonModelProfile {
  const ComparisonModelProfile({
    required this.modelId,
    required this.supportsReasoningEffort,
    required this.pickerReasoningEffort,
    required this.acceptsReasoningEffort,
  });

  final String modelId;

  /// Whether the model takes `reasoning_effort` at all.
  final bool supportsReasoningEffort;

  /// The effort the picker holds for this model, or null for automatic.
  final String? pickerReasoningEffort;

  /// Whether the model accepts [effort] as a value (an effort the model's own
  /// scale does not contain is not a wire value it can read).
  final bool Function(String effort) acceptsReasoningEffort;
}

enum ComparisonConflictSource {
  /// The chat saved `reasoning_effort` itself.
  chatOverride,

  /// The picker holds different values for the selected models.
  modelPicker,
}

/// A parameter the selected models would not read the same way.
final class ComparisonSettingsConflict {
  const ComparisonSettingsConflict({
    required this.parameter,
    required this.source,
    required this.modelIds,
  });

  /// The request parameter, `reasoning_effort`.
  final String parameter;
  final ComparisonConflictSource source;

  /// The models that cannot honour the value the others would send.
  final List<String> modelIds;
}

const String kComparisonReasoningEffortParam = 'reasoning_effort';

bool _isAutomaticEffort(Object? value) =>
    value == null ||
    (value is String &&
        (value.trim().isEmpty || value.trim().toLowerCase() == 'automatic'));

/// Whether the group can be sent with the chat's own settings and the picker's
/// values, or what stops it.
///
/// An override saved on the chat applies to every answer: each selected model
/// must support the parameter and accept the value. With no override, the
/// picker's per-model values must wire the same way for every model, because
/// the server sends the one value to all of them. Slot order never decides
/// which model's value wins, and nothing is dropped silently.
ComparisonSettingsConflict? findComparisonSettingsConflict({
  required Map<String, dynamic> chatParams,
  required List<ComparisonModelProfile> models,
}) {
  final override = chatParams[kComparisonReasoningEffortParam];
  if (chatParams.containsKey(kComparisonReasoningEffortParam) &&
      !_isAutomaticEffort(override)) {
    final value = override.toString().trim();
    final blocked = [
      for (final model in models)
        if (!model.supportsReasoningEffort ||
            !model.acceptsReasoningEffort(value))
          model.modelId,
    ];
    return blocked.isEmpty
        ? null
        : ComparisonSettingsConflict(
            parameter: kComparisonReasoningEffortParam,
            source: ComparisonConflictSource.chatOverride,
            modelIds: blocked,
          );
  }
  // An explicit "automatic" saved on the chat is a deliberate default that
  // every model reads the same, so the picker's values do not apply.
  if (chatParams.containsKey(kComparisonReasoningEffortParam)) return null;

  // How each model would read the value the request carries. A model that does
  // not take the parameter and one left on automatic both send nothing; only a
  // specific effort is a value the others would have to share.
  String wire(ComparisonModelProfile model) {
    if (!model.supportsReasoningEffort) return 'none';
    final effort = model.pickerReasoningEffort;
    return _isAutomaticEffort(effort) ? 'none' : 'effort:$effort';
  }

  final wires = {for (final model in models) model.modelId: wire(model)};
  if (wires.values.toSet().length <= 1) return null;
  return ComparisonSettingsConflict(
    parameter: kComparisonReasoningEffortParam,
    source: ComparisonConflictSource.modelPicker,
    modelIds: wires.keys.toList(growable: false),
  );
}

/// The `message_ids` entries of [group], in slot order.
List<ChatCompletionTarget> comparisonTargets(ComparisonGroupSnapshot group) => [
  for (final slot in group.slots)
    ChatCompletionTarget(
      modelId: slot.model,
      messageId: slot.assistantMessageId,
      modelIdx: slot.modelIdx,
    ),
];

/// Tells the slot a server task belongs to, by the order the request listed the
/// answers in. The server returns tasks in `message_ids` order and nothing else
/// names them, so a short list leaves the tail slots without a task.
Map<String, String> comparisonTaskIdsBySlot(
  ComparisonGroupSnapshot group,
  List<String> taskIds,
) {
  return {
    for (var i = 0; i < group.slots.length && i < taskIds.length; i++)
      group.slots[i].assistantMessageId: taskIds[i],
  };
}
