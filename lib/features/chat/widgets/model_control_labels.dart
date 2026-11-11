import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/chat/providers/reasoning_effort_provider.dart'
    show kAutomaticReasoningEffort;
import 'package:conduit_core/models/model_controls.dart';

/// A reasoning effort as the app names it (`High` for `high`); a value it
/// has no name for is shown as given.
String reasoningEffortDisplayLabel(AppLocalizations l10n, String effort) =>
    switch (effort) {
      kAutomaticReasoningEffort => l10n.ollamaThinkingAutomatic,
      'low' => l10n.reasoningEffortLow,
      'medium' => l10n.reasoningEffortMedium,
      'high' => l10n.reasoningEffortHigh,
      'light' => l10n.reasoningEffortLight,
      'moderate' => l10n.reasoningEffortModerate,
      'deep' => l10n.reasoningEffortDeep,
      'minimal' => l10n.reasoningEffortMinimal,
      'xhigh' => l10n.reasoningEffortExtraHigh,
      'max' => l10n.reasoningEffortMaximum,
      'none' => l10n.reasoningEffortNone,
      _ => effort,
    };

/// The control's name in the app's language for the two Open WebUI's coding
/// agents use; any other keeps the name the server gives it.
String modelControlTitle(AppLocalizations l10n, ModelControl control) =>
    switch (control.key) {
      kReasoningEffortModelControl => l10n.reasoningEffort,
      'service_tier' => l10n.modelControlServiceTier,
      _ => control.label,
    };

/// The option [value] of [control], in the app's language where it knows
/// the value, or "Default" when nothing is picked and the control has no
/// default.
String modelControlOptionLabel(
  AppLocalizations l10n,
  ModelControl control,
  String? value,
) {
  final option = control.optionFor(value);
  if (option == null) return l10n.defaultLabel;
  if (control.key == kReasoningEffortModelControl) {
    final known = reasoningEffortDisplayLabel(l10n, option.value);
    if (known != option.value) return known;
  }
  return option.label;
}
