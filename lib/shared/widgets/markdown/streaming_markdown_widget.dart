import 'package:flutter/material.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/utils/citation_parser.dart';
import '../../theme/theme_extensions.dart';
import 'citation_badge.dart';
import 'markdown_config.dart';
import 'markdown_preprocessor.dart';
import 'renderer/block_renderer.dart';
import 'renderer/conduit_markdown_widget.dart';

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

    final normalized =
        ConduitMarkdownPreprocessor.normalize(content);

    // Collect all special blocks (Mermaid and ChartJS)
    final specialBlocks = <_SpecialBlock>[];

    // Find mermaid blocks
    for (final match
        in _mermaidRegex.allMatches(normalized)) {
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
    for (final match
        in _htmlBlockRegex.allMatches(normalized)) {
      final html = match.group(1)?.trim() ?? '';
      if (html.isNotEmpty &&
          ConduitMarkdown.containsChartJs(html)) {
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
    specialBlocks.sort(
      (a, b) => a.start.compareTo(b.start),
    );

    Widget buildMarkdown(String data) {
      return _buildMarkdownWithCitations(
        context,
        data,
      );
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

        final before = normalized.substring(
          currentIndex,
          block.start,
        );
        if (before.trim().isNotEmpty) {
          children.add(buildMarkdown(before));
        }

        switch (block.type) {
          case _BlockType.mermaid:
            children.add(
              ConduitMarkdown.buildMermaidBlock(
                context,
                block.content,
              ),
            );
          case _BlockType.chartJs:
            children.add(
              ConduitMarkdown.buildChartJsBlock(
                context,
                block.content,
              ),
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
  Widget _buildMarkdownWithCitations(
    BuildContext context,
    String data,
  ) {
    // If no sources, render plain markdown
    if (sources == null || sources!.isEmpty) {
      return ConduitMarkdownWidget(
        data: data,
        onLinkTap: onTapLink,
        imageBuilder: _adaptImageBuilder(),
      );
    }

    // No citations present, render plain markdown
    if (!CitationParser.hasCitations(data)) {
      return ConduitMarkdownWidget(
        data: data,
        onLinkTap: onTapLink,
        imageBuilder: _adaptImageBuilder(),
      );
    }

    // Render content with inline citation badges
    return _InlineCitationMarkdown(
      data: data,
      sources: sources!,
      onTapLink: onTapLink,
      onSourceTap: onSourceTap,
      imageBuilderOverride: imageBuilderOverride,
    );
  }
}

/// Renders markdown with inline citation badges.
///
/// Parses the markdown content, identifies citation
/// patterns, and renders them as clickable badges inline.
class _InlineCitationMarkdown extends StatelessWidget {
  const _InlineCitationMarkdown({
    required this.data,
    required this.sources,
    this.onTapLink,
    this.onSourceTap,
    this.imageBuilderOverride,
  });

  final String data;
  final List<ChatSourceReference> sources;
  final MarkdownLinkTapCallback? onTapLink;
  final void Function(int sourceIndex)? onSourceTap;
  final Widget Function(
    Uri uri,
    String? title,
    String? alt,
  )? imageBuilderOverride;

  /// Adapts [imageBuilderOverride] to [ImageBuilder].
  ImageBuilder? _adaptImageBuilder() {
    final override = imageBuilderOverride;
    if (override == null) return null;
    return (String src, String? alt, String? title) {
      final uri = Uri.tryParse(src);
      if (uri == null) {
        return const SizedBox.shrink();
      }
      return override(uri, title, alt);
    };
  }

  @override
  Widget build(BuildContext context) {
    final segments =
        _parseContentWithCitations(data);

    if (segments.isEmpty) {
      return ConduitMarkdownWidget(
        data: data,
        onLinkTap: onTapLink,
        imageBuilder: _adaptImageBuilder(),
      );
    }

    // Build widgets for each segment
    final children = <Widget>[];
    final buffer = StringBuffer();

    for (final segment in segments) {
      if (segment.hasCitations) {
        // Flush accumulated non-citation content
        if (buffer.isNotEmpty) {
          children.add(
            ConduitMarkdownWidget(
              data: buffer.toString(),
              onLinkTap: onTapLink,
              imageBuilder: _adaptImageBuilder(),
            ),
          );
          buffer.clear();
        }

        // Render segment with inline citations
        children.add(
          _buildParagraphWithCitations(
            context,
            segment.text,
          ),
        );
      } else {
        // Accumulate non-citation content
        if (buffer.isNotEmpty) {
          buffer.writeln();
        }
        buffer.write(segment.text);
      }
    }

    // Flush remaining content
    if (buffer.isNotEmpty) {
      children.add(
        ConduitMarkdownWidget(
          data: buffer.toString(),
          onLinkTap: onTapLink,
          imageBuilder: _adaptImageBuilder(),
        ),
      );
    }

    if (children.isEmpty) {
      return const SizedBox.shrink();
    }

    if (children.length == 1) {
      return children.first;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// Parses content into segments, identifying which have citations.
  List<_ContentSegment> _parseContentWithCitations(String content) {
    final segments = <_ContentSegment>[];

    // Split by double newlines (paragraphs) while preserving structure
    final paragraphs = content.split(RegExp(r'\n\n+'));

    for (final paragraph in paragraphs) {
      if (paragraph.trim().isEmpty) continue;

      final hasCitations = CitationParser.hasCitations(paragraph);
      segments.add(
        _ContentSegment(text: paragraph, hasCitations: hasCitations),
      );
    }

    return segments;
  }

  /// Builds a paragraph widget with inline citation badges.
  Widget _buildParagraphWithCitations(BuildContext context, String text) {
    final theme = context.conduitTheme;
    final segments = CitationParser.parse(text);

    if (segments == null || segments.isEmpty) {
      return Text(text);
    }

    final baseStyle = AppTypography.bodyMediumStyle.copyWith(
      color: theme.textPrimary,
      height: 1.45,
    );

    final spans = <InlineSpan>[];

    for (final segment in segments) {
      if (segment.isText && segment.text != null) {
        // Process text for basic markdown formatting
        spans.add(_buildTextSpan(segment.text!, baseStyle, theme));
      } else if (segment.isCitation && segment.citation != null) {
        final citation = segment.citation!;
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _buildCitationBadge(context, citation.sourceIds),
          ),
        );
      }
    }

    return Text.rich(TextSpan(children: spans), style: baseStyle);
  }

  /// Builds a text span with basic markdown formatting support.
  InlineSpan _buildTextSpan(
    String text,
    TextStyle baseStyle,
    ConduitThemeExtension theme,
  ) {
    // Handle basic inline markdown: **bold**, *italic*, `code`
    final spans = <InlineSpan>[];

    // Pattern for bold, italic, and code
    final pattern = RegExp(r'(\*\*(.+?)\*\*)|(\*(.+?)\*)|(`(.+?)`)');

    var lastEnd = 0;
    for (final match in pattern.allMatches(text)) {
      // Add text before match
      if (match.start > lastEnd) {
        spans.add(
          TextSpan(
            text: text.substring(lastEnd, match.start),
            style: baseStyle,
          ),
        );
      }

      if (match.group(1) != null) {
        // Bold **text**
        spans.add(
          TextSpan(
            text: match.group(2),
            style: baseStyle.copyWith(fontWeight: FontWeight.bold),
          ),
        );
      } else if (match.group(3) != null) {
        // Italic *text*
        spans.add(
          TextSpan(
            text: match.group(4),
            style: baseStyle.copyWith(fontStyle: FontStyle.italic),
          ),
        );
      } else if (match.group(5) != null) {
        // Code `text`
        spans.add(
          TextSpan(
            text: match.group(6),
            style: baseStyle.copyWith(
              fontFamily: AppTypography.monospaceFontFamily,
              backgroundColor: theme.surfaceContainer.withValues(alpha: 0.3),
            ),
          ),
        );
      }

      lastEnd = match.end;
    }

    // Add remaining text
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd), style: baseStyle));
    }

    if (spans.isEmpty) {
      return TextSpan(text: text, style: baseStyle);
    }

    if (spans.length == 1) {
      return spans.first;
    }

    return TextSpan(children: spans);
  }

  /// Builds a citation badge widget.
  Widget _buildCitationBadge(BuildContext context, List<int> sourceIds) {
    if (sourceIds.isEmpty) {
      return const SizedBox.shrink();
    }

    // Convert to 0-based indices
    final indices = sourceIds.map((id) => id - 1).toList();

    if (indices.length == 1) {
      return CitationBadge(
        sourceIndex: indices.first,
        sources: sources,
        onTap: onSourceTap != null ? () => onSourceTap!(indices.first) : null,
      );
    }

    return CitationBadgeGroup(
      sourceIndices: indices,
      sources: sources,
      onSourceTap: onSourceTap,
    );
  }
}

/// A segment of content that may or may not contain citations.
class _ContentSegment {
  final String text;
  final bool hasCitations;

  const _ContentSegment({required this.text, required this.hasCitations});
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
