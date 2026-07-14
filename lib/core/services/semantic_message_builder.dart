import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

// Escape only the characters needed to neutralize HTML tags (`&`, `<`, `>`)
// and keep double-quoted `<details>` attributes intact (`"`). The default
// `HtmlEscape()` (HtmlEscapeMode.unknown) additionally escapes `/` -> `&#47;`
// and `'` -> `&#39;`. Those extra entities are unnecessary for tag safety and
// are never decoded inside markdown code spans/blocks, so they leak into
// rendered output (e.g. URLs showing `https:&#47;&#47;`). See issue #549.
const HtmlEscape _semanticHtmlEscape = HtmlEscape(HtmlEscapeMode.attribute);

/// Semantic assistant-message blocks that can be serialized into the markdown
/// dialect consumed by Conduit's shared markdown renderer.
sealed class SemanticMessageBlock {
  const SemanticMessageBlock();
}

final class SemanticTextBlock extends SemanticMessageBlock {
  const SemanticTextBlock(this.text);

  final String text;
}

final class SemanticDetailsBlock extends SemanticMessageBlock {
  const SemanticDetailsBlock._({
    required this.type,
    required this.summary,
    required this.done,
    this.bodyMarkdown = '',
    this.id,
    this.name,
    this.duration,
    this.arguments,
    this.result,
    this.files,
    this.embeds,
  });

  factory SemanticDetailsBlock.reasoning({
    required String text,
    required bool done,
    String? duration,
  }) {
    final normalized = text.trim();
    final display = normalized.isEmpty
        ? ''
        : LineSplitter.split(
            normalized,
          ).map((line) => line.startsWith('>') ? line : '> $line').join('\n');
    final resolvedDuration = duration ?? '0';
    return SemanticDetailsBlock._(
      type: 'reasoning',
      summary: done ? 'Thought for $resolvedDuration seconds' : 'Thinking…',
      done: done,
      duration: done ? resolvedDuration : null,
      bodyMarkdown: display,
    );
  }

  factory SemanticDetailsBlock.toolCall({
    required String id,
    required String name,
    required Object? arguments,
    required bool done,
    Object? result,
    Object? files,
    Object? embeds,
  }) {
    return SemanticDetailsBlock._(
      type: 'tool_calls',
      summary: done ? 'Tool Executed' : 'Executing...',
      done: done,
      id: id,
      name: name,
      arguments: arguments,
      result: result,
      files: files,
      embeds: embeds,
    );
  }

  factory SemanticDetailsBlock.codeInterpreter({
    required String code,
    required String language,
    required bool done,
    String? duration,
    Object? output,
  }) {
    final bodyParts = <String>[
      if (code.isNotEmpty) _markdownCodeFence(code, language),
      if (output != null) _formatBodyValue(output),
    ].where((part) => part.trim().isNotEmpty).toList(growable: false);
    return SemanticDetailsBlock._(
      type: 'code_interpreter',
      summary: done ? 'Analyzed' : 'Analyzing...',
      done: done,
      duration: done ? duration ?? '0' : null,
      bodyMarkdown: bodyParts.join('\n\n'),
    );
  }

  final String type;
  final String summary;
  final bool done;
  final String bodyMarkdown;
  final String? id;
  final String? name;
  final String? duration;
  final Object? arguments;
  final Object? result;
  final Object? files;
  final Object? embeds;
}

String renderSemanticMessageBlocks(List<SemanticMessageBlock> blocks) {
  if (blocks.isEmpty) return '';

  final parts = <String>[];
  for (final block in blocks) {
    switch (block) {
      case SemanticTextBlock(:final text):
        if (text.trim().isNotEmpty) {
          parts.add(_escapeText(text));
        }
      case SemanticDetailsBlock():
        final rendered = _renderDetailsBlock(block);
        if (rendered.trim().isNotEmpty) {
          parts.add(rendered);
        }
    }
  }

  return parts.join('\n');
}

/// Escapes one plain-text streaming fragment without allowing it to create
/// Conduit-owned semantic HTML.
///
/// This deliberately does not preserve Markdown code spans or fences. Callers
/// may append fragments only while they have proved that the accumulated text
/// has no code delimiter; once one appears they must rebuild the authoritative
/// value with [renderSemanticMessageBlocks] so [_escapeText] can parse the
/// complete Markdown context.
String renderSemanticPlainTextFragment(String value) =>
    _semanticHtmlEscape.convert(value);

String _renderDetailsBlock(SemanticDetailsBlock block) {
  final attributes = <String, String>{
    'type': block.type,
    'done': block.done ? 'true' : 'false',
    if (block.id != null) 'id': block.id!,
    if (block.name != null) 'name': block.name!,
    if (block.duration != null) 'duration': block.duration!,
    if (block.arguments != null)
      'arguments': _jsonAttributeValue(block.arguments),
    if (block.result != null) 'result': _jsonAttributeValue(block.result),
    if (block.files != null) 'files': _jsonAttributeValue(block.files),
    if (block.embeds != null) 'embeds': _jsonAttributeValue(block.embeds),
  };
  final attrs = attributes.entries
      .where((entry) => entry.value.trim().isNotEmpty)
      .map((entry) => '${entry.key}="${_escape(entry.value)}"')
      .join(' ');
  final body = block.bodyMarkdown.trim().isEmpty
      ? ''
      : '\n${_escape(block.bodyMarkdown)}';
  return '<details $attrs>\n'
      '<summary>${_escape(block.summary)}</summary>'
      '$body\n'
      '</details>';
}

String _jsonAttributeValue(Object? value) {
  try {
    return jsonEncode(value);
  } catch (_) {
    return value?.toString() ?? '';
  }
}

String _formatBodyValue(Object value) {
  if (value is String) {
    return value;
  }
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value.toString();
  }
}

String _markdownCodeFence(String code, String language) {
  final longestFence = RegExp(r'`+').allMatches(code).fold<int>(0, (
    max,
    match,
  ) {
    final length = match.group(0)?.length ?? 0;
    return length > max ? length : max;
  });
  final fence = '`' * (longestFence >= 3 ? longestFence + 1 : 3);
  return '$fence$language\n$code\n$fence';
}

String _escape(String value) => _semanticHtmlEscape.convert(value);

// Line-anchored fence patterns used by [_escapeText], mirroring the markdown
// block parser (CommonMark fenced code blocks). A backtick fence opens on a
// line of 3+ backticks (0-3 spaces indent) whose info string has no backtick; a
// tilde fence opens on 3+ tildes. A fence closes on a line of the same fence
// character repeated at least as many times as the opener, followed only by
// whitespace. Because open/close detection matches the parser exactly, the code
// regions [_escapeText] skips equal the parser's — a line-leading `<details>`/
// `<summary>` can never be smuggled through unescaped (via a mid-line marker,
// a longer/shorter closing fence, a backtick in the info string, etc.).
final _openingBacktickFence = RegExp(r'^ {0,3}(`{3,})[^`]*$');
final _openingTildeFence = RegExp(r'^ {0,3}(~{3,}).*$');
final _closingFence = RegExp(r'^ {0,3}(`{3,}|~{3,})[ \t]*$');
final _indentedCodeLine = RegExp(r'^(?:    | {0,3}\t)');
final _semanticDetailsBlockStart = RegExp(
  r'^\s{0,3}<details(?:\s+[^>]*)?>',
  caseSensitive: false,
);

// These alternatives mirror the Markdown package's line-local CodeSyntax,
// AutolinkSyntax, and EmailAutolinkSyntax. Preserving only syntaxes the parser
// will turn into code/link nodes prevents entity escaping from changing their
// rendered text while leaving arbitrary angle-bracket HTML neutralized.
final _safeInlineMarkdown = RegExp(
  r'(?<!`)(`+(?!`))(.*?[^`])\1(?!`)|'
  r'<(?:[a-zA-Z][a-zA-Z\-\+\.]+):(?://)?[^\s>]*>|'
  r'''<[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9]'''
  r'''(?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?'''
  r'''(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*>''',
);

// CodeSyntax accepts newlines, but only after the block parser has kept those
// lines in one inline-capable block. Matching the raw document alone is unsafe:
// a candidate can cross a line-leading HTML block, leaving its opening backtick
// literal and its apparent code contents active as HTML. Mark candidates in a
// temporary copy and let the same GFM block/inline parser used by Conduit prove
// which occurrences are real code spans before preserving them.
final _multilineCodeSpanCandidate = RegExp(
  r'(?<!`)(`+(?!`))((?:.|\n)*?[^`])\1(?!`)',
);
const int _maxMultilineCodeSpanCandidates = 4096;

final class _SourceSpan {
  const _SourceSpan(this.start, this.end);

  final int start;
  final int end;
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
    final marker = _marker.firstMatch(match.group(0)!);
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
        !_semanticDetailsBlockStart.hasMatch(line)) {
      candidates.add(index);
    }
  }
  if (candidates.isEmpty) return const <int>{};

  var markerStart = '\uE000conduit-indented-code';
  while (value.contains(markerStart)) {
    markerStart += '\uE000';
  }
  var markerEnd = '\uE001';
  while (value.contains(markerEnd) || markerStart.contains(markerEnd)) {
    markerEnd += '\uE001';
  }

  final markedLines = List<String>.from(lines);
  for (final index in candidates) {
    final rawLine = markedLines[index];
    final hasCarriageReturn = rawLine.endsWith('\r');
    final line = hasCarriageReturn
        ? rawLine.substring(0, rawLine.length - 1)
        : rawLine;
    markedLines[index] =
        '$line$markerStart${index.toRadixString(36)}$markerEnd'
        '${hasCarriageReturn ? '\r' : ''}';
  }

  final recorder = _RecordingIndentedCodeSyntax(
    markerStart: markerStart,
    markerEnd: markerEnd,
  );
  try {
    md.Document(
      extensionSet: md.ExtensionSet.gitHubWeb,
      blockSyntaxes: <md.BlockSyntax>[recorder],
      encodeHtml: false,
    ).parse(markedLines.join('\n'));
  } catch (_) {
    // Parser disagreement must fail closed: ordinary escaping is always safe.
    return const <int>{};
  }
  return recorder.matchedLines;
}

List<_SourceSpan> _parserConfirmedMultilineCodeSpans(String value) {
  final candidates = _multilineCodeSpanCandidate
      .allMatches(value)
      .where((match) => match.group(0)!.contains('\n'))
      .toList(growable: false);
  if (candidates.isEmpty ||
      candidates.length > _maxMultilineCodeSpanCandidates) {
    return const <_SourceSpan>[];
  }

  // Private-use sentinels are inert Markdown text. Make the pair absent from
  // provider input so an answer cannot forge a candidate index.
  var markerStart = '\uE000conduit-code-span';
  while (value.contains(markerStart)) {
    markerStart += '\uE000';
  }
  var markerEnd = '\uE001';
  while (value.contains(markerEnd) || markerStart.contains(markerEnd)) {
    markerEnd += '\uE001';
  }

  final marked = StringBuffer();
  var sourceOffset = 0;
  for (var index = 0; index < candidates.length; index++) {
    final candidate = candidates[index];
    final openingLength = candidate.group(1)!.length;
    final insertionOffset = candidate.start + openingLength;
    marked
      ..write(value.substring(sourceOffset, insertionOffset))
      ..write(markerStart)
      ..write(index.toRadixString(36))
      ..write(markerEnd);
    sourceOffset = insertionOffset;
  }
  marked.write(value.substring(sourceOffset));

  final recorder = _RecordingCodeSyntax(
    markerStart: markerStart,
    markerEnd: markerEnd,
  );
  try {
    md.Document(
      extensionSet: md.ExtensionSet.gitHubWeb,
      inlineSyntaxes: <md.InlineSyntax>[recorder],
      encodeHtml: false,
    ).parse(marked.toString());
  } catch (_) {
    // Parser disagreement must fail closed: ordinary escaping is always safe.
    return const <_SourceSpan>[];
  }

  final confirmed = recorder.matchedCandidates.toList(growable: false)..sort();
  return <_SourceSpan>[
    for (final index in confirmed)
      if (index >= 0 && index < candidates.length)
        _SourceSpan(candidates[index].start, candidates[index].end),
  ];
}

String _escapeInlineMarkdownSegment(String value) => value.splitMapJoin(
  _safeInlineMarkdown,
  onMatch: (match) => match[0] ?? '',
  onNonMatch: _escape,
);

({String text, int nextSpanIndex}) _escapeInlineMarkdownLine(
  String line, {
  required int sourceStart,
  required List<_SourceSpan> protectedSpans,
  required int spanIndex,
}) {
  final sourceEnd = sourceStart + line.length;
  var nextSpanIndex = spanIndex;
  while (nextSpanIndex < protectedSpans.length &&
      protectedSpans[nextSpanIndex].end <= sourceStart) {
    nextSpanIndex += 1;
  }

  final result = StringBuffer();
  var lineOffset = 0;
  var candidateIndex = nextSpanIndex;
  while (candidateIndex < protectedSpans.length) {
    final span = protectedSpans[candidateIndex];
    if (span.start >= sourceEnd) break;
    final protectedStart = span.start <= sourceStart
        ? 0
        : span.start - sourceStart;
    final protectedEnd = span.end >= sourceEnd
        ? line.length
        : span.end - sourceStart;
    if (protectedStart > lineOffset) {
      result.write(
        _escapeInlineMarkdownSegment(
          line.substring(lineOffset, protectedStart),
        ),
      );
    }
    if (protectedEnd > lineOffset) {
      result.write(line.substring(protectedStart, protectedEnd));
      lineOffset = protectedEnd;
    }
    if (span.end <= sourceEnd) {
      candidateIndex += 1;
      nextSpanIndex = candidateIndex;
    } else {
      break;
    }
  }
  if (lineOffset < line.length) {
    result.write(_escapeInlineMarkdownSegment(line.substring(lineOffset)));
  }
  return (text: result.toString(), nextSpanIndex: nextSpanIndex);
}

/// Escapes HTML-significant characters in plain answer text while leaving the
/// contents of fenced/indented code blocks, inline code spans, and angle
/// autolinks untouched.
///
/// Answer text is re-parsed by the markdown pipeline, which does not decode
/// entity references inside code spans/fences; escaping there would leak literal
/// entities into rendered output (e.g. `List&lt;int&gt;`, `https:&#47;&#47;`).
/// Text outside code is still escaped so a model cannot emit a literal
/// `<details>`/`<summary>` that renders as a spoofed reasoning/tool section.
///
/// The scan is line-based and mirrors the block parser's fenced-code handling,
/// including unclosed fences (which extend to end of input, e.g. mid-stream).
/// Indented code is preserved only when the Markdown block parser confirms the
/// exact source line as code. This includes code immediately after a completed
/// non-paragraph block (for example a fence or ATX heading), while an indented
/// line that continues a paragraph remains escaped. Multi-line inline code is
/// likewise preserved only when the parser confirms that its exact occurrence
/// stays inside one inline-capable block, so an apparent span cannot hide a
/// line-leading tag that actually interrupts its paragraph.
///
/// Unlike [_escape], this is only safe for top-level answer text; `<details>`
/// attributes/summaries/bodies are HTML-unescaped wholesale at parse time and
/// must keep full escaping.
String _escapeText(String value) {
  final lines = value.split('\n');
  final multilineCodeSpans = _parserConfirmedMultilineCodeSpans(value);
  final indentedCodeLines = _parserConfirmedIndentedCodeLines(value);
  final result = <String>[];
  String? openFenceChar;
  var openFenceLength = 0;
  var inIndentedCode = false;
  var sourceStart = 0;
  var multilineSpanIndex = 0;

  for (var index = 0; index < lines.length; index++) {
    final rawLine = lines[index];
    // Normalize CRLF: split('\n') leaves a trailing '\r' the fence patterns
    // (and the downstream renderer) would otherwise mishandle.
    final line = rawLine.endsWith('\r')
        ? rawLine.substring(0, rawLine.length - 1)
        : rawLine;
    if (openFenceChar != null) {
      // Inside a fenced block: emit verbatim, closing on a matching fence line.
      result.add(line);
      final close = _closingFence.firstMatch(line);
      if (close != null) {
        final run = close.group(1)!;
        if (run[0] == openFenceChar && run.length >= openFenceLength) {
          openFenceChar = null;
          openFenceLength = 0;
        }
      }
      sourceStart += rawLine.length + 1;
      continue;
    }

    final isBlank = line.trim().isEmpty;
    final isIndented = _indentedCodeLine.hasMatch(line);
    if (inIndentedCode) {
      if (isBlank || isIndented) {
        result.add(line);
        sourceStart += rawLine.length + 1;
        continue;
      }
      inIndentedCode = false;
    }

    if (isIndented &&
        !_semanticDetailsBlockStart.hasMatch(line) &&
        indentedCodeLines.contains(index)) {
      inIndentedCode = true;
      result.add(line);
      sourceStart += rawLine.length + 1;
      continue;
    }

    final open =
        _openingBacktickFence.firstMatch(line) ??
        _openingTildeFence.firstMatch(line);
    if (open != null) {
      final run = open.group(1)!;
      openFenceChar = run[0];
      openFenceLength = run.length;
      result.add(line);
      sourceStart += rawLine.length + 1;
      continue;
    }

    // Outside any code block: preserve only parser-recognized inline code and
    // angle autolinks. In particular, `<details>` and `<summary>` do not match
    // these alternatives and remain escaped.
    final escapedLine = _escapeInlineMarkdownLine(
      line,
      sourceStart: sourceStart,
      protectedSpans: multilineCodeSpans,
      spanIndex: multilineSpanIndex,
    );
    result.add(escapedLine.text);
    multilineSpanIndex = escapedLine.nextSpanIndex;
    sourceStart += rawLine.length + 1;
  }

  return result.join('\n');
}
