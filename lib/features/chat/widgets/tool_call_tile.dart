import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../core/utils/tool_calls_parser.dart';
import 'enhanced_image_attachment.dart';

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
  bool _isExpanded = false;

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
    final theme = context.conduitTheme;
    final showShimmer = widget.isStreaming && !tc.done;

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: GestureDetector(
        onTap: () => setState(() => _isExpanded = !_isExpanded),
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _ToolCallHeader(
              toolCall: tc,
              isExpanded: _isExpanded,
              showShimmer: showShimmer,
              theme: theme,
            ),
            AnimatedCrossFade(
              firstChild: const SizedBox.shrink(),
              secondChild: _ToolCallExpandedContent(
                toolCall: tc,
                theme: theme,
                pretty: _pretty,
              ),
              crossFadeState: _isExpanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 200),
            ),
            if (tc.done && tc.files != null) ...[
              _ToolCallFiles(files: tc.files!),
            ],
          ],
        ),
      ),
    );
  }
}

class _ToolCallHeader extends StatelessWidget {
  final ToolCallEntry toolCall;
  final bool isExpanded;
  final bool showShimmer;
  final ConduitThemeExtension theme;

  const _ToolCallHeader({
    required this.toolCall,
    required this.isExpanded,
    required this.showShimmer,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final headerWidget = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(
          isExpanded
              ? Icons.keyboard_arrow_up_rounded
              : Icons.keyboard_arrow_down_rounded,
          size: 14,
          color: theme.textPrimary.withValues(alpha: 0.8),
        ),
        const SizedBox(width: 2),
        Flexible(
          child: Text(
            toolCall.done
                ? 'Used ${toolCall.name}'
                : 'Running ${toolCall.name}…',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppTypography.bodySmall,
              color: theme.textPrimary.withValues(alpha: 0.8),
              height: 1.3,
            ),
          ),
        ),
      ],
    );

    if (showShimmer) {
      return headerWidget
          .animate(onPlay: (controller) => controller.repeat())
          .shimmer(
            duration: 1500.ms,
            color: theme.shimmerHighlight.withValues(alpha: 0.6),
          );
    }
    return headerWidget;
  }
}

class _ToolCallExpandedContent extends StatelessWidget {
  final ToolCallEntry toolCall;
  final ConduitThemeExtension theme;
  final String Function(dynamic, {int max}) pretty;

  const _ToolCallExpandedContent({
    required this.toolCall,
    required this.theme,
    required this.pretty,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: Spacing.xs, left: 16),
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
            if (toolCall.result != null)
              const SizedBox(height: Spacing.xs),
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
