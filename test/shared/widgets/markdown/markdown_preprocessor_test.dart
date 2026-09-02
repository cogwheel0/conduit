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

    test('separates attached tool-call details outside code', () {
      const details = '<details type="tool_calls" done="true"></details>';
      final result = ConduitMarkdownPreprocessor.normalize(
        'Answer$details\n\n`Example$details`',
      );

      check(result).contains('Answer\n\n$details');
      check(result).contains('`Example$details`');
    });

    test('joins details open tag spanning lines from newlines in attribute values', () {
      const raw =
          '<details type="tool_calls" done="true" id="x" name="fetch_url" '
          'arguments="&quot;{\\&quot;url\\&quot;: \\&quot;https://example.com\\&quot;}&quot;" '
          'result="[{&quot;type&quot;:&quot;input_text&quot;,&quot;text&quot;:&quot;line one\nline two\nline three&quot;}]">\n'
          '<summary>Tool Executed</summary>\n'
          '</details>\nTrailing answer.';
      final result = ConduitMarkdownPreprocessor.normalize(raw);

      // The opening tag must now start a line as a complete tag.
      final firstLine = result.split('\n').first;
      check(firstLine).startsWith('<details');
      check(firstLine).endsWith('>');
      // Newlines inside the attribute value are folded to spaces.
      check(firstLine.contains('line one')).isTrue();
      check(firstLine.contains('line three&quot;}]">')).isTrue();
    });

    test('escapes raw angle brackets inside details attribute values', () {
      const raw =
          '<details type="tool_calls" done="true" id="x" name="fetch_url" '
          'result="[{&quot;text&quot;:&quot;2026-07-14<br> (123)&quot;}]">'
          '</details>';
      final result = ConduitMarkdownPreprocessor.normalize(raw);

      // The raw < > inside the quoted value must not truncate tag parsing.
      check(result).contains('&lt;br&gt;');
      // The tag must remain a single line and keep its raw-<br> escaped,
      // i.e. no bare < or > left inside the attribute value.
      final firstLine = result.split('\n').first;
      check(firstLine.contains('<br>')).isFalse();
      check(firstLine.startsWith('<details')).isTrue();
    });

    test('well-formed single-line tag is unchanged', () {
      const raw =
          'text before\n'
          '<details type="tool_calls" done="true" id="x" name="t" '
          'result="[{&quot;a&quot;:&quot;ok&quot;}]">\n'
          '<summary>Tool Executed</summary>\n'
          '</details>\nafter';
      final result = ConduitMarkdownPreprocessor.normalize(raw);
      check(result).contains(
        '<details type="tool_calls" done="true" id="x" name="t" '
        'result="[{&quot;a&quot;:&quot;ok&quot;}]">',
      );
    });

    test('joins spanning tag with raw <br> inside a quoted value', () {
      // Combined case: the tag spans lines AND the value contains a raw <br>.
      // The join must use the quote-balanced > (the real tag end), not the >
      // inside <br>; the escaper must then neutralize it.
      const raw =
          '<details type="tool_calls" done="true" id="x" name="fetch_url" '
          'result="[{&quot;text&quot;:&quot;line one\nline two <br> (123)\nline three&quot;}]">\n'
          '<summary>Tool Executed</summary>\n'
          '</details>\nTrailing answer.';
      final result = ConduitMarkdownPreprocessor.normalize(raw);

      final firstLine = result.split('\n').first;
      // The full tag (through the real >) must be joined onto one line.
      check(firstLine.contains('line three&quot;}]">')).isTrue();
      check(firstLine.contains('&lt;br&gt;')).isTrue();
      // No raw <br> remains inside the attribute value.
      check(firstLine.contains('<br>')).isFalse();
    });

    test('escapes every raw angle bracket in quoted values, not just the first',
        () {
      // Greptile P1: _detailsOpenTagSingleLine matches stop at the first raw
      // >, so only the first <br> was previously escaped; the second stayed
      // raw and the parser truncated the attribute list after it.
      const raw =
          '<details type="tool_calls" result="a<br>b<br>c" other="x">\n'
          '<summary>Tool Executed</summary>\n'
          '</details>';
      final result = ConduitMarkdownPreprocessor.normalize(raw);

      final firstLine = result.split('\n').first;
      // The full original tag, with every raw < > escaped.
      check(firstLine.contains('other="x">')).isTrue();
      check('&lt;br&gt;'.allMatches(firstLine).length).equals(2);
      check(firstLine.contains('<br>')).isFalse();
    });

    test('mixed-case spanning tag is joined too', () {
      const raw =
          '<DETAILS type="tool_calls" done="true" id="x" name="fetch_url" '
          'result="[{&quot;text&quot;:&quot;line one\nline two\nline three&quot;}]">\n'
          '<summary>Tool Executed</summary>\n'
          '</DETAILS>\nTrailing answer.';
      final result = ConduitMarkdownPreprocessor.normalize(raw);

      final firstLine = result.split('\n').first;
      check(firstLine.startsWith('<DETAILS')).isTrue();
      check(firstLine.endsWith('>')).isTrue();
      check(firstLine.contains('line three&quot;}]">')).isTrue();
    });

    test('escapes raw angle brackets in single-quoted attribute values', () {
      // CodeRabbit + Greptile P1: the quote-aware scan only tracked `"`, so a
      // single-quoted value's raw `<br>` acted as a false tag terminator.
      const raw =
          "<details type='tool_calls' result='before <br> after'>\n"
          '<summary>Tool Executed</summary>\n'
          '</details>';
      final result = ConduitMarkdownPreprocessor.normalize(raw);

      final firstLine = result.split('\n').first;
      check(firstLine.contains("result='before &lt;br&gt; after'")).isTrue();
      check(firstLine.contains('<br>')).isFalse();
    });

    test('joins single-quoted spanning tag too', () {
      const raw =
          "<details type='tool_calls' result='line one\nline two'>\n"
          '<summary>Tool Executed</summary>\n'
          '</details>\nTrailing answer.';
      final result = ConduitMarkdownPreprocessor.normalize(raw);

      final firstLine = result.split('\n').first;
      check(firstLine.startsWith('<details')).isTrue();
      check(firstLine.endsWith('>')).isTrue();
      check(firstLine.contains("line two'>")).isTrue();
    });

    test('double quotes inside a single-quoted value do not end the tag', () {
      const raw =
          '<details type="tool_calls" data-x=\'{"a":"x>y"}\' result="ok">\n'
          '<summary>Tool Executed</summary>\n'
          '</details>';
      final result = ConduitMarkdownPreprocessor.normalize(raw);

      final firstLine = result.split('\n').first;
      check(firstLine.contains('result="ok">')).isTrue();
    });

    test('prose apostrophe before a tag does not corrupt quote state', () {
      // A quote only opens a value immediately after `=`; "It's" in prose
      // must not flip the scanner into quote mode.
      const raw =
          "It's a nice day\n"
          '<details type="tool_calls" result="a>b" other="y">\n'
          '<summary>Tool Executed</summary>\n'
          '</details>';
      final result = ConduitMarkdownPreprocessor.normalize(raw);

      final tagLine =
          result.split('\n').firstWhere((l) => l.startsWith('<details'));
      check(tagLine.contains('other="y">')).isTrue();
    });

    test('tilde-fenced code block content is left untouched', () {
      // CodeRabbit: _codeSpanOrFence did not mask ~~~ fences, so literal
      // <details> examples inside them were escaped before parsing.
      const raw = '~~~\n<details result="a<br>b">\n~~~';
      final result = ConduitMarkdownPreprocessor.normalize(raw);

      check(result.contains('a<br>b')).isTrue();
      check(result.contains('a&lt;br&gt;b')).isFalse();
    });

    test('tilde fence with info string and indentation is masked', () {
      const raw = '  ~~~html\n<details result="a<br>b">\n  ~~~\nafter';
      final result = ConduitMarkdownPreprocessor.normalize(raw);

      check(result.contains('a<br>b')).isTrue();
      check(result.contains('a&lt;br&gt;b')).isFalse();
    });

    test('real details tag after a tilde fence is still normalized', () {
      const raw =
          '~~~\nliteral <details result="a<br>b">\n~~~\n\n'
          '<details type="tool_calls" result="x<br>y">\n'
          '<summary>Tool Executed</summary>\n'
          '</details>';
      final result = ConduitMarkdownPreprocessor.normalize(raw);

      check(result.contains('literal <details result="a<br>b">')).isTrue();
      final tagLine =
          result.split('\n').firstWhere((l) => l.startsWith('<details'));
      check(tagLine.contains('&lt;br&gt;')).isTrue();
      check(tagLine.contains('<br>')).isFalse();
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

    test('preserves literal reasoning blocks inside code spans and fences', () {
      const input = '''before <think>remove me</think>

``<think>`inline example`</think>``

````
<details type="reasoning">fenced example</details>
````

after''';

      final result = ConduitMarkdownPreprocessor.sanitize(input);
      check(result).not((value) => value.contains('remove me'));
      check(result).contains('``<think>`inline example`</think>``');
      check(result).contains(
        '````\n<details type="reasoning">fenced example</details>\n````',
      );
    });

    test('collapses 3+ newlines to double newline', () {
      final result = ConduitMarkdownPreprocessor.sanitize('a\n\n\n\nb');
      check(result).equals('a\n\nb');
    });
  });

  group('ConduitMarkdownPreprocessor.stripLinkReferenceDefinitions', () {
    test('preserves definitions inside variable-length code delimiters', () {
      const input = '''[remove]: https://example.com/remove

``[inline]: `literal` ``

````
[fenced]: https://example.com/keep
````''';

      final result = ConduitMarkdownPreprocessor.stripLinkReferenceDefinitions(
        input,
      );
      check(result).not((value) => value.contains('[remove]'));
      check(result).contains('``[inline]: `literal` ``');
      check(result).contains('````\n[fenced]: https://example.com/keep\n````');
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

  group('ConduitMarkdownPreprocessor.cleanText', () {
    test('whitespace-only returns empty', () {
      check(ConduitMarkdownPreprocessor.cleanText('   ')).equals('');
    });

    test('preserves details until caller strips them like OpenWebUI', () {
      final result = ConduitMarkdownPreprocessor.cleanText(
        'Before <details><summary>Hidden</summary>tool output</details> after',
      );
      check(result).contains('Before');
      check(result).contains('after');
      check(result)
          .contains('<details><summary>Hidden</summary>tool output</details>');
    });

    test('preserves generic html content to mirror OpenWebUI', () {
      final result = ConduitMarkdownPreprocessor.cleanText(
        'Hello <b>world</b>',
      );
      check(result).contains('<b>world</b>');
    });

    test('strips markdown formatting and emojis', () {
      final result = ConduitMarkdownPreprocessor.cleanText(
        '## **Hello** 😄\n- item\n`code`',
      );
      check(result).contains('Hello');
      check(result).contains('item');
      check(result).contains('code');
      check(result).not((s) => s.contains('##'));
      check(result).not((s) => s.contains('**'));
      check(result).not((s) => s.contains('😄'));
    });

    test('preserves newline boundaries for downstream splitting', () {
      final result = ConduitMarkdownPreprocessor.cleanText(
        'First paragraph\n\nSecond paragraph',
      );
      check(result).equals('First paragraph\nSecond paragraph');
      check(result).contains('\n');
    });
  });

  group('ConduitMarkdownPreprocessor.removeAllDetails', () {
    test('removes details outside code spans', () {
      final result = ConduitMarkdownPreprocessor.removeAllDetails(
        'keep ```<details>code</details>``` hide <details>x</details>',
      );
      check(result).contains('```<details>code</details>```');
      check(result).not((s) => s.contains(' hide <details>x</details>'));
    });

    test('removes details containing code without splitting the block', () {
      const input = '''before
<details><summary>Hidden</summary>
``inline `secret` ``
````
fenced secret
````
</details>
after''';

      final result = ConduitMarkdownPreprocessor.removeAllDetails(input);
      check(result).not((value) => value.contains('Hidden'));
      check(result).not((value) => value.contains('secret'));
      check(result).contains('before');
      check(result).contains('after');
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
