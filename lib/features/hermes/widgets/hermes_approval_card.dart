import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';

/// Resolution state of a Hermes approval gate, mirrored from the assistant
/// message's `metadata['hermesApproval']['state']`.
enum HermesApprovalState { pending, resolving, approved, denied }

/// In-chat card shown when a Hermes run pauses for human approval.
///
/// Presentational only: [onDecision] is invoked with the user's choice; the
/// caller performs the POST and updates the message metadata.
class HermesApprovalCard extends StatelessWidget {
  const HermesApprovalCard({
    super.key,
    required this.state,
    required this.onDecision,
    this.summary,
  });

  final HermesApprovalState state;
  final String? summary;
  final void Function(bool approved) onDecision;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final resolved =
        state == HermesApprovalState.approved ||
        state == HermesApprovalState.denied;

    return Container(
      margin: const EdgeInsets.only(top: Spacing.sm),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: theme.surfaceBackground,
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        border: Border.all(color: theme.cardBorder),
      ),
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
                'Approval required',
                style: AppTypography.standard.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            summary ?? 'The agent is requesting permission to continue.',
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
            ),
          ),
          const SizedBox(height: Spacing.md),
          if (resolved)
            Text(
              state == HermesApprovalState.approved ? 'Approved ✓' : 'Denied',
              style: AppTypography.standard.copyWith(
                color: state == HermesApprovalState.approved
                    ? theme.success
                    : theme.error,
              ),
            )
          else
            Row(
              children: [
                ConduitButton(
                  text: 'Approve',
                  isCompact: true,
                  isLoading: state == HermesApprovalState.resolving,
                  onPressed: state == HermesApprovalState.pending
                      ? () => onDecision(true)
                      : null,
                ),
                const SizedBox(width: Spacing.sm),
                ConduitButton(
                  text: 'Deny',
                  isCompact: true,
                  isSecondary: true,
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
