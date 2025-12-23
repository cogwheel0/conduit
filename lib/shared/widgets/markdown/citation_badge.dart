import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/models/chat_message.dart';
import '../../theme/theme_extensions.dart';

/// Helper utilities for working with source references.
class SourceHelper {
  const SourceHelper._();

  /// Extracts a URL from a source reference, checking multiple fields.
  static String? getSourceUrl(ChatSourceReference source) {
    String? url = source.url;
    if (url == null || url.isEmpty) {
      if (source.id != null && source.id!.startsWith('http')) {
        url = source.id;
      } else if (source.title != null && source.title!.startsWith('http')) {
        url = source.title;
      } else if (source.metadata != null) {
        url =
            source.metadata!['url']?.toString() ??
            source.metadata!['source']?.toString() ??
            source.metadata!['link']?.toString();
      }
    }
    return (url != null && url.startsWith('http')) ? url : null;
  }

  /// Gets a display title for a source.
  ///
  /// For web sources (with URLs), shows the domain name like "wikipedia.org".
  /// This matches OpenWebUI's behavior where web search results show domains.
  static String getSourceTitle(ChatSourceReference source, int index) {
    // For web sources, prefer showing the URL domain
    final url = getSourceUrl(source);
    if (url != null) {
      return extractDomain(url);
    }

    // If title is a URL, extract domain
    if (source.title != null && source.title!.isNotEmpty) {
      final title = source.title!;
      if (title.startsWith('http')) {
        return extractDomain(title);
      }
      return title;
    }

    // Check if ID is a URL
    if (source.id != null && source.id!.isNotEmpty) {
      final id = source.id!;
      if (id.startsWith('http')) {
        return extractDomain(id);
      }
      return id;
    }

    return 'Source ${index + 1}';
  }

  /// Extracts the domain from a URL for display.
  static String extractDomain(String url) {
    try {
      final uri = Uri.parse(url);
      String domain = uri.host;
      if (domain.startsWith('www.')) {
        domain = domain.substring(4);
      }
      return domain;
    } catch (e) {
      return url;
    }
  }

  /// Formats a title for display, truncating if needed.
  /// Matches OpenWebUI's getDisplayTitle behavior.
  static String formatDisplayTitle(String title) {
    if (title.isEmpty) return 'N/A';
    if (title.length > 25) {
      return '${title.substring(0, 12)}…${title.substring(title.length - 8)}';
    }
    return title;
  }

  /// Launches a URL in an external browser.
  static Future<void> launchSourceUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      // Handle error silently
    }
  }
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

    // Check if index is valid
    if (sourceIndex < 0 || sourceIndex >= sources.length) {
      return const SizedBox.shrink();
    }

    final source = sources[sourceIndex];
    final url = SourceHelper.getSourceUrl(source);
    final title = SourceHelper.getSourceTitle(source, sourceIndex);
    final displayTitle = SourceHelper.formatDisplayTitle(title);

    return Tooltip(
      message: title,
      preferBelow: false,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            if (onTap != null) {
              onTap!();
            } else if (url != null) {
              SourceHelper.launchSourceUrl(url);
            }
          },
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.sm,
              vertical: Spacing.xxs,
            ),
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: theme.surfaceContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: theme.dividerColor.withValues(alpha: 0.5),
                width: 1,
              ),
            ),
            child: Text(
              displayTitle,
              style: TextStyle(
                fontSize: AppTypography.labelSmall,
                fontWeight: FontWeight.w500,
                color: theme.textSecondary,
              ),
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

    // Get first valid source for display
    final firstIndex = sourceIndices.first;
    final isFirstValid = firstIndex >= 0 && firstIndex < sources.length;

    if (!isFirstValid) {
      return const SizedBox.shrink();
    }

    final firstSource = sources[firstIndex];
    final firstTitle = SourceHelper.getSourceTitle(firstSource, firstIndex);
    final displayTitle = SourceHelper.formatDisplayTitle(firstTitle);
    final additionalCount = sourceIndices.length - 1;

    return PopupMenuButton<int>(
      tooltip: 'View sources',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
      ),
      color: theme.surfaceBackground,
      surfaceTintColor: Colors.transparent,
      elevation: Elevation.medium,
      itemBuilder: (context) {
        return sourceIndices
            .map((index) {
              final isValid = index >= 0 && index < sources.length;
              if (!isValid) return null;

              final source = sources[index];
              final title = SourceHelper.getSourceTitle(source, index);

              return PopupMenuItem<int>(
                value: index,
                height: 40,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.link_rounded,
                      size: 14,
                      color: theme.textSecondary.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: Spacing.sm),
                    Flexible(
                      child: Text(
                        SourceHelper.formatDisplayTitle(title),
                        style: TextStyle(
                          fontSize: AppTypography.bodySmall,
                          fontWeight: FontWeight.w500,
                          color: theme.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              );
            })
            .whereType<PopupMenuItem<int>>()
            .toList();
      },
      onSelected: (index) {
        if (onSourceTap != null) {
          onSourceTap!(index);
        } else if (index >= 0 && index < sources.length) {
          final url = SourceHelper.getSourceUrl(sources[index]);
          if (url != null) {
            SourceHelper.launchSourceUrl(url);
          }
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.xxs,
        ),
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: theme.surfaceContainer.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(AppBorderRadius.chip),
          border: Border.all(
            color: theme.cardBorder.withValues(alpha: 0.5),
            width: BorderWidth.thin,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.link_rounded,
              size: 10,
              color: theme.textSecondary.withValues(alpha: 0.7),
            ),
            const SizedBox(width: Spacing.xxs),
            Text(
              displayTitle,
              style: TextStyle(
                fontSize: AppTypography.labelSmall,
                fontWeight: FontWeight.w500,
                color: theme.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(width: Spacing.xxs),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: theme.buttonPrimary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(AppBorderRadius.small),
              ),
              child: Text(
                '+$additionalCount',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  color: theme.buttonPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
