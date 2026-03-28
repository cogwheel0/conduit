import 'dart:convert';
import 'package:flutter/material.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../core/utils/tool_calls_parser.dart';
import 'enhanced_image_attachment.dart';
import 'assistant_detail_header.dart';

/// A tile displaying a tool call execution with status, name,
/// and expandable parameters/result.
///
/// Mirrors Open WebUI's Collapsible.svelte for tool call rendering.
class ToolCallTile extends StatefulWidget {
  /// The tool call entry to display.
  final ToolCallEntry toolCall;

  /// Whether the parent message is currently streaming.
  final bool isStreaming;

  const ToolCallTile({
    super.key,
    required this.toolCall,
    required this.isStreaming,
  });

  @override
  State<ToolCallTile> createState() => _ToolCallTileState();
}

class _ToolCallTileState extends State<ToolCallTile> {
  String _pretty(dynamic v, {int max = 1200}) {
    try {
      final formatted = const JsonEncoder.withIndent('  ').convert(v);
      return formatted.length > max
          ? '${formatted.substring(0, max)}\n…'
          : formatted;
    } catch (_) {
      final s = v?.toString() ?? '';
      return s.length > max ? '${s.substring(0, max)}…' : s;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = widget.toolCall;
    final theme = context.qonduitTheme;
    final showShimmer = widget.isStreaming && !tc.done;

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: GestureDetector(
        onTap: () => _showToolCallBottomSheet(context, tc, theme),
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _ToolCallHeader(toolCall: tc, showShimmer: showShimmer),
            if (tc.done && tc.files != null) ...[
              _ToolCallFiles(files: tc.files!),
            ],
          ],
        ),
      ),
    );
  }

  void _showToolCallBottomSheet(
    BuildContext context,
    ToolCallEntry toolCall,
    QonduitThemeExtension theme,
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
                        Icons.build_outlined,
                        size: IconSize.md,
                        color: theme.textPrimary,
                      ),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: Text(
                          toolCall.done
                              ? 'Used ${toolCall.name}'
                              : 'Running ${toolCall.name}…',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTypography.bodyLarge,
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
                      _ToolCallExpandedContent(
                        toolCall: toolCall,
                        theme: theme,
                        pretty: _pretty,
                        isBottomSheet: true,
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

class _ToolCallHeader extends StatelessWidget {
  final ToolCallEntry toolCall;
  final bool showShimmer;

  const _ToolCallHeader({required this.toolCall, required this.showShimmer});

  @override
  Widget build(BuildContext context) => AssistantDetailHeader(
    title: toolCall.done ? toolCall.name : '${toolCall.name}…',
    showShimmer: showShimmer,
  );
}

class _ToolCallExpandedContent extends StatelessWidget {
  final ToolCallEntry toolCall;
  final QonduitThemeExtension theme;
  final String Function(dynamic, {int max}) pretty;

  const _ToolCallExpandedContent({
    required this.toolCall,
    required this.theme,
    required this.pretty,
    this.isBottomSheet = false,
  });

  final bool isBottomSheet;

  @override
  Widget build(BuildContext context) {
    final child = Container(
      margin: isBottomSheet
          ? EdgeInsets.zero
          : const EdgeInsets.only(top: Spacing.xs, left: 16),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.xs,
      ),
      decoration: BoxDecoration(
        color: theme.surfaceContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(4),
        border: Border(
          left: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.4),
            width: 2,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (toolCall.arguments != null) ...[
            Text(
              'Arguments',
              style: TextStyle(
                fontSize: AppTypography.labelSmall,
                color: theme.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            SelectableText(
              pretty(toolCall.arguments),
              style: TextStyle(
                fontSize: AppTypography.bodySmall,
                color: theme.textSecondary,
                fontFamily: AppTypography.monospaceFontFamily,
                height: 1.35,
              ),
            ),
            if (toolCall.result != null) const SizedBox(height: Spacing.xs),
          ],
          if (toolCall.result != null) ...[
            Text(
              'Result',
              style: TextStyle(
                fontSize: AppTypography.labelSmall,
                color: theme.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            SelectableText(
              pretty(toolCall.result),
              style: TextStyle(
                fontSize: AppTypography.bodySmall,
                color: theme.textSecondary,
                fontFamily: AppTypography.monospaceFontFamily,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );

    if (isBottomSheet) {
      return child;
    }

    return child;
  }
}

/// Renders file images produced by tool calls.
///
/// Mirrors Open WebUI's Collapsible.svelte file rendering logic:
/// - String starting with 'data:image/' -> base64 image
/// - Object with type='image' and url -> network image
class _ToolCallFiles extends StatelessWidget {
  final List<dynamic> files;

  const _ToolCallFiles({required this.files});

  @override
  Widget build(BuildContext context) {
    final imageUrls = <String>[];

    for (final file in files) {
      if (file is String) {
        if (file.startsWith('data:image/')) {
          imageUrls.add(file);
        }
      } else if (file is Map) {
        final type = file['type']?.toString();
        final url = file['url']?.toString();
        if (type == 'image' && url != null && url.isNotEmpty) {
          imageUrls.add(url);
        }
      }
    }

    if (imageUrls.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: Spacing.sm),
      child: Wrap(
        spacing: Spacing.sm,
        runSpacing: Spacing.sm,
        children: imageUrls.map((url) {
          return EnhancedImageAttachment(
            attachmentId: url,
            isMarkdownFormat: true,
            constraints: BoxConstraints(
              maxWidth: imageUrls.length == 1 ? 400 : 200,
              maxHeight: imageUrls.length == 1 ? 300 : 150,
            ),
            disableAnimation: false,
          );
        }).toList(),
      ),
    );
  }
}
