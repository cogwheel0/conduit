import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../../l10n/app_localizations_en.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_dropdown_field.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/utility_components.dart';

import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/models/hermes_job_delivery.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/utils/hermes_schedule_validation.dart';
import 'package:conduit_core/features/push/services/hermes_push_backend.dart'
    show
        hermesDeliverIncludesConduit,
        hermesDeliverWithConduit,
        kConduitHermesPluginName;

import 'hermes_job_delivery_field.dart';

/// What the job editor returns. [deliver] and [catchUp] are null when the
/// editor did not offer them or, when editing, the user left them as they
/// were, so an edit never rewrites a value it did not touch. [notify] is the
/// "Notify me" switch, or null when the editor did not offer it.
typedef HermesJobEditorResult = ({
  String name,
  String prompt,
  String schedule,
  String? deliver,
  HermesJobCatchUp? catchUp,
  bool? notify,
});

/// Shows the create/edit dialog for a scheduled Hermes job, or null if
/// cancelled. [scheduling] adds the missed-run policy and the "Deliver to"
/// checklist, which only the Desktop Gateway's dashboard accepts.
///
/// With [initialNotify], the dialog also offers "Notify me", which sends a
/// push when the job delivers; leave it null where push can't reach the
/// connection. With [notifyUnavailableHint] the switch shows off and cannot
/// be changed, with the hint saying why, and the result's `notify` is null.
/// Push is that switch alone: the checklist leaves out the Conduit target,
/// and keeps it as the job had it.
///
/// [deliveryEditable] is false for a job whose delivery targets this app
/// can't read: the checklist is left out, so a save can't replace them.
Future<HermesJobEditorResult?> showHermesJobEditor(
  BuildContext context, {
  String? initialName,
  String? initialPrompt,
  String? initialSchedule,
  String? initialDeliver,
  HermesJobCatchUp initialCatchUp = HermesJobCatchUp.hermesDefault,
  bool scheduling = false,
  bool deliveryEditable = true,
  bool? initialNotify,
  String? notifyUnavailableHint,
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
      deliveryEditable: deliveryEditable,
      initialNotify: initialNotify,
      notifyUnavailableHint: notifyUnavailableHint,
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
    this.deliveryEditable = true,
    this.initialNotify,
    this.notifyUnavailableHint,
  });

  final String? initialName;
  final String? initialPrompt;
  final String? initialSchedule;
  final String? initialDeliver;
  final HermesJobCatchUp initialCatchUp;
  final bool scheduling;
  final bool deliveryEditable;
  final bool? initialNotify;
  final String? notifyUnavailableHint;

  @override
  State<_HermesJobEditorDialog> createState() => _HermesJobEditorDialogState();
}

class _HermesJobEditorDialogState extends State<_HermesJobEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _prompt;
  late final TextEditingController _schedule;
  late String _deliver;

  /// The checklist as it opened, to tell whether the user changed it.
  late final String _openedDeliver;
  late HermesJobCatchUp _catchUp;
  bool _showErrors = false;
  bool? _notify;

  /// Whether the job delivers to Conduit already. The checklist leaves that
  /// target out, so a save keeps it as it was; "Notify me" changes it.
  late final bool _deliversToConduit = hermesDeliverIncludesConduit(
    widget.initialDeliver,
  );

  bool get _isEditing => widget.initialPrompt != null;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName ?? '');
    _prompt = TextEditingController(text: widget.initialPrompt ?? '');
    _schedule = TextEditingController(
      text: widget.initialSchedule ?? '0 9 * * *',
    );
    _notify = widget.initialNotify;
    _deliver = _openedDeliver = hermesDeliverWithConduit(
      parseHermesDeliveryTargets(widget.initialDeliver).join(','),
      notify: false,
    );
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
        !_isEditing || !hermesDeliveryTargetsMatch(_deliver, _openedDeliver);
    final deliver = hermesDeliverWithConduit(
      _deliver,
      notify: _deliversToConduit,
    );
    final catchUpChanged = !_isEditing || _catchUp != widget.initialCatchUp;
    Navigator.of(context).pop((
      name: name,
      prompt: prompt,
      schedule: schedule,
      deliver: scheduling && widget.deliveryEditable && deliverChanged
          ? deliver
          : null,
      catchUp: scheduling && catchUpChanged ? _catchUp : null,
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
              if (widget.deliveryEditable) ...[
                const SizedBox(height: Spacing.md),
                Consumer(
                  builder: (context, ref, _) {
                    final options = ref.watch(hermesJobDeliveryOptionsProvider);
                    final listed = options.asData?.value;
                    return HermesJobDeliveryField(
                      value: _deliver,
                      options: listed == null
                          ? null
                          : HermesDeliveryOptions([
                              for (final option in listed.options)
                                if (option.target != kConduitHermesPluginName)
                                  option,
                            ]),
                      loading: options.isLoading,
                      // Room for `,conduit`, which saving or "Notify Me" adds.
                      reservedCharacters:
                          _deliversToConduit || widget.initialNotify != null
                          ? kConduitHermesPluginName.length + 1
                          : 0,
                      onChanged: (value) => setState(() => _deliver = value),
                    );
                  },
                ),
              ],
            ],
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
