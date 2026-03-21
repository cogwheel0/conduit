import 'package:checks/checks.dart';
import 'package:conduit/shared/widgets/markdown/markdown_preprocessor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConduitMarkdownPreprocessor.normalize', () {
    test('empty string returns empty', () {
      check(ConduitMarkdownPreprocessor.normalize('')).equals('');
    });

    test('CRLF is converted to LF', () {
      final result = ConduitMarkdownPreprocessor.normalize('hello\r\nworld');
      check(result).not((s) => s.contains('\r'));
      check(result).contains('hello\nworld');
    });

    test('auto-closes unmatched fence (odd count)', () {
      final result = ConduitMarkdownPreprocessor.normalize('```python\ncode');
      check(result).endsWith('```');
      // Should have exactly 2 fences now (even)
      final fenceCount = RegExp(r'```').allMatches(result).length;
      check(fenceCount.isEven).isTrue();
    });

    test('dedents indented opening fence', () {
      final result = ConduitMarkdownPreprocessor.normalize(
        '    ```python\ncode\n```',
      );
      check(result).contains('```python');
      check(result).not((s) => s.contains('    ```python'));
    });

    test('dedents indented closing fence', () {
      final result = ConduitMarkdownPreprocessor.normalize(
        '```python\ncode\n    ```',
      );
      // The closing fence should not be indented.
      check(result).not((s) => s.contains('    ```'));
    });

    test('moves fence after list marker to new line', () {
      final result = ConduitMarkdownPreprocessor.normalize(
        '- ```python\ncode\n```',
      );
      // The fence should be on its own line after the list marker.
      check(result).contains('- \n```python');
    });

    test('ensures closing fence on own line', () {
      final result = ConduitMarkdownPreprocessor.normalize(
        '```\nsome code```\n',
      );
      // "code```" at EOL should become "code\n```"
      check(result).contains('some code\n```');
    });

    test('fixes numeric heading by inserting ZWNJ after dot', () {
      final result = ConduitMarkdownPreprocessor.normalize('### 1. First');
      // Should insert \u200C between the dot and space.
      check(result).contains('1.\u200C');
    });

    test('fixes Setext heading false positive', () {
      final result = ConduitMarkdownPreprocessor.normalize('**Bold**\n---');
      // Should add a blank line between the bold text and the dashes.
      check(result).contains('**Bold**\n\n');
    });
  });

  group('ConduitMarkdownPreprocessor.sanitize', () {
    test('empty string returns empty', () {
      check(ConduitMarkdownPreprocessor.sanitize('')).equals('');
    });

    test('removes <think>...</think> blocks', () {
      final result = ConduitMarkdownPreprocessor.sanitize(
        'before<think>internal reasoning</think>after',
      );
      check(result).not((s) => s.contains('think'));
      check(result).not((s) => s.contains('internal'));
      check(result).contains('before');
      check(result).contains('after');
    });

    test('removes <details type="reasoning">...</details> blocks', () {
      final result = ConduitMarkdownPreprocessor.sanitize(
        'before<details type="reasoning">hidden</details>after',
      );
      check(result).not((s) => s.contains('hidden'));
      check(result).contains('before');
      check(result).contains('after');
    });

    test('collapses 3+ newlines to double newline', () {
      final result = ConduitMarkdownPreprocessor.sanitize('a\n\n\n\nb');
      check(result).equals('a\n\nb');
    });
  });

  group('ConduitMarkdownPreprocessor.toPlainText', () {
    test('whitespace-only returns empty', () {
      check(ConduitMarkdownPreprocessor.toPlainText('   ')).equals('');
    });

    test('removes code blocks, keeps inline code text', () {
      final result = ConduitMarkdownPreprocessor.toPlainText(
        '```dart\nvoid main() {}\n```\nUse `print` here',
      );
      check(result).not((s) => s.contains('void main'));
      check(result).contains('print');
    });

    test('removes images ![alt](url)', () {
      final result = ConduitMarkdownPreprocessor.toPlainText(
        'See ![photo](http://img.png) here',
      );
      check(result).not((s) => s.contains('photo'));
      check(result).not((s) => s.contains('http'));
    });

    test('keeps link text [text](url)', () {
      final result = ConduitMarkdownPreprocessor.toPlainText(
        'Click [here](http://example.com) now',
      );
      check(result).contains('here');
      check(result).not((s) => s.contains('http'));
    });

    test('strips **bold** markers', () {
      final result = ConduitMarkdownPreprocessor.toPlainText(
        'This is **bold** text',
      );
      check(result).contains('bold');
      check(result).not((s) => s.contains('**'));
    });

    test('strips ***bold italic*** markers', () {
      final result = ConduitMarkdownPreprocessor.toPlainText(
        'This is ***important*** text',
      );
      check(result).contains('important');
      check(result).not((s) => s.contains('***'));
    });

    test('strips ~~strikethrough~~ markers', () {
      final result = ConduitMarkdownPreprocessor.toPlainText(
        'This is ~~deleted~~ text',
      );
      check(result).contains('deleted');
      check(result).not((s) => s.contains('~~'));
    });

    test('strips # heading markers', () {
      final result = ConduitMarkdownPreprocessor.toPlainText(
        '## My Heading\nParagraph',
      );
      check(result).contains('My Heading');
      check(result).not((s) => s.contains('##'));
    });

    test('strips list markers (-, *, 1.)', () {
      final result = ConduitMarkdownPreprocessor.toPlainText(
        '- item one\n* item two\n1. item three',
      );
      check(result).contains('item one');
      check(result).contains('item two');
      check(result).contains('item three');
    });

    test('strips > blockquote markers', () {
      final result = ConduitMarkdownPreprocessor.toPlainText('> quoted text');
      check(result).contains('quoted text');
      check(result).not((s) => s.startsWith('>'));
    });

    test('removes HTML tags', () {
      final result = ConduitMarkdownPreprocessor.toPlainText(
        'Hello <b>world</b>',
      );
      check(result).contains('world');
      check(result).not((s) => s.contains('<b>'));
    });

    test('removes tool call details from spoken text', () {
      final result = ConduitMarkdownPreprocessor.toPlainText(
        'Before <details type="tool_calls" done="true" '
        'name="search"><summary>Tool Executed</summary></details> after',
      );
      check(result).contains('Before');
      check(result).contains('after');
      check(result).not((s) => s.contains('Tool Executed'));
    });

    test('removes extended reasoning blocks from spoken text', () {
      final result = ConduitMarkdownPreprocessor.toPlainText(
        'Start <reason>internal chain of thought</reason> '
        '<details><summary>Thinking</summary>private notes</details> end',
      );
      check(result).contains('Start');
      check(result).contains('end');
      check(result).not((s) => s.contains('chain of thought'));
      check(result).not((s) => s.contains('Thinking'));
      check(result).not((s) => s.contains('private notes'));
    });

    test('preserves generic details content in sanitize', () {
      final result = ConduitMarkdownPreprocessor.sanitize(
        'before <details><summary>Thinking about dinner</summary>menu</details> after',
      );
      check(result).contains('Thinking about dinner');
      check(result).contains('menu');
    });

    test('normalizes whitespace', () {
      final result = ConduitMarkdownPreprocessor.toPlainText(
        'hello   world\n\nnew  paragraph',
      );
      check(result).not((s) => s.contains('  '));
    });
  });

  group('ConduitMarkdownPreprocessor.softenInlineCode', () {
    test('short input returned unchanged', () {
      final result = ConduitMarkdownPreprocessor.softenInlineCode('short');
      check(result).equals('short');
    });

    test('inserts ZWSP every chunkSize chars for long input', () {
      // Default chunkSize is 24.
      final input = 'a' * 48;
      final result = ConduitMarkdownPreprocessor.softenInlineCode(input);
      // Should have ZWSP at positions 24 and 48.
      check(result).contains('\u200B');
      check(result.length).equals(48 + 2);
    });

    test('custom chunkSize works', () {
      final input = 'abcdefghij'; // length 10
      final result = ConduitMarkdownPreprocessor.softenInlineCode(
        input,
        chunkSize: 5,
      );
      // ZWSP inserted after position 5 and position 10.
      check(result).equals('abcde\u200Bfghij\u200B');
    });
  });
}
