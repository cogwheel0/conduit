import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../../l10n/app_localizations_en.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/utility_components.dart';

import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/utils/hermes_schedule_validation.dart';

/// What the job editor returns. [notify] is the "Notify me" switch, or null
/// when the editor did not offer it.
typedef HermesJobDraft = ({
  String name,
  String prompt,
  String schedule,
  bool? notify,
});

/// Shows the create/edit dialog for a scheduled Hermes job and returns the
/// entered name, prompt, and schedule, or null if cancelled.
///
/// With [initialNotify], the dialog also offers "Notify me", which sends a
/// push when the job delivers; leave it null where push can't reach the
/// connection. With [notifyUnavailableHint] the switch shows off and cannot
/// be changed, with the hint saying why, and the draft's `notify` is null.
Future<HermesJobDraft?> showHermesJobEditor(
  BuildContext context, {
  String? initialName,
  String? initialPrompt,
  String? initialSchedule,
  bool? initialNotify,
  String? notifyUnavailableHint,
}) {
  return ThemedDialogs.showCustom<HermesJobDraft>(
    context: context,
    builder: (context) => _HermesJobEditorDialog(
      initialName: initialName,
      initialPrompt: initialPrompt,
      initialSchedule: initialSchedule,
      initialNotify: initialNotify,
      notifyUnavailableHint: notifyUnavailableHint,
    ),
  );
}

class _HermesJobEditorDialog extends StatefulWidget {
  const _HermesJobEditorDialog({
    this.initialName,
    this.initialPrompt,
    this.initialSchedule,
    this.initialNotify,
    this.notifyUnavailableHint,
  });

  final String? initialName;
  final String? initialPrompt;
  final String? initialSchedule;
  final bool? initialNotify;
  final String? notifyUnavailableHint;

  @override
  State<_HermesJobEditorDialog> createState() => _HermesJobEditorDialogState();
}

class _HermesJobEditorDialogState extends State<_HermesJobEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _prompt;
  late final TextEditingController _schedule;
  bool _showErrors = false;
  bool? _notify;

  @override
  void initState() {
    super.initState();
    _notify = widget.initialNotify;
    _name = TextEditingController(text: widget.initialName ?? '');
    _prompt = TextEditingController(text: widget.initialPrompt ?? '');
    _schedule = TextEditingController(
      text: widget.initialSchedule ?? '0 9 * * *',
    );
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
    Navigator.of(context).pop((
      name: name,
      prompt: prompt,
      schedule: schedule,
      // Shown but not changeable: nothing to change.
      notify: widget.notifyUnavailableHint == null ? _notify : null,
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
    final isEditing = widget.initialPrompt != null;
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
            if (widget.notifyUnavailableHint case final hint?) ...[
              const SizedBox(height: Spacing.sm),
              UtilityRow(
                key: const Key('hermes-job-notify'),
                enabled: false,
                title: l10n.hermesJobNotifyTitle,
                subtitle: hint,
                padding: EdgeInsets.zero,
                toggled: false,
                trailing: const AdaptiveSwitch(value: false, onChanged: null),
              ),
            ] else if (_notify case final notify?) ...[
              const SizedBox(height: Spacing.sm),
              UtilityRow(
                key: const Key('hermes-job-notify'),
                title: l10n.hermesJobNotifyTitle,
                subtitle: l10n.hermesJobNotifyDescription,
                padding: EdgeInsets.zero,
                toggled: notify,
                trailing: AdaptiveSwitch(
                  value: notify,
                  onChanged: (value) => setState(() => _notify = value),
                ),
                onTap: () => setState(() => _notify = !notify),
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
