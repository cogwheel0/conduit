import 'dart:convert';

const HtmlEscape _semanticHtmlEscape = HtmlEscape();

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
          parts.add(_escape(text));
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
