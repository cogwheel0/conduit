import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/models/chat_message.dart';
import '../../theme/theme_extensions.dart';
import 'source_reference_helper.dart';

Future<void> _launchSourceUrl(String url) async {
  try {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  } catch (_) {
    // Ignore source launch failures.
  }
}

TextStyle _badgeLabelTextStyle(BuildContext context, Color color) {
  final textTheme = Theme.of(context).textTheme;
  return textTheme.labelSmall?.copyWith(
        color: color,
        fontWeight: FontWeight.w500,
        fontSize: AppTypography.labelSmallStyle.fontSize,
        height: 1,
      ) ??
      AppTypography.labelSmallStyle.copyWith(
        color: color,
        fontWeight: FontWeight.w500,
        height: 1,
      );
}

TextStyle _badgeCountTextStyle(BuildContext context, Color color) {
  final textTheme = Theme.of(context).textTheme;
  return textTheme.labelSmall?.copyWith(
        color: color,
        fontWeight: FontWeight.w600,
        fontSize: AppTypography.labelSmallStyle.fontSize,
      ) ??
      AppTypography.labelSmallStyle.copyWith(
        color: color,
        fontWeight: FontWeight.w600,
      );
}

/// A compact inline citation badge showing source domain/title.
///
/// Uses the app's design system for consistency with other chips and badges.
class CitationBadge extends StatelessWidget {
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
  Widget build(BuildContext context) {
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
    );
    final displayTitle = SourceReferenceHelper.formatDisplayTitle(inlineTitle);

    return AdaptiveTooltip(
      message: title,
      preferBelow: false,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            if (onTap != null) {
              onTap!();
            } else if (url != null) {
              _launchSourceUrl(url);
            }
          },
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: theme.surfaceContainer.withValues(alpha: 0.24),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              displayTitle,
              style: badgeTextStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }
}

/// A grouped citation badge for multiple sources like [1,2,3].
///
/// Shows first source with +N indicator for additional sources.
class CitationBadgeGroup extends StatelessWidget {
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
  Widget build(BuildContext context) {
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
    final countTextStyle = _badgeCountTextStyle(context, theme.buttonPrimary);

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
    );
    final displayTitle = SourceReferenceHelper.formatDisplayTitle(firstTitle);
    final additionalCount = sourceIndices.length - 1;

    final menuItems = sourceIndices
        .where((index) => index >= 0 && index < sources.length)
        .map((index) {
          final source = sources[index];
          final title = SourceReferenceHelper.getInlineSourceLabel(
            source,
            index,
          );
          return AdaptivePopupMenuItem<int>(
            value: index,
            label: SourceReferenceHelper.formatDisplayTitle(title),
            icon: PlatformInfo.isIOS ? 'link' : Icons.link_rounded,
          );
        })
        .toList();

    return AdaptivePopupMenuButton.widget<int>(
      items: menuItems,
      onSelected: (_, entry) {
        final index = entry.value;
        if (index == null) return;

        if (onSourceTap != null) {
          onSourceTap!(index);
          return;
        }

        if (index >= 0 && index < sources.length) {
          final url = SourceReferenceHelper.getSourceUrl(sources[index]);
          if (url != null) {
            _launchSourceUrl(url);
          }
        }
      },
      buttonStyle: PopupButtonStyle.glass,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          color: theme.surfaceContainer.withValues(alpha: 0.24),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.link_rounded,
              size: 9,
              color: theme.textSecondary.withValues(alpha: 0.7),
            ),
            const SizedBox(width: 3),
            Text(
              displayTitle,
              style: badgeTextStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(width: 3),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: theme.buttonPrimary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(AppBorderRadius.small),
              ),
              child: Text('+$additionalCount', style: countTextStyle),
            ),
          ],
        ),
      ),
    );
  }
}
