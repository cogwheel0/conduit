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
    expect(
      lift(
        'Before the trip.\n\n> [!WARNING]\n> Check the **tide table**.\n'
        '> Twice.\n\nAfter it.',
      ),
      [
        text('Before the trip.'),
        alert('warning', 'Check the **tide table**.\nTwice.'),
        text('After it.'),
      ],
    );
  });

  test('every kind, in any case, and an escaped marker', () {
    for (final type in markdownAlertTypes) {
      expect(lift('> [!${type.toUpperCase()}]\n> Body'), [alert(type, 'Body')]);
    }
    expect(lift('> [!Tip]\n> Body'), [alert('tip', 'Body')]);
    expect(
      lift(
        r'> \[!NOTE\]'
        '\n> Body',
      ),
      [alert('note', 'Body')],
    );
  });

  test('the last paragraph continues lazily, a new block ends it', () {
    expect(lift('> [!NOTE]\n> One line\nand its lazy end\n# Heading'), [
      alert('note', 'One line\nand its lazy end'),
      text('# Heading'),
    ]);
    expect(lift('> [!NOTE]\n> Item\n\nLater'), [
      alert('note', 'Item'),
      text('Later'),
    ]);
    expect(lift('> [!TIP]\n> One\n\n> [!TIP]\n> Two'), [
      alert('tip', 'One'),
      alert('tip', 'Two'),
    ]);
  });

  test('alerts in code, math, other quotes and lists stay text', () {
    const fenced = '```md\n> [!NOTE]\n> In code\n```';
    expect(lift(fenced), [text(fenced)]);
    const tilde = '~~~\n> [!TIP]\n~~~\nafter';
    expect(lift(tilde), [text(tilde)]);
    const math = '\$\$\n> [!TIP]\n\$\$';
    expect(lift(math), [text(math)]);
    const quoted = '> Quote\n> [!NOTE]\n> More';
    expect(lift(quoted), [text(quoted)]);
    const listed = '- item\n  > [!NOTE]\n  > In the item';
    expect(lift(listed), [text(listed)]);
  });

  test('a marker with more on its line is a plain quote', () {
    const inline = '> [!NOTE] Not an alert';
    expect(lift(inline), [text(inline)]);
    const other = '> [!DANGER]\n> Unknown kind';
    expect(lift(other), [text(other)]);
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
    expect(identical(liftMarkdownAlerts(blocks), blocks), isTrue);
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
    expect(blocks.single.toJson(), {
      'kind': 'alert',
      'type': 'caution',
      'markdown': r'Costs \$5 [1](conduit-cite:1)',
    });
  });
}
