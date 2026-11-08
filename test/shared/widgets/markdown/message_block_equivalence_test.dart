import 'dart:convert';
import 'dart:io';

import 'package:conduit/shared/widgets/markdown/compiled_markdown_document.dart';
import 'package:conduit/shared/widgets/markdown/markdown_compile_service.dart';
import 'package:conduit/shared/widgets/markdown/renderer/details_block_widget.dart';
import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

/// The desktop block segmenter (`segmentAssistantMessage` in
/// conduit_markdown) must show what this app shows. For every message in the
/// segmenter's corpus, this compiles the content the way the chat transcript
/// does (`prepareMarkdownContent` + `compilePreparedMarkdownSync`) and
/// compares the two, block by block and field by field.
///
/// Math placeholders differ between the two (the app keeps them in its
/// compiled document; the segmenter hands back the source), so both sides
/// are compared with every formula written as `⟦tex⟧`: the app's
/// placeholders are resolved, then any math still in source form on either
/// side (tool attributes, which neither side tokenizes) is put through the
/// shared rule.
void main() {
  final corpus = (jsonDecode(
    File(
      'packages/conduit_markdown/test/corpus/'
      'assistant_message_blocks.json',
    ).readAsStringSync(),
  ) as List).cast<Map<String, Object?>>();

  test('the corpus is not empty', () => expect(corpus.length, greaterThan(40)));

  // While streaming, the segmenter holds back a semantic section that has not
  // closed; the app shows it as raw text (or a section whose later text leaks
  // out). Everything before the section must still match.
  const streamingHoldBacks = <String, String>{
    'unterminated reasoning while streaming': '<details type="reasoning"',
    'complete tool call inside an unterminated reasoning while streaming':
        '<details type="reasoning"',
  };

  for (final entry in corpus) {
    final name = entry['name']! as String;
    final content = entry['content']! as String;
    final streaming = entry['streaming']! as bool;

    test('matches the app: $name', () {
      final blocks = segmentAssistantMessage(content, streaming: streaming);
      expect(
        [for (final block in blocks) block.toJson()],
        entry['blocks'],
        reason: 'the corpus golden is stale; regenerate it',
      );

      final holdBack = streamingHoldBacks[name];
      final appContent = holdBack == null
          ? content
          : content.substring(0, content.indexOf(holdBack));
      if (holdBack != null) {
        expect(
          _appView(content, streaming: streaming),
          isNot(_appView(appContent, streaming: streaming)),
          reason: 'the app should still differ here; update the hold-backs',
        );
      }
      expect(
        _segmenterView(blocks),
        _appView(appContent, streaming: streaming),
      );
    });

    test('claims the same math as the app: $name', () {
      for (final block in segmentAssistantMessage(
        content,
        streaming: streaming,
      ).whereType<TextMessageBlock>()) {
        final document = compilePreparedMarkdownSync(block.markdown);
        final appTex = [
          ...document.blockLatexExpressions.values,
          ...document.inlineLatexExpressions.values,
        ]..sort();
        final normalized = normalizeTextForPlainMarkdown(
          block.markdown,
          hasSources: false,
        );
        expect(_emittedTex(normalized)..sort(), appTex);
      }
    });
  }

  test('reasoning titles match the app for every done/duration/summary', () {
    for (final summary in [
      '',
      'Thinking…',
      'thinking...',
      'Thought for 9 seconds',
      'Weighing it (3s)',
      'Weighing the routes',
    ]) {
      for (final done in [true, false]) {
        for (final duration in [null, '0', '7', 'n/a']) {
          final content =
              '<details type="reasoning" done="$done"'
              '${duration == null ? '' : ' duration="$duration"'}>\n'
              '<summary>$summary</summary>\nbody\n</details>';
          final block =
              segmentAssistantMessage(content).single as ReasoningMessageBlock;
          final data =
              (compilePreparedMarkdownSync(
                        prepareMarkdownContent(content, streaming: false),
                      ).blocks.single
                      as CompiledMarkdownDetailsBlock)
                  .detailsData;
          expect(
            _title(block.title),
            _appTitle(resolveReasoningHeader(data)),
            reason: content,
          );
        }
      }
    }
  });
}

// --- the app's view ---------------------------------------------------------

List<Object?> _appView(String content, {required bool streaming}) {
  final document = compilePreparedMarkdownSync(
    prepareMarkdownContent(content, streaming: streaming),
  );
  String plain(String text) => _sourceWithMath(_withMath(text, document));
  final view = _View();
  for (final block in document.blocks) {
    switch (block) {
      case CompiledMarkdownDetailsGroup(:final items):
        view.add({
          'toolCalls': [
            for (final item in items) _appToolCall(item.detailsData, plain),
          ],
        });
      case CompiledMarkdownDetailsBlock(:final detailsData):
        view.add(_appDetails(detailsData, plain));
      case CompiledMarkdownNodeBlock(:final node):
        // `</details>` with text after it on the same line compiles to a div
        // holding the section and the text.
        if (node is CompiledMarkdownElement &&
            node.tag == 'div' &&
            node.children.isNotEmpty &&
            node.children.first is CompiledMarkdownElement &&
            (node.children.first as CompiledMarkdownElement).detailsData !=
                null) {
          final details =
              (node.children.first as CompiledMarkdownElement).detailsData!;
          view.add(_appDetails(details, plain));
          for (final child in node.children.skip(1)) {
            view.addText(plain(child.textContent));
          }
        } else {
          view.addText(plain(node.textContent));
        }
      default:
        fail('unexpected block ${block.runtimeType}');
    }
  }
  return view.entries;
}

Map<String, Object?> _appDetails(
  CompiledMarkdownDetailsData data,
  String Function(String) plain,
) {
  switch (data.type) {
    case 'tool_calls':
      return {
        'toolCalls': [_appToolCall(data, plain)],
      };
    case 'reasoning':
      return {
        'reasoning': {
          'summary': data.summaryText,
          'durationSeconds': data.hasDuration ? data.durationSeconds : null,
          'done': data.isDone,
          'pending': data.isPending,
          'body': plain(data.bodyMarkdown),
        },
      };
    case 'code_interpreter':
      return {
        'codeInterpreter': {
          'text': _collapse(_withoutFenceLines(plain(data.bodyMarkdown))),
          'done': data.isDone,
          'pending': data.isPending,
        },
      };
    default:
      return {
        'details': {
          'type': data.type,
          'summary': data.summaryText,
          'body': plain(data.bodyMarkdown),
          'done': data.isDone,
          'pending': data.isPending,
        },
      };
  }
}

Map<String, Object?> _appToolCall(
  CompiledMarkdownDetailsData data,
  String Function(String) plain,
) {
  final tool = data.toolCallData!;
  return {
    'name': data.name,
    'arguments': plain(tool.argumentsText),
    'result': plain(tool.resultText),
    'done': data.isDone,
    'pending': data.isPending,
    'status': data.status,
    'isError': tool.isError,
    'hasImages': tool.imageUrls.isNotEmpty,
    'hasEmbeds': tool.embedSources.isNotEmpty,
  };
}

// --- the segmenter's view ---------------------------------------------------

List<Object?> _segmenterView(List<MessageBlock> blocks) {
  final view = _View();
  for (final block in blocks) {
    switch (block) {
      case TextMessageBlock(:final markdown):
        // Compile the text the app's way so both sides read the same.
        final document = compilePreparedMarkdownSync(markdown);
        for (final node in document.nodes) {
          view.addText(_sourceWithMath(_withMath(node.textContent, document)));
        }
      case ToolCallsMessageBlock(:final calls):
        view.add({
          'toolCalls': [
            for (final call in calls)
              {
                'name': call.name,
                'arguments': _sourceWithMath(call.arguments),
                'result': _sourceWithMath(call.result),
                'done': call.done,
                'pending': call.pending,
                'status': call.status,
                'isError': call.isError,
                'hasImages': call.files?.contains('image') ?? false,
                'hasEmbeds': call.embeds != null,
              },
          ],
        });
      case ReasoningMessageBlock():
        view.add({
          'reasoning': {
            'summary': block.summary,
            'durationSeconds': block.durationSeconds,
            'done': block.done,
            'pending': block.pending,
            'body': _sourceWithMath(block.body),
          },
        });
      case CodeInterpreterMessageBlock():
        view.add({
          'codeInterpreter': {
            'text': _collapse(
              '${_sourceWithMath(block.code)} '
              '${_sourceWithMath(block.output)}',
            ),
            'done': block.done,
            'pending': block.pending,
          },
        });
      case DetailsMessageBlock():
        view.add({
          'details': {
            'type': block.type,
            'summary': block.summary,
            'body': _sourceWithMath(block.body),
            'done': block.done,
            'pending': block.pending,
          },
        });
    }
  }
  return view.entries;
}

// --- helpers ----------------------------------------------------------------

/// Entries with adjacent text merged and whitespace collapsed.
final class _View {
  final List<Object?> entries = [];

  void add(Map<String, Object?> entry) => entries.add(entry);

  void addText(String text) {
    final collapsed = _collapse(text);
    if (collapsed.isEmpty) return;
    if (entries.isNotEmpty && entries.last is Map<String, Object?>) {
      final last = entries.last! as Map<String, Object?>;
      if (last.containsKey('text')) {
        entries[entries.length - 1] = {'text': '${last['text']} $collapsed'};
        return;
      }
    }
    entries.add({'text': collapsed});
  }
}

String _collapse(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

final _fenceLine = RegExp(r'^ {0,3}(?:`{3,}|~{3,}).*$', multiLine: true);
String _withoutFenceLines(String text) => text.replaceAll(_fenceLine, '');

/// [text] from the app's compiled [document], every formula as `⟦tex⟧`.
String _withMath(String text, CompiledMarkdownDocument document) {
  final expressions = {
    ...document.blockLatexExpressions,
    ...document.inlineLatexExpressions,
  };
  if (expressions.isEmpty) return text;
  return text.replaceAllMapped(
    RegExp('(\n\n)?(${expressions.keys.map(RegExp.escape).join('|')})(\n\n)?'),
    (match) => '⟦${expressions[match[2]]}⟧',
  );
}

/// Segmenter source with every formula the shared rule claims as `⟦tex⟧`.
String _sourceWithMath(String source) {
  final tokenizer = MathTokenizer();
  return tokenizer.replaceTokens(
    tokenizer.tokenize(source),
    (_, span, {required wrapped}) => '⟦${span.tex}⟧',
  );
}

/// The TeX of each formula in normalized output: `$$` blocks and unescaped
/// `$…$` spans.
List<String> _emittedTex(String normalized) => [
  for (final match in RegExp(
    r'(?<!\\)\$\$\n([\s\S]*?)\n\$\$|(?<![\\$])\$(?!\$)([^$\n]+?)(?<!\\)\$',
  ).allMatches(normalized))
    match[1] ?? match[2]!,
];

String _title(ReasoningTitle title) => switch (title.kind) {
  ReasoningTitleKind.thinking => 'thinking',
  ReasoningTitleKind.thoughtFor => 'thoughtFor ${title.seconds}',
  ReasoningTitleKind.summary => 'summary ${title.summary}',
  ReasoningTitleKind.thoughts => 'thoughts',
};

String _appTitle(ReasoningHeader header) => switch (header) {
  ReasoningHeaderThinking() => 'thinking',
  ReasoningHeaderThoughtFor(:final seconds) => 'thoughtFor $seconds',
  ReasoningHeaderSummary(:final summary) => 'summary $summary',
  ReasoningHeaderThoughts() => 'thoughts',
};
