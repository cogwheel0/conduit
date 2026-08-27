import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

class SkillSuggestionOverlay extends StatelessWidget {
  const SkillSuggestionOverlay({
    required this.skills,
    required this.selectionIndex,
    required this.onSkillSelected,
    super.key,
  });

  final AsyncValue<List<WorkspaceSkillSummary>> skills;
  final int selectionIndex;
  final ValueChanged<WorkspaceSkillSummary> onSkillSelected;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final borderColor = context.conduitTheme.cardBorder.withValues(
      alpha: brightness == Brightness.dark ? 0.6 : 0.4,
    );

    return Container(
      decoration: BoxDecoration(
        color: context.conduitTheme.cardBackground,
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        border: Border.all(color: borderColor, width: BorderWidth.thin),
        boxShadow: [
          BoxShadow(
            color: context.conduitTheme.cardShadow.withValues(
              alpha: brightness == Brightness.dark ? 0.28 : 0.16,
            ),
            blurRadius: 22,
            offset: const Offset(0, 8),
            spreadRadius: -4,
          ),
        ],
      ),
      child: skills.when(
        data: (items) {
          if (items.isEmpty) {
            return _SkillOverlayPlaceholder(
              leading: Icon(
                Icons.inbox_outlined,
                size: IconSize.medium,
                color: context.conduitTheme.textSecondary.withValues(
                  alpha: Alpha.medium,
                ),
              ),
              message: AppLocalizations.of(context)!.noResults,
            );
          }

          final activeIndex = selectionIndex.clamp(0, items.length - 1);
          return ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
              shrinkWrap: true,
              physics: const ClampingScrollPhysics(),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: Spacing.xxs),
              itemBuilder: (context, index) {
                final skill = items[index];
                final selected = index == activeIndex;
                return Semantics(
                  button: true,
                  selected: selected,
                  label: '${skill.name}, ${skill.id}',
                  child: GestureDetector(
                    key: ValueKey('skill-suggestion-${skill.id}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onSkillSelected(skill),
                    child: Container(
                      decoration: BoxDecoration(
                        color: selected
                            ? context.conduitTheme.navigationSelectedBackground
                                  .withValues(alpha: 0.4)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(
                          AppBorderRadius.card,
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.sm,
                        vertical: Spacing.xs,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              skill.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: context.conduitTheme.textPrimary,
                                  ),
                            ),
                          ),
                          const SizedBox(width: Spacing.sm),
                          Flexible(
                            child: Text(
                              skill.id,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: context.conduitTheme.textSecondary,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
        loading: () => _SkillOverlayPlaceholder(
          leading: SizedBox.square(
            dimension: IconSize.large,
            child: CircularProgressIndicator(
              strokeWidth: BorderWidth.regular,
              color: context.conduitTheme.loadingIndicator,
            ),
          ),
        ),
        error: (_, _) => _SkillOverlayPlaceholder(
          leading: Icon(
            Icons.error_outline,
            size: IconSize.medium,
            color: context.conduitTheme.error,
          ),
        ),
      ),
    );
  }
}

class _SkillOverlayPlaceholder extends StatelessWidget {
  const _SkillOverlayPlaceholder({required this.leading, this.message});

  final Widget leading;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.md,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          leading,
          if (message != null) ...[
            const SizedBox(width: Spacing.sm),
            Flexible(
              child: Text(
                message!,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: context.conduitTheme.textSecondary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
