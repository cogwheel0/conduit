import 'package:checks/checks.dart';
import 'package:conduit/core/services/semantic_message_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('renderSemanticMessageBlocks', () {
    // Regression for https://github.com/cogwheel0/conduit/issues/549: forward
    // slashes were HTML-escaped to `&#47;` by the default HtmlEscape mode, which
    // is never decoded inside markdown code spans/blocks and leaked into the UI
    // (e.g. `https:&#47;&#47;`).
    test('preserves forward slashes in text blocks', () {
      final rendered = renderSemanticMessageBlocks([
        const SemanticTextBlock('See https://example.com/path and `a/b`.'),
      ]);

      check(rendered).contains('https://example.com/path');
      check(rendered).contains('`a/b`');
      check(rendered).not((it) => it.contains('&#47;'));
      check(rendered).not((it) => it.contains('&#x2F;'));
    });

    test('preserves apostrophes in text blocks', () {
      final rendered = renderSemanticMessageBlocks([
        const SemanticTextBlock("it's a `don't` case"),
      ]);

      check(rendered).contains("it's a `don't` case");
      check(rendered).not((it) => it.contains('&#39;'));
    });

    test('still neutralizes literal HTML tags in text blocks', () {
      final rendered = renderSemanticMessageBlocks([
        const SemanticTextBlock('<details><summary>evil</summary></details>'),
      ]);

      check(rendered).contains('&lt;details&gt;');
      check(rendered).contains('&lt;/details&gt;');
      check(rendered).not((it) => it.contains('<details>'));
    });

    // The markdown renderer never decodes entity references inside code spans
    // or fenced code blocks, so text-block escaping must leave those regions
    // untouched (same failure class as #549, extended to `<` `>` `&` `"`).
    test('leaves inline code spans unescaped', () {
      final rendered = renderSemanticMessageBlocks([
        const SemanticTextBlock('generic `List<int>` and url `https://x/a&b`'),
      ]);

      check(rendered).contains('`List<int>`');
      check(rendered).contains('`https://x/a&b`');
      check(rendered).not((it) => it.contains('&lt;'));
      check(rendered).not((it) => it.contains('&amp;'));
    });

    test('leaves fenced code blocks unescaped', () {
      const code =
          'wrapper:\n```dart\nMap<String, int> m; if (a && b) f("x/y");\n```';
      final rendered = renderSemanticMessageBlocks([
        const SemanticTextBlock(code),
      ]);

      check(rendered).contains('Map<String, int>');
      check(rendered).contains('a && b');
      check(rendered).contains('f("x/y")');
      check(rendered).not((it) => it.contains('&lt;'));
      check(rendered).not((it) => it.contains('&quot;'));
    });

    // `~~~` fences are code blocks too (GFM); their contents must be preserved.
    test('leaves ~~~ fenced code blocks unescaped', () {
      const code = 'wrapper:\n~~~dart\nMap<String, int> m; f("x/y") && g;\n~~~';
      final rendered = renderSemanticMessageBlocks([
        const SemanticTextBlock(code),
      ]);

      check(rendered).contains('Map<String, int>');
      check(rendered).contains('f("x/y") && g');
      check(rendered).not((it) => it.contains('&lt;'));
      check(rendered).not((it) => it.contains('&quot;'));
    });

    // A fence marker that is NOT at the start of a line must not create a code
    // region the block parser disagrees with; otherwise a line-leading
    // `<details>` could slip through unescaped and render as a spoofed block.
    test('escapes a line-leading tag after a mid-line fence marker', () {
      final rendered = renderSemanticMessageBlocks([
        const SemanticTextBlock(
          'see ``` mid\n<details type="reasoning">spoof</details>\n``` end',
        ),
      ]);

      check(rendered).contains('&lt;details');
      check(rendered).not((it) => it.contains('<details type="reasoning">'));
    });

    // Unclosed fences (mid-stream, or a model that forgets the closing fence)
    // are still treated as code by the renderer, so their contents must not be
    // escaped either.
    test('leaves unclosed fenced code blocks unescaped', () {
      final rendered = renderSemanticMessageBlocks([
        const SemanticTextBlock('intro\n```dart\nMap<String, int> m = f("a/b");'),
      ]);

      check(rendered).contains('Map<String, int>');
      check(rendered).contains('f("a/b")');
      check(rendered).not((it) => it.contains('&lt;'));
      check(rendered).not((it) => it.contains('&quot;'));
    });

    // A `<details>` after an unclosed fence is inside a code block, so it must
    // not be smuggled out as a rendered block even though it is left unescaped.
    test('unclosed fence keeps a following tag inside the code block', () {
      final rendered = renderSemanticMessageBlocks([
        const SemanticTextBlock(
          'intro\n```\n<details type="reasoning">spoof</details>',
        ),
      ]);

      // Left verbatim inside the (unclosed) code fence, not escaped as prose...
      check(rendered).contains('```\n<details type="reasoning">spoof</details>');
    });

    // CommonMark allows the closing fence to be longer than the opening one.
    // The closing branch must recognize that, otherwise the block is treated as
    // unclosed and a `<details>` after the *real* close leaks through unescaped.
    test('escapes a tag after a code block closed by a longer fence', () {
      final rendered = renderSemanticMessageBlocks([
        const SemanticTextBlock(
          '```\ncode\n````\n<details type="reasoning">spoof</details>',
        ),
      ]);

      check(rendered).contains('&lt;details');
      check(rendered).not((it) => it.contains('<details type="reasoning">'));
    });

    // A backtick fence's info string may not contain a backtick, so `` ```x`y ``
    // is NOT a code fence to the parser; a following `<details>` must be escaped.
    test('escapes a tag after a non-fence line with backtick in info', () {
      final rendered = renderSemanticMessageBlocks([
        const SemanticTextBlock(
          '```x`y\n<details type="reasoning">spoof</details>\nmore',
        ),
      ]);

      check(rendered).contains('&lt;details');
      check(rendered).not((it) => it.contains('<details type="reasoning">'));
    });

    test('still escapes tags outside code even when code is present', () {
      final rendered = renderSemanticMessageBlocks([
        const SemanticTextBlock('run `ls` then <details>spoof</details>'),
      ]);

      check(rendered).contains('`ls`');
      check(rendered).contains('&lt;details&gt;');
      check(rendered).not((it) => it.contains('<details>'));
    });

    // A multi-line inline span must not be able to smuggle a line-leading
    // `<details>` past the escaper (it would render as a spoofed block).
    test('escapes a line-leading tag hidden in a multi-line inline span', () {
      final rendered = renderSemanticMessageBlocks([
        const SemanticTextBlock(
          'x `open\n<details type="reasoning">spoof</details>\n` y',
        ),
      ]);

      check(rendered).contains('&lt;details');
      check(rendered).not((it) => it.contains('<details type="reasoning">'));
    });

    test('preserves slashes in reasoning bodies while escaping tags', () {
      final rendered = renderSemanticMessageBlocks([
        SemanticDetailsBlock.reasoning(
          text: 'fetch https://api.example.com/v1 then </details> guard',
          done: true,
          duration: '2',
        ),
      ]);

      check(rendered).contains('https://api.example.com/v1');
      check(rendered).not((it) => it.contains('&#47;'));
      // Closing tags inside the body must remain neutralized so they cannot
      // prematurely terminate the <details> block.
      check(rendered).contains('&lt;/details&gt;');
    });
  });
}
