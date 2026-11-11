import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:test/test.dart';

String plain(String markdown, {bool hasSources = false}) =>
    normalizeTextForPlainMarkdown(markdown, hasSources: hasSources);

void main() {
  group('math', () {
    test(r'keeps $…$ inline math as it is', () {
      expect(plain(r'Let $x^2$ be.'), r'Let $x^2$ be.');
    });

    test(r'turns \(…\) into $…$', () {
      expect(plain(r'Then \(a+b\) holds.'), r'Then $a+b$ holds.');
    });

    test(r'turns \[…\] and $$…$$ into a $$ block on its own lines', () {
      expect(plain(r'\[a+b\]'), '\n\n\$\$\na+b\n\$\$\n\n');
      expect(
        plain(r'Area: $$\pi r^2$$ units'),
        'Area: \n\n\$\$\n\\pi r^2\n\$\$\n\n units',
      );
      expect(
        plain('Before\n\n\$\$\n\\int_0^1 x\\,dx\n\$\$\n\nAfter'),
        'Before\n\n\n\n\$\$\n\\int_0^1 x\\,dx\n\$\$\n\n\n\nAfter',
      );
    });

    test('decodes entities inside math once (stored text is escaped)', () {
      expect(plain(r'If $a &lt; b$ then'), r'If $a < b$ then');
      expect(plain(r'\(x &gt; 0\)'), r'$x > 0$');
    });

    test('leaves a raw < inside math alone', () {
      expect(plain(r'If $a<b$ then'), r'If $a<b$ then');
    });

    test('folds line breaks inside inline math', () {
      expect(plain('\\(a +\n  b\\)'), r'$a + b$');
    });

    test('uses a longer delimiter when the TeX holds a dollar', () {
      expect(plain(r'\(\$5\)'), r'$$\$5$$');
      expect(plain(r'\(5\$\)'), r'$$ 5\$ $$');
    });

    test('a lone backslash before math does not escape the delimiter', () {
      expect(plain(r'\\(x\)'), r'\\$x$');
    });

    test('a span that would swallow code stays prose', () {
      expect(plain(r'$a `b$c` d$'), r'\$a `b$c` d\$');
    });
  });

  group('dollars', () {
    test('escapes prices', () {
      expect(
        plain(r'I paid $5 and $10 for it.'),
        r'I paid \$5 and \$10 for it.',
      );
      expect(
        plain(r'Plain currency text like $65,539 USD is about ~$42.6 million.'),
        r'Plain currency text like \$65,539 USD is about ~\$42.6 million.',
      );
    });

    test('keeps math against emphasis, hyphens and CJK', () {
      expect(plain(r'the $n$-th term'), r'the $n$-th term');
      expect(plain(r'**$E=mc^2$**'), r'**$E=mc^2$**');
      expect(plain(r'数学$x$是'), r'数学$x$是');
    });

    test('escapes what the shared rule keeps as prose', () {
      expect(
        plain(r'Use "$@" instead of "$*".'),
        r'Use "\$@" instead of "\$*".',
      );
      expect(plain(r'$f$(x)'), r'\$f\$(x)');
    });

    test('leaves an escaped dollar alone and escapes one after \\\\', () {
      expect(plain(r'costs \$5'), r'costs \$5');
      expect(plain(r'a \\$5'), r'a \\\$5');
    });
  });

  group('raw HTML', () {
    test('escapes < outside code so tags show as text', () {
      expect(
        plain('a <b>bold</b> & c <script>x</script>'),
        'a &lt;b>bold&lt;/b> & c &lt;script>x&lt;/script>',
      );
    });

    test('does not escape again what is already escaped (#728)', () {
      expect(
        plain('&lt;think&gt;plan&lt;/think&gt; AT&amp;T'),
        '&lt;think&gt;plan&lt;/think&gt; AT&amp;T',
      );
    });

    test('leaves a < already escaped by a backslash alone', () {
      expect(plain(r'\<tag> but \\<b>'), r'\<tag> but \\&lt;b>');
    });

    test('keeps blockquotes', () {
      expect(plain('> quoted <i>'), '> quoted &lt;i>');
    });

    test('a details tag in text shows as text, its dollars as prose', () {
      expect(
        plain(r'<details type="reasoning" summary="$5">'),
        r'&lt;details type="reasoning" summary="\$5">',
      );
    });
  });

  group('code is never touched', () {
    test("#754's cases: a shell variable in a code span is code", () {
      expect(plain(r'Run `echo $PATH` first.'), r'Run `echo $PATH` first.');
    });

    test("#754's cases: a fenced block is never math", () {
      const fence = '```sh\necho \$HOME\nexport \$X=1\n```';
      expect(plain(fence), fence);
    });

    test('code spans keep dollars, tags and brackets', () {
      const text = r'Use `$x$ <b> [1]` or ``a ` $b$``.';
      expect(plain(text, hasSources: true), text);
    });

    test('an escaped backtick opens no code span; the next one can', () {
      expect(plain(r'\`cost $5 <i>`'), r'\`cost \$5 &lt;i>`');
      expect(plain(r'\`a `b $5` c $6'), r'\`a `b $5` c \$6');
      expect(plain(r'\\`b $5`'), r'\\`b $5`');
    });

    test('fences keep everything, unclosed ones to the end', () {
      const closed = '~~~\n\$x\$ <i> [1] \\(y\\)\n~~~\n\nafter \$5';
      expect(
        plain(closed, hasSources: true),
        '~~~\n\$x\$ <i> [1] \\(y\\)\n~~~\n\nafter \\\$5',
      );
      const open = 'Text \$5\n\n```\n\$x\$ <i>';
      expect(plain(open), 'Text \\\$5\n\n```\n\$x\$ <i>');
    });

    test('indented code keeps everything; a lazy indented line is prose', () {
      expect(plain('Para\n\n    \$x\$ <i>\n'), 'Para\n\n    \$x\$ <i>\n');
      expect(plain('Para\n    \$5 <i>'), 'Para\n    \\\$5 &lt;i>');
    });

    test('multi-line code spans keep everything', () {
      expect(plain('A `two\nline \$x\$` span'), 'A `two\nline \$x\$` span');
    });

    test('a backtick across a paragraph break does not hide a later span', () {
      expect(
        plain('`orphan \$4\n\nA `two\nline \$5` end'),
        '`orphan \\\$4\n\nA `two\nline \$5` end',
      );
    });

    test('a span inside a single-line span is not confirmed by it', () {
      expect(plain('``a `b`` \$4\nc` \$5'), '``a `b`` \\\$4\nc` \\\$5');
    });

    test(
      'a triple-backtick span mid-line is a span; at line start, a fence',
      () {
        const span = 'Use ```a \$x\$\nb <i>``` inline, then \$5';
        expect(plain(span), 'Use ```a \$x\$\nb <i>``` inline, then \\\$5');
        const fence = '```\n`a \$x\$\nb` <i>\n```\nthen \$5';
        expect(plain(fence), '```\n`a \$x\$\nb` <i>\n```\nthen \\\$5');
      },
    );

    test('autolinks keep their dollars', () {
      expect(
        plain(r'See <https://example.invalid/a$b> or mail <a@example.invalid>'),
        r'See <https://example.invalid/a$b> or mail <a@example.invalid>',
      );
    });
  });

  group('citations', () {
    test('become links only when the message has sources', () {
      const text = 'See [1] and [2,3].';
      expect(plain(text), text);
      expect(
        plain(text, hasSources: true),
        'See [1](conduit-cite:1) and [2,3](conduit-cite:2,3).',
      );
    });

    test('adjacent brackets merge, as CitationParser merges them', () {
      expect(
        plain('Both[1][2].', hasSources: true),
        'Both[1,2](conduit-cite:1,2).',
      );
      expect(
        plain('Tagged [1#p2, 3].', hasSources: true),
        'Tagged [1,3](conduit-cite:1,3).',
      );
    });

    test('skip footnotes, links, definitions and zero', () {
      for (final text in [
        'A note[^1].',
        'A note^[1].',
        'A [1](https://example.invalid) link.',
        '[1]: https://example.invalid',
        'Index [0].',
      ]) {
        expect(plain(text, hasSources: true), text, reason: text);
      }
    });

    test('skip link and image destinations and reference definitions', () {
      for (final text in [
        '[download](https://example.invalid/files/[1].pdf)',
        '![chart](https://example.invalid/plots/[2].png "Figure [2]")',
        '[guide]: https://example.invalid/pages/[3].html',
      ]) {
        expect(plain(text, hasSources: true), text, reason: text);
      }
      expect(
        plain('[a](https://example.invalid/[1]) per [1].', hasSources: true),
        '[a](https://example.invalid/[1]) per [1](conduit-cite:1).',
      );
      // Not a link (a space ends the destination), so the brackets show.
      expect(
        plain('[a](b [1] c)', hasSources: true),
        '[a](b [1](conduit-cite:1) c)',
      );
    });

    test('a label with a definition left in the text is a link', () {
      // The preprocessor strips one-line definitions, so `[download][1]`
      // with none left reads `[download]` and a chip, as on mobile.
      expect(
        plain('[download][1] is ready.', hasSources: true),
        '[download][1](conduit-cite:1) is ready.',
      );
      // A definition whose destination is on the next line is not stripped,
      // and markdown links the labels that name it.
      const defined =
          '[download][1] or [1] is ready, as [2] says.\n'
          '\n'
          '[1]:\n'
          '  https://example.invalid/harbour-tides\n';
      expect(
        plain(defined, hasSources: true),
        defined.replaceFirst('[2]', '[2](conduit-cite:2)'),
      );
    });

    test("a link's text is not a citation, the brackets before it are", () {
      expect(
        plain('[1][2](https://example.invalid)', hasSources: true),
        '[1](conduit-cite:1)[2](https://example.invalid)',
      );
    });

    test('an escaped bracket still cites, as on mobile', () {
      expect(
        plain(r'Fact \[1].', hasSources: true),
        'Fact [1](conduit-cite:1).',
      );
    });

    test('with a source count, a number past it stays text, as on mobile', () {
      String counted(String text) =>
          normalizeTextForPlainMarkdown(text, hasSources: true, sourceCount: 2);
      expect(counted('In range [2].'), 'In range [2](conduit-cite:2).');
      expect(counted('Past it [3].'), 'Past it [3].');
      // The chip needs every number it names.
      expect(counted('Mixed [1,3].'), 'Mixed [1,3].');
      expect(counted('Both[1][2].'), 'Both[1,2](conduit-cite:1,2).');
    });
  });

  group('normalizeBlocksForPlainMarkdown', () {
    test('normalizes markdown fields and leaves data alone', () {
      final call = MessageToolCall(
        id: 'c1',
        name: 'price',
        arguments: r'{"q": "$5 <b>"}',
        result: r'"$6"',
        done: true,
        pending: false,
        isError: false,
      );
      final blocks = normalizeBlocksForPlainMarkdown([
        const ReasoningMessageBlock(
          summary: r'Costs $5',
          durationSeconds: 1,
          done: true,
          pending: false,
          body: r'Maybe $5 [1]',
        ),
        ToolCallsMessageBlock([call]),
        const CodeInterpreterMessageBlock(
          code: r'print("$5")',
          language: 'python',
          output: r'$5 <out>',
          done: true,
          pending: false,
        ),
        const DetailsMessageBlock(
          type: '',
          summary: 'Notes',
          body: r'$5',
          done: false,
          pending: false,
        ),
        const TextMessageBlock(r'It costs $5 [1].'),
      ], hasSources: true);

      expect(blocks, [
        const ReasoningMessageBlock(
          summary: r'Costs $5',
          durationSeconds: 1,
          done: true,
          pending: false,
          body: r'Maybe \$5 [1]',
        ),
        ToolCallsMessageBlock([call]),
        const CodeInterpreterMessageBlock(
          code: r'print("$5")',
          language: 'python',
          output: r'\$5 &lt;out>',
          done: true,
          pending: false,
        ),
        const DetailsMessageBlock(
          type: '',
          summary: 'Notes',
          body: r'\$5',
          done: false,
          pending: false,
        ),
        const TextMessageBlock(r'It costs \$5 [1](conduit-cite:1).'),
      ]);
    });
  });
}
