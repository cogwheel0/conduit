import 'package:flutter/material.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/utils/citation_parser.dart';
import 'renderer/markdown_style.dart';
import 'citation_badge.dart';

/// Renders text with inline citation badges.
///
/// Parses citation patterns like [1], [2,3] and renders them as clickable
/// badges showing source titles inline with the surrounding text.
class InlineCitationText extends StatelessWidget {
  const InlineCitationText({
    super.key,
    required this.text,
    required this.sources,
    this.style,
    this.onSourceTap,
  });

  /// The text content that may contain citation patterns like [1], [2,3].
  final String text;

  /// Available sources for citation lookup.
  final List<ChatSourceReference> sources;

  /// Base text style.
  final TextStyle? style;

  /// Callback when a source badge is tapped.
  final void Function(int sourceIndex)? onSourceTap;

  @override
  Widget build(BuildContext context) {
    final segments = CitationParser.parse(text);
    final markdownStyle = ConduitMarkdownStyle.fromTheme(context);

    // If no citations found, render as plain text
    if (segments == null || segments.isEmpty) {
      return Text(text, style: style);
    }

    final baseStyle = style ?? markdownStyle.body;

    final spans = <InlineSpan>[];

    for (final segment in segments) {
      if (segment.isText && segment.text != null) {
        spans.add(TextSpan(text: segment.text, style: baseStyle));
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
