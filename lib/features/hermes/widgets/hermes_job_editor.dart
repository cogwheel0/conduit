import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../../l10n/app_localizations_en.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_dropdown_field.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';

import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/models/hermes_job_delivery.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/utils/hermes_schedule_validation.dart';

import 'hermes_job_delivery_field.dart';

/// What the job editor returns. [deliver] and [catchUp] are null when the
/// editor did not offer them or, when editing, the user left them as they
/// were, so an edit never rewrites a value it did not touch.
typedef HermesJobEditorResult = ({
  String name,
  String prompt,
  String schedule,
  String? deliver,
  HermesJobCatchUp? catchUp,
});

/// Shows the create/edit dialog for a scheduled Hermes job, or null if
/// cancelled. [scheduling] adds the missed-run policy and the "Deliver to"
/// checklist, which only the Desktop Gateway's dashboard accepts.
Future<HermesJobEditorResult?> showHermesJobEditor(
  BuildContext context, {
  String? initialName,
  String? initialPrompt,
  String? initialSchedule,
  String? initialDeliver,
  HermesJobCatchUp initialCatchUp = HermesJobCatchUp.hermesDefault,
  bool scheduling = false,
}) {
  return ThemedDialogs.showCustom<HermesJobEditorResult>(
    context: context,
    builder: (context) => _HermesJobEditorDialog(
      initialName: initialName,
      initialPrompt: initialPrompt,
      initialSchedule: initialSchedule,
      initialDeliver: initialDeliver,
      initialCatchUp: initialCatchUp,
      scheduling: scheduling,
    ),
  );
}

String hermesJobCatchUpLabel(AppLocalizations l10n, HermesJobCatchUp value) =>
    switch (value) {
      HermesJobCatchUp.hermesDefault => l10n.hermesJobCatchUpDefault,
      HermesJobCatchUp.runOnce => l10n.hermesJobCatchUpRunOnce,
      HermesJobCatchUp.skip => l10n.hermesJobCatchUpSkip,
    };

class _HermesJobEditorDialog extends StatefulWidget {
  const _HermesJobEditorDialog({
    this.initialName,
    this.initialPrompt,
    this.initialSchedule,
    this.initialDeliver,
    this.initialCatchUp = HermesJobCatchUp.hermesDefault,
    this.scheduling = false,
  });

  final String? initialName;
  final String? initialPrompt;
  final String? initialSchedule;
  final String? initialDeliver;
  final HermesJobCatchUp initialCatchUp;
  final bool scheduling;

  @override
  State<_HermesJobEditorDialog> createState() => _HermesJobEditorDialogState();
}

class _HermesJobEditorDialogState extends State<_HermesJobEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _prompt;
  late final TextEditingController _schedule;
  late String _deliver;
  late HermesJobCatchUp _catchUp;
  bool _showErrors = false;

  bool get _isEditing => widget.initialPrompt != null;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName ?? '');
    _prompt = TextEditingController(text: widget.initialPrompt ?? '');
    _schedule = TextEditingController(
      text: widget.initialSchedule ?? '0 9 * * *',
    );
    _deliver = parseHermesDeliveryTargets(widget.initialDeliver).join(',');
    _catchUp = widget.initialCatchUp;
  }

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    _schedule.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final prompt = _prompt.text.trim();
    final schedule = _schedule.text.trim();
    if (!hermesJobDraftIsValid(
      validateHermesJobDraft(name: name, prompt: prompt, schedule: schedule),
    )) {
      setState(() => _showErrors = true);
      return;
    }
    final scheduling = widget.scheduling;
    final deliverChanged =
        !_isEditing ||
        !hermesDeliveryTargetsMatch(_deliver, widget.initialDeliver);
    final catchUpChanged = !_isEditing || _catchUp != widget.initialCatchUp;
    Navigator.of(context).pop((
      name: name,
      prompt: prompt,
      schedule: schedule,
      deliver: scheduling && deliverChanged ? _deliver : null,
      catchUp: scheduling && catchUpChanged ? _catchUp : null,
    ));
  }

  String? _errorText(
    AppLocalizations l10n,
    HermesJobFieldError? error, {
    int maximum = 0,
  }) => switch (_showErrors ? error : null) {
    null => null,
    HermesJobFieldError.required => l10n.requiredFieldHelper,
    HermesJobFieldError.tooLong => l10n.hermesJobTooLong(maximum),
    HermesJobFieldError.invalidSchedule => l10n.hermesJobScheduleInvalid,
  };

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final isEditing = _isEditing;
    final l10n = AppLocalizations.of(context) ?? AppLocalizationsEn();
    final errors = validateHermesJobDraft(
      name: _name.text,
      prompt: _prompt.text,
      schedule: _schedule.text,
    );

    return ThemedDialogs.buildBase(
      context: context,
      title: isEditing ? l10n.hermesJobEditorEditTitle : l10n.hermesJobNew,
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConduitInput(
              label: l10n.name,
              hint: l10n.hermesJobNameHint,
              controller: _name,
              errorText: _errorText(
                l10n,
                errors.name,
                maximum: kMaxHermesJobNameCharacters,
              ),
              onChanged: (_) {
                if (_showErrors) setState(() {});
              },
            ),
            const SizedBox(height: Spacing.md),
            ConduitInput(
              label: l10n.hermesJobPromptLabel,
              hint: l10n.hermesJobPromptHint,
              controller: _prompt,
              minLines: 2,
              maxLines: 5,
              errorText: _errorText(
                l10n,
                errors.prompt,
                maximum: kMaxHermesJobPromptCharacters,
              ),
              onChanged: (_) {
                if (_showErrors) setState(() {});
              },
            ),
            const SizedBox(height: Spacing.md),
            ConduitInput(
              label: l10n.hermesJobScheduleLabel,
              hint: l10n.hermesJobScheduleHint,
              controller: _schedule,
              errorText: _errorText(
                l10n,
                errors.schedule,
                maximum: kMaxHermesJobScheduleCharacters,
              ),
              onChanged: (_) {
                if (_showErrors) setState(() {});
              },
            ),
            const SizedBox(height: Spacing.xs),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l10n.hermesJobScheduleHelp,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.textSecondary,
                ),
              ),
            ),
            if (widget.scheduling) ...[
              const SizedBox(height: Spacing.md),
              AdaptiveDropdownField<HermesJobCatchUp>(
                key: const ValueKey<String>('hermes-job-catch-up'),
                value: _catchUp,
                options: [
                  for (final choice in HermesJobCatchUp.values)
                    AdaptiveDropdownOption<HermesJobCatchUp>(
                      value: choice,
                      label: hermesJobCatchUpLabel(l10n, choice),
                    ),
                ],
                onChanged: (choice) => setState(() => _catchUp = choice),
                decoration: InputDecoration(
                  labelText: l10n.hermesJobCatchUpLabel,
                  helperText: l10n.hermesJobCatchUpHint,
                  helperMaxLines: 3,
                ),
                nativeTitle: l10n.hermesJobCatchUpLabel,
              ),
              const SizedBox(height: Spacing.md),
              Consumer(
                builder: (context, ref, _) {
                  final options = ref.watch(hermesJobDeliveryOptionsProvider);
                  return HermesJobDeliveryField(
                    value: _deliver,
                    options: options.asData?.value,
                    loading: options.isLoading,
                    onChanged: (value) => setState(() => _deliver = value),
                  );
                },
              ),
            ],
          ],
        ),
      ),
      actions: [
        ConduitTextButton(
          onPressed: () => Navigator.of(context).pop(),
          text: l10n.cancel,
        ),
        ConduitTextButton(text: l10n.save, onPressed: _save, isPrimary: true),
      ],
    );
  }
}
