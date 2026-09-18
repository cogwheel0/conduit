// Regression tests for issue #677.
//
// Two failure classes, reproduced from real user data before the fix:
//  A. Semantic tool-call/reasoning blocks appended after an answer that
//     leaves a ``` fence open got swallowed by the synthetic fence auto-
//     close and rendered as a raw wall;
//  B. Tool-call attributes whose values contain raw double quotes (scraped
//     page text) terminated the parser's attr="(.*?)" match early, leaking
//     the tail as literal entity text.
import 'package:checks/checks.dart';
import 'package:conduit/core/services/semantic_message_builder.dart';
import 'package:conduit/shared/widgets/markdown/markdown_preprocessor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const toolTag =
      '<details type="tool_calls" done="true" id="x" name="fetch_url" '
      'result="ok">\n<summary>Tool Executed</summary>\n</details>';

  group('#677 attribute-value quote escaping', () {
    test('quotes inside attribute values cannot terminate the attr early', () {
      // result value contains raw quotes (scraped content)
      final rendered = renderSemanticMessageBlocks([
        SemanticDetailsBlock.toolCall(
          id: 'x',
          name: 'fetch_url',
          arguments: '{}',
          done: true,
          result: 'He said "stay focused" and left',
        ),
      ]);
      // The whole value must live between the FIRST and LAST quote of the
      // attribute: the parser's non-greedy regex must not stop early.
      final attrStart = rendered.indexOf('result="');
      final rest = rendered.substring(attrStart + 8);
      // The value's final quote is the last " before the tag close.
      final tagEnd = rendered.indexOf('>', attrStart);
      final attrText = rendered.substring(attrStart + 8, tagEnd - 1);
      // No raw quote may appear inside the value; all become &quot;.
      check(attrText.contains('"')).isFalse();
      check(attrText.contains('&quot;')).isTrue();
      check(attrText.contains('stay focused')).isTrue();
    });

    test('already-JSON string values are not double-encoded', () {
      final rendered = renderSemanticMessageBlocks([
        SemanticDetailsBlock.toolCall(
          id: 'x',
          name: 'search_web',
          done: true,
          arguments: '{"count": 8, "query": "test"}',
        ),
      ]);
      // The stored JSON string is the serialized form; a second jsonEncode
      // would produce \" sequences. The attribute must hold single-escaped
      // entities instead.
      final tagEnd = rendered.indexOf('>', rendered.indexOf('arguments='));
      final attrText = rendered.substring(
          rendered.indexOf('arguments=') + 10, tagEnd - 1);
      check(attrText.contains('\\"')).isFalse();
      check(attrText.contains('&quot;count&quot;')).isTrue();
    });
  });

  group('#677 truncated tail', () {
    test('unterminated semantic tag at EOF is stripped', () {
      final raw = 'Answer text.\n\n<details type="tool_calls" done="true" '
          'result="partial';
      final out = ConduitMarkdownPreprocessor.normalize(raw);
      // ignore: avoid_print
      print('DEBUG-LEN: ' + out.length.toString());
      // ignore: avoid_print
      print('DEBUG-CODEUNITS: ' +
          out.codeUnits.map((c) => c.toString()).join(','));
      check(out).equals('Answer text.');
    });

    test('complete semantic block is NOT stripped', () {
      final raw = 'Answer text.\n\n$toolTag';
      check(ConduitMarkdownPreprocessor.normalize(raw))
          .contains('<summary>Tool Executed</summary>');
    });

    test('unterminated ordinary details (no type) is NOT stripped', () {
      final raw = 'Example:\n\n<details>\n<summary>literal sample';
      check(ConduitMarkdownPreprocessor.normalize(raw)).contains('<details>');
    });
  });

  group('#677 fence hoist', () {
    test('semantic block after an unclosed fence is hoisted out', () {
      final raw = 'Answer with code:\n\n```python\nprint(1)\n\n$toolTag';
      final out = ConduitMarkdownPreprocessor.normalize(raw);
      final tagIndex = out.indexOf('<details type="tool_calls"');
      check(tagIndex).isGreaterThan(0);
      final before = out.substring(0, tagIndex);
      // The fence is closed before the hoisted block.
      check(RegExp(r'^```$', multiLine: true).allMatches(before).length)
          .isGreaterThan(0);
    });

    test('deliberate closed fence around details stays verbatim', () {
      final raw = '```\n$toolTag\n```';
      check(ConduitMarkdownPreprocessor.normalize(raw)).equals(raw);
    });

    test('closed fence before details (control) keeps details parseable', () {
      final raw = '```python\nprint(1)\n```\n\n$toolTag';
      check(ConduitMarkdownPreprocessor.normalize(raw)).equals(raw);
    });
  });
}
