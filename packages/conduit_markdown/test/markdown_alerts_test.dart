import 'package:checks/checks.dart';
import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:test/test.dart';

List<Map<String, Object?>> lift(String markdown) => [
  for (final block in liftMarkdownAlerts([TextMessageBlock(markdown)]))
    block.toJson(),
];

Map<String, Object?> text(String markdown) => {
  'kind': 'text',
  'markdown': markdown,
};

Map<String, Object?> alert(String type, String markdown) => {
  'kind': 'alert',
  'type': type,
  'markdown': markdown,
};

void main() {
  test('an alert between paragraphs becomes its own block', () {
    check(
      lift(
        'Before the trip.\n\n> [!WARNING]\n> Check the **tide table**.\n'
        '> Twice.\n\nAfter it.',
      ),
    ).deepEquals([
      text('Before the trip.'),
      alert('warning', 'Check the **tide table**.\nTwice.'),
      text('After it.'),
    ]);
  });

  test('every kind, in any case, and an escaped marker', () {
    for (final type in markdownAlertTypes) {
      check(lift('> [!${type.toUpperCase()}]\n> Body'))
          .deepEquals([alert(type, 'Body')]);
    }
    check(lift('> [!Tip]\n> Body')).deepEquals([alert('tip', 'Body')]);
    check(
      lift(
        r'> \[!NOTE\]'
        '\n> Body',
      ),
    ).deepEquals([alert('note', 'Body')]);
  });

  test('the last paragraph continues lazily, a new block ends it', () {
    check(lift('> [!NOTE]\n> One line\nand its lazy end\n# Heading'))
        .deepEquals([
          alert('note', 'One line\nand its lazy end'),
          text('# Heading'),
        ]);
    check(lift('> [!NOTE]\n> Item\n\nLater'))
        .deepEquals([alert('note', 'Item'), text('Later')]);
    check(lift('> [!TIP]\n> One\n\n> [!TIP]\n> Two'))
        .deepEquals([alert('tip', 'One'), alert('tip', 'Two')]);
  });

  test('alerts in code, math, other quotes and lists stay text', () {
    const fenced = '```md\n> [!NOTE]\n> In code\n```';
    check(lift(fenced)).deepEquals([text(fenced)]);
    const tilde = '~~~\n> [!TIP]\n~~~\nafter';
    check(lift(tilde)).deepEquals([text(tilde)]);
    // A shorter or other inner fence does not close a longer one.
    const long = '~~~~markdown\n~~~\n> [!NOTE]\n> literal example\n~~~~';
    check(lift(long)).deepEquals([text(long)]);
    const mixed = '````\n~~~~\n> [!NOTE]\n> literal\n````';
    // A closing fence ends with CRLF as well as LF.
    final crlf = lift('~~~\r\ncode\r\n~~~\r\n> [!NOTE]\r\n> Body');
    check(crlf).length.equals(2);
    check(crlf.last).deepEquals(alert('note', 'Body'));
    check(lift(mixed)).deepEquals([text(mixed)]);
    const math = '\$\$\n> [!TIP]\n\$\$';
    check(lift(math)).deepEquals([text(math)]);
    const quoted = '> Quote\n> [!NOTE]\n> More';
    check(lift(quoted)).deepEquals([text(quoted)]);
    const listed = '- item\n  > [!NOTE]\n  > In the item';
    check(lift(listed)).deepEquals([text(listed)]);
  });

  test(
    'the body keeps its lines as written, less the blank ones around it',
    () {
      // An indented code block first, a hard break on the last line.
      check(lift('> [!TIP]\n>\n>     code\n>\n> Line one  \n> Line two  \n>'))
          .deepEquals([alert('tip', '    code\n\nLine one  \nLine two  ')]);
      // Right under the marker, it goes on the marker's paragraph: not code.
      check(lift('> [!NOTE]\n>     print(1)'))
          .deepEquals([alert('note', 'print(1)')]);
    },
  );

  test('a marker with more on its line is a plain quote', () {
    const inline = '> [!NOTE] Not an alert';
    check(lift(inline)).deepEquals([text(inline)]);
    const other = '> [!DANGER]\n> Unknown kind';
    check(lift(other)).deepEquals([text(other)]);
  });

  test('blocks without a marker pass through untouched', () {
    final blocks = <MessageBlock>[
      const TextMessageBlock('plain'),
      const ReasoningMessageBlock(
        summary: '',
        durationSeconds: null,
        done: true,
        pending: false,
        body: '> [!NOTE]\n> In reasoning',
      ),
    ];
    check(identical(liftMarkdownAlerts(blocks), blocks)).isTrue();
  });

  test('alerts survive the plain markdown normalisation', () {
    final blocks = liftMarkdownAlerts(
      normalizeBlocksForPlainMarkdown(
        [
          const TextMessageBlock(
            r'> [!CAUTION]'
            '\n> Costs \$5 [1]',
          ),
        ],
        hasSources: true,
        sourceCount: 1,
      ),
    );
    check(blocks.single.toJson()).deepEquals({
      'kind': 'alert',
      'type': 'caution',
      'markdown': r'Costs \$5 [1](conduit-cite:1)',
    });
  });
}
