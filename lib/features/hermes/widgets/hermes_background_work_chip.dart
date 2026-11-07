import 'package:flutter/widgets.dart';

import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'hermes_background_work_sheet.dart';

/// [overlay] (the plan and any prompt card) with a chip above it naming
/// the open chat's running subagents and background processes, when any
/// run.
Widget? withHermesBackgroundWork(
  Widget? overlay, {
  required int agents,
  required int processes,
}) {
  if (agents <= 0 && processes <= 0) return overlay;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: HermesBackgroundWorkChip(agents: agents, processes: processes),
      ),
      ?overlay,
    ],
  );
}

/// "2 agents · 1 process": what the open chat's agent has running besides
/// its reply. Tapping it opens the background work sheet.
class HermesBackgroundWorkChip extends StatelessWidget {
  const HermesBackgroundWorkChip({
    super.key,
    required this.agents,
    required this.processes,
  });

  final int agents;
  final int processes;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final label = hermesBackgroundWorkSummary(l10n, agents, processes);
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: Semantics(
        container: true,
        button: true,
        label: label,
        hint: l10n.hermesBackgroundWorkShow,
        excludeSemantics: true,
        child: GestureDetector(
          key: const ValueKey('hermes-background-work-chip'),
          behavior: HitTestBehavior.opaque,
          onTap: () => showHermesBackgroundWorkSheet(context),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.surfaceBackground,
              borderRadius: BorderRadius.circular(AppBorderRadius.round),
              border: Border.all(color: theme.cardBorder),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    agents > 0
                        ? Icons.account_tree_outlined
                        : Icons.terminal_rounded,
                    size: 16,
                    color: theme.buttonPrimary,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Text(
                    label,
                    style: AppTypography.labelSmallStyle.copyWith(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: Spacing.xxs),
                  Icon(
                    Icons.keyboard_arrow_up_rounded,
                    size: 18,
                    color: theme.iconSecondary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "2 agents · 1 process", leaving out a kind with none running.
String hermesBackgroundWorkSummary(
  AppLocalizations l10n,
  int agents,
  int processes,
) => [
  if (agents > 0) l10n.hermesBackgroundAgentCount(agents),
  if (processes > 0) l10n.hermesBackgroundProcessCount(processes),
].join(' · ');
