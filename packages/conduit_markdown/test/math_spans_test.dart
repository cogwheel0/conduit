import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:test/test.dart';

/// The TeX of every span [MathTokenizer] finds in [text], in the order of
/// the source.
List<String> mathIn(String text) {
  final tokenizer = MathTokenizer();
  final tokenized = tokenizer.tokenize(text);
  return [
    for (final match in RegExp(
      '${RegExp.escape('​​LATEX_')}(?:BLOCK|INLINE)_\\d+'
      '${RegExp.escape(MathTokenizer.tokenSuffix)}',
    ).allMatches(tokenized))
      tokenizer.spans[match[0]]!.tex,
  ];
}

/// The rule the earlier desktop renderer (#754, `math_syntax.dart`) used, as
/// a reference: two `package:markdown` inline syntaxes, display tried before
/// inline at each position, within one paragraph. Prose only; it does not
/// model markdown escapes or code spans.
List<String> rule754(String text) {
  final display = RegExp(r'\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]');
  final inline = RegExp(
    r'(?<![\w$])\$(?![\s$])([^$\n]+?)(?<![\s\\])\$(?![\w$])'
    r'|\\\(([\s\S]+?)\\\)',
  );
  final found = <String>[];
  for (final paragraph in text.split(RegExp(r'\n[ \t]*\n'))) {
    var index = 0;
    while (index < paragraph.length) {
      final match =
          display.matchAsPrefix(paragraph, index) ??
          inline.matchAsPrefix(paragraph, index);
      final source = match == null ? null : (match[1] ?? match[2]);
      if (match == null || source == null || source.trim().isEmpty) {
        index++;
        continue;
      }
      found.add(source.trim());
      index = match.end;
    }
  }
  return found;
}

void main() {
  group('MathTokenizer: the shared rule', () {
    test('finds each delimiter form, display before inline', () {
      final tokenizer = MathTokenizer();
      final out = tokenizer.tokenize(r'a \[x\] b $$y$$ c \(z\) d $w$ e');
      expect(
        tokenizer.spans.values.map((s) => (s.delimiter, s.tex, s.isDisplay)),
        [
          (MathDelimiter.bracket, 'x', true),
          (MathDelimiter.doubleDollar, 'y', true),
          (MathDelimiter.parenthesis, 'z', false),
          (MathDelimiter.dollar, 'w', false),
        ],
      );
      // Display tokens are wrapped in blank lines; inline tokens are not.
      expect(
        out,
        'a \n\n${tokenizer.spans.keys.elementAt(0)}\n\n b '
        '\n\n${tokenizer.spans.keys.elementAt(1)}\n\n c '
        '${tokenizer.spans.keys.elementAt(2)} d '
        '${tokenizer.spans.keys.elementAt(3)} e',
      );
    });

    test('tokens keep the mobile placeholder format and keep counting', () {
      final tokenizer = MathTokenizer(firstIndex: 5);
      tokenizer.tokenize(r'$a$');
      tokenizer.tokenize(r'$$b$$');
      expect(tokenizer.spans.keys, ['​​LATEX_INLINE_5​​', '​​LATEX_BLOCK_6​​']);
      expect(tokenizer.nextIndex, 7);
    });

    test('display and parenthesis TeX is trimmed', () {
      expect(mathIn(r'$$  x + 1  $$ and \( y \) and \[ z \]'), [
        'x + 1',
        'y',
        'z',
      ]);
    });

    test('restore inverts tokenize, nested tokens included', () {
      const samples = [
        r'Plain $x$, then $$y$$ and \[z\] with \(w\).',
        'no math at all',
        r'prices $5 and $10',
        // `$$` matches across the `\[…\]` token the first pass left.
        r'$$ a \[x\] b $$',
        '\$\$\n\nspans a blank line\n\n\$\$',
      ];
      for (final sample in samples) {
        final tokenizer = MathTokenizer();
        expect(tokenizer.restore(tokenizer.tokenize(sample)), sample);
      }
    });

    test('content without a dollar or backslash is returned as is', () {
      final tokenizer = MathTokenizer();
      const text = 'Nothing to see (here) [1].';
      expect(identical(tokenizer.tokenize(text), text), isTrue);
      expect(tokenizer.spans, isEmpty);
    });

    test('currency stays prose', () {
      expect(
        mathIn(
          r'Plain currency text like $65,539 USD is about ~$42.6 million.',
        ),
        isEmpty,
      );
    });
  });

  // The cases #754's desktop renderer tested (apps/desktop_ui/test/
  // math_test.dart on split/2-desktop-app), on the shared rule. Its
  // code-span and fence cases are code, which the plain-markdown normalizer
  // never touches; they live in plain_markdown_test.dart.
  group("#754's cases", () {
    test('inline dollar math', () => expect(mathIn(r'Let $x^2$ be.'), ['x^2']));

    test('display math', () {
      final tokenizer = MathTokenizer();
      tokenizer.tokenize(r'$$\int_0^1 x\,dx$$');
      expect(tokenizer.spans.values.single.isDisplay, isTrue);
      expect(tokenizer.spans.values.single.tex, r'\int_0^1 x\,dx');
    });

    test('the backslash forms', () {
      final inline = MathTokenizer()..tokenize(r'Then \(a+b\) holds.');
      expect(inline.spans.values.single.tex, 'a+b');
      expect(inline.spans.values.single.isDisplay, isFalse);
      final block = MathTokenizer()..tokenize(r'\[a+b\]');
      expect(block.spans.values.single.isDisplay, isTrue);
    });

    test('prices stay prose', () {
      expect(mathIn(r'I paid $5 and $10 for it.'), isEmpty);
    });

    test('a dollar against a word opens nothing here', () {
      expect(mathIn(r'Costs US$5, or EUR$4 today.'), isEmpty);
    });

    test('padded delimiters are prose', () {
      expect(mathIn(r'From $ 100 to $ 200 a month.'), isEmpty);
    });

    test('two formulas are two spans', () {
      expect(mathIn(r'$a$ and $b$'), ['a', 'b']);
      expect(mathIn(r'$x$'), ['x']);
    });
  });

  // Every probe runs through both rules. Where they differ, Conduit keeps the
  // mobile rule (the shared one); the `rule754` column records what the
  // earlier desktop renderer did, for a later decision.
  group('where the shared rule and #754 disagree', () {
    const agree = <(String, List<String>)>[
      (r'Let $x^2$ be.', ['x^2']),
      (r'($x$)', ['x']),
      (r'$x$, $y$; $z$: done!', ['x', 'y', 'z']),
      (r'e.g.$x$', ['x']),
      (r'a$b$c', []),
      (r'$1$st', []),
      (r'$x$_1', []),
      (r'_$x$_', []),
      (r'$5-$10', []),
      (r'$ x$ and $x $', []),
      (r'$$a$$b', ['a']),
      (r'\(a\)b', ['a']),
    ];
    for (final (input, expected) in agree) {
      test('both: $input', () {
        expect(mathIn(input), expected);
        expect(rule754(input), expected);
      });
    }

    // (input, shared rule, #754)
    const disagree = <(String, List<String>, List<String>)>[
      // A closing `$` followed by something other than whitespace or
      // `] ) , . ; : ! ?`: the shared rule keeps it prose; #754 only
      // refused a word character there.
      (r'the $n$-th term', [], ['n']),
      (r"$x$'s value", [], ['x']),
      (r'**$E=mc^2$** is bold', [], ['E=mc^2']),
      (r'"$x$" in quotes', [], ['x']),
      (r'$f$(x)', [], ['f']),
      (r'|$a$|$b$|', [], ['a', 'b']),
      (r'$x$/$y$', ['y'], ['x', 'y']),
      (r'$x$-$y$', ['y'], ['x', 'y']),
      (r'$x$~', [], ['x']),
      (r'数学$x$是', [], ['x']),
      (r'公式$x$。', [], ['x']),
      // An opening `$` right after a word character: the shared rule opens;
      // #754 did not.
      (r'2$x$ apples', ['x'], []),
      (r'x$y$ z', ['y'], []),
      // A backslash before the closing `$`: the shared rule closes there;
      // #754 did not (in markdown, `\$` is an escaped dollar).
      (r'$a\$ b', [r'a\'], []),
      // Display math across a blank line: the shared rule runs over the
      // whole message; #754 ran inside one paragraph.
      ('\$\$\na\n\nb\n\$\$', ['a\n\nb'], []),
    ];
    for (final (input, shared, earlier) in disagree) {
      test('differs: ${input.replaceAll('\n', r'\n')}', () {
        expect(mathIn(input), shared, reason: 'the shared (mobile) rule');
        expect(rule754(input), earlier, reason: "#754's rule");
      });
    }
  });
}
