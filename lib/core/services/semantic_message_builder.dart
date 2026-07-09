import 'dart:convert';

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
final _closingFence = RegExp(r'^ {0,3}(`{3,}|~{3,})[ \t]*\r?$');
final _inlineCodeSpan = RegExp(r'`[^`]+?`');

/// Escapes HTML-significant characters in plain answer text while leaving the
/// contents of fenced code blocks and inline code spans untouched.
///
/// Answer text is re-parsed by the markdown pipeline, which does not decode
/// entity references inside code spans/fences; escaping there would leak literal
/// entities into rendered output (e.g. `List&lt;int&gt;`, `https:&#47;&#47;`).
/// Text outside code is still escaped so a model cannot emit a literal
/// `<details>`/`<summary>` that renders as a spoofed reasoning/tool section.
///
/// The scan is line-based and mirrors the block parser's fenced-code handling,
/// including unclosed fences (which extend to end of input, e.g. mid-stream),
/// so the skipped regions are exactly the parser's code and escaping is never
/// skipped where the parser would begin a block. Inline code is matched a
/// single line at a time so a multi-line span cannot hide a line-leading tag.
///
/// Unlike [_escape], this is only safe for top-level answer text; `<details>`
/// attributes/summaries/bodies are HTML-unescaped wholesale at parse time and
/// must keep full escaping.
String _escapeText(String value) {
  final lines = value.split('\n');
  final result = <String>[];
  String? openFenceChar;
  var openFenceLength = 0;

  for (final line in lines) {
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
      continue;
    }

    // Outside any code block: escape everything except inline code spans.
    result.add(
      line.splitMapJoin(
        _inlineCodeSpan,
        onMatch: (match) => match[0] ?? '',
        onNonMatch: _escape,
      ),
    );
  }

  return result.join('\n');
}
