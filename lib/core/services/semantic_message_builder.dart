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

// Matches fenced code blocks (``` or ~~~) and single-line inline code spans.
// Fences must OPEN at the start of a line (0-3 spaces indent); the three
// alternatives are (1) a fence whose closing line repeats the same fence
// character at least as many times as the opening run (`\1[`~]*`, matching
// CommonMark's "closing fence may be longer"), (2) an unclosed fence that runs
// to end of input (as the block parser and [ConduitMarkdownPreprocessor.
// normalize] treat it — e.g. mid-stream, or when a model forgets the closing
// fence), and (3) a single-line inline span. Because every fence is anchored to
// a line start, the matched regions are a strict subset of what the markdown
// block parser treats as code, so escaping is only ever SKIPPED where the
// parser would not begin a block — a line-leading `<details>`/`<summary>` can
// never be smuggled past [_escapeText] via a mid-line fence marker or a longer
// closing fence. Inline code is matched one line at a time for the same reason.
final _codeRegionPattern = RegExp(
  r'(?:^|\n)[ ]{0,3}(`{3,}|~{3,})[^\n]*\n[\s\S]*?\n[ ]{0,3}\1[`~]*[ \t]*(?=\n|$)'
  r'|(?:^|\n)[ ]{0,3}(?:`{3,}|~{3,})[^\n]*\n[\s\S]*$'
  r'|`[^`\n]+?`',
  multiLine: true,
);

/// Escapes HTML-significant characters in plain answer text while leaving the
/// contents of markdown code spans and fenced code blocks untouched.
///
/// Answer text is re-parsed by the markdown pipeline, which does not decode
/// entity references inside code spans/fences. Escaping those regions leaks
/// literal entities into the rendered output (e.g. `List&lt;int&gt;`,
/// `https:&#47;&#47;`). Text outside code is still escaped so a model cannot
/// emit a literal `<details>`/`<summary>` block that renders as a spoofed
/// reasoning/tool section. Unlike [_escape], this is only safe for top-level
/// answer text; `<details>` attributes/summaries/bodies are HTML-unescaped
/// wholesale at parse time and must keep full escaping.
String _escapeText(String value) => value.splitMapJoin(
  _codeRegionPattern,
  onMatch: (match) => match[0] ?? '',
  onNonMatch: _escape,
);
