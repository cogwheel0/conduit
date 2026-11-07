import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/widgets.dart';

import 'package:conduit_core/features/hermes/models/hermes_job_delivery.dart';

import '../../../l10n/app_localizations.dart';
import '../../../l10n/app_localizations_en.dart';
import '../../../shared/theme/theme_extensions.dart';

/// A delivery target's label on its own: "Save in Hermes only", a platform,
/// bot, or room name, or the stored token for anything unrecognised.
String hermesDeliveryOptionLabel(
  AppLocalizations l10n,
  HermesDeliveryOption option,
) => switch (option.kind) {
  HermesDeliveryKind.local => l10n.hermesJobDeliverLocal,
  HermesDeliveryKind.other => option.target,
  _ => option.name,
};

/// A job's `deliver` value for its card: each target with its kind, such as
/// "Bot Chat: Research", in stored order.
String describeHermesJobDelivery(
  AppLocalizations l10n,
  String? deliver, {
  HermesDeliveryOptions? options,
}) => [
  for (final target in parseHermesDeliveryTargets(deliver))
    _targetSummary(
      l10n,
      options?.optionFor(target) ?? describeHermesDeliveryTarget(target),
    ),
].join(', ');

String _targetSummary(AppLocalizations l10n, HermesDeliveryOption option) =>
    switch (option.kind) {
      HermesDeliveryKind.botChat => l10n.hermesJobDeliverBotChat(option.name),
      HermesDeliveryKind.room => l10n.hermesJobDeliverGroupChat(option.name),
      _ => hermesDeliveryOptionLabel(l10n, option),
    };

/// The editor's "Deliver to" checklist. Hermes takes several targets at
/// once, so each is a checkbox; the last one cannot be cleared. Targets the
/// job already has but [options] do not list stay visible and selected.
class HermesJobDeliveryField extends StatelessWidget {
  const HermesJobDeliveryField({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.loading = false,
  });

  /// The `deliver` value being edited.
  final String value;

  /// Targets Hermes offers; null shows only local and the current targets.
  final HermesDeliveryOptions? options;
  final ValueChanged<String>? onChanged;

  /// Whether [options] are still loading.
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context) ?? AppLocalizationsEn();
    final selected = parseHermesDeliveryTargets(value);
    final all = (options ?? HermesDeliveryOptions.localOnly).withSelected(
      selected,
    );
    List<HermesDeliveryOption> ofKind(Set<HermesDeliveryKind> kinds) =>
        all.where((option) => kinds.contains(option.kind)).toList();
    final general = ofKind({
      HermesDeliveryKind.local,
      HermesDeliveryKind.other,
    });
    final platforms = ofKind({HermesDeliveryKind.platform});
    final botChats = ofKind({HermesDeliveryKind.botChat});
    final rooms = ofKind({HermesDeliveryKind.room});

    Widget row(HermesDeliveryOption option) => _HermesDeliveryTargetRow(
      key: ValueKey<String>('hermes-job-deliver-${option.target}'),
      label: hermesDeliveryOptionLabel(l10n, option),
      hint: option.available ? null : l10n.hermesJobDeliverNeedsHomeChannel,
      checked: selected.contains(option.target),
      onChanged: _onChangedFor(option, selected),
    );

    Widget section(String title, List<HermesDeliveryOption> rows) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: Spacing.sm),
        Semantics(
          header: true,
          child: Text(
            title,
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        for (final option in rows) row(option),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.hermesJobDeliverLabel,
                style: AppTypography.standard.copyWith(
                  fontWeight: FontWeight.w500,
                  color: theme.textPrimary,
                ),
              ),
            ),
            if (loading)
              const SizedBox(
                width: 16,
                height: 16,
                child: AdaptiveProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: Spacing.xs),
        for (final option in general) row(option),
        if (platforms.isNotEmpty)
          section(l10n.hermesJobDeliverMessaging, platforms),
        if (botChats.isNotEmpty)
          section(l10n.hermesJobDeliverBotChats, botChats),
        if (rooms.isNotEmpty) ...[
          section(l10n.hermesJobDeliverGroupChats, rooms),
          Text(
            l10n.hermesJobDeliverRoomHint,
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
            ),
          ),
        ],
      ],
    );
  }

  /// Null when the row cannot change: the only selected target, or a
  /// platform Hermes cannot send to yet.
  ValueChanged<bool>? _onChangedFor(
    HermesDeliveryOption option,
    List<String> selected,
  ) {
    final callback = onChanged;
    if (callback == null) return null;
    final checked = selected.contains(option.target);
    if (checked ? selected.length <= 1 : !option.available) return null;
    return (next) => callback(
      toggleHermesDeliveryTarget(value, option.target, selected: next),
    );
  }
}

class _HermesDeliveryTargetRow extends StatelessWidget {
  const _HermesDeliveryTargetRow({
    super.key,
    required this.label,
    required this.checked,
    required this.onChanged,
    this.hint,
  });

  final String label;
  final String? hint;
  final bool checked;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final callback = onChanged;
    final enabled = callback != null;
    return MergeSemantics(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => callback(!checked) : null,
        child: Row(
          children: [
            AdaptiveCheckbox(
              value: checked,
              onChanged: enabled
                  ? (next) => callback(next ?? !checked)
                  : null,
            ),
            const SizedBox(width: Spacing.xs),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: AppTypography.standard.copyWith(
                        color: enabled || checked
                            ? theme.textPrimary
                            : theme.textSecondary,
                      ),
                    ),
                    if (hint != null)
                      Text(
                        hint!,
                        style: AppTypography.bodySmallStyle.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
