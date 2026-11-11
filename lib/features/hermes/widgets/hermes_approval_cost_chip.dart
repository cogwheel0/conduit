import 'package:flutter/widgets.dart';

import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:conduit_core/features/hermes/models/hermes_approval_cost.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';

/// The approval and question texts a card shows, with a paid tool's price
/// taken out of the text and returned apart: from the shown text when it
/// states it (a Desktop Gateway approval's command), else from what the
/// run kept ([stored], a REST approval whose card shows the description).
({String? summary, HermesApprovalCost? cost}) hermesApprovalPresentation(
  String? summary,
  Object? stored,
) {
  final parsed = parseHermesApprovalCost([summary]);
  if (parsed != null) {
    return (
      summary: parsed.remainder.isEmpty ? null : parsed.remainder,
      cost: parsed,
    );
  }
  return (summary: summary, cost: HermesApprovalCost.fromJson(stored));
}

/// The price of a paid MCP tool call and what the chat spent so far, as
/// compact chips, plus a warning when the call passes the spend limit.
class HermesApprovalCostChips extends StatelessWidget {
  const HermesApprovalCostChips({super.key, required this.cost});

  final HermesApprovalCost cost;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final price = cost.cost;
    final spent = cost.spent;
    final limit = cost.limit;
    final spend = spent != null && limit != null
        ? l10n.hermesApprovalSpentOfLimit(spent, limit)
        : spent != null
        ? l10n.hermesApprovalSpent(spent)
        : limit != null
        ? l10n.hermesApprovalSpendLimit(limit)
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: Spacing.xs,
          runSpacing: Spacing.xs,
          children: [
            if (price != null)
              _Chip(
                key: const ValueKey('hermes-approval-cost'),
                icon: Icons.toll_outlined,
                text: [
                  cost.approximate ? '≈ $price' : price,
                  ?cost.note,
                ].join(' · '),
                semanticsLabel: l10n.hermesApprovalCost(
                  [price, ?cost.note].join(', '),
                ),
                color: theme.textPrimary,
                background: theme.surfaceContainerHighest,
              ),
            if (spend != null)
              _Chip(
                key: const ValueKey('hermes-approval-spend'),
                icon: Icons.account_balance_wallet_outlined,
                text: cost.server == null ? spend : '$spend · ${cost.server}',
                color: cost.overLimit ? theme.warning : theme.textSecondary,
                background: cost.overLimit
                    ? theme.warningBackground
                    : theme.surfaceContainer,
              ),
          ],
        ),
        if (cost.overLimit) ...[
          const SizedBox(height: Spacing.xs),
          Row(
            key: const ValueKey('hermes-approval-over-limit'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, size: 16, color: theme.warning),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: Text(
                  l10n.hermesApprovalOverLimit,
                  style: AppTypography.labelSmallStyle.copyWith(
                    color: theme.warning,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    super.key,
    required this.icon,
    required this.text,
    required this.color,
    required this.background,
    this.semanticsLabel,
  });

  final IconData icon;
  final String text;
  final Color color;
  final Color background;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: semanticsLabel,
    excludeSemantics: semanticsLabel != null,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppBorderRadius.round),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.xxs + 1,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: Spacing.xs),
            Flexible(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.labelSmallStyle.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
