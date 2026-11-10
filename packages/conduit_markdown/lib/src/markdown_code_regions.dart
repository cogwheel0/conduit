import 'package:markdown/markdown.dart' as md;

import 'linear_inline_syntaxes.dart';

/// A half-open range of source offsets.
final class SourceRange {
  const SourceRange(this.start, this.end);

  final int start;
  final int end;

  @override
  String toString() => 'SourceRange($start, $end)';
}

// Line-anchored fence patterns, mirroring the markdown block parser
// (CommonMark fenced code blocks) exactly as Conduit's semantic message builder
// does when it escapes answer text. A backtick fence opens on 3+ backticks
// (0-3 spaces indent) whose info string has no backtick; a tilde fence opens
// on 3+ tildes. A fence closes on a run of the same character at least as long
// as the opener, followed only by whitespace.
final _openingBacktickFence = RegExp(r'^ {0,3}(`{3,})[^`]*$');
final _openingTildeFence = RegExp(r'^ {0,3}(~{3,}).*$');
final _closingFence = RegExp(r'^ {0,3}(`{3,}|~{3,})[ \t]*$');
final _indentedCodeLine = RegExp(r'^(?:    | {0,3}\t)');
final _detailsBlockStart = RegExp(
  r'^\s{0,3}<details(?:\s+[^>]*)?>',
  caseSensitive: false,
);

// The Markdown package's line-local CodeSyntax, AutolinkSyntax and
// EmailAutolinkSyntax.
final _verbatimInline = RegExp(
  r'(?<!`)(`+(?!`))(.*?[^`])\1(?!`)|'
  r'<(?:[a-zA-Z][a-zA-Z\-\+\.]+):(?://)?[^\s>]*>|'
  r'''<[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9]'''
  r'''(?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?'''
  r'''(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*>''',
);

final _backtickRun = RegExp(r'(?<!`)`+');
final _multilineCodeSpanCandidate = RegExp(
  r'(?<!`)(`+(?!`))((?:.|\n)*?[^`])\1(?!`)',
);
const int _maxMultilineCodeSpanCandidates = 4096;

/// The parts of [markdown] a markdown renderer shows verbatim: fenced and
/// indented code blocks, code spans, and angle autolinks. Sorted, merged
/// ranges.
///
/// The rules are the ones Conduit's semantic message builder uses to escape
/// answer text outside code (issue #549): a line-based fence walk that
/// matches the block parser (unclosed fences run to the end), indented code
/// and multi-line code spans only where `package:markdown` confirms them, and
/// single-line code spans and autolinks by pattern. Like the builder, it does
/// not look inside list items or blockquotes for fences.
List<SourceRange> findVerbatimMarkdownRanges(String markdown) {
  final lines = markdown.split('\n');
  final multilineSpans = _parserConfirmedMultilineCodeSpans(markdown);
  final indentedLines = _parserConfirmedIndentedCodeLines(markdown);
  final ranges = <SourceRange>[...multilineSpans];

  String? openFenceChar;
  var openFenceLength = 0;
  var inIndentedCode = false;
  var lineStart = 0;
  var spanIndex = 0;
  for (var index = 0; index < lines.length; index++) {
    final rawLine = lines[index];
    final line = rawLine.endsWith('\r')
        ? rawLine.substring(0, rawLine.length - 1)
        : rawLine;
    final lineEnd = lineStart + rawLine.length;
    final start = lineStart;
    lineStart = lineEnd + 1;

    if (openFenceChar != null) {
      ranges.add(SourceRange(start, lineEnd));
      final close = _closingFence.firstMatch(line);
      if (close != null) {
        final run = close.group(1)!;
        if (run[0] == openFenceChar && run.length >= openFenceLength) {
          openFenceChar = null;
          openFenceLength = 0;
        }
      }
      continue;
    }

    final isBlank = line.trim().isEmpty;
    final isIndented = _indentedCodeLine.hasMatch(line);
    if (inIndentedCode) {
      if (isBlank || isIndented) {
        ranges.add(SourceRange(start, lineEnd));
        continue;
      }
      inIndentedCode = false;
    }
    if (isIndented &&
        !_detailsBlockStart.hasMatch(line) &&
        indentedLines.contains(index)) {
      inIndentedCode = true;
      ranges.add(SourceRange(start, lineEnd));
      continue;
    }

    final open =
        _openingBacktickFence.firstMatch(line) ??
        _openingTildeFence.firstMatch(line);
    if (open != null) {
      final run = open.group(1)!;
      openFenceChar = run[0];
      openFenceLength = run.length;
      ranges.add(SourceRange(start, lineEnd));
      continue;
    }

    // Prose line: code spans and autolinks outside the confirmed multi-line
    // spans that touch it.
    while (spanIndex < multilineSpans.length &&
        multilineSpans[spanIndex].end <= start) {
      spanIndex++;
    }
    var segmentStart = start;
    for (var i = spanIndex; i < multilineSpans.length; i++) {
      final span = multilineSpans[i];
      if (span.start >= lineEnd) break;
      if (span.start > segmentStart) {
        _addInline(markdown, segmentStart, span.start, ranges);
      }
      segmentStart = span.end > segmentStart ? span.end : segmentStart;
    }
    if (segmentStart < lineEnd) {
      _addInline(markdown, segmentStart, lineEnd, ranges);
    }
  }
  return _merge(ranges);
}

void _addInline(String markdown, int start, int end, List<SourceRange> ranges) {
  final segment = markdown.substring(start, end);
  var from = 0;
  while (from < segment.length) {
    final match = _verbatimInline.allMatches(segment, from).firstOrNull;
    if (match == null) return;
    if (segment.startsWith('`', match.start) &&
        _escapedAt(segment, match.start)) {
      // `\`` is a literal backtick; as in the parser, a code span can still
      // open after it.
      from = match.start + 1;
      continue;
    }
    ranges.add(SourceRange(start + match.start, start + match.end));
    from = match.end;
  }
}

/// Whether the character at [index] is escaped by an odd run of
/// backslashes.
bool _escapedAt(String text, int index) {
  var count = 0;
  for (var cursor = index - 1; cursor >= 0 && text[cursor] == r'\'; cursor--) {
    count++;
  }
  return count.isOdd;
}

List<SourceRange> _merge(List<SourceRange> ranges) {
  if (ranges.isEmpty) return const <SourceRange>[];
  ranges.sort((a, b) => a.start.compareTo(b.start));
  final merged = <SourceRange>[ranges.first];
  for (final range in ranges.skip(1)) {
    final last = merged.last;
    if (range.start <= last.end) {
      if (range.end > last.end) {
        merged[merged.length - 1] = SourceRange(last.start, range.end);
      }
    } else {
      merged.add(range);
    }
  }
  return merged;
}

/// Masks [ranges] of [text] with inert tokens and restores them.
final class VerbatimMask {
  VerbatimMask._(this.masked, this._marker, this._originals);

  /// [text] with each range replaced by a token made of private-use
  /// characters, an `x` and digits: no whitespace, `$`, `\`, `<`, `[` or `]`.
  factory VerbatimMask(String text, List<SourceRange> ranges) {
    var marker = '';
    while (text.contains(marker)) {
      marker += '';
    }
    final originals = <String>[];
    final masked = StringBuffer();
    var cursor = 0;
    for (final range in ranges) {
      masked
        ..write(text.substring(cursor, range.start))
        ..write('${marker}x${originals.length}');
      originals.add(text.substring(range.start, range.end));
      cursor = range.end;
    }
    masked.write(text.substring(cursor));
    return VerbatimMask._(masked.toString(), marker, originals);
  }

  final String masked;
  final String _marker;
  final List<String> _originals;

  RegExp get _token => RegExp('${RegExp.escape(_marker)}x(\\d+)');

  /// Whether [text] holds any token of this mask.
  bool hasToken(String text) =>
      _originals.isNotEmpty && text.contains('${_marker}x');

  /// [text] with every token turned back into the source it hid.
  String restore(String text) {
    if (!hasToken(text)) return text;
    return text.replaceAllMapped(_token, (match) {
      final index = int.parse(match[1]!);
      return index < _originals.length ? _originals[index] : match[0]!;
    });
  }
}

final class _RecordingCodeSyntax extends md.CodeSyntax {
  _RecordingCodeSyntax({required String markerStart, required String markerEnd})
    : _marker = RegExp(
        '${RegExp.escape(markerStart)}([0-9a-z]+)${RegExp.escape(markerEnd)}',
      );

  final RegExp _marker;
  final Set<int> matchedCandidates = <int>{};

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    // A candidate's marker sits right after its opening backticks. A marker
    // further in belongs to a candidate that opens inside this span.
    final marker = _marker.matchAsPrefix(
      match.group(0)!,
      match.group(1)!.length,
    );
    final encodedIndex = marker?.group(1);
    if (encodedIndex != null) {
      matchedCandidates.add(int.parse(encodedIndex, radix: 36));
    }
    return super.onMatch(parser, match);
  }
}

final class _RecordingIndentedCodeSyntax extends md.CodeBlockSyntax {
  _RecordingIndentedCodeSyntax({
    required String markerStart,
    required String markerEnd,
  }) : _marker = RegExp(
         '${RegExp.escape(markerStart)}([0-9a-z]+)${RegExp.escape(markerEnd)}',
       );

  final RegExp _marker;
  final Set<int> matchedLines = <int>{};

  @override
  List<md.Line> parseChildLines(md.BlockParser parser) {
    final childLines = super.parseChildLines(parser);
    for (final line in childLines) {
      for (final marker in _marker.allMatches(line.content)) {
        matchedLines.add(int.parse(marker.group(1)!, radix: 36));
      }
    }
    return childLines;
  }
}

({String start, String end}) _markers(String value, String name) {
  // Private-use sentinels are inert Markdown text. Make the pair absent from
  // the input so content cannot forge a candidate index.
  var start = 'conduit-$name';
  while (value.contains(start)) {
    start += '';
  }
  var end = '';
  while (value.contains(end) || start.contains(end)) {
    end += '';
  }
  return (start: start, end: end);
}

/// Indented-code lines the block parser confirms (an indented line that
/// continues a paragraph is not code).
Set<int> _parserConfirmedIndentedCodeLines(String value) {
  final lines = value.split('\n');
  final candidates = <int>[];
  for (var index = 0; index < lines.length; index++) {
    final rawLine = lines[index];
    final line = rawLine.endsWith('\r')
        ? rawLine.substring(0, rawLine.length - 1)
        : rawLine;
    if (line.trim().isNotEmpty &&
        _indentedCodeLine.hasMatch(line) &&
        !_detailsBlockStart.hasMatch(line)) {
      candidates.add(index);
    }
  }
  if (candidates.isEmpty) return const <int>{};

  final markers = _markers(value, 'indented-code');
  final markedLines = List<String>.from(lines);
  for (final index in candidates) {
    final rawLine = markedLines[index];
    final hasCarriageReturn = rawLine.endsWith('\r');
    final line = hasCarriageReturn
        ? rawLine.substring(0, rawLine.length - 1)
        : rawLine;
    markedLines[index] =
        '$line${markers.start}${index.toRadixString(36)}${markers.end}'
        '${hasCarriageReturn ? '\r' : ''}';
  }

  final recorder = _RecordingIndentedCodeSyntax(
    markerStart: markers.start,
    markerEnd: markers.end,
  );
  try {
    md.Document(
      extensionSet: conduitGitHubWebExtensionSet,
      blockSyntaxes: <md.BlockSyntax>[recorder],
      inlineSyntaxes: <md.InlineSyntax>[LongAlphanumericRunSyntax()],
      encodeHtml: false,
    ).parse(markedLines.join('\n'));
  } catch (_) {
    // Fail closed: treating code as prose only over-escapes.
    return const <int>{};
  }
  return recorder.matchedLines;
}

/// Whether the backtick run at [start] opens a fenced code block: the fence
/// walk already treats such a line as code, and it is never a code span, so
/// the (whole-document) parser confirmation can skip it.
bool _opensFence(String value, int start) {
  final lineStart = value.lastIndexOf('\n', start == 0 ? 0 : start - 1) + 1;
  final lineEnd = value.indexOf('\n', start);
  final line = value.substring(
    lineStart,
    lineEnd == -1 ? value.length : lineEnd,
  );
  final indent = start - lineStart;
  return indent <= 3 &&
      line.substring(0, indent).trim().isEmpty &&
      _openingBacktickFence.hasMatch(
        line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
      );
}

/// Code spans that cross a line break, where the parser confirms the exact
/// occurrence stays inside one inline-capable block.
List<SourceRange> _parserConfirmedMultilineCodeSpans(String value) {
  // Every backtick run is tried as an opener, including one an earlier
  // candidate closes on: if the parser rejects that candidate (it crosses a
  // paragraph break, say), the run can still open a span of its own.
  final candidates = <Match>[];
  for (final run in _backtickRun.allMatches(value)) {
    final match = _multilineCodeSpanCandidate.matchAsPrefix(value, run.start);
    if (match == null ||
        !match.group(0)!.contains('\n') ||
        _opensFence(value, match.start)) {
      continue;
    }
    candidates.add(match);
    if (candidates.length > _maxMultilineCodeSpanCandidates) {
      return const <SourceRange>[];
    }
  }
  if (candidates.isEmpty) return const <SourceRange>[];

  final markers = _markers(value, 'code-span');
  final marked = StringBuffer();
  var sourceOffset = 0;
  for (var index = 0; index < candidates.length; index++) {
    final candidate = candidates[index];
    final insertionOffset = candidate.start + candidate.group(1)!.length;
    marked
      ..write(value.substring(sourceOffset, insertionOffset))
      ..write(markers.start)
      ..write(index.toRadixString(36))
      ..write(markers.end);
    sourceOffset = insertionOffset;
  }
  marked.write(value.substring(sourceOffset));

  final recorder = _RecordingCodeSyntax(
    markerStart: markers.start,
    markerEnd: markers.end,
  );
  try {
    md.Document(
      extensionSet: conduitGitHubWebExtensionSet,
      inlineSyntaxes: <md.InlineSyntax>[LongAlphanumericRunSyntax(), recorder],
      encodeHtml: false,
    ).parse(marked.toString());
  } catch (_) {
    return const <SourceRange>[];
  }

  final confirmed = recorder.matchedCandidates.toList(growable: false)..sort();
  return <SourceRange>[
    for (final index in confirmed)
      if (index >= 0 && index < candidates.length)
        SourceRange(candidates[index].start, candidates[index].end),
  ];
}
