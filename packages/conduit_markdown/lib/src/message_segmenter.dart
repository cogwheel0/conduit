import 'dart:convert';

import 'package:html_unescape/html_unescape.dart';
import 'package:markdown/markdown.dart' as md;

import 'details_block_syntax.dart';
import 'linear_inline_syntaxes.dart' show conduitGitHubWebExtensionSet;
import 'markdown_preprocessor.dart';
import 'math_spans.dart';
import 'message_blocks.dart';
import 'semantic_details.dart';

final _detailsOpenPattern = RegExp(r'<details\b', caseSensitive: false);
final _toolCallDetailsOpenPattern = RegExp(
  r'<details\b[^>]*type="tool_calls"[^>]*>',
  caseSensitive: false,
);
final _detailsTagHint = RegExp('<details', caseSensitive: false);

final _attributeUnescape = HtmlUnescape();

/// Drops a trailing Open WebUI tool-call block whose `</details>` has not
/// arrived yet, so a half-streamed call never shows as raw text.
///
/// This is the mobile renderer's streaming rule, unchanged: it looks only at
/// the last `tool_calls` opener anywhere in [input] and does not know about
/// code.
String stripTrailingIncompleteToolCallDetails(String input) {
  if (input.isEmpty || !_detailsOpenPattern.hasMatch(input)) {
    return input;
  }

  final matches = _toolCallDetailsOpenPattern
      .allMatches(input)
      .toList(growable: false);
  if (matches.isEmpty) {
    return input;
  }

  final lastOpen = matches.last;
  final trailing = input.substring(lastOpen.start).toLowerCase();
  if (trailing.contains('</details>')) {
    return input;
  }

  return input.substring(0, lastOpen.start).trimRight();
}

/// Prepares assistant content for display the way the mobile renderer does
/// before it parses markdown: [ConduitMarkdownPreprocessor.normalize], plus,
/// while [streaming], [stripTrailingIncompleteToolCallDetails].
String prepareAssistantMarkdown(String content, {required bool streaming}) {
  final normalized = ConduitMarkdownPreprocessor.normalize(content);
  return streaming
      ? stripTrailingIncompleteToolCallDetails(normalized)
      : normalized;
}

/// Splits an assistant message into ordered [MessageBlock]s: answer text,
/// reasoning, tool calls, code-interpreter runs and other `<details>`
/// sections.
///
/// [content] is the message content as stored and as the mobile renderer
/// receives it (Open WebUI-style markdown with semantic `<details>` blocks).
/// The result shows the same thing the mobile renderer shows for the same
/// input, because it is the same parse:
///
/// 1. [prepareAssistantMarkdown] (normalize; while [streaming], drop a
///    trailing unfinished tool call);
/// 2. [MathTokenizer] outside `<details>` opening tags, since display-math
///    tokens add blank lines that can move a tag onto its own line;
/// 3. `package:markdown` with [DetailsBlockSyntax] and the GitHub-web
///    extension set, recording which top-level lines each `<details>` block
///    consumed. Blocks inside code, or escaped as `&lt;details&gt;` (model
///    text cannot spoof a section, issue #549), never reach the syntax.
///
/// Then the math tokens are turned back into their source, so text and
/// bodies hold the original markdown.
///
/// Field values follow the mobile renderer's, including its entity decoding
/// of attributes and bodies. Adjacent tool-call blocks merge into one
/// [ToolCallsMessageBlock], as the mobile renderer groups them.
///
/// While [streaming], a top-level semantic `<details>` block that has not
/// closed yet is dropped with everything after it, nested sections included;
/// the mobile renderer shows such a block as raw text, or, when a nested
/// section inside it has closed, as a section with the rest of the outer
/// block leaking out as answer text. A truncated opening tag is dropped in
/// both modes by the normalizer. When not streaming, blocks come out exactly
/// as on mobile, an unterminated one as text.
///
/// Text between sections merges into one [TextMessageBlock].
///
/// Limits: `<details>` nested in a list item or blockquote stays in its text
/// block (the mobile renderer draws it there; a plain renderer shows the
/// escaped tag), and a nested `<details>` inside a section body stays in that
/// body's markdown.
List<MessageBlock> segmentAssistantMessage(
  String content, {
  bool streaming = false,
}) {
  final prepared = prepareAssistantMarkdown(content, streaming: streaming);
  if (prepared.trim().isEmpty) return const <MessageBlock>[];
  if (!_detailsTagHint.hasMatch(prepared)) {
    return <MessageBlock>[TextMessageBlock(_tidyText(prepared))];
  }

  final tokenizer = MathTokenizer();
  final tokenized = tokenizeMathOutsideDetailsTags(tokenizer, prepared);
  final lines = LineSplitter.split(tokenized)
      .map(md.Line.new)
      .toList(growable: false);
  final recorder = _RecordingDetailsSyntax(lines);
  final document = md.Document(
    extensionSet: conduitGitHubWebExtensionSet,
    blockSyntaxes: <md.BlockSyntax>[recorder],
    encodeHtml: false,
  );
  md.BlockParser(lines, document).parseLines();

  final builder = _BlockListBuilder(tokenizer);
  var cursor = 0;
  for (final record in recorder.records) {
    builder.addText(_joinLines(lines, cursor, record.start));
    cursor = record.end;
    final node = record.node;
    if (streaming &&
        DetailsBlockSyntax.unclosedDepth(
              lines.sublist(record.start, record.end).map((l) => l.content),
            ) >
            0) {
      // Still open at the end of the stream. A nested section that has
      // closed makes the syntax return a section anyway, with the outer
      // block's later text leaking out as answer text; hold the whole
      // section back instead, as an unclosed one is.
      builder.addText(
        dropUnterminatedSemanticDetails(
          _joinLines(lines, record.start, record.end),
        ),
      );
      continue;
    }
    if (node is md.Element && node.tag == 'details') {
      builder.addDetails(node, groupable: true);
      continue;
    }
    if (node is md.Element && node.tag == 'div') {
      // `</details>` followed by more text on its line: the syntax returns
      // the section plus the trailing text, entity-decoded and re-parsed.
      // The mobile renderer does not group a section from this shape with
      // its neighbours.
      final details = node.children!.first as md.Element;
      builder.addDetails(details, groupable: false);
      final raw = _joinLines(lines, record.start, record.end);
      final closing = raw.toLowerCase().lastIndexOf('</details>');
      builder.addText(
        _attributeUnescape
            .convert(raw.substring(closing + '</details>'.length))
            .trimLeft(),
      );
      continue;
    }
    // No `</details>` before the end of the message: the syntax consumed
    // every remaining line and returned them as one raw paragraph.
    final raw = _joinLines(lines, record.start, record.end);
    builder.addText(streaming ? dropUnterminatedSemanticDetails(raw) : raw);
  }
  builder.addText(_joinLines(lines, cursor, lines.length));
  return builder.build();
}

String _joinLines(List<md.Line> lines, int start, int end) =>
    [for (var index = start; index < end; index++) lines[index].content]
        .join('\n');

/// Text block markdown: leading blank lines and trailing whitespace go;
/// leading indentation on the first line stays (it can make indented code).
String _tidyText(String text) {
  var start = 0;
  while (true) {
    final newline = text.indexOf('\n', start);
    if (newline == -1 || text.substring(start, newline).trim().isNotEmpty) {
      break;
    }
    start = newline + 1;
  }
  return text.substring(start).trimRight();
}

final class _DetailsRecord {
  const _DetailsRecord(this.start, this.end, this.node);

  /// First top-level line the block consumed, and one past the last.
  final int start;
  final int end;
  final md.Node node;
}

/// [DetailsBlockSyntax], noting the top-level lines each block consumed.
/// Child parsers (blockquotes, list items, trailing text) have their own
/// line lists and are not recorded.
final class _RecordingDetailsSyntax extends DetailsBlockSyntax {
  _RecordingDetailsSyntax(List<md.Line> lines)
    : _lines = lines,
      _index = Map<md.Line, int>.identity()
        ..addEntries([
          for (var index = 0; index < lines.length; index++)
            MapEntry(lines[index], index),
        ]);

  final List<md.Line> _lines;
  final Map<md.Line, int> _index;
  final List<_DetailsRecord> records = <_DetailsRecord>[];

  @override
  md.Node parse(md.BlockParser parser) {
    final topLevel = identical(parser.lines, _lines);
    final start = topLevel ? _index[parser.current]! : -1;
    final node = super.parse(parser);
    if (topLevel) {
      final end = parser.isDone ? _lines.length : _index[parser.current]!;
      records.add(_DetailsRecord(start, end, node));
    }
    return node;
  }
}

final class _BlockListBuilder {
  _BlockListBuilder(this._tokenizer);

  final MathTokenizer _tokenizer;
  final List<MessageBlock> _blocks = <MessageBlock>[];
  List<MessageToolCall>? _openGroup;

  void addText(String tokenized) {
    final text = _tidyText(_tokenizer.restore(tokenized));
    if (text.trim().isEmpty) return;
    _closeGroup();
    final last = _blocks.isEmpty ? null : _blocks.last;
    if (last is TextMessageBlock) {
      _blocks[_blocks.length - 1] = TextMessageBlock(
        '${last.markdown}\n\n$text',
      );
      return;
    }
    _blocks.add(TextMessageBlock(text));
  }

  void addDetails(md.Element element, {required bool groupable}) {
    final attributes = element.attributes;
    final type = attributes['type']?.trim() ?? '';
    final done = attributes['done'];
    final status = attributes['status'];
    final terminalTool =
        type == 'tool_calls' &&
        (status == 'failed' || status == 'incomplete' || status == 'rejected');
    final isDone = done == 'true' || terminalTool;
    final isPending =
        !isDone && (done != null || (type == 'tool_calls' && status != null));
    final body = _restore(_decode(attributes['body_markdown']));
    final children = element.children ?? const <md.Node>[];
    final summary =
        children.isNotEmpty &&
            children.first is md.Element &&
            (children.first as md.Element).tag == 'summary'
        ? _restore(children.first.textContent.trim())
        : '';

    if (type == 'tool_calls') {
      final call = _toolCall(attributes, isDone: isDone, isPending: isPending);
      final group = _openGroup;
      if (groupable && group != null) {
        group.add(call);
        return;
      }
      _closeGroup();
      _openGroup = <MessageToolCall>[call];
      return;
    }

    _closeGroup();
    switch (type) {
      case 'reasoning':
        final rawDuration = attributes['duration']?.trim() ?? '';
        _blocks.add(
          ReasoningMessageBlock(
            summary: summary,
            durationSeconds: rawDuration.isEmpty
                ? null
                : int.tryParse(rawDuration) ?? 0,
            done: isDone,
            pending: isPending,
            body: body,
          ),
        );
      case 'code_interpreter':
        final parts = _splitCodeInterpreterBody(body);
        _blocks.add(
          CodeInterpreterMessageBlock(
            code: parts.code,
            language: parts.language,
            output: parts.output,
            done: isDone,
            pending: isPending,
          ),
        );
      default:
        _blocks.add(
          DetailsMessageBlock(
            type: type,
            summary: summary,
            body: body,
            done: isDone,
            pending: isPending,
          ),
        );
    }
  }

  MessageToolCall _toolCall(
    Map<String, String> attributes, {
    required bool isDone,
    required bool isPending,
  }) {
    final result = _restore(_decode(attributes['result']));
    final files = attributes['files'];
    final embeds = attributes['embeds'];
    final status = attributes['status'];
    return MessageToolCall(
      id: attributes['id'] ?? '',
      name: attributes['name']?.trim() ?? '',
      arguments: _restore(_decode(attributes['arguments'])),
      result: result,
      done: isDone,
      pending: isPending,
      status: status,
      isError: status == 'failed' || _isToolResultError(result, attributes),
      files: files == null || files.isEmpty ? null : _decode(files),
      embeds: embeds == null || embeds.isEmpty ? null : _decode(embeds),
    );
  }

  String _restore(String value) => _tokenizer.restore(value);

  void _closeGroup() {
    final group = _openGroup;
    if (group == null) return;
    _blocks.add(ToolCallsMessageBlock(group));
    _openGroup = null;
  }

  List<MessageBlock> build() {
    _closeGroup();
    return List<MessageBlock>.unmodifiable(_blocks);
  }
}

String _decode(String? input) =>
    input == null || input.isEmpty ? '' : _attributeUnescape.convert(input);

// The fence rules Conduit's semantic builder uses (CommonMark): a backtick
// fence's info string has no backtick; a fence closes on a run of the same
// character at least as long, followed only by whitespace.
final _openingBacktickFence = RegExp(r'^ {0,3}(`{3,})([^`]*)$');
final _openingTildeFence = RegExp(r'^ {0,3}(~{3,})(.*)$');

/// Code, language and output from a code-interpreter body: Conduit and Open
/// WebUI write the code as the body's leading fence and any output after it.
({String code, String language, String output}) _splitCodeInterpreterBody(
  String body,
) {
  final trimmed = body.trim();
  final lines = trimmed.split('\n');
  final open =
      _openingBacktickFence.firstMatch(lines.first) ??
      _openingTildeFence.firstMatch(lines.first);
  if (open == null) return (code: '', language: '', output: trimmed);
  final fence = open[1]!;
  final info = open[2]!.trim();
  final language = info.isEmpty ? '' : info.split(RegExp(r'\s')).first;
  final closing = RegExp(
    '^ {0,3}${RegExp.escape(fence[0])}{${fence.length},}[ \\t]*\$',
  );
  for (var index = 1; index < lines.length; index++) {
    if (closing.hasMatch(lines[index])) {
      return (
        code: lines.sublist(1, index).join('\n'),
        language: language,
        output: lines.sublist(index + 1).join('\n').trim(),
      );
    }
  }
  return (code: lines.sublist(1).join('\n'), language: language, output: '');
}

// The tool-result helpers below follow the mobile renderer, which follows
// Open WebUI's `ToolCallDisplay.svelte`.

Object? _parseJsonString(String input) {
  if (input.isEmpty) return '';
  try {
    final decoded = json.decode(input);
    if (decoded is String && decoded != input) {
      return _parseJsonString(decoded);
    }
    return decoded;
  } catch (_) {
    return input;
  }
}

const Set<String> _toolResultTextPartTypes = {
  'input_text',
  'output_text',
  'text',
};

/// The text of a tool result that is a list of content parts, as Open WebUI's
/// `getToolResultText` shows a `function_call_output`; null for any other
/// shape.
String? _toolResultPartsText(
  Object? result, {
  required bool structuredOpenWebUi,
}) {
  if (result is! List) return null;
  if (result.isEmpty) return structuredOpenWebUi ? '' : null;
  final text = StringBuffer();
  var hasTextPart = false;
  for (final part in result) {
    if (part is! Map) {
      if (structuredOpenWebUi) continue;
      return null;
    }
    final type = part['type'];
    if (type == 'input_image') continue;
    if (!structuredOpenWebUi &&
        !part.containsKey('text') &&
        !_toolResultTextPartTypes.contains(type)) {
      return null;
    }
    final value = part['text'];
    if (value is String) {
      text.write(value);
    } else if (value is num || value is bool) {
      text.write(value.toString());
    } else if (value != null) {
      return null;
    }
    hasTextPart = true;
  }
  return hasTextPart || structuredOpenWebUi ? text.toString() : null;
}

bool _isToolResultError(String resultText, Map<String, String> attributes) {
  final parsed = _parseJsonString(resultText);
  return _isErrorValue(
    _toolResultPartsText(
          parsed,
          structuredOpenWebUi: attributes.containsKey('status'),
        ) ??
        parsed,
  );
}

bool _isErrorValue(Object? result) {
  if (result is String) {
    final text = result.trim().toLowerCase();
    if (text.startsWith('error:') ||
        text.startsWith('exception:') ||
        text.startsWith('traceback') ||
        text.startsWith('http error!')) {
      return true;
    }
    result = _parseJsonString(result);
  }
  if (result is! Map) return false;
  bool hasValue(Object? value) =>
      value is String ? value.trim().isNotEmpty : value is Map || value is List;
  if (hasValue(result['error'])) return true;
  final status = result['status']?.toString().trim().toLowerCase();
  if (status == 'error' || status == 'failed') return true;
  return (result['success'] == false || result['ok'] == false) &&
      hasValue(result['message']);
}
