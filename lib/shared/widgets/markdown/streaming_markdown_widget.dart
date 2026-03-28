import 'package:flutter/material.dart';

import '../../../core/models/chat_message.dart';
import 'markdown_config.dart';
import 'markdown_preprocessor.dart';
import 'renderer/block_renderer.dart';
import 'renderer/qonduit_markdown_widget.dart';

// Pre-compiled regex for mermaid diagram detection (performance optimization)
final _mermaidRegex = RegExp(r'```mermaid\s*([\s\S]*?)```', multiLine: true);

// Pre-compiled regex for HTML code blocks that may contain ChartJS
final _htmlBlockRegex = RegExp(r'```html\s*([\s\S]*?)```', multiLine: true);

class StreamingMarkdownWidget extends StatelessWidget {
  const StreamingMarkdownWidget({
    super.key,
    required this.content,
    required this.isStreaming,
    this.onTapLink,
    this.imageBuilderOverride,
    this.sources,
    this.onSourceTap,
  });

  final String content;
  final bool isStreaming;
  final MarkdownLinkTapCallback? onTapLink;
  final Widget Function(Uri uri, String? title, String? alt)?
  imageBuilderOverride;

  /// Sources for inline citation badge rendering.
  /// When provided, [1] patterns will be rendered as clickable badges.
  final List<ChatSourceReference>? sources;

  /// Callback when a source badge is tapped.
  final void Function(int sourceIndex)? onSourceTap;

  /// Adapts the legacy [imageBuilderOverride] callback
  /// to the [ImageBuilder] signature used by the custom
  /// renderer.
  ImageBuilder? _adaptImageBuilder() {
    final override = imageBuilderOverride;
    if (override == null) return null;
    return (String src, String? alt, String? title) {
      final uri = Uri.tryParse(src);
      if (uri == null) return const SizedBox.shrink();
      return override(uri, title, alt);
    };
  }

  @override
  Widget build(BuildContext context) {
    if (content.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    final normalized = QonduitMarkdownPreprocessor.normalize(content);

    // Collect all special blocks (Mermaid and ChartJS)
    final specialBlocks = <_SpecialBlock>[];

    // Find mermaid blocks
    for (final match in _mermaidRegex.allMatches(normalized)) {
      final code = match.group(1)?.trim() ?? '';
      if (code.isNotEmpty) {
        specialBlocks.add(
          _SpecialBlock(
            start: match.start,
            end: match.end,
            type: _BlockType.mermaid,
            content: code,
          ),
        );
      }
    }

    // Find HTML blocks that contain ChartJS
    for (final match in _htmlBlockRegex.allMatches(normalized)) {
      final html = match.group(1)?.trim() ?? '';
      if (html.isNotEmpty && QonduitMarkdown.containsChartJs(html)) {
        specialBlocks.add(
          _SpecialBlock(
            start: match.start,
            end: match.end,
            type: _BlockType.chartJs,
            content: html,
          ),
        );
      }
    }

    // Sort by position
    specialBlocks.sort((a, b) => a.start.compareTo(b.start));

    Widget buildMarkdown(String data) {
      return _buildMarkdownWithCitations(data);
    }

    Widget result;

    if (specialBlocks.isEmpty) {
      result = buildMarkdown(normalized);
    } else {
      final children = <Widget>[];
      var currentIndex = 0;
      for (final block in specialBlocks) {
        // Skip overlapping blocks
        if (block.start < currentIndex) continue;

        final before = normalized.substring(currentIndex, block.start);
        if (before.trim().isNotEmpty) {
          children.add(buildMarkdown(before));
        }

        switch (block.type) {
          case _BlockType.mermaid:
            children.add(
              QonduitMarkdown.buildMermaidBlock(context, block.content),
            );
          case _BlockType.chartJs:
            children.add(
              QonduitMarkdown.buildChartJsBlock(context, block.content),
            );
        }

        currentIndex = block.end;
      }

      final tail = normalized.substring(currentIndex);
      if (tail.trim().isNotEmpty) {
        children.add(buildMarkdown(tail));
      }

      result = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }

    // Only wrap in SelectionArea when not streaming to
    // avoid concurrent modification errors in Flutter's
    // selection system during rapid updates.
    if (isStreaming) {
      return result;
    }

    return SelectionArea(child: result);
  }

  /// Builds markdown with inline citation badges.
  ///
  /// Citations like [1], [2] are rendered as clickable
  /// badges inline with the text.
  Widget _buildMarkdownWithCitations(String data) {
    return QonduitMarkdownWidget(
      data: data,
      onLinkTap: onTapLink,
      imageBuilder: _adaptImageBuilder(),
      sources: sources,
      onSourceTap: onSourceTap,
    );
  }
}

/// Types of special blocks that need custom rendering
enum _BlockType { mermaid, chartJs }

/// Represents a special block in the content
class _SpecialBlock {
  final int start;
  final int end;
  final _BlockType type;
  final String content;

  const _SpecialBlock({
    required this.start,
    required this.end,
    required this.type,
    required this.content,
  });
}

extension StreamingMarkdownExtension on String {
  Widget toMarkdown({
    required BuildContext context,
    bool isStreaming = false,
    MarkdownLinkTapCallback? onTapLink,
    List<ChatSourceReference>? sources,
    void Function(int sourceIndex)? onSourceTap,
  }) {
    return StreamingMarkdownWidget(
      content: this,
      isStreaming: isStreaming,
      onTapLink: onTapLink,
      sources: sources,
      onSourceTap: onSourceTap,
    );
  }
}

class MarkdownWithLoading extends StatelessWidget {
  const MarkdownWithLoading({super.key, this.content, required this.isLoading});

  final String? content;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final value = content ?? '';
    if (isLoading && value.trim().isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return StreamingMarkdownWidget(content: value, isStreaming: isLoading);
  }
}
