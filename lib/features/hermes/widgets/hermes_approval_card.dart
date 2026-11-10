import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/features/hermes/models/hermes_approval_cost.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/composer_prompt_surface.dart';
import '../../../shared/widgets/conduit_components.dart';
import 'hermes_approval_cost_chip.dart';

/// Resolution state of a Hermes approval gate, mirrored from the assistant
/// message's `metadata['hermesApproval']['state']`.
enum HermesApprovalState { pending, resolving, approved, denied }

/// Composer prompt shown when a Hermes run pauses for human approval.
///
/// Presentational only: [onDecision] is invoked with the user's choice; the
/// caller performs the POST and updates the message metadata.
class HermesApprovalCard extends StatelessWidget {
  const HermesApprovalCard({
    super.key,
    required this.state,
    required this.onDecision,
    this.summary,
    this.choices = const <String>[],
    this.onChoice,
    this.cost,
  });

  final HermesApprovalState state;
  final String? summary;
  final void Function(bool approved) onDecision;
  final List<String> choices;
  final void Function(String choice)? onChoice;

  /// A paid tool's price and the chat's spend, shown as chips.
  final HermesApprovalCost? cost;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final resolved =
        state == HermesApprovalState.approved ||
        state == HermesApprovalState.denied;
    // Past the spend limit Hermes takes an answer for this call only.
    final offered = cost?.overLimit == true
        ? choices.where(const {'once', 'deny'}.contains).toList()
        : choices;

    return ComposerPromptSurface(
      semanticsLabel: l10n.hermesApprovalRequired,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.verified_user_outlined,
                size: 18,
                color: theme.buttonPrimary,
              ),
              const SizedBox(width: Spacing.sm),
              Text(
                l10n.hermesApprovalRequired,
                style: AppTypography.standard.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            summary ?? l10n.hermesApprovalFallback,
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
            ),
          ),
          if (cost case final cost? when cost.hasDetails) ...[
            const SizedBox(height: Spacing.sm),
            HermesApprovalCostChips(cost: cost),
          ],
          const SizedBox(height: Spacing.md),
          if (resolved)
            Text(
              state == HermesApprovalState.approved
                  ? l10n.hermesApprovalApproved
                  : l10n.hermesApprovalDenied,
              style: AppTypography.standard.copyWith(
                color: state == HermesApprovalState.approved
                    ? theme.success
                    : theme.error,
              ),
            )
          else if (offered.isNotEmpty && onChoice != null)
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                for (final choice in offered)
                  ConduitButton(
                    text: switch (choice) {
                      'once' => l10n.hermesApprovalAllowOnce,
                      'session' => l10n.hermesApprovalAllowSession,
                      'always' => l10n.hermesApprovalAlwaysAllow,
                      'deny' => l10n.hermesApprovalDenyAction,
                      _ => choice,
                    },
                    isCompact: true,
                    isSecondary: choice == 'deny',
                    onPressed: state == HermesApprovalState.pending
                        ? () => onChoice!(choice)
                        : null,
                  ),
              ],
            )
          else
            Row(
              children: [
                ConduitButton(
                  text: l10n.hermesApprovalApproveAction,
                  isCompact: true,
                  isLoading: state == HermesApprovalState.resolving,
                  onPressed: state == HermesApprovalState.pending
                      ? () => onDecision(true)
                      : null,
                ),
                const SizedBox(width: Spacing.sm),
                ConduitButton(
                  text: l10n.hermesApprovalDenyAction,
                  isCompact: true,
                  isSecondary: true,
                  isLoading: state == HermesApprovalState.resolving,
                  onPressed: state == HermesApprovalState.pending
                      ? () => onDecision(false)
                      : null,
                ),
              ],
            ),
        ],
      ),
    );
  }
}
