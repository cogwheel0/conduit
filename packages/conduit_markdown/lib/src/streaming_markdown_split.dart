/// Where a streaming answer can be cut so the part before the cut never needs
/// parsing again.
///
/// Markdown blocks mostly parse on their own: a finished paragraph, heading,
/// fenced block or list does not change when more text arrives after it. The
/// split finds the last such boundary, so a renderer can keep the prefix it
/// already parsed and re-parse only the tail. What does reach backwards -- a
/// reference definition rebinding earlier links, a raw HTML block with its own
/// termination rules -- keeps the affected region mutable.
///
/// Shared by the Flutter app's streaming compiler and the desktop renderer.
library;

import 'package:meta/meta.dart';

final RegExp _streamingFenceStartPattern = RegExp(r'^\s*(`{3,}|~{3,})(.*)$');
final RegExp _streamingHeadingPattern = RegExp(r'^\s{0,3}#{1,6}\s+\S');
final RegExp _streamingHorizontalRulePattern = RegExp(
  r'^\s{0,3}(?:\*\s*){3,}$|^\s{0,3}(?:-\s*){3,}$|^\s{0,3}(?:_\s*){3,}$',
);
final RegExp _streamingSetextUnderlinePattern = RegExp(
  r'^\s{0,3}(?:=+|-+)\s*$',
);
final RegExp _streamingUnorderedListPattern = RegExp(r'^\s{0,3}[-+*]\s+');
final RegExp _streamingOrderedListPattern = RegExp(r'^\s{0,3}\d+[.)]\s+');
final RegExp _streamingBlockquotePattern = RegExp(r'^\s{0,3}>');
final RegExp _streamingTableDividerPattern = RegExp(
  r'^\s*\|?(?:\s*:?-{3,}:?\s*\|)+\s*:?-{3,}:?\s*\|?\s*$',
);
final RegExp _streamingDetailsOpenPattern = RegExp(
  r'^<details\b',
  caseSensitive: false,
);
// The details parser counts nested opens ANYWHERE in a line with the
// complete-tag pattern (details_block_syntax.dart _openingTagPattern), not
// just at line starts. Depth counting must match it, or an inline nested
// open makes the first close exit scanner details mode one level early.
final RegExp _streamingDetailsInlineOpenPattern = RegExp(
  r'<details(?:\s+[^>]*)?>',
  caseSensitive: false,
);

// Complete tags only, exactly like the parser: crediting a partial
// line-leading `<details` here left scanner depth permanently stale when a
// body contained a literal `<details` that never completed, keeping the
// scanner "inside" a block the parser had already closed. Incomplete ENTRY
// tags are handled structurally instead (the tail stays mutable until the
// tag completes).
int _streamingDetailsOpenCount(String line) =>
    _streamingDetailsInlineOpenPattern.allMatches(line).length;

// Must match exactly what the details parser recognizes as a close
// (details_block_syntax.dart uses the literal `</details>`): counting a
// looser `</details >` as a close exits details tracking early, and a
// subsequent backtick line inside the still-open body then poisons fence
// state and hides later reference definitions.
final RegExp _streamingDetailsClosePattern = RegExp(
  r'</details>',
  caseSensitive: false,
);
final RegExp _streamingRawHtmlBlockPattern = RegExp(
  r'^\s{0,3}(?:'
  r'<(?:pre|script|style|textarea)(?:\s|>)|'
  r'<!--|<\?|<![A-Z]|<!\[CDATA\[|'
  r'<(?:address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|section|table|tbody|td|tfoot|th|thead|title|tr|track|ul)(?:\s|/?>))',
  caseSensitive: false,
  multiLine: true,
);
// Labels may contain backslash-escaped brackets ("[a\]b]:"), so escaped
// pairs are consumed before the closing bracket. The character class
// excludes the backslash so the two branches cannot overlap — an overlap
// backtracks exponentially on long malformed labels, and this pattern runs
// on the UI isolate during streamed flushes.
final RegExp _streamingReferenceDefinitionPattern = RegExp(
  r'^\s{0,3}\[(?:\\.|[^\]\\\n])+\]:',
  multiLine: true,
);

/// Splits [preparedContent] into a prefix whose blocks are final and the
/// tail that may still change as the stream continues.
///
/// Parsing the two halves separately and concatenating the results gives the
/// same blocks as parsing the whole, which is what makes the prefix safe to
/// keep. [StreamingMarkdownSplit.canIncrementallyCompile] is false when no cut
/// is safe at all; the whole content is then the tail.
StreamingMarkdownSplit splitStreamingMarkdown(String preparedContent) {
  if (preparedContent.isEmpty) {
    return const StreamingMarkdownSplit(frozenPrefix: '', mutableTail: '');
  }

  final lines = _splitStreamingPreparedLines(preparedContent);

  // One fence-aware pass finds the first line with possible non-local effects.
  // Reference definitions can retroactively rebind earlier links in this
  // region, so they keep the whole region mutable — but only when they appear
  // outside fenced code; previously a definition-shaped line (or any raw HTML
  // block) anywhere, including inside code fences, disabled incremental
  // compilation for the entire message on every streamed flush.
  //
  // Raw HTML blocks have tag-specific termination rules the scanner does not
  // model, but they cannot affect blocks before them, so freezing is capped
  // at the first HTML block start instead of keeping the whole document
  // mutable.
  final unsafe = _firstStreamingUnsafeLine(lines);
  if (unsafe != null && unsafe.isReferenceDefinition) {
    return StreamingMarkdownSplit(
      frozenPrefix: '',
      mutableTail: preparedContent,
      fallbackReason: 'referenceDefinitions',
    );
  }
  final freezeCap = unsafe?.offset ?? preparedContent.length;

  var index = 0;
  var safeBoundary = 0;

  while (index < lines.length) {
    if (lines[index].isBlank) {
      index += 1;
      continue;
    }

    final result = _scanStreamingPreparedBlock(
      lines,
      index,
      preparedContent.length,
    );
    if (result == null || result.safeBoundary > freezeCap) {
      break;
    }

    safeBoundary = result.safeBoundary;
    index = result.nextIndex;
  }

  return StreamingMarkdownSplit(
    frozenPrefix: preparedContent.substring(0, safeBoundary),
    mutableTail: preparedContent.substring(safeBoundary),
  );
}

List<_StreamingPreparedLine> _splitStreamingPreparedLines(String content) {
  if (content.isEmpty) {
    return const <_StreamingPreparedLine>[];
  }

  final lines = <_StreamingPreparedLine>[];
  var start = 0;
  while (start < content.length) {
    final newlineIndex = content.indexOf('\n', start);
    if (newlineIndex == -1) {
      lines.add(
        _StreamingPreparedLine(
          text: content.substring(start),
          start: start,
          end: content.length,
          endsWithNewline: false,
        ),
      );
      break;
    }

    lines.add(
      _StreamingPreparedLine(
        text: content.substring(start, newlineIndex),
        start: start,
        end: newlineIndex + 1,
        endsWithNewline: true,
      ),
    );
    start = newlineIndex + 1;
  }
  return lines;
}

({int offset, bool isReferenceDefinition})? _firstStreamingUnsafeLine(
  List<_StreamingPreparedLine> lines,
) {
  String? fenceCharacter;
  var fenceLength = 0;
  var detailsDepth = 0;
  int? firstRawHtmlOffset;

  // Reference definitions must be detected across the whole region — one
  // after a raw HTML block still rebinds links before it — so the scan never
  // stops at the first raw HTML line; only its offset is recorded as the
  // freeze cap.
  //
  // Once a raw HTML block has started, fence tracking is unreliable: backtick
  // lines inside raw HTML are content, not fences, and an odd count would
  // leave the tracker "inside" a fence and skip a later real definition. From
  // that point every line is checked for a definition regardless of fence
  // state — at worst more conservative than the pre-split whole-document
  // check this replaced.
  //
  // <details> bodies are treated the same way the block scanner treats them:
  // as opaque content tracked by open/close depth. An unmatched backtick line
  // inside a details body must not open a phantom outer fence that would hide
  // a definition appearing after the block.
  for (final line in lines) {
    if (detailsDepth > 0) {
      // The parser counts nested opens/closes on the RAW line — indentation
      // is irrelevant inside a details block — so this must not go through
      // the dedented candidate, which is null for indented lines and would
      // miss tags the parser counts, exiting details mode a level early.
      // (Depth can only be non-zero while firstRawHtmlOffset is null: raw
      // HTML detection runs outside details mode and ends the other checks.)
      detailsDepth += _streamingDetailsOpenCount(line.text);
      detailsDepth -= _streamingDetailsClosePattern
          .allMatches(line.text)
          .length;
      if (detailsDepth < 0) {
        detailsDepth = 0;
      }
      // Definition-shaped lines inside a details body are not document-scoped:
      // the parser lifts the body into a `body_markdown` attribute compiled as
      // its own document, so they cannot couple frozen and mutable segments.
      continue;
    }

    final candidate = _streamingBlockStarterCandidate(line.text);
    if (candidate == null) {
      continue;
    }

    if (firstRawHtmlOffset != null) {
      if (_streamingReferenceDefinitionPattern.hasMatch(candidate)) {
        return (offset: line.start, isReferenceDefinition: true);
      }
      continue;
    }

    if (fenceCharacter != null) {
      if (_isStreamingFenceClose(candidate, fenceCharacter, fenceLength)) {
        fenceCharacter = null;
        fenceLength = 0;
      }
      continue;
    }

    if (_streamingDetailsOpenPattern.hasMatch(candidate)) {
      detailsDepth = _streamingDetailsOpenCount(line.text);
      detailsDepth -= _streamingDetailsClosePattern
          .allMatches(line.text)
          .length;
      if (detailsDepth < 0) {
        detailsDepth = 0;
      }
      continue;
    }

    final fenceMatch = _streamingFenceStartPattern.firstMatch(candidate);
    if (fenceMatch != null) {
      final fence = fenceMatch.group(1)!;
      fenceCharacter = fence[0];
      fenceLength = fence.length;
      continue;
    }

    if (_streamingReferenceDefinitionPattern.hasMatch(candidate)) {
      return (offset: line.start, isReferenceDefinition: true);
    }
    if (_streamingRawHtmlBlockPattern.hasMatch(candidate)) {
      firstRawHtmlOffset = line.start;
    }
  }

  if (firstRawHtmlOffset != null) {
    return (offset: firstRawHtmlOffset, isReferenceDefinition: false);
  }
  return null;
}

bool _isStreamingFenceClose(
  String candidate,
  String fenceCharacter,
  int minimumLength,
) {
  final fenceCodeUnit = fenceCharacter.codeUnitAt(0);
  var index = 0;
  while (index < candidate.length &&
      candidate.codeUnitAt(index) == fenceCodeUnit) {
    index += 1;
  }
  if (index < minimumLength) {
    return false;
  }
  while (index < candidate.length) {
    final codeUnit = candidate.codeUnitAt(index);
    if (codeUnit != 0x20 && codeUnit != 0x09) {
      return false;
    }
    index += 1;
  }
  return true;
}

_StreamingBlockScanResult? _scanStreamingPreparedBlock(
  List<_StreamingPreparedLine> lines,
  int index,
  int contentLength,
) {
  final line = lines[index];
  final starterCandidate = _streamingBlockStarterCandidate(line.text);

  final fenceMatch = starterCandidate == null
      ? null
      : _streamingFenceStartPattern.firstMatch(starterCandidate);
  if (fenceMatch != null) {
    final fence = fenceMatch.group(1)!;
    for (var lineIndex = index + 1; lineIndex < lines.length; lineIndex += 1) {
      final closingCandidate = _streamingBlockStarterCandidate(
        lines[lineIndex].text,
      );
      if (closingCandidate == null ||
          !_isStreamingFenceClose(closingCandidate, fence[0], fence.length)) {
        continue;
      }
      final nextIndex = _skipBlankStreamingLines(lines, lineIndex + 1);
      return _StreamingBlockScanResult(
        safeBoundary: _safeBoundaryOffset(lines, nextIndex, contentLength),
        nextIndex: nextIndex,
      );
    }
    return null;
  }

  if (_startsStreamingDetailsBlock(line.text)) {
    if (_streamingDetailsOpenCount(line.text) == 0) {
      // The entry tag is still incomplete (`<details` without `>`): the
      // parser sees only a paragraph until the tag completes, so keep the
      // tail mutable rather than freezing a boundary that shifts on the
      // next flush.
      return null;
    }
    var depth = 0;
    for (var lineIndex = index; lineIndex < lines.length; lineIndex += 1) {
      final currentLine = lines[lineIndex];
      // Count on the RAW line: the parser counts tags regardless of
      // indentation inside the block, and the dedented candidate is null
      // for indented lines, which would drop tags the parser counts.
      depth += _streamingDetailsOpenCount(currentLine.text);
      depth -= _streamingDetailsClosePattern
          .allMatches(currentLine.text)
          .length;
      if (depth > 0) {
        continue;
      }
      if (lineIndex == lines.length - 1 && !currentLine.endsWithNewline) {
        return null;
      }
      final nextIndex = _skipBlankStreamingLines(lines, lineIndex + 1);
      return _StreamingBlockScanResult(
        safeBoundary: _safeBoundaryOffset(lines, nextIndex, contentLength),
        nextIndex: nextIndex,
      );
    }
    return null;
  }

  if (starterCandidate != null &&
      (_streamingHeadingPattern.hasMatch(starterCandidate) ||
          _streamingHorizontalRulePattern.hasMatch(starterCandidate))) {
    if (!line.endsWithNewline && index == lines.length - 1) {
      return null;
    }
    final nextIndex = _skipBlankStreamingLines(lines, index + 1);
    return _StreamingBlockScanResult(
      safeBoundary: _safeBoundaryOffset(lines, nextIndex, contentLength),
      nextIndex: nextIndex,
    );
  }

  if (_looksLikeStreamingTable(lines, index)) {
    var lineIndex = index + 2;
    while (lineIndex < lines.length &&
        _looksLikeStreamingTableRow(lines[lineIndex].text)) {
      lineIndex += 1;
    }
    if (lineIndex == lines.length) {
      return null;
    }
    final nextIndex = _skipBlankStreamingLines(lines, lineIndex);
    return _StreamingBlockScanResult(
      safeBoundary: _safeBoundaryOffset(lines, nextIndex, contentLength),
      nextIndex: nextIndex,
    );
  }

  if (starterCandidate != null &&
      _looksLikeStreamingListItem(starterCandidate)) {
    var lineIndex = index + 1;
    while (true) {
      while (lineIndex < lines.length && !lines[lineIndex].isBlank) {
        lineIndex += 1;
      }
      if (lineIndex == lines.length) {
        return null;
      }
      final nextIndex = _skipBlankStreamingLines(lines, lineIndex);
      if (nextIndex < lines.length) {
        final nextCandidate = _streamingBlockStarterCandidate(
          lines[nextIndex].text,
        );
        if (_looksLikeStreamingIndentedContinuation(lines[nextIndex].text) ||
            (nextCandidate != null &&
                _looksLikeStreamingListItem(nextCandidate))) {
          lineIndex = nextIndex + 1;
          continue;
        }
      }
      return _StreamingBlockScanResult(
        safeBoundary: _safeBoundaryOffset(lines, nextIndex, contentLength),
        nextIndex: nextIndex,
      );
    }
  }

  if (starterCandidate != null &&
      _streamingBlockquotePattern.hasMatch(starterCandidate)) {
    var lineIndex = index + 1;
    while (lineIndex < lines.length) {
      final nextLine = lines[lineIndex];
      final nextCandidate = _streamingBlockStarterCandidate(nextLine.text);
      if (nextCandidate != null &&
          _streamingBlockquotePattern.hasMatch(nextCandidate)) {
        lineIndex += 1;
        continue;
      }
      if (nextLine.isBlank ||
          _startsStandaloneStreamingBlock(lines, lineIndex)) {
        break;
      }
      // CommonMark/GFM allow paragraph continuations inside blockquotes
      // without a leading `>` marker until a new block boundary appears.
      lineIndex += 1;
    }
    if (lineIndex == lines.length) {
      return null;
    }
    final nextIndex = _skipBlankStreamingLines(lines, lineIndex);
    return _StreamingBlockScanResult(
      safeBoundary: _safeBoundaryOffset(lines, nextIndex, contentLength),
      nextIndex: nextIndex,
    );
  }

  var lineIndex = index;
  while (true) {
    final nextIndex = lineIndex + 1;
    if (nextIndex >= lines.length) {
      return null;
    }
    if (_looksLikeStreamingSetextUnderline(lines[nextIndex].text) &&
        lines[lineIndex].text.trim().isNotEmpty) {
      lineIndex = nextIndex;
      continue;
    }
    if (lines[nextIndex].isBlank) {
      final blockEndIndex = _skipBlankStreamingLines(lines, nextIndex);
      return _StreamingBlockScanResult(
        safeBoundary: _safeBoundaryOffset(lines, blockEndIndex, contentLength),
        nextIndex: blockEndIndex,
      );
    }
    if (_startsStandaloneStreamingBlock(lines, nextIndex)) {
      return _StreamingBlockScanResult(
        safeBoundary: lines[nextIndex].start,
        nextIndex: nextIndex,
      );
    }
    lineIndex = nextIndex;
  }
}

bool _startsStandaloneStreamingBlock(
  List<_StreamingPreparedLine> lines,
  int index,
) {
  final starterCandidate = _streamingBlockStarterCandidate(lines[index].text);
  if (starterCandidate == null) {
    return false;
  }
  return _streamingFenceStartPattern.hasMatch(starterCandidate) ||
      _streamingHeadingPattern.hasMatch(starterCandidate) ||
      _streamingHorizontalRulePattern.hasMatch(starterCandidate) ||
      _startsStandaloneStreamingListItem(starterCandidate) ||
      _streamingBlockquotePattern.hasMatch(starterCandidate) ||
      _streamingDetailsOpenPattern.hasMatch(starterCandidate) ||
      _looksLikeStreamingTable(lines, index);
}

bool _looksLikeStreamingTable(List<_StreamingPreparedLine> lines, int index) {
  if (index + 1 >= lines.length) {
    return false;
  }
  final dividerCandidate = _streamingBlockStarterCandidate(
    lines[index + 1].text,
  );
  return _looksLikeStreamingTableRow(lines[index].text) &&
      dividerCandidate != null &&
      _streamingTableDividerPattern.hasMatch(dividerCandidate);
}

bool _looksLikeStreamingTableRow(String line) {
  final starterCandidate = _streamingBlockStarterCandidate(line);
  if (starterCandidate == null) {
    return false;
  }
  final trimmed = starterCandidate.trim();
  if (trimmed.isEmpty || !_hasUnescapedPipe(trimmed)) {
    return false;
  }
  return trimmed.startsWith('|') || trimmed.endsWith('|');
}

bool _hasUnescapedPipe(String text) {
  for (var index = 0; index < text.length; index += 1) {
    if (text[index] != '|') {
      continue;
    }
    if (index == 0 || text[index - 1] != r'\') {
      return true;
    }
  }
  return false;
}

// A marker alone on its line is an item too -- an empty one, or one whose
// text has not streamed in yet. Only here, where a list is already open:
// an empty item cannot interrupt a paragraph, and a lone `-` under one is a
// setext underline.
final RegExp _streamingEmptyListItemPattern = RegExp(
  r'^\s{0,3}(?:[-+*]|\d+[.)])\s*$',
);

bool _looksLikeStreamingListItem(String line) {
  return _streamingUnorderedListPattern.hasMatch(line) ||
      _streamingOrderedListPattern.hasMatch(line) ||
      _streamingEmptyListItemPattern.hasMatch(line);
}

bool _startsStandaloneStreamingListItem(String line) {
  if (_streamingUnorderedListPattern.hasMatch(line)) {
    return true;
  }
  final match = RegExp(r'^(\d+)[.)]\s+').firstMatch(line);
  if (match == null) {
    return false;
  }
  return match.group(1) == '1';
}

bool _looksLikeStreamingIndentedContinuation(String line) {
  if (line.startsWith('\t')) {
    return true;
  }
  var leadingSpaces = 0;
  while (leadingSpaces < line.length &&
      line.codeUnitAt(leadingSpaces) == 0x20) {
    leadingSpaces += 1;
  }
  return leadingSpaces >= 2;
}

bool _looksLikeStreamingSetextUnderline(String line) {
  final starterCandidate = _streamingBlockStarterCandidate(line);
  return starterCandidate != null &&
      _streamingSetextUnderlinePattern.hasMatch(starterCandidate);
}

bool _startsStreamingDetailsBlock(String line) {
  final starterCandidate = _streamingBlockStarterCandidate(line);
  return starterCandidate != null &&
      _streamingDetailsOpenPattern.hasMatch(starterCandidate);
}

String? _streamingBlockStarterCandidate(String line) {
  var index = 0;
  var indentColumns = 0;
  while (index < line.length) {
    final codeUnit = line.codeUnitAt(index);
    if (codeUnit == 0x20) {
      indentColumns += 1;
    } else if (codeUnit == 0x09) {
      indentColumns += 4 - (indentColumns % 4);
    } else {
      break;
    }
    if (indentColumns > 3) {
      return null;
    }
    index += 1;
  }
  return line.substring(index);
}

int _skipBlankStreamingLines(List<_StreamingPreparedLine> lines, int index) {
  var nextIndex = index;
  while (nextIndex < lines.length && lines[nextIndex].isBlank) {
    nextIndex += 1;
  }
  return nextIndex;
}

int _safeBoundaryOffset(
  List<_StreamingPreparedLine> lines,
  int nextIndex,
  int contentLength,
) {
  if (nextIndex >= lines.length) {
    return contentLength;
  }
  return lines[nextIndex].start;
}

@immutable
/// The result of [splitStreamingMarkdown].
class StreamingMarkdownSplit {
  const StreamingMarkdownSplit({
    required this.frozenPrefix,
    required this.mutableTail,
    this.fallbackReason,
  });

  final String frozenPrefix;
  final String mutableTail;
  final String? fallbackReason;

  bool get canIncrementallyCompile => fallbackReason == null;
}

@immutable
class _StreamingPreparedLine {
  const _StreamingPreparedLine({
    required this.text,
    required this.start,
    required this.end,
    required this.endsWithNewline,
  });

  final String text;
  final int start;
  final int end;
  final bool endsWithNewline;

  bool get isBlank => text.trim().isEmpty;
}

@immutable
class _StreamingBlockScanResult {
  const _StreamingBlockScanResult({
    required this.safeBoundary,
    required this.nextIndex,
  });

  final int safeBoundary;
  final int nextIndex;
}
