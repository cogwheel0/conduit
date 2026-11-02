import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/models/chat_message.dart';

import '../../../core/services/haptic_service.dart';

import 'package:conduit_core/services/settings_service.dart';

import '../../theme/theme_extensions.dart';
import '../adaptive_dropdown_field.dart';
import '../platform_ui/platform_ui.dart';
import '../../utils/external_link_launcher.dart';

import 'package:conduit_core/utils/source_reference_helper.dart';

TextStyle _badgeLabelTextStyle(BuildContext context, Color color) {
  final textTheme = Theme.of(context).textTheme;
  return textTheme.labelSmall?.copyWith(
        color: color,
        fontWeight: FontWeight.w500,
        height: 1.2,
      ) ??
      AppTypography.labelSmallStyle.copyWith(
        color: color,
        fontWeight: FontWeight.w500,
        height: 1.2,
      );
}

BoxDecoration _badgeDecoration(BuildContext context, bool showBackground) =>
    BoxDecoration(
      color: !showBackground
          ? Colors.transparent
          : PlatformInfo.isIOS
          ? CupertinoColors.secondarySystemFill.resolveFrom(context)
          : context.conduitTheme.surfaceContainerHighest.withValues(
              alpha: 0.95,
            ),
      borderRadius: BorderRadius.circular(AppBorderRadius.pill),
    );

/// A compact inline citation badge showing source domain/title.
///
/// Uses the app's design system for consistency with other chips and badges.
class CitationBadge extends ConsumerWidget {
  const CitationBadge({
    super.key,
    required this.sourceIndex,
    required this.sources,
    this.onTap,
  });

  /// 0-based index into the sources list.
  final int sourceIndex;

  /// List of sources from the message.
  final List<ChatSourceReference> sources;

  /// Optional tap callback. If null, will try to launch URL.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showTitles = ref.watch(
      appSettingsProvider.select((settings) => settings.citationShowTitles),
    );
    final showBackground = ref.watch(
      appSettingsProvider.select((settings) => settings.citationBackground),
    );
    final theme = context.conduitTheme;
    final badgeTextStyle = _badgeLabelTextStyle(context, theme.textSecondary);

    // Check if index is valid
    if (sourceIndex < 0 || sourceIndex >= sources.length) {
      return const SizedBox.shrink();
    }

    final source = sources[sourceIndex];
    final url = SourceReferenceHelper.getSourceUrl(source);
    final title = SourceReferenceHelper.getSourceLabel(source, sourceIndex);
    final inlineTitle = SourceReferenceHelper.getInlineSourceLabel(
      source,
      sourceIndex,
      preferTitle: showTitles,
    );
    final displayTitle = SourceReferenceHelper.formatDisplayTitle(inlineTitle);

    return Tooltip(
      message: title,
      preferBelow: false,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (onTap != null) {
            onTap!();
          } else if (url != null) {
            launchExternalLink(url, scope: 'markdown/citation');
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: Spacing.xxs,
          ),
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: _badgeDecoration(context, showBackground),
          child: Text(
            displayTitle,
            style: badgeTextStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

/// A grouped citation badge for multiple sources like [1,2,3].
///
/// Shows first source with +N indicator for additional sources.
class CitationBadgeGroup extends ConsumerWidget {
  const CitationBadgeGroup({
    super.key,
    required this.sourceIndices,
    required this.sources,
    this.onSourceTap,
  });

  /// 0-based indices into the sources list.
  final List<int> sourceIndices;

  /// List of sources from the message.
  final List<ChatSourceReference> sources;

  /// Optional callback when a source is tapped.
  final void Function(int index)? onSourceTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showTitles = ref.watch(
      appSettingsProvider.select((settings) => settings.citationShowTitles),
    );
    final showBackground = ref.watch(
      appSettingsProvider.select((settings) => settings.citationBackground),
    );
    if (sourceIndices.isEmpty) {
      return const SizedBox.shrink();
    }

    // For single citation, use simple badge
    if (sourceIndices.length == 1) {
      return CitationBadge(
        sourceIndex: sourceIndices.first,
        sources: sources,
        onTap: onSourceTap != null
            ? () => onSourceTap!(sourceIndices.first)
            : null,
      );
    }

    final theme = context.conduitTheme;
    final badgeTextStyle = _badgeLabelTextStyle(context, theme.textSecondary);

    // Get first valid source for display
    final firstIndex = sourceIndices.first;
    final isFirstValid = firstIndex >= 0 && firstIndex < sources.length;

    if (!isFirstValid) {
      return const SizedBox.shrink();
    }

    final firstSource = sources[firstIndex];
    final firstTitle = SourceReferenceHelper.getInlineSourceLabel(
      firstSource,
      firstIndex,
      preferTitle: showTitles,
    );
    final displayTitle = SourceReferenceHelper.formatDisplayTitle(firstTitle);
    final additionalCount = sourceIndices.length - 1;

    final validIndices = sourceIndices
        .where((index) => index >= 0 && index < sources.length)
        .toList(growable: false);

    void selectSource(int index) {
      ConduitHaptics.selectionClick();
      if (onSourceTap != null) {
        onSourceTap!(index);
        return;
      }

      if (index >= 0 && index < sources.length) {
        final url = SourceReferenceHelper.getSourceUrl(sources[index]);
        if (url != null) {
          launchExternalLink(url, scope: 'markdown/citation');
        }
      }
    }

    final badge = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.xxs,
      ),
      margin: const EdgeInsets.symmetric(horizontal: 1),
      decoration: _badgeDecoration(context, showBackground),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            displayTitle,
            style: badgeTextStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(width: Spacing.xs),
          Text('+$additionalCount', style: badgeTextStyle),
        ],
      ),
    );
    if (PlatformInfo.isIOS) {
      return AdaptiveSingleChoiceTrigger<int>(
        value: null,
        options: [
          for (final index in validIndices)
            AdaptiveDropdownOption(
              value: index,
              label: SourceReferenceHelper.formatDisplayTitle(
                SourceReferenceHelper.getInlineSourceLabel(
                  sources[index],
                  index,
                  preferTitle: showTitles,
                ),
              ),
            ),
        ],
        onChanged: selectSource,
        child: badge,
      );
    }

    return Material(
      type: MaterialType.transparency,
      child: PopupMenuButton<int>(
        itemBuilder: (context) => [
          for (final index in validIndices)
            PopupMenuItem<int>(
              value: index,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.link_rounded, size: 16),
                  const SizedBox(width: Spacing.xs),
                  Flexible(
                    child: Text(
                      SourceReferenceHelper.formatDisplayTitle(
                        SourceReferenceHelper.getInlineSourceLabel(
                          sources[index],
                          index,
                          preferTitle: showTitles,
                        ),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
        onSelected: selectSource,
        padding: EdgeInsets.zero,
        tooltip: '',
        child: badge,
      ),
    );
  }
}
