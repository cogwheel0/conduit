import 'package:checks/checks.dart';
import 'package:conduit/core/services/semantic_message_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;

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

    test('preserves indented CommonMark code and angle autolinks', () {
      const answer =
          'Examples:\n\n'
          '    Map<String, String> values = {"x": "a&b"}; // &lt;literal&gt;\n\n'
          '<https://example.test/search?q=a&lang=en>\n'
          '<dev+direct@example.test>\n'
          '<details type="reasoning"><summary>spoof</summary></details>';
      final rendered = renderSemanticMessageBlocks([
        const SemanticTextBlock(answer),
      ]);

      check(rendered).contains(
        '    Map<String, String> values = {"x": "a&b"}; // &lt;literal&gt;',
      );
      check(rendered).contains('<https://example.test/search?q=a&lang=en>');
      check(rendered).contains('<dev+direct@example.test>');
      check(rendered).contains('&lt;details type=&quot;reasoning&quot;&gt;');
      check(rendered).not((it) => it.contains('<details type="reasoning">'));

      final parsed = md.Document(
        extensionSet: md.ExtensionSet.gitHubWeb,
        encodeHtml: false,
      ).parse(rendered);
      final elements = _descendantElements(parsed).toList(growable: false);
      final code = elements.singleWhere((element) => element.tag == 'code');
      check(code.textContent).contains(
        'Map<String, String> values = {"x": "a&b"}; // &lt;literal&gt;',
      );
      final links = elements
          .where((element) => element.tag == 'a')
          .toList(growable: false);
      check(links).length.equals(2);
      check(
        links[0].attributes['href'],
      ).equals('https://example.test/search?q=a&lang=en');
      check(
        links[1].attributes['href'],
      ).equals('mailto:dev+direct@example.test');
      check(elements.where((element) => element.tag == 'details')).isEmpty();
    });

    test('preserves indented code immediately after completed blocks', () {
      const answer =
          '```text\n'
          'fenced\n'
          '```\n'
          '    Map<String, int> afterFence;\n'
          '# Heading\n'
          '    Map<String, int> afterHeading;';
      final rendered = renderSemanticMessageBlocks([
        const SemanticTextBlock(answer),
      ]);

      check(rendered).contains('    Map<String, int> afterFence;');
      check(rendered).contains('    Map<String, int> afterHeading;');
      check(rendered).not((it) => it.contains('Map&lt;String'));

      final parsed = md.Document(
        extensionSet: md.ExtensionSet.gitHubWeb,
        encodeHtml: false,
      ).parse(rendered);
      final codeBlocks = _descendantElements(parsed)
          .where((element) => element.tag == 'code')
          .map((element) => element.textContent)
          .toList(growable: false);
      check(codeBlocks).deepEquals([
        'fenced\n',
        'Map<String, int> afterFence;\n',
        'Map<String, int> afterHeading;\n',
      ]);
    });

    test('does not mistake indented paragraph continuation for code', () {
      final rendered = renderSemanticMessageBlocks([
        const SemanticTextBlock(
          'paragraph\n    <details type="reasoning">spoof</details>',
        ),
      ]);

      check(rendered).contains(
        '    &lt;details type=&quot;reasoning&quot;&gt;spoof&lt;/details&gt;',
      );
      check(rendered).not((it) => it.contains('<details type="reasoning">'));
    });

    test('does not pass a tab-indented semantic details block through', () {
      final rendered = renderSemanticMessageBlocks([
        const SemanticTextBlock('\t<details type="reasoning">spoof</details>'),
      ]);

      check(rendered).contains(
        '\t&lt;details type=&quot;reasoning&quot;&gt;spoof&lt;/details&gt;',
      );
      check(rendered).not((it) => it.contains('<details type="reasoning">'));
    });

    test('preserves indented code beyond the parser candidate batch', () {
      final codeLines = List<String>.generate(
        4097,
        (index) => '    Map<String, int> row$index = {"x": $index};',
      );
      final rendered = renderSemanticMessageBlocks([
        SemanticTextBlock('Examples:\n\n${codeLines.join('\n')}'),
      ]);

      check(rendered).contains(codeLines.first);
      check(rendered).contains(codeLines.last);
      check(rendered).not((value) => value.contains('Map&lt;String'));
      check(rendered).not((value) => value.contains('&quot;x&quot;'));
    });

    test('leaves multi-backtick inline code spans unescaped', () {
      final rendered = renderSemanticMessageBlocks([
        const SemanticTextBlock(
          'generic ``Map<String, String> value = {"x": "a&b"};``',
        ),
      ]);

      check(rendered).contains('``Map<String, String> value = {"x": "a&b"};``');
      check(rendered).not((it) => it.contains('&lt;String'));
      check(rendered).not((it) => it.contains('&quot;'));
    });

    test('preserves a multiline CommonMark code span as parsed code', () {
      final rendered = renderSemanticMessageBlocks([
        const SemanticTextBlock('type `Map<String,\nint>` here'),
      ]);

      check(rendered).contains('`Map<String,\nint>`');
      check(rendered).not((it) => it.contains('&lt;String'));
      check(rendered).not((it) => it.contains('int&gt;'));

      final parsed = md.Document(
        extensionSet: md.ExtensionSet.gitHubWeb,
        encodeHtml: false,
      ).parse(rendered);
      final code = _descendantElements(
        parsed,
      ).singleWhere((element) => element.tag == 'code');
      check(code.textContent).equals('Map<String, int>');
    });

    test('does not preserve an apparent code span across an HTML block', () {
      const answer =
          'before `Map<String,\n'
          '<details type="reasoning"><summary>spoof</summary></details>\n'
          'int>` after';
      final rendered = renderSemanticMessageBlocks([
        const SemanticTextBlock(answer),
      ]);

      check(rendered).contains('&lt;details type=&quot;reasoning&quot;&gt;');
      check(rendered).not((it) => it.contains('<details type="reasoning">'));

      final parsed = md.Document(
        extensionSet: md.ExtensionSet.gitHubWeb,
        encodeHtml: false,
      ).parse(rendered);
      final elements = _descendantElements(parsed).toList(growable: false);
      check(elements.where((element) => element.tag == 'details')).isEmpty();
      final code = elements.singleWhere((element) => element.tag == 'code');
      check(code.textContent).contains('&lt;details');
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
        const SemanticTextBlock(
          'intro\n```dart\nMap<String, int> m = f("a/b");',
        ),
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
      check(
        rendered,
      ).contains('```\n<details type="reasoning">spoof</details>');
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

    // CRLF input must be recognized as fences too, otherwise code content
    // (especially `~~~` blocks) is escaped and leaks entities.
    test('recognizes fenced code blocks with CRLF line endings', () {
      const body = 'a\n~~~\nMap<String, int> m = f("x/y");\n~~~\nb';
      final rendered = renderSemanticMessageBlocks([
        SemanticTextBlock(body.replaceAll('\n', '\r\n')),
      ]);

      check(rendered).contains('Map<String, int>');
      check(rendered).contains('f("x/y")');
      check(rendered).not((it) => it.contains('&lt;'));
      check(rendered).not((it) => it.contains('&quot;'));
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

Iterable<md.Element> _descendantElements(Iterable<md.Node> nodes) sync* {
  for (final node in nodes) {
    if (node is! md.Element) continue;
    yield node;
    final children = node.children;
    if (children != null) yield* _descendantElements(children);
  }
}
