import 'dart:io' show Platform;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'package:conduit_core/features/chat/views/chat_status_display.dart';
import 'package:conduit_core/models/chat_message.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../shared/services/raster_media_policy.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/external_link_launcher.dart';
import '../../../shared/widgets/themed_sheets.dart';
import 'assistant_detail_header.dart';

export 'package:conduit_core/features/chat/views/chat_status_display.dart'
    show filterVisibleStatusUpdates;

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
    final displayUpdates = filterVisibleStatusUpdates(
      widget.updates,
      isStreaming: widget.isStreaming,
    );
    if (displayUpdates.isEmpty) return const SizedBox.shrink();

    final current = displayUpdates.last;
    final hermesTools = displayUpdates.where(_isHermesToolUpdate).toList();
    final groupedHermesTitle = hermesTools.length > 1
        ? _buildHermesToolGroupTitle(context, hermesTools, widget.isStreaming)
        : null;
    final isPending = groupedHermesTitle != null
        ? hermesTools.any((update) => update.done != true) && widget.isStreaming
        : current.done != true && widget.isStreaming;
    final hasDetails =
        displayUpdates.length > 1 ||
        _collectQueries(current).isNotEmpty ||
        _collectLinks(current).isNotEmpty ||
        _collectDetailItems(current).isNotEmpty;

    return GestureDetector(
      onTap: hasDetails
          ? () => _showStatusBottomSheet(
              context,
              updates: displayUpdates,
              isStreaming: widget.isStreaming,
            )
          : null,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.only(bottom: Spacing.xs),
        child: _MinimalStatusRow(
          update: current,
          title: groupedHermesTitle,
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
  }) async {
    final theme = context.conduitTheme;
    final current = updates.last;
    final hermesTools = updates.where(_isHermesToolUpdate).toList();
    final title = hermesTools.length > 1
        ? _buildHermesToolGroupTitle(context, hermesTools, isStreaming)
        : _resolveStatusDescription(current);

    if (Platform.isIOS) {
      final items = <NativeSheetItemConfig>[
        for (var index = 0; index < updates.length; index++)
          _buildNativeStatusItem(
            updates[index],
            index: index,
            total: updates.length,
            isStreaming: isStreaming,
          ),
      ];
      final detailSheets = <NativeSheetDetailConfig>[
        for (var index = 0; index < updates.length; index++)
          if (_collectDetailItems(updates[index]).isNotEmpty)
            NativeSheetDetailConfig(
              id: 'status-update-$index',
              title: _resolveStatusDescription(updates[index]),
              items: [
                for (
                  var itemIndex = 0;
                  itemIndex < _collectDetailItems(updates[index]).length;
                  itemIndex++
                )
                  NativeSheetItemConfig(
                    id: 'status-update-$index-detail-$itemIndex',
                    title: _collectDetailItems(
                      updates[index],
                    )[itemIndex].title!,
                    value: _collectDetailItems(
                      updates[index],
                    )[itemIndex].snippet!,
                    kind: NativeSheetItemKind.readOnlyText,
                  ),
              ],
            ),
      ];
      try {
        await NativeSheetBridge.instance.presentSheet(
          root: NativeSheetDetailConfig(
            id: 'streaming-status',
            title: title,
            items: items,
          ),
          detailSheets: detailSheets,
          rethrowErrors: true,
        );
        return;
      } catch (_) {
        if (!context.mounted) {
          return;
        }
      }
    }

    if (!context.mounted) {
      return;
    }

    ThemedSheets.showSurface<void>(
      context: context,
      isScrollControlled: true,
      showHandle: false,
      padding: EdgeInsets.zero,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: DraggableModalSheetSizes.initialChildSize,
          minChildSize: DraggableModalSheetSizes.minChildSize,
          maxChildSize: DraggableModalSheetSizes.maxChildSize,
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
                      SheetCloseButton(
                        onPressed: () => Navigator.of(ctx).pop(),
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

  NativeSheetItemConfig _buildNativeStatusItem(
    ChatStatusUpdate update, {
    required int index,
    required int total,
    required bool isStreaming,
  }) {
    final queries = _collectQueries(update);
    final links = _collectLinks(update);

    return NativeSheetItemConfig(
      id: 'status-update-$index',
      title: _resolveStatusDescription(update),
      subtitle: queries.isEmpty ? null : queries.join(', '),
      sfSymbol: 'circle.dotted',
      kind: NativeSheetItemKind.statusUpdate,
      queries: queries,
      links: [
        for (final link in links)
          NativeSheetLinkConfig(
            url: link.url,
            title: link.title,
            faviconUrl: _nativeFaviconUrl(link.url),
          ),
      ],
      pending: index == total - 1 && update.done != true && isStreaming,
    );
  }

  String? _nativeFaviconUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }

    var domain = uri.host.trim();
    if (domain.startsWith('www.')) {
      domain = domain.substring(4);
    }
    if (domain.isEmpty) {
      return null;
    }

    return 'https://www.google.com/s2/favicons?sz=16&domain=$domain';
  }
}

/// Minimal status row - just text with optional chevron.
class _MinimalStatusRow extends StatelessWidget {
  const _MinimalStatusRow({
    required this.update,
    required this.isPending,
    required this.hasDetails,
    this.title,
  });

  final ChatStatusUpdate update;
  final String? title;
  final bool isPending;
  final bool hasDetails;

  @override
  Widget build(BuildContext context) {
    return AssistantDetailHeader(
      title: title ?? _resolveStatusDescription(update),
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

  static const double _markerGap = Spacing.sm;

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
      final detailItems = _collectDetailItems(update);

      return Stack(
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: _TimelineMarker._width + _markerGap,
              bottom: Spacing.sm,
            ),
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
                if (detailItems.isNotEmpty) ...[
                  const SizedBox(height: Spacing.xs),
                  for (final detail in detailItems)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Spacing.xs),
                      child: SelectableText(
                        '${detail.title}: ${detail.snippet}',
                        style: AppTypography.bodySmallStyle.copyWith(
                          color: theme.textSecondary,
                        ),
                        magnifierConfiguration:
                            nativeIosTextMagnifierConfiguration,
                        contextMenuBuilder:
                            AdaptiveTextSelectionMenu.editableText,
                      ),
                    ),
                ],
              ],
            ),
          ),
          Positioned(
            top: 0,
            bottom: 0,
            left: 0,
            child: _TimelineMarker(
              index: index,
              isFirst: isFirst,
              isLast: isLast,
              isPending: isPending,
              theme: theme,
            ),
          ),
        ],
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
          child: _statusItemEntrance(
            context,
            index: index,
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
            ),
          ),
        );
      }).toList(),
    );
  }

  void _launchSearch(String query) async {
    final url = 'https://www.google.com/search?q=${Uri.encodeComponent(query)}';
    await launchExternalLink(url, scope: 'status');
  }
}

/// Minimal source links - smaller, less prominent.
class _MinimalSourceLinks extends StatelessWidget {
  const _MinimalSourceLinks({required this.links});

  final List<StatusLink> links;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final displayLinks = links.take(4).toList();
    final remaining = links.length - 4;
    final faviconTarget = RasterMediaPolicy.forBox(
      context,
      profile: RasterDecodeProfile.avatar,
      logicalWidth: 12,
      logicalHeight: 12,
    );

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        ...displayLinks.asMap().entries.map((entry) {
          final index = entry.key;
          final link = entry.value;
          final domain = statusLinkDomain(link.url);

          return GestureDetector(
            onTap: () => launchExternalLink(link.url, scope: 'status'),
            child: _statusItemEntrance(
              context,
              index: index,
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
                      child: Image(
                        image: RasterMediaPolicy.resizeProvider(
                          NetworkImage(
                            'https://www.google.com/s2/favicons'
                            '?sz=16&domain=$domain',
                          ),
                          faviconTarget,
                        ),
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
              ),
            ),
          );
        }),
        if (remaining > 0)
          _statusItemEntrance(
            context,
            index: displayLinks.length,
            child: Text(
              '+$remaining',
              style: AppTypography.labelMediumStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
          ),
      ],
    );
  }
}

Widget _statusItemEntrance(
  BuildContext context, {
  required int index,
  required Widget child,
}) {
  if (context.reduceMotion) {
    return child;
  }
  return child.animate().fadeIn(duration: 150.ms, delay: (30 * index).ms);
}

// The status rules live in core (chat_status_display.dart), shared with
// every other client; these keep this file's call sites short.

List<String> _collectQueries(ChatStatusUpdate update) =>
    collectStatusQueries(update);

List<ChatStatusItem> _collectDetailItems(ChatStatusUpdate update) =>
    collectStatusDetailItems(update);

List<StatusLink> _collectLinks(ChatStatusUpdate update) =>
    collectStatusLinks(update);

bool _isHermesToolUpdate(ChatStatusUpdate update) => isHermesToolStatus(update);

String _buildHermesToolGroupTitle(
  BuildContext context,
  List<ChatStatusUpdate> updates,
  bool isStreaming,
) {
  final l10n = AppLocalizations.of(context)!;
  final summary = hermesToolGroupSummary(
    updates,
    unnamedTool: l10n.markdownDetailsGroupUnnamedTool,
  );
  return isStreaming && updates.any((update) => update.done != true)
      ? l10n.markdownDetailsGroupPendingTitle(summary)
      : l10n.markdownDetailsGroupCompleteTitle(summary);
}

String _resolveStatusDescription(ChatStatusUpdate update) =>
    resolveStatusDescription(update);
