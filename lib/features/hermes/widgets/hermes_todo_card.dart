import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:conduit_core/features/hermes/models/hermes_todo.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';

/// Whether each chat's plan is folded, as the user left it, for this run
/// of the app. Absent means folded once nothing is left to do.
final Map<String, bool> _foldedByChat = {};

/// The share of the screen the open plan may take before it scrolls.
const double _kMaxListHeightFraction = 0.28;

/// [overlay] (an approval or question card) with the open chat's [plan]
/// above it, when the chat has one.
Widget? withHermesPlan(
  Widget? overlay, {
  required HermesTodoState? plan,
  required String? chatKey,
}) {
  if (plan == null || plan.isEmpty || chatKey == null) return overlay;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      HermesTodoCard(plan: plan, chatKey: chatKey),
      ?overlay,
    ],
  );
}

/// The agent's task list for the open chat, pinned above the composer:
/// what is done, under way and still to do. Tapping the header folds it to
/// one line with the step under way.
class HermesTodoCard extends StatefulWidget {
  const HermesTodoCard({super.key, required this.plan, required this.chatKey});

  final HermesTodoState plan;

  /// The chat the plan belongs to; its fold state is kept per chat.
  final String chatKey;

  @override
  State<HermesTodoCard> createState() => _HermesTodoCardState();
}

class _HermesTodoCardState extends State<HermesTodoCard> {
  bool get _folded => _foldedByChat[widget.chatKey] ?? !widget.plan.active;

  void _toggle() => setState(() => _foldedByChat[widget.chatKey] = !_folded);

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final plan = widget.plan;
    final folded = _folded;
    final current = plan.current;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: DecoratedBox(
        key: const ValueKey('hermes-todo-card'),
        decoration: BoxDecoration(
          color: theme.surfaceBackground,
          borderRadius: BorderRadius.circular(AppBorderRadius.card),
          border: Border.all(color: theme.cardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              container: true,
              button: true,
              expanded: !folded,
              label: folded ? l10n.hermesPlanShow : l10n.hermesPlanHide,
              child: GestureDetector(
                key: const ValueKey('hermes-todo-toggle'),
                behavior: HitTestBehavior.opaque,
                onTap: _toggle,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.md,
                    vertical: Spacing.sm,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.checklist_rounded,
                        size: 18,
                        color: theme.buttonPrimary,
                      ),
                      const SizedBox(width: Spacing.sm),
                      Text(
                        l10n.hermesPlanTitle,
                        style: AppTypography.labelStyle.copyWith(
                          color: theme.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: Spacing.sm),
                      Text(
                        l10n.hermesPlanProgress(plan.done, plan.items.length),
                        style: AppTypography.labelSmallStyle.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: folded && current != null
                            ? Text(
                                current.content,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTypography.labelSmallStyle.copyWith(
                                  color: theme.textSecondary,
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                      Icon(
                        folded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 20,
                        color: theme.iconSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (!folded && plan.items.isNotEmpty)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: math.max(
                    96,
                    MediaQuery.sizeOf(context).height *
                        _kMaxListHeightFraction,
                  ),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(
                    Spacing.md,
                    0,
                    Spacing.md,
                    Spacing.sm,
                  ),
                  itemCount: plan.items.length,
                  itemBuilder: (context, index) {
                    final item = plan.items[index];
                    return _TodoRow(item: item, depth: plan.depthOf(item));
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TodoRow extends StatelessWidget {
  const _TodoRow({required this.item, required this.depth});

  final HermesTodoItem item;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final (icon, color) = switch (item.status) {
      HermesTodoStatus.completed => (Icons.check_circle_rounded, theme.success),
      HermesTodoStatus.inProgress => (
        Icons.timelapse_rounded,
        theme.buttonPrimary,
      ),
      HermesTodoStatus.cancelled => (Icons.cancel_outlined, theme.textTertiary),
      HermesTodoStatus.pending => (
        Icons.radio_button_unchecked_rounded,
        theme.iconSecondary,
      ),
    };
    final finished = !item.active;
    return Padding(
      padding: EdgeInsetsDirectional.only(
        start: depth * Spacing.md,
        top: Spacing.xxs,
        bottom: Spacing.xxs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              item.content,
              style: AppTypography.bodySmallStyle.copyWith(
                color: finished ? theme.textTertiary : theme.textPrimary,
                fontWeight: item.status == HermesTodoStatus.inProgress
                    ? FontWeight.w600
                    : null,
                decoration: finished ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
