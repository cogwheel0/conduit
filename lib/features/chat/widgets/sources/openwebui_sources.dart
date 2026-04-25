import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/models/chat_message.dart';
import '../../../../shared/theme/theme_extensions.dart';
import '../../../../shared/widgets/conduit_components.dart';
import '../../../../shared/widgets/markdown/source_reference_helper.dart';
import '../../../../shared/widgets/sheet_handle.dart';

/// OpenWebUI-style sources component with a compact chip and details sheet.
class OpenWebUISourcesWidget extends StatelessWidget {
  const OpenWebUISourcesWidget({
    super.key,
    required this.sources,
    this.messageId,
  });

  final List<ChatSourceReference> sources;
  final String? messageId;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = context.conduitTheme;
    final urlSources = sources
        .where((source) {
          return SourceReferenceHelper.getSourceUrl(source) != null;
        })
        .toList(growable: false);
    final chipContent = _buildChipContent(context, urlSources);

    if (PlatformInfo.isIOS26OrHigher()) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final labelStyle = AppTypography.labelMediumStyle.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.textPrimary.withValues(alpha: 0.8),
          );
          final textPainter = TextPainter(
            text: TextSpan(
              text: _sourceCountLabel(sources.length),
              style: labelStyle,
            ),
            maxLines: 1,
            textScaler: MediaQuery.textScalerOf(context),
            textDirection: Directionality.of(context),
          )..layout();
          final faviconWidth = urlSources.isNotEmpty
              ? (urlSources.length > 3 ? 52.0 : urlSources.length * 18.0) + 8.0
              : 0.0;
          final desiredWidth = faviconWidth + textPainter.width + 20.0;
          final targetWidth = constraints.maxWidth.isFinite
              ? desiredWidth.clamp(0.0, constraints.maxWidth).toDouble()
              : desiredWidth;

          return Semantics(
            button: true,
            label: _sourceCountLabel(sources.length),
            child: AdaptiveButton.child(
              onPressed: () => _showSourcesBottomSheet(context),
              style: AdaptiveButtonStyle.glass,
              size: AdaptiveButtonSize.small,
              padding: EdgeInsets.zero,
              minSize: Size(targetWidth, 28),
              useSmoothRectangleBorder: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                child: chipContent,
              ),
            ),
          );
        },
      );
    }

    if (PlatformInfo.isIOS) {
      return Semantics(
        button: true,
        label: _sourceCountLabel(sources.length),
        child: GestureDetector(
          onTap: () => _showSourcesBottomSheet(context),
          behavior: HitTestBehavior.opaque,
          child: FloatingAppBarPill(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: chipContent,
            ),
          ),
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showSourcesBottomSheet(context),
        borderRadius: BorderRadius.circular(20),
        hoverColor: theme.surfaceContainer.withValues(alpha: 0.1),
        splashColor: theme.surfaceContainer.withValues(alpha: 0.2),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.5),
              width: 1,
            ),
            color: theme.surfaceContainer.withValues(alpha: 0.3),
            boxShadow: [
              BoxShadow(
                color: theme.cardShadow.withValues(alpha: 0.1),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: chipContent,
        ),
      ),
    );
  }

  Widget _buildChipContent(
    BuildContext context,
    List<ChatSourceReference> urlSources,
  ) {
    final theme = context.conduitTheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (urlSources.isNotEmpty) ...[
          SizedBox(
            width: urlSources.length > 3 ? 52 : urlSources.length * 18.0,
            height: 16,
            child: Stack(
              children: [
                for (
                  int i = 0;
                  i < (urlSources.length > 3 ? 3 : urlSources.length);
                  i++
                )
                  Positioned(
                    left: i * 12.0,
                    child: _SourceFavicon(
                      url: SourceReferenceHelper.getSourceUrl(urlSources[i])!,
                      size: 16,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
        ],
        Text(
          _sourceCountLabel(sources.length),
          style: AppTypography.labelMediumStyle.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.textPrimary.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }

  void _showSourcesBottomSheet(BuildContext context) {
    final theme = context.conduitTheme;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.surfaceBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.dialog),
        ),
      ),
      builder: (sheetContext) {
        final liveTheme = sheetContext.conduitTheme;

        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.35,
          maxChildSize: 0.9,
          expand: false,
          builder: (_, controller) {
            return SafeArea(
              top: false,
              child: Column(
                children: [
                  const SheetHandle(
                    margin: EdgeInsets.only(
                      top: Spacing.sm,
                      bottom: Spacing.sm,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Spacing.lg,
                      0,
                      Spacing.md,
                      Spacing.sm,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.link_rounded,
                          size: IconSize.md,
                          color: liveTheme.textPrimary,
                        ),
                        const SizedBox(width: Spacing.sm),
                        Expanded(
                          child: Text(
                            _sourceCountLabel(sources.length),
                            style: AppTypography.bodyLargeStyle.copyWith(
                              fontWeight: FontWeight.w600,
                              color: liveTheme.textPrimary,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          color: liveTheme.textSecondary,
                        ),
                      ],
                    ),
                  ),
                  Divider(
                    height: 1,
                    color: liveTheme.dividerColor.withValues(alpha: 0.3),
                  ),
                  Expanded(
                    child: ListView.separated(
                      controller: controller,
                      padding: const EdgeInsets.all(Spacing.lg),
                      itemCount: sources.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: Spacing.sm),
                      itemBuilder: (itemContext, index) {
                        return _buildSourceItem(
                          itemContext,
                          sources[index],
                          index,
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSourceItem(
    BuildContext context,
    ChatSourceReference source,
    int index,
  ) {
    final theme = context.conduitTheme;
    final url = SourceReferenceHelper.getSourceUrl(source);
    final displayText = SourceReferenceHelper.getSourceLabel(source, index);
    final snippet = _sourceSnippet(source);
    final type = source.type?.trim();
    final hasType = type != null && type.isNotEmpty;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: url == null ? null : () => _launchUrl(url),
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        child: Ink(
          padding: const EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            color: theme.surfaceContainer.withValues(alpha: 0.36),
            borderRadius: BorderRadius.circular(AppBorderRadius.card),
            border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.32),
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SourceIndexBadge(index: index + 1),
                  const SizedBox(width: Spacing.sm),
                  if (url != null) ...[
                    _SourceFavicon(url: url, size: 18),
                    const SizedBox(width: Spacing.sm),
                  ] else ...[
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(9),
                        color: theme.surfaceContainerHighest,
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.description_outlined,
                        size: 11,
                        color: theme.textSecondary,
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayText,
                          style: AppTypography.bodyMediumStyle.copyWith(
                            fontWeight: FontWeight.w600,
                            color: theme.textPrimary,
                          ),
                        ),
                        if (url != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            url,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.bodySmallStyle.copyWith(
                              color: theme.textSecondary,
                            ),
                          ),
                        ] else if (hasType) ...[
                          const SizedBox(height: 2),
                          Text(
                            type,
                            style: AppTypography.bodySmallStyle.copyWith(
                              color: theme.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (url != null) ...[
                    const SizedBox(width: Spacing.sm),
                    Icon(
                      Icons.open_in_new_rounded,
                      size: IconSize.sm,
                      color: theme.textSecondary,
                    ),
                  ],
                ],
              ),
              if (snippet != null) ...[
                const SizedBox(height: Spacing.sm),
                Text(
                  snippet,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.bodySmallStyle.copyWith(
                    height: 1.45,
                    color: theme.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _sourceCountLabel(int count) {
    return count == 1 ? '1 Source' : '$count Sources';
  }

  String? _sourceSnippet(ChatSourceReference source) {
    final candidates = <dynamic>[
      source.snippet,
      ..._metadataSnippetCandidates(source),
    ];

    for (final candidate in candidates) {
      final normalized = _normalizeSnippet(candidate);
      if (normalized != null) {
        return normalized;
      }
    }

    return null;
  }

  Iterable<dynamic> _metadataSnippetCandidates(
    ChatSourceReference source,
  ) sync* {
    final metadata = source.metadata;
    if (metadata == null) {
      return;
    }

    final documents = metadata['documents'];
    if (documents is List) {
      for (final document in documents) {
        yield document;
      }
    }

    final primaryMetadata = SourceReferenceHelper.primaryMetadata(source);
    final nestedSource = SourceReferenceHelper.nestedSourceMetadata(source);
    for (final entry in [primaryMetadata, nestedSource]) {
      if (entry == null) {
        continue;
      }
      yield entry['snippet'];
      yield entry['content'];
      yield entry['description'];
      yield entry['text'];
    }
  }

  String? _normalizeSnippet(dynamic value) {
    if (value == null) {
      return null;
    }

    final text = value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.isEmpty ? null : text;
  }

  Future<void> _launchUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      // Ignore source launch failures.
    }
  }
}

class _SourceIndexBadge extends StatelessWidget {
  const _SourceIndexBadge({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: theme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(7),
      ),
      alignment: Alignment.center,
      child: Text(
        index.toString(),
        style: AppTypography.labelMediumStyle.copyWith(
          fontWeight: FontWeight.w600,
          color: theme.textPrimary,
        ),
      ),
    );
  }
}

class _SourceFavicon extends StatelessWidget {
  const _SourceFavicon({required this.url, required this.size});

  final String url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final domain = SourceReferenceHelper.extractDomain(url);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size / 2),
        border: Border.all(color: theme.surfaceBackground, width: 1),
        color: theme.surfaceBackground,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular((size / 2) - 1),
        child: Image.network(
          'https://www.google.com/s2/favicons?sz=32&domain=$domain',
          width: size - 2,
          height: size - 2,
          errorBuilder: (context, error, stackTrace) {
            return Container(
              width: size - 2,
              height: size - 2,
              color: theme.textSecondary.withValues(alpha: 0.1),
              alignment: Alignment.center,
              child: Icon(
                Icons.language,
                size: size * 0.55,
                color: theme.textSecondary.withValues(alpha: 0.6),
              ),
            );
          },
        ),
      ),
    );
  }
}
