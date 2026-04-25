import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'assistant_detail_header.dart';

/// A minimal, unobtrusive streaming status widget inspired by OpenWebUI.
/// Displays live status updates during AI response generation without
/// drawing focus away from the actual response content.
class StreamingStatusWidget extends StatefulWidget {
  const StreamingStatusWidget({
    super.key,
    required this.updates,
    this.isStreaming = true,
  });

  final List<ChatStatusUpdate> updates;
  final bool isStreaming;

  @override
  State<StreamingStatusWidget> createState() => _StreamingStatusWidgetState();
}

class _StreamingStatusWidgetState extends State<StreamingStatusWidget> {
  @override
  Widget build(BuildContext context) {
    final visible = widget.updates
        .where((u) => u.hidden != true)
        .toList(growable: false);
    if (visible.isEmpty) return const SizedBox.shrink();

    final current = visible.last;
    final isPending = current.done != true && widget.isStreaming;
    final hasDetails =
        visible.length > 1 ||
        _collectQueries(current).isNotEmpty ||
        _collectLinks(current).isNotEmpty;

    return GestureDetector(
      onTap: hasDetails
          ? () => _showStatusBottomSheet(
              context,
              updates: visible,
              isStreaming: widget.isStreaming,
            )
          : null,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.only(bottom: Spacing.xs),
        child: _MinimalStatusRow(
          update: current,
          isPending: isPending,
          hasDetails: hasDetails,
        ),
      ),
    );
  }

  void _showStatusBottomSheet(
    BuildContext context, {
    required List<ChatStatusUpdate> updates,
    required bool isStreaming,
  }) {
    final theme = context.conduitTheme;
    final current = updates.last;
    final title = _resolveStatusDescription(current);

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
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.public,
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
                      _MinimalHistoryTimeline(
                        updates: updates,
                        isStreaming: isStreaming,
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Minimal status row - just text with optional chevron.
class _MinimalStatusRow extends StatelessWidget {
  const _MinimalStatusRow({
    required this.update,
    required this.isPending,
    required this.hasDetails,
  });

  final ChatStatusUpdate update;
  final bool isPending;
  final bool hasDetails;

  @override
  Widget build(BuildContext context) {
    final description = _resolveStatusDescription(update);
    return AssistantDetailHeader(
      title: description,
      showShimmer: isPending,
      showChevron: hasDetails,
    );
  }
}

/// Minimal timeline for expanded history - small dots like OpenWebUI.
class _MinimalHistoryTimeline extends StatelessWidget {
  const _MinimalHistoryTimeline({
    required this.updates,
    required this.isStreaming,
  });

  final List<ChatStatusUpdate> updates;
  final bool isStreaming;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    final items = updates.asMap().entries.map((entry) {
      final index = entry.key;
      final update = entry.value;
      final isFirst = index == 0;
      final isLast = index == updates.length - 1;
      final isPending = isLast && update.done != true && isStreaming;
      final description = _resolveStatusDescription(update);
      final queries = _collectQueries(update);
      final links = _collectLinks(update);

      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TimelineMarker(
              index: index,
              isFirst: isFirst,
              isLast: isLast,
              isPending: isPending,
              theme: theme,
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: Spacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AssistantDetailHeader(
                      title: description,
                      showShimmer: isPending,
                      allowWrap: true,
                      showChevron: false,
                    ),
                    if (queries.isNotEmpty) ...[
                      const SizedBox(height: Spacing.xs),
                      _MinimalQueryChips(queries: queries),
                    ],
                    if (links.isNotEmpty) ...[
                      const SizedBox(height: Spacing.xs),
                      _MinimalSourceLinks(links: links),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: items,
    );
  }
}

class _TimelineMarker extends StatelessWidget {
  const _TimelineMarker({
    required this.index,
    required this.isFirst,
    required this.isLast,
    required this.isPending,
    required this.theme,
  });

  static const double _width = 20;
  static const double _dotSize = 8;
  static const double _dotTop = 5;
  static const double _lineWidth = 2;

  final int index;
  final bool isFirst;
  final bool isLast;
  final bool isPending;
  final ConduitThemeExtension theme;

  @override
  Widget build(BuildContext context) {
    final lineColor = theme.textSecondary.withValues(alpha: 0.6);
    final dotColor = isPending
        ? theme.shimmerHighlight.withValues(alpha: 0.85)
        : theme.textSecondary.withValues(alpha: 0.6);
    final backgroundColor = theme.surfaceBackground;
    final centerOffset = (_width - _lineWidth) / 2;
    final dotCenterY = _dotTop + (_dotSize / 2);

    return SizedBox(
      width: _width,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            key: ValueKey<String>('status-timeline-rail-$index'),
            left: centerOffset,
            top: 0,
            bottom: 0,
            width: _lineWidth,
            child: ColoredBox(color: lineColor),
          ),
          if (isFirst)
            Positioned(
              key: ValueKey<String>('status-timeline-mask-top-$index'),
              left: centerOffset - 1,
              width: _lineWidth + 2,
              top: 0,
              height: dotCenterY,
              child: ColoredBox(color: backgroundColor),
            ),
          if (isLast)
            Positioned(
              key: ValueKey<String>('status-timeline-mask-bottom-$index'),
              left: centerOffset - 1,
              width: _lineWidth + 2,
              top: dotCenterY,
              bottom: 0,
              child: ColoredBox(color: backgroundColor),
            ),
          Positioned(
            top: _dotTop,
            left: (_width - _dotSize) / 2,
            child: Container(
              width: _dotSize,
              height: _dotSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dotColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Minimal query chips - smaller, less prominent.
class _MinimalQueryChips extends StatelessWidget {
  const _MinimalQueryChips({required this.queries});

  final List<String> queries;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: queries.asMap().entries.map((entry) {
        final index = entry.key;
        final query = entry.value;
        return GestureDetector(
          onTap: () => _launchSearch(query),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: theme.surfaceContainer.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.search_rounded,
                  size: 11,
                  color: theme.textSecondary,
                ),
                const SizedBox(width: 3),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: Text(
                    query,
                    style: AppTypography.labelMediumStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ).animate().fadeIn(duration: 150.ms, delay: (30 * index).ms),
        );
      }).toList(),
    );
  }

  void _launchSearch(String query) async {
    final url = 'https://www.google.com/search?q=${Uri.encodeComponent(query)}';
    try {
      await launchUrlString(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      DebugLogger.log('Failed to launch search: $e', scope: 'status');
    }
  }
}

/// Minimal source links - smaller, less prominent.
class _MinimalSourceLinks extends StatelessWidget {
  const _MinimalSourceLinks({required this.links});

  final List<_LinkData> links;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final displayLinks = links.take(4).toList();
    final remaining = links.length - 4;

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        ...displayLinks.asMap().entries.map((entry) {
          final index = entry.key;
          final link = entry.value;
          final domain = _extractDomain(link.url);

          return GestureDetector(
            onTap: () => _launchUrl(link.url),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: theme.surfaceContainer.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: Image.network(
                      'https://www.google.com/s2/favicons?sz=16&domain=$domain',
                      width: 12,
                      height: 12,
                      errorBuilder: (context, error, stackTrace) => Icon(
                        Icons.public_rounded,
                        size: 12,
                        color: theme.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 100),
                    child: Text(
                      link.title ?? domain,
                      style: AppTypography.labelMediumStyle.copyWith(
                        color: theme.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ).animate().fadeIn(duration: 150.ms, delay: (30 * index).ms),
          );
        }),
        if (remaining > 0)
          Text(
            '+$remaining',
            style: AppTypography.labelMediumStyle.copyWith(
              color: theme.textSecondary,
            ),
          ).animate().fadeIn(
            duration: 150.ms,
            delay: (30 * displayLinks.length).ms,
          ),
      ],
    );
  }

  void _launchUrl(String url) async {
    try {
      await launchUrlString(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      DebugLogger.log('Failed to launch URL: $e', scope: 'status');
    }
  }

  String _extractDomain(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    var host = uri.host;
    if (host.startsWith('www.')) host = host.substring(4);
    return host;
  }
}

// Helper classes and functions

class _LinkData {
  const _LinkData({required this.url, this.title});
  final String url;
  final String? title;
}

List<String> _collectQueries(ChatStatusUpdate update) {
  final merged = <String>[];
  for (final query in update.queries) {
    final trimmed = query.trim();
    if (trimmed.isNotEmpty && !merged.contains(trimmed)) {
      merged.add(trimmed);
    }
  }
  final single = update.query?.trim();
  if (single != null && single.isNotEmpty && !merged.contains(single)) {
    merged.add(single);
  }
  return merged;
}

List<_LinkData> _collectLinks(ChatStatusUpdate update) {
  final links = <_LinkData>[];

  for (final item in update.items) {
    final url = item.link;
    if (url != null && url.isNotEmpty) {
      links.add(_LinkData(url: url, title: item.title));
    }
  }

  for (final url in update.urls) {
    if (url.isNotEmpty && !links.any((l) => l.url == url)) {
      links.add(_LinkData(url: url));
    }
  }

  return links;
}

String _resolveStatusDescription(ChatStatusUpdate update) {
  final description = update.description?.trim();
  final action = update.action?.trim();

  if (action == 'knowledge_search' && update.query?.isNotEmpty == true) {
    return 'Searching Knowledge for "${update.query}"';
  }

  if (action == 'web_search_queries_generated' && update.queries.isNotEmpty) {
    return 'Searching';
  }

  if (action == 'queries_generated' && update.queries.isNotEmpty) {
    return 'Querying';
  }

  if (action == 'sources_retrieved' && update.count != null) {
    final count = update.count!;
    if (count == 0) return 'No sources found';
    if (count == 1) return 'Retrieved 1 source';
    return 'Retrieved $count sources';
  }

  if (description != null && description.isNotEmpty) {
    if (description == 'Generating search query') {
      return 'Generating search query';
    }
    if (description == 'No search query generated') {
      return 'No search query generated';
    }
    if (description == 'Searching the web') {
      return 'Searching the web';
    }
    return _replaceStatusPlaceholders(description, update);
  }

  if (action != null && action.isNotEmpty) {
    return action.replaceAll('_', ' ').capitalize();
  }

  return 'Processing';
}

String _replaceStatusPlaceholders(String template, ChatStatusUpdate update) {
  var result = template;

  if (result.contains('{{count}}')) {
    final count = update.count ?? update.urls.length + update.items.length;
    result = result.replaceAll(
      '{{count}}',
      count > 0 ? count.toString() : 'multiple',
    );
  }

  if (result.contains('{{searchQuery}}')) {
    final query = update.query?.trim();
    if (query != null && query.isNotEmpty) {
      result = result.replaceAll('{{searchQuery}}', query);
    }
  }

  return result;
}

extension _StringExtension on String {
  String capitalize() {
    if (isEmpty) return this;
    return '${this[0].toUpperCase()}${substring(1)}';
  }
}
