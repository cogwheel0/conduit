import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/models/chat_message.dart';
import '../../../../shared/theme/theme_extensions.dart';
import '../../../../shared/widgets/markdown/source_reference_helper.dart';

/// OpenWebUI-style sources component with compact button and expandable list
class OpenWebUISourcesWidget extends StatefulWidget {
  const OpenWebUISourcesWidget({
    super.key,
    required this.sources,
    this.messageId,
  });

  final List<ChatSourceReference> sources;
  final String? messageId;

  @override
  State<OpenWebUISourcesWidget> createState() => _OpenWebUISourcesWidgetState();
}

class _OpenWebUISourcesWidgetState extends State<OpenWebUISourcesWidget> {
  bool _showSources = false;

  @override
  Widget build(BuildContext context) {
    if (widget.sources.isEmpty) {
      return const SizedBox.shrink();
    }

    // Debug logging can be enabled here if needed for future debugging
    // debugPrint('OpenWebUI Sources: ${widget.sources.length} sources');

    final theme = context.conduitTheme;
    final urlSources = widget.sources.where((source) {
      return SourceReferenceHelper.getSourceUrl(source) != null;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Compact sources toggle button
        Padding(
          padding: const EdgeInsets.only(top: 0, bottom: 4),
          child: Row(
            children: [
              InkWell(
                onTap: () {
                  setState(() {
                    _showSources = !_showSources;
                  });
                },
                borderRadius: BorderRadius.circular(20),
                hoverColor: theme.surfaceContainer.withValues(alpha: 0.1),
                splashColor: theme.surfaceContainer.withValues(alpha: 0.2),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
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
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Favicon previews for URL sources
                      if (urlSources.isNotEmpty) ...[
                        SizedBox(
                          width: urlSources.length > 3
                              ? 52
                              : urlSources.length * 18.0,
                          height: 16,
                          child: Stack(
                            children: [
                              for (
                                int i = 0;
                                i <
                                    (urlSources.length > 3
                                        ? 3
                                        : urlSources.length);
                                i++
                              )
                                Positioned(
                                  left: i * 12.0,
                                  child: Container(
                                    width: 16,
                                    height: 16,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: theme.surfaceBackground,
                                        width: 1,
                                      ),
                                      color: theme.surfaceBackground,
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(7),
                                      child: Image.network(
                                        'https://www.google.com/s2/favicons?sz=32&domain=${SourceReferenceHelper.extractDomain(SourceReferenceHelper.getSourceUrl(urlSources[i])!)}',
                                        width: 14,
                                        height: 14,
                                        errorBuilder:
                                            (context, error, stackTrace) {
                                              return Container(
                                                width: 14,
                                                height: 14,
                                                color: theme.textSecondary
                                                    .withValues(alpha: 0.1),
                                                child: Icon(
                                                  Icons.language,
                                                  size: 8,
                                                  color: theme.textSecondary
                                                      .withValues(alpha: 0.6),
                                                ),
                                              );
                                            },
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        widget.sources.length == 1
                            ? '1 Source'
                            : '${widget.sources.length} Sources',
                        style: TextStyle(
                          fontSize: AppTypography.labelSmall,
                          fontWeight: FontWeight.w600,
                          color: theme.textPrimary.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),

        // Expandable sources list
        if (_showSources) ...[
          const SizedBox(height: 6),
          Column(
            children: [
              for (int i = 0; i < widget.sources.length; i++) ...[
                _buildSourceItem(context, widget.sources[i], i + 1),
                if (i < widget.sources.length - 1) const SizedBox(height: 2),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildSourceItem(
    BuildContext context,
    ChatSourceReference source,
    int index,
  ) {
    final theme = context.conduitTheme;

    final url = SourceReferenceHelper.getSourceUrl(source);
    final isUrl = url != null;
    final displayText = SourceReferenceHelper.getSourceLabel(source, index - 1);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: isUrl ? () => _launchUrl(url) : null,
        borderRadius: BorderRadius.circular(8),
        child: Row(
          children: [
            // Source number badge
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: theme.surfaceContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Center(
                child: Text(
                  index.toString(),
                  style: TextStyle(
                    fontSize: AppTypography.labelSmall,
                    fontWeight: FontWeight.w600,
                    color: theme.textPrimary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),

            // Favicon for URL sources
            if (isUrl) ...[
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.surfaceBackground, width: 1),
                  color: theme.surfaceBackground,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: Image.network(
                    'https://www.google.com/s2/favicons?sz=32&domain=${SourceReferenceHelper.extractDomain(url)}',
                    width: 14,
                    height: 14,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        width: 14,
                        height: 14,
                        color: theme.textSecondary.withValues(alpha: 0.1),
                        child: Icon(
                          Icons.language,
                          size: 8,
                          color: theme.textSecondary.withValues(alpha: 0.6),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ] else ...[
              // Show a generic icon for non-URL sources
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: theme.surfaceContainer,
                ),
                child: Icon(
                  Icons.description,
                  size: 10,
                  color: theme.textSecondary,
                ),
              ),
              const SizedBox(width: 8),
            ],

            // Source URL/title
            Expanded(
              child: Text(
                displayText,
                style: TextStyle(
                  fontSize: AppTypography.bodySmall,
                  color: theme.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _launchUrl(String url) async {
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
