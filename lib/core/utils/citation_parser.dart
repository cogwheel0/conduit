/// Utility class for parsing inline citation references like [1], [1,2,3].
///
/// This matches OpenWebUI's citation-extension.ts behavior where adjacent
/// citation brackets are merged and parsed into source indices.
///
/// Reference: openwebui-src/src/lib/utils/marked/citation-extension.ts
library;

/// Represents a parsed citation with one or more source IDs.
class Citation {
  /// 1-based source indices referenced by this citation.
  final List<int> sourceIds;

  /// The raw text that was matched (e.g., "[1]" or "[1,2,3]").
  final String raw;

  const Citation({required this.sourceIds, required this.raw});

  /// Converts to 0-based indices for array access.
  List<int> get zeroBasedIndices =>
      sourceIds.map((id) => id - 1).toList(growable: false);
}

/// A segment of content that is either plain text or a citation.
class CitationSegment {
  final String? text;
  final Citation? citation;

  const CitationSegment._({this.text, this.citation});

  factory CitationSegment.text(String text) => CitationSegment._(text: text);
  factory CitationSegment.citation(Citation citation) =>
      CitationSegment._(citation: citation);

  bool get isText => text != null;
  bool get isCitation => citation != null;
}

/// Parser for inline citations in markdown content.
class CitationParser {
  const CitationParser._();

  // Matches one or more adjacent [N], [N,M,...], or [N#suffix] blocks.
  // Examples: "[1]", "[1,2,3]", "[1][2]", "[1,2][3,4#foo]"
  static final _citationPattern = RegExp(
    r'(\[(?:\d+(?:#[^,\]\s]+)?(?:,\s*\d+(?:#[^,\]\s]+)?)*)\])+',
  );

  // Matches individual bracket groups within a citation match
  static final _bracketGroupPattern = RegExp(r'\[([^\]]+)\]');

  // Avoids matching footnotes like [^1]
  static final _footnotePattern = RegExp(r'^\[\^');

  /// Parses content and returns segments of text and citations.
  ///
  /// Returns null if no citations are found.
  static List<CitationSegment>? parse(String content) {
    if (content.isEmpty) return null;

    final segments = <CitationSegment>[];
    int lastEnd = 0;

    for (final match in _citationPattern.allMatches(content)) {
      // Check if this looks like a footnote reference
      final beforeMatch = match.start > 0
          ? content.substring(match.start - 1, match.start)
          : '';
      if (beforeMatch == '^') continue;

      // Check the matched content for footnote pattern
      final raw = match.group(0)!;
      if (_footnotePattern.hasMatch(raw)) continue;

      // Add text before this citation
      if (match.start > lastEnd) {
        final textBefore = content.substring(lastEnd, match.start);
        if (textBefore.isNotEmpty) {
          segments.add(CitationSegment.text(textBefore));
        }
      }

      // Parse the citation IDs
      final ids = <int>[];
      for (final bracketMatch in _bracketGroupPattern.allMatches(raw)) {
        final idsStr = bracketMatch.group(1) ?? '';
        final parsed = idsStr
            .split(',')
            .map((part) => RegExp(r'^(\d+)(?:#.+)?$').firstMatch(part.trim()))
            .map((match) => int.tryParse(match?.group(1) ?? ''))
            .whereType<int>()
            .where((n) => n > 0) // Only positive indices
            .toList();
        ids.addAll(parsed);
      }

      if (ids.isNotEmpty) {
        segments.add(
          CitationSegment.citation(Citation(sourceIds: ids, raw: raw)),
        );
      } else {
        // No valid IDs found, treat as text
        segments.add(CitationSegment.text(raw));
      }

      lastEnd = match.end;
    }

    // Add remaining text
    if (lastEnd < content.length) {
      final remaining = content.substring(lastEnd);
      if (remaining.isNotEmpty) {
        segments.add(CitationSegment.text(remaining));
      }
    }

    // Return null if no citations were found
    final hasCitations = segments.any((s) => s.isCitation);
    return hasCitations ? segments : null;
  }

  /// Checks if content contains any citation patterns.
  static bool hasCitations(String content) {
    if (content.isEmpty) return false;
    // The regex already excludes footnotes like [^1] since it requires
    // a digit immediately after the opening bracket.
    return _citationPattern.hasMatch(content);
  }

  /// Extracts all unique source IDs from content (1-based).
  static List<int> extractSourceIds(String content) {
    final segments = parse(content);
    if (segments == null) return const [];

    final ids = <int>{};
    for (final segment in segments) {
      if (segment.isCitation) {
        ids.addAll(segment.citation!.sourceIds);
      }
    }
    return ids.toList()..sort();
  }
}
