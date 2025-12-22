/// Utility class for parsing and extracting reasoning/thinking content from messages.
///
/// This parser handles:
/// - `<details type="reasoning">` blocks (server-emitted, preferred)
/// - Raw tag pairs like `<think>`, `<thinking>`, `<reasoning>`, etc.
///
/// Reference: openwebui-src/backend/open_webui/utils/middleware.py DEFAULT_REASONING_TAGS
library;

import 'package:html_unescape/html_unescape.dart';

final _htmlUnescape = HtmlUnescape();

/// Unescape HTML entities in reasoning content.
String _unescapeHtml(String s) => _htmlUnescape.convert(s);

/// All reasoning tag pairs supported by Open WebUI.
/// Reference: DEFAULT_REASONING_TAGS in middleware.py
const List<(String, String)> defaultReasoningTagPairs = [
  ('<think>', '</think>'),
  ('<thinking>', '</thinking>'),
  ('<reason>', '</reason>'),
  ('<reasoning>', '</reasoning>'),
  ('<thought>', '</thought>'),
  ('<Thought>', '</Thought>'),
  ('<|begin_of_thought|>', '<|end_of_thought|>'),
  ('◁think▷', '◁/think▷'),
];

/// Type of collapsible block (reasoning vs code_interpreter).
enum CollapsibleBlockType { reasoning, codeInterpreter }

/// Lightweight reasoning block for segmented rendering.
class ReasoningEntry {
  final String reasoning;
  final String summary;
  final int duration;
  final bool isDone;
  final CollapsibleBlockType blockType;

  const ReasoningEntry({
    required this.reasoning,
    required this.summary,
    required this.duration,
    required this.isDone,
    this.blockType = CollapsibleBlockType.reasoning,
  });

  /// Whether this is a code interpreter block.
  bool get isCodeInterpreter =>
      blockType == CollapsibleBlockType.codeInterpreter;

  String get formattedDuration => ReasoningParser.formatDuration(duration);

  /// Gets the cleaned reasoning text (removes leading '>' from blockquote format).
  String get cleanedReasoning {
    return reasoning
        .split('\n')
        .map((line) {
          // Remove leading '>' and optional space (blockquote format from server)
          if (line.startsWith('> ')) return line.substring(2);
          if (line.startsWith('>')) return line.substring(1);
          return line;
        })
        .join('\n')
        .trim();
  }
}

/// Ordered segment that is either plain text or a reasoning entry.
class ReasoningSegment {
  final String? text;
  final ReasoningEntry? entry;

  const ReasoningSegment._({this.text, this.entry});

  factory ReasoningSegment.text(String text) => ReasoningSegment._(text: text);
  factory ReasoningSegment.entry(ReasoningEntry entry) =>
      ReasoningSegment._(entry: entry);

  bool get isReasoning => entry != null;
}

/// Model class for reasoning content (legacy, kept for compatibility).
class ReasoningContent {
  final String reasoning;
  final String summary;
  final int duration;
  final bool isDone;
  final String mainContent;
  final String originalContent;

  const ReasoningContent({
    required this.reasoning,
    required this.summary,
    required this.duration,
    required this.isDone,
    required this.mainContent,
    required this.originalContent,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReasoningContent &&
          runtimeType == other.runtimeType &&
          reasoning == other.reasoning &&
          summary == other.summary &&
          duration == other.duration &&
          isDone == other.isDone &&
          mainContent == other.mainContent &&
          originalContent == other.originalContent;

  @override
  int get hashCode =>
      reasoning.hashCode ^
      summary.hashCode ^
      duration.hashCode ^
      isDone.hashCode ^
      mainContent.hashCode ^
      originalContent.hashCode;

  String get formattedDuration => ReasoningParser.formatDuration(duration);

  /// Gets the cleaned reasoning text (removes leading '>').
  String get cleanedReasoning {
    return reasoning
        .split('\n')
        .map((line) {
          if (line.startsWith('> ')) return line.substring(2);
          if (line.startsWith('>')) return line.substring(1);
          return line;
        })
        .join('\n')
        .trim();
  }
}

/// Utility class for parsing and extracting reasoning/thinking content.
class ReasoningParser {
  /// Patterns that indicate a details block is reasoning content.
  /// Used when the `type` attribute is missing.
  static final _reasoningSummaryPattern = RegExp(
    r'Thought|Thinking|Reasoning',
    caseSensitive: false,
  );

  /// Splits content into ordered segments of plain text and reasoning entries.
  ///
  /// Handles:
  /// - `<details type="reasoning">` blocks with optional summary/duration/done
  /// - `<details>` blocks without type but with reasoning-like summary
  /// - Raw tag pairs like `<think>`, `<thinking>`, `<reasoning>`, etc.
  /// - Incomplete/streaming cases by emitting a partial reasoning entry
  static List<ReasoningSegment>? segments(
    String content, {
    List<(String, String)>? customTagPairs,
    bool detectDefaultTags = true,
  }) {
    if (content.isEmpty) return null;

    // Build the list of raw tag pairs to detect
    final tagPairs = <(String, String)>[];
    if (customTagPairs != null) {
      tagPairs.addAll(customTagPairs);
    }
    if (detectDefaultTags) {
      tagPairs.addAll(defaultReasoningTagPairs);
    }

    final segments = <ReasoningSegment>[];
    int index = 0;

    while (index < content.length) {
      // Find the earliest match: either <details (any type) or a raw tag
      int nextDetailsIdx = -1;
      int nextRawIdx = -1;
      (String, String)? matchedRawPair;

      // Check for any <details tag (we'll determine if it's reasoning later)
      final detailsMatch = RegExp(
        r'<details(?:\s|>)',
      ).firstMatch(content.substring(index));
      if (detailsMatch != null) {
        nextDetailsIdx = index + detailsMatch.start;
      }

      // Check for raw tag pairs
      // Supports tags with optional attributes like <think foo="bar">
      // Reference: openwebui-src/backend/open_webui/utils/middleware.py
      for (final pair in tagPairs) {
        final startTag = pair.$1;
        int idx = -1;

        // For XML-like tags (e.g., <think>), match with optional attributes
        if (startTag.startsWith('<') && startTag.endsWith('>')) {
          final tagName = startTag.substring(1, startTag.length - 1);
          final pattern = RegExp('<${RegExp.escape(tagName)}(\\s[^>]*)?>');
          final match = pattern.firstMatch(content.substring(index));
          if (match != null) {
            idx = index + match.start;
          }
        } else {
          // For non-XML tags (e.g., ◁think▷), use exact matching
          idx = content.indexOf(startTag, index);
        }

        if (idx != -1 && (nextRawIdx == -1 || idx < nextRawIdx)) {
          nextRawIdx = idx;
          matchedRawPair = pair;
        }
      }

      // Determine which comes first
      final int nextIdx;
      final String kind;
      if (nextDetailsIdx == -1 && nextRawIdx == -1) {
        // No more reasoning blocks
        if (index < content.length) {
          final remaining = content.substring(index);
          if (remaining.trim().isNotEmpty) {
            segments.add(ReasoningSegment.text(remaining));
          }
        }
        break;
      } else if (nextDetailsIdx != -1 &&
          (nextRawIdx == -1 || nextDetailsIdx <= nextRawIdx)) {
        nextIdx = nextDetailsIdx;
        kind = 'details';
      } else {
        nextIdx = nextRawIdx;
        kind = 'raw';
      }

      // Add text before this block
      if (nextIdx > index) {
        final textBefore = content.substring(index, nextIdx);
        if (textBefore.trim().isNotEmpty) {
          segments.add(ReasoningSegment.text(textBefore));
        }
      }

      if (kind == 'details') {
        // Parse <details> block and check if it's reasoning content
        final result = _parseDetailsBlock(content, nextIdx);

        // Only add as reasoning if it's a reasoning type or looks like reasoning
        if (result.isReasoning) {
          segments.add(ReasoningSegment.entry(result.entry));
        } else {
          // Not a reasoning block, treat as text
          final detailsText = content.substring(nextIdx, result.endIndex);
          if (detailsText.trim().isNotEmpty) {
            segments.add(ReasoningSegment.text(detailsText));
          }
        }

        if (!result.isComplete) {
          // Incomplete block, stop here
          break;
        }
        index = result.endIndex;
      } else if (kind == 'raw' && matchedRawPair != null) {
        // Parse raw tag pair
        final result = _parseRawReasoning(
          content,
          nextIdx,
          matchedRawPair.$1,
          matchedRawPair.$2,
        );
        segments.add(ReasoningSegment.entry(result.entry));

        if (!result.isComplete) {
          // Incomplete block, stop here
          break;
        }
        index = result.endIndex;
      }
    }

    return segments.isEmpty ? null : segments;
  }

  /// Parse a `<details>` block starting at the given index.
  /// Returns whether the block is reasoning content based on type or summary.
  static _DetailsResult _parseDetailsBlock(String content, int startIdx) {
    // Find the opening tag end
    final openTagEnd = content.indexOf('>', startIdx);
    if (openTagEnd == -1) {
      // Incomplete opening tag - assume reasoning for streaming
      return _DetailsResult(
        entry: ReasoningEntry(
          reasoning: '',
          summary: '',
          duration: 0,
          isDone: false,
        ),
        endIndex: content.length,
        isComplete: false,
        isReasoning: true,
      );
    }

    final openTag = content.substring(startIdx, openTagEnd + 1);

    // Parse attributes - use non-greedy match to handle attributes correctly
    // Mirrors Open WebUI's parseAttributes: /(\w+)="(.*?)"/g
    final attrs = <String, String>{};
    final attrRegex = RegExp(r'(\w+)="(.*?)"');
    for (final m in attrRegex.allMatches(openTag)) {
      attrs[m.group(1)!] = m.group(2) ?? '';
    }

    final type = attrs['type']?.toLowerCase() ?? '';
    // Open WebUI treats done as string comparison: done === 'true'
    final isDone = attrs['done'] == 'true';
    final duration = int.tryParse(attrs['duration'] ?? '0') ?? 0;

    // Find matching closing tag with nesting support
    int depth = 1;
    int i = openTagEnd + 1;
    while (i < content.length && depth > 0) {
      final nextOpen = content.indexOf('<details', i);
      final nextClose = content.indexOf('</details>', i);
      if (nextClose == -1) break;
      if (nextOpen != -1 && nextOpen < nextClose) {
        depth++;
        i = nextOpen + '<details'.length;
      } else {
        depth--;
        i = nextClose + '</details>'.length;
      }
    }

    // Determine block type based on type attribute
    final blockType = type == 'code_interpreter'
        ? CollapsibleBlockType.codeInterpreter
        : CollapsibleBlockType.reasoning;

    if (depth != 0) {
      // Incomplete block (streaming)
      final innerContent = content.substring(openTagEnd + 1);
      final summaryResult = _extractSummary(innerContent);

      // Determine if this is reasoning based on type or summary
      // Also treat code_interpreter as reasoning-like (collapsible thinking)
      final isReasoning =
          type == 'reasoning' ||
          type == 'code_interpreter' ||
          (type.isEmpty &&
              _reasoningSummaryPattern.hasMatch(summaryResult.summary));

      // Extract duration from summary if not in attributes
      final effectiveDuration = duration > 0
          ? duration
          : _extractDurationFromSummary(summaryResult.summary);

      return _DetailsResult(
        entry: ReasoningEntry(
          reasoning: _unescapeHtml(summaryResult.remaining),
          summary: _unescapeHtml(summaryResult.summary),
          duration: effectiveDuration,
          isDone: false,
          blockType: blockType,
        ),
        endIndex: content.length,
        isComplete: false,
        isReasoning: isReasoning,
      );
    }

    // Complete block
    final closeIdx = i - '</details>'.length;
    final innerContent = content.substring(openTagEnd + 1, closeIdx);
    final summaryResult = _extractSummary(innerContent);

    // Determine if this is reasoning based on type or summary
    // Also treat code_interpreter as reasoning-like (collapsible thinking)
    final isReasoning =
        type == 'reasoning' ||
        type == 'code_interpreter' ||
        (type.isEmpty &&
            _reasoningSummaryPattern.hasMatch(summaryResult.summary));

    // Extract duration from summary if not in attributes
    final effectiveDuration = duration > 0
        ? duration
        : _extractDurationFromSummary(summaryResult.summary);

    return _DetailsResult(
      entry: ReasoningEntry(
        reasoning: _unescapeHtml(summaryResult.remaining),
        summary: _unescapeHtml(summaryResult.summary),
        duration: effectiveDuration,
        isDone: isDone,
        blockType: blockType,
      ),
      endIndex: i,
      isComplete: true,
      isReasoning: isReasoning,
    );
  }

  /// Parse a raw reasoning tag pair (e.g., `<think>...</think>`).
  /// Supports tags with optional attributes like `<think foo="bar">`.
  ///
  /// Reference: openwebui-src/backend/open_webui/utils/middleware.py
  static _ReasoningResult _parseRawReasoning(
    String content,
    int startIdx,
    String startTag,
    String endTag,
  ) {
    // Find the actual end of the opening tag (handles attributes)
    int contentStartIdx;
    if (startTag.startsWith('<') && startTag.endsWith('>')) {
      // For XML-like tags, find the closing '>' to skip any attributes
      final tagCloseIdx = content.indexOf('>', startIdx);
      if (tagCloseIdx == -1) {
        // Incomplete opening tag
        return _ReasoningResult(
          entry: ReasoningEntry(
            reasoning: '',
            summary: '',
            duration: 0,
            isDone: false,
          ),
          endIndex: content.length,
          isComplete: false,
        );
      }
      contentStartIdx = tagCloseIdx + 1;
    } else {
      // For non-XML tags, use exact tag length
      contentStartIdx = startIdx + startTag.length;
    }

    final endIdx = content.indexOf(endTag, contentStartIdx);

    if (endIdx == -1) {
      // Incomplete block (streaming)
      final innerContent = content.substring(contentStartIdx);
      return _ReasoningResult(
        entry: ReasoningEntry(
          reasoning: _unescapeHtml(innerContent.trim()),
          summary: '',
          duration: 0,
          isDone: false,
        ),
        endIndex: content.length,
        isComplete: false,
      );
    }

    // Complete block
    final innerContent = content.substring(contentStartIdx, endIdx);
    return _ReasoningResult(
      entry: ReasoningEntry(
        reasoning: _unescapeHtml(innerContent.trim()),
        summary: '',
        duration: 0,
        isDone: true,
      ),
      endIndex: endIdx + endTag.length,
      isComplete: true,
    );
  }

  /// Extract `<summary>...</summary>` from content.
  static _SummaryResult _extractSummary(String content) {
    final summaryRegex = RegExp(
      r'^\s*<summary>(.*?)</summary>\s*',
      dotAll: true,
    );
    final match = summaryRegex.firstMatch(content);

    if (match != null) {
      return _SummaryResult(
        summary: (match.group(1) ?? '').trim(),
        remaining: content.substring(match.end).trim(),
      );
    }

    return _SummaryResult(summary: '', remaining: content.trim());
  }

  /// Extract duration from summary text like "Thought (1s)" or "Thinking (2m 30s)".
  static int _extractDurationFromSummary(String summary) {
    // Match patterns like "(1s)", "(30s)", "(1m)", "(2m 30s)", "(1m30s)"
    // Supports minutes-only "(1m)", seconds-only "(30s)", or both "(2m 30s)"
    final durationRegex = RegExp(
      r'\((\d+)m(?:\s*(\d+)s)?\)|\((\d+)s\)',
      caseSensitive: false,
    );
    final match = durationRegex.firstMatch(summary);
    if (match != null) {
      // Check if it's a minutes pattern (groups 1 and 2) or seconds-only (group 3)
      if (match.group(1) != null) {
        // Minutes pattern: "(Xm)" or "(Xm Ys)"
        final minutes = int.tryParse(match.group(1) ?? '0') ?? 0;
        final seconds = int.tryParse(match.group(2) ?? '0') ?? 0;
        return minutes * 60 + seconds;
      } else if (match.group(3) != null) {
        // Seconds-only pattern: "(Xs)"
        return int.tryParse(match.group(3) ?? '0') ?? 0;
      }
    }
    return 0;
  }

  /// Parses a message and extracts the first reasoning content block.
  /// Returns null if no reasoning content is found.
  static ReasoningContent? parseReasoningContent(
    String content, {
    List<(String, String)>? customTagPairs,
    bool detectDefaultTags = true,
  }) {
    final segs = segments(
      content,
      customTagPairs: customTagPairs,
      detectDefaultTags: detectDefaultTags,
    );
    if (segs == null || segs.isEmpty) return null;

    // Find the first reasoning entry
    ReasoningEntry? firstEntry;
    final textParts = <String>[];

    for (final seg in segs) {
      if (seg.isReasoning && firstEntry == null) {
        firstEntry = seg.entry;
      } else if (seg.text != null) {
        textParts.add(seg.text!);
      }
    }

    if (firstEntry == null) return null;

    return ReasoningContent(
      reasoning: firstEntry.reasoning,
      summary: firstEntry.summary,
      duration: firstEntry.duration,
      isDone: firstEntry.isDone,
      mainContent: textParts.join().trim(),
      originalContent: content,
    );
  }

  /// Checks if a message contains reasoning content.
  static bool hasReasoningContent(String content) {
    // Check for <details type="reasoning" (case-insensitive)
    if (RegExp(r'type="reasoning"', caseSensitive: false).hasMatch(content)) {
      return true;
    }

    // Check for <details type="code_interpreter" (case-insensitive)
    if (RegExp(
      r'type="code_interpreter"',
      caseSensitive: false,
    ).hasMatch(content)) {
      return true;
    }

    // Check for <details> with reasoning-like summary
    if (content.contains('<details')) {
      final summaryMatch = RegExp(
        r'<summary>([^<]*)</summary>',
      ).firstMatch(content);
      if (summaryMatch != null) {
        final summary = summaryMatch.group(1) ?? '';
        if (_reasoningSummaryPattern.hasMatch(summary)) return true;
      }
    }

    // Check for raw tag pairs
    for (final pair in defaultReasoningTagPairs) {
      if (content.contains(pair.$1)) return true;
    }

    return false;
  }

  /// Formats the duration for display.
  /// Mirrors Open WebUI's dayjs.duration(seconds, 'seconds').humanize():
  /// - < 1: "less than a second"
  /// - < 60: "X seconds"
  /// - >= 60: humanized (e.g., "a minute", "2 minutes", "about an hour")
  ///
  /// Reference: openwebui-src/src/lib/components/common/Collapsible.svelte
  static String formatDuration(int seconds) {
    if (seconds < 1) return 'less than a second';
    if (seconds < 60) return '$seconds second${seconds == 1 ? '' : 's'}';

    // Match dayjs.duration().humanize() behavior
    // Reference: https://day.js.org/docs/en/durations/humanize
    if (seconds < 90) return 'a minute';
    if (seconds < 2700) {
      // 45 minutes
      final minutes = (seconds / 60).round();
      return '$minutes minutes';
    }
    if (seconds < 5400) return 'about an hour'; // 90 minutes
    if (seconds < 79200) {
      // 22 hours
      final hours = (seconds / 3600).round();
      return '$hours hours';
    }
    if (seconds < 129600) return 'a day'; // 36 hours
    final days = (seconds / 86400).round();
    return '$days days';
  }
}

class _ReasoningResult {
  final ReasoningEntry entry;
  final int endIndex;
  final bool isComplete;

  const _ReasoningResult({
    required this.entry,
    required this.endIndex,
    required this.isComplete,
  });
}

class _DetailsResult {
  final ReasoningEntry entry;
  final int endIndex;
  final bool isComplete;
  final bool isReasoning;

  const _DetailsResult({
    required this.entry,
    required this.endIndex,
    required this.isComplete,
    required this.isReasoning,
  });
}

class _SummaryResult {
  final String summary;
  final String remaining;

  const _SummaryResult({required this.summary, required this.remaining});
}
