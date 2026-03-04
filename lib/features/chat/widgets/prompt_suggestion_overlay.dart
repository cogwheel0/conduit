import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/prompt.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../prompts/providers/prompts_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';

/// Autocomplete overlay that appears when the user types `/` commands.
///
/// Displays a filtered list of available prompts and allows selection
/// via tap. The parent widget manages filtering logic and selection
/// state; this widget is responsible only for rendering.
class PromptSuggestionOverlay extends ConsumerWidget {
  /// Creates a prompt suggestion overlay.
  const PromptSuggestionOverlay({
    required this.filteredPrompts,
    required this.selectionIndex,
    required this.onPromptSelected,
    super.key,
  });

  /// The prompts matching the current filter, already filtered by the parent.
  ///
  /// When `null`, the prompt list is still loading from the provider.
  final List<Prompt> Function(List<Prompt>)? filteredPrompts;

  /// Index of the currently highlighted prompt in the filtered list.
  final int selectionIndex;

  /// Called when the user taps a prompt to apply it.
  final ValueChanged<Prompt> onPromptSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Brightness brightness = Theme.of(context).brightness;
    final overlayColor = context.conduitTheme.cardBackground;
    final borderColor = context.conduitTheme.cardBorder.withValues(
      alpha: brightness == Brightness.dark ? 0.6 : 0.4,
    );

    final AsyncValue<List<Prompt>> promptsAsync = ref.watch(
      promptsListProvider,
    );

    return Container(
      decoration: BoxDecoration(
        color: overlayColor,
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
      child: promptsAsync.when(
        data: (prompts) {
          final List<Prompt> filtered =
              filteredPrompts != null ? filteredPrompts!(prompts) : prompts;
          if (filtered.isEmpty) {
            return _PromptOverlayPlaceholder(
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

          int activeIndex = selectionIndex;
          if (activeIndex < 0) {
            activeIndex = 0;
          } else if (activeIndex >= filtered.length) {
            activeIndex = filtered.length - 1;
          }

          return ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
              shrinkWrap: true,
              physics: const ClampingScrollPhysics(),
              itemCount: filtered.length,
              separatorBuilder: (context, index) =>
                  const SizedBox(height: Spacing.xxs),
              itemBuilder: (context, index) {
                final prompt = filtered[index];
                final bool isSelected = index == activeIndex;
                final Color highlight = isSelected
                    ? context
                          .conduitTheme
                          .navigationSelectedBackground
                          .withValues(alpha: 0.4)
                    : Colors.transparent;

                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(
                      AppBorderRadius.card,
                    ),
                    onTap: () => onPromptSelected(prompt),
                    child: Container(
                      decoration: BoxDecoration(
                        color: highlight,
                        borderRadius: BorderRadius.circular(
                          AppBorderRadius.card,
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.sm,
                        vertical: Spacing.xs,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            prompt.command,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: context.conduitTheme.textPrimary,
                                ),
                          ),
                          if (prompt.title.trim().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(
                                top: Spacing.xxs,
                              ),
                              child: Text(
                                prompt.title,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color:
                                          context.conduitTheme.textSecondary,
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
        loading: () => _PromptOverlayPlaceholder(
          leading: SizedBox(
            width: IconSize.large,
            height: IconSize.large,
            child: CircularProgressIndicator(
              strokeWidth: BorderWidth.regular,
              valueColor: AlwaysStoppedAnimation<Color>(
                context.conduitTheme.loadingIndicator,
              ),
            ),
          ),
        ),
        error: (error, stackTrace) => _PromptOverlayPlaceholder(
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

/// Placeholder shown when the prompt list is loading, empty, or errored.
class _PromptOverlayPlaceholder extends StatelessWidget {
  const _PromptOverlayPlaceholder({
    required this.leading,
    this.message,
  });

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
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.conduitTheme.textSecondary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
