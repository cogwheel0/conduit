@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/widgets/markdown_view.dart';
import 'package:jaspr_test/jaspr_test.dart';
import 'package:markdown/markdown.dart' as md;

/// The renderer turns a model's markdown into DOM.
///
/// The security tests are the point of the file. This text arrives from a
/// model, and the renderer is the origin holding the preload bridge -- so
/// "renders bold correctly" is table stakes and "does not execute a script
/// tag" is the requirement.
void main() {
  group('formatting', () {
    testComponents('renders emphasis and strong', (tester) async {
      tester.pumpComponent(const MarkdownView('*italic* and **bold**'));
      expect(find.tag('em'), findsOneComponent);
      expect(find.tag('strong'), findsOneComponent);
    });

    testComponents('renders fenced code as a code block', (tester) async {
      tester.pumpComponent(const MarkdownView('```dart\nvoid main() {}\n```'));
      expect(find.tag('pre'), findsOneComponent);
      // The source is split across highlighted spans now, so the assertion
      // is on the tokens rather than on one text node.
      expect(find.text('void'), findsOneComponent);
      expect(find.text('dart'), findsOneComponent);
    });

    testComponents('an unfenced language renders as plain text', (
      tester,
    ) async {
      tester.pumpComponent(const MarkdownView('```\nsome output\n```'));
      expect(find.tag('pre'), findsOneComponent);
      expect(find.text('some output\n'), findsOneComponent);
    });

    testComponents('renders lists and headings', (tester) async {
      tester.pumpComponent(const MarkdownView('# Title\n\n- one\n- two'));
      expect(find.tag('h1'), findsOneComponent);
      expect(find.tag('ul'), findsOneComponent);
      expect(find.tag('li'), findsNComponents(2));
    });

    testComponents('renders GitHub tables', (tester) async {
      tester.pumpComponent(
        const MarkdownView('| a | b |\n| --- | --- |\n| 1 | 2 |'),
      );
      expect(find.tag('table'), findsOneComponent);
      expect(find.tag('td'), findsNComponents(2));
    });
  });

  group('streaming', () {
    // A streamed answer keeps the blocks that can no longer change and
    // re-parses only the tail; that is only a speed-up if it draws what
    // parsing the whole answer draws, at every length it passes through.
    const answer =
        '# Plan\n\n'
        'A paragraph that runs\nacross two lines.\n\n'
        '- tight one\n- tight two\n\n'
        '1. loose one\n\n2. loose two\n   continued\n\n'
        '```dart\nvoid main() {\n\n  print(1);\n}\n```\n\n'
        '| a | b |\n| --- | --- |\n| 1 | 2 |\n\n'
        '> quoted\nlazy continuation\n\n'
        '<details type="reasoning" done="true">\n<summary>Thought</summary>\n'
        'Inside.\n\nStill inside.\n</details>\n\n'
        'Title\n=====\n\n'
        r'Inline $x^2$ and `code`.'
        '\n\n---\n\nThe end.';

    // The tree the walker reads, written out. A raw HTML block's text keeps
    // the newline before it when it follows another block, and not when it
    // starts the document -- which is where a half-arrived `<details` lands
    // when the blocks before it are kept. It is a text node, so the
    // difference is whitespace the page collapses.
    String tree(List<md.Node> nodes) => nodes
        .map(
          (node) => switch (node) {
            md.Element() =>
              '<${node.tag} ${node.attributes}>'
                  '${tree(node.children ?? const <md.Node>[])}</${node.tag}>',
            md.Text() => '"${node.text.replaceFirst(RegExp(r'^\n'), '')}"',
            _ => node.textContent,
          },
        )
        .join();

    test('matches a whole parse at every length', () {
      for (var length = 1; length <= answer.length; length++) {
        final text = answer.substring(0, length);
        expect(
          tree(MarkdownView(text, streaming: true).debugParse()),
          tree(MarkdownView(text).debugParse()),
          reason: 'at length $length',
        );
      }
    });
  });

  group('safety', () {
    // These assert on the component tree, which is what this file can prove:
    // the walker never *constructs* an element for a tag it does not know.
    // The escaping of text nodes is Jaspr's, not ours -- the renderer is
    // client-mode, so there is no server-rendered HTML here to assert on, and
    // relying on a framework to escape a text node is reasonable in a way
    // that relying on it to sanitize an `innerHTML` assignment would not be.
    // Which is the point: there is no `innerHTML` assignment.

    testComponents('an img is not rendered', (tester) async {
      tester.pumpComponent(
        const MarkdownView('![x](https://tracker.example/pixel.gif)'),
      );
      // A remote image in a reply is a pixel that reports when it was read.
      expect(find.tag('img'), findsNothing);
    });

    testComponents('an iframe is not rendered', (tester) async {
      tester.pumpComponent(
        const MarkdownView('<iframe src="https://evil.test"></iframe>'),
      );
      expect(find.tag('iframe'), findsNothing);
    });

    testComponents('a javascript: link is not a link', (tester) async {
      tester.pumpComponent(const MarkdownView('[click](javascript:alert(1))'));
      // Not offered at all, rather than offered and silently denied by the
      // shell's window-open handler.
      expect(find.tag('a'), findsNothing);
      expect(find.text('click'), findsOneComponent);
    });

    testComponents('an app: link is not a link', (tester) async {
      // The app's own scheme reaches the origin that holds the bridge.
      tester.pumpComponent(const MarkdownView('[x](app://conduit/)'));
      expect(find.tag('a'), findsNothing);
    });

    testComponents('an https link opens outward safely', (tester) async {
      tester.pumpComponent(
        const MarkdownView('[docs](https://docs.example.com/a)'),
      );
      expect(find.tag('a'), findsOneComponent);
    });
  });

  group('degradation', () {
    testComponents('raw html survives as literal text', (tester) async {
      tester.pumpComponent(const MarkdownView('<marquee>hello</marquee>'));
      // The parser hands raw HTML through as a text node, and the walker
      // renders text nodes as text -- so it is displayed, angle brackets and
      // all, rather than interpreted or dropped. A dropped element would
      // make a reply silently incomplete, which is worse than an ugly one.
      expect(find.text('<marquee>hello</marquee>'), findsOneComponent);
      expect(find.tag('marquee'), findsNothing);
    });

    testComponents('empty markdown renders nothing and does not throw', (
      tester,
    ) async {
      tester.pumpComponent(const MarkdownView(''));
      expect(find.tag('p'), findsNothing);
    });
  });
}
