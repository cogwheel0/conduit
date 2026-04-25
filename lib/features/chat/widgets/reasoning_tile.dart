import 'package:flutter/material.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/markdown/streaming_markdown_widget.dart';
import '../../../core/utils/reasoning_parser.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher_string.dart';
import '../../../core/utils/debug_logger.dart';
import 'assistant_detail_header.dart';

/// An expandable tile showing the model's reasoning/thinking section.
///
/// Tapping opens a bottom sheet with the full reasoning content.
/// Mirrors Open WebUI's Collapsible.svelte logic for reasoning blocks.
class ReasoningTile extends StatelessWidget {
  /// The reasoning entry to display.
  final ReasoningEntry reasoning;

  /// The segment index used for tracking expanded state.
  final int index;

  /// Called when the reasoning tile is tapped to mark it expanded.
  final ValueChanged<int> onExpand;

  /// Called when the reasoning bottom sheet is dismissed.
  final ValueChanged<int> onCollapse;

  const ReasoningTile({
    super.key,
    required this.reasoning,
    required this.index,
    required this.onExpand,
    required this.onCollapse,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final showShimmer = !reasoning.isDone;
    final title = _headerText(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: GestureDetector(
        onTap: () {
          if (reasoning.cleanedReasoning.trim().isEmpty) return;
          onExpand(index);
          _showReasoningBottomSheet(context, title, theme);
        },
        behavior: HitTestBehavior.opaque,
        child: _ReasoningHeader(title: title, showShimmer: showShimmer),
      ),
    );
  }

  String _headerText(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hasSummary = reasoning.summary.isNotEmpty;
    final summaryLower = reasoning.summary.trim().toLowerCase();

    if (reasoning.isCodeInterpreter) {
      if (!reasoning.isDone) {
        return l10n.analyzing;
      }
      return l10n.analyzed;
    }

    final isThinkingSummary =
        summaryLower == 'thinking…' ||
        summaryLower == 'thinking...' ||
        summaryLower.startsWith('thinking');

    final hasDurationInSummary = RegExp(
      r'\(\d+s\)|\bfor \d+ secs?\b',
      caseSensitive: false,
    ).hasMatch(reasoning.summary);

    if (!reasoning.isDone) {
      return hasSummary && !isThinkingSummary
          ? reasoning.summary
          : l10n.thinking;
    }

    if (reasoning.duration >= 0 &&
        (reasoning.duration > 0 || hasDurationInSummary || isThinkingSummary)) {
      return l10n.thoughtForDuration(reasoning.formattedDuration);
    }

    if (hasSummary && !isThinkingSummary) {
      return reasoning.summary;
    }

    return l10n.thoughts;
  }

  void _showReasoningBottomSheet(
    BuildContext context,
    String title,
    ConduitThemeExtension theme,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.surfaceBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.dialog),
        ),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.95,
          expand: false,
          builder: (_, controller) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: Spacing.sm),
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.dividerColor.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.lg,
                    vertical: Spacing.sm,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.psychology_outlined,
                        size: IconSize.md,
                        color: theme.textPrimary,
                      ),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: Text(
                          title,
                          style: AppTypography.bodyLargeStyle.copyWith(
                            fontWeight: FontWeight.w600,
                            color: theme.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => Navigator.of(ctx).pop(),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        color: theme.textSecondary,
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  color: theme.dividerColor.withValues(alpha: 0.3),
                ),
                Expanded(
                  child: ListView(
                    controller: controller,
                    padding: const EdgeInsets.all(Spacing.lg),
                    children: [
                      StreamingMarkdownWidget(
                        content: reasoning.cleanedReasoning,
                        isStreaming: !reasoning.isDone,
                        onTapLink: (url, _) => _launchUri(url),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    ).whenComplete(() => onCollapse(index));
  }
}

class _ReasoningHeader extends StatelessWidget {
  final String title;
  final bool showShimmer;

  const _ReasoningHeader({required this.title, required this.showShimmer});

  @override
  Widget build(BuildContext context) =>
      AssistantDetailHeader(title: title, showShimmer: showShimmer);
}

Future<void> _launchUri(String url) async {
  if (url.isEmpty) return;
  try {
    await launchUrlString(url, mode: LaunchMode.externalApplication);
  } catch (err) {
    DebugLogger.log('Unable to open url $url: $err', scope: 'chat/reasoning');
  }
}
