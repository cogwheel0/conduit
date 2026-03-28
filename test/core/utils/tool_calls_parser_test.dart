import 'package:checks/checks.dart';
import 'package:qonduit/core/utils/tool_calls_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('segments', () {
    test('returns null for empty string', () {
      check(ToolCallsParser.segments('')).isNull();
    });

    test('returns null for no <details', () {
      check(ToolCallsParser.segments('Hello world')).isNull();
    });

    test('parses complete tool call block', () {
      const content =
          'Before '
          '<details type="tool_calls" name="search" '
          'id="abc123" done="true">'
          '<summary>Search</summary>result'
          '</details>'
          ' After';
      final segs = ToolCallsParser.segments(content);
      check(segs).isNotNull();
      final s = segs!;

      // Text before
      check(s[0].isToolCall).isFalse();
      check(s[0].text!).equals('Before ');

      // Tool call entry
      check(s[1].isToolCall).isTrue();
      final entry = s[1].entry!;
      check(entry.name).equals('search');
      check(entry.id).equals('abc123');
      check(entry.done).isTrue();

      // Text after
      check(s[2].isToolCall).isFalse();
      check(s[2].text!).equals(' After');
    });

    test('handles streaming/incomplete block', () {
      const content =
          '<details type="tool_calls" name="fetch" id="x1">'
          '<summary>Fetching';
      final segs = ToolCallsParser.segments(content);
      check(segs).isNotNull();
      // Incomplete tag means it's appended as text since
      // opening tag never closed with >
      // Actually the opening tag IS closed. Let's check.
      final s = segs!;
      check(s.length).equals(1);
      check(s[0].isToolCall).isTrue();
      check(s[0].entry!.name).equals('fetch');
      check(s[0].entry!.done).isFalse();
    });

    test('decodes HTML entities in attributes', () {
      const content =
          '<details type="tool_calls" name="run" id="t1" '
          'arguments="&quot;hello&quot;" done="true">'
          '</details>';
      final segs = ToolCallsParser.segments(content);
      check(segs).isNotNull();
      final entry = segs!.first.entry!;
      // &quot;hello&quot; -> "hello" -> decoded JSON string
      check(entry.arguments).equals('hello');
    });

    test('treats non-tool_calls details as text', () {
      const content =
          '<details type="reasoning">'
          '<summary>Thought</summary>inner</details>';
      final segs = ToolCallsParser.segments(content);
      check(segs).isNotNull();
      check(segs!.first.isToolCall).isFalse();
      check(segs.first.text).isNotNull();
    });

    test('generates fallback ID when missing', () {
      const content =
          '<details type="tool_calls" name="myTool" done="true">'
          '</details>';
      final segs = ToolCallsParser.segments(content);
      check(segs).isNotNull();
      final entry = segs!.first.entry!;
      // Fallback ID is name_startIndex
      check(entry.id).startsWith('myTool_');
    });

    test('parses files attribute as list', () {
      const content =
          '<details type="tool_calls" name="upload" id="u1" '
          'done="true" files="[&quot;a.txt&quot;,&quot;b.txt&quot;]">'
          '</details>';
      final segs = ToolCallsParser.segments(content);
      check(segs).isNotNull();
      final entry = segs!.first.entry!;
      check(entry.files).isNotNull();
      check(entry.files!.length).equals(2);
      check(entry.files![0]).equals('a.txt');
    });
  });

  group('parse', () {
    test('returns null for no tool calls', () {
      check(ToolCallsParser.parse('plain text')).isNull();
    });

    test('extracts tool calls and mainContent', () {
      const content =
          'Hello '
          '<details type="tool_calls" name="calc" id="c1" '
          'done="true" result="&quot;42&quot;">'
          '</details>'
          ' world';
      final result = ToolCallsParser.parse(content);
      check(result).isNotNull();
      check(result!.toolCalls.length).equals(1);
      check(result.toolCalls.first.name).equals('calc');
      // Spaces adjacent to block are trimmed per segment
      check(result.mainContent).equals('Helloworld');
      check(result.originalContent).equals(content);
    });
  });

  group('summarize', () {
    test('returns original for no tools', () {
      check(ToolCallsParser.summarize('Hello')).equals('Hello');
    });

    test('summarizes done tools', () {
      const content =
          '<details type="tool_calls" name="search" id="s1" '
          'done="true" result="&quot;found&quot;">'
          '</details>'
          'Remaining text';
      final summary = ToolCallsParser.summarize(content);
      check(summary).contains('Tool Executed: search');
      check(summary).contains('Remaining text');
    });
  });

  group('sanitizeForApi', () {
    test('returns empty string unchanged', () {
      check(ToolCallsParser.sanitizeForApi('')).equals('');
    });

    test('replaces tool block with result', () {
      const content =
          'prefix '
          '<details type="tool_calls" name="calc" id="c1" '
          'done="true" result="&quot;42&quot;">'
          '</details>'
          ' suffix';
      final sanitized = ToolCallsParser.sanitizeForApi(content);
      // Result "42" is a string, json.encode gives "42" which
      // already starts/ends with quotes so no extra wrapping
      check(sanitized).contains('"42"');
      check(sanitized).contains('prefix');
      check(sanitized).contains('suffix');
    });

    test('wraps non-quoted result in quotes', () {
      const content =
          '<details type="tool_calls" name="calc" id="c1" '
          'done="true" result="42">'
          '</details>';
      final sanitized = ToolCallsParser.sanitizeForApi(content);
      // 42 is a number, json.encode gives 42, then wrapped in quotes
      check(sanitized).contains('"42"');
    });
  });
}
