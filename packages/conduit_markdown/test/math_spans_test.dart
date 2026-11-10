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
        // Inline math right against display math, on either side.
        r'\(x\)$$y$$ tail',
        r'\(x\)\[y\]\(z\)',
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

  // Math that sits against emphasis, an apostrophe, a hyphen, quotes, a
  // tilde or CJK. The shared rule used to keep these as prose; it now
  // agrees with #754 on them.
  group('now math', () {
    const cases = <(String, List<String>)>[
      (r'**$E=mc^2$** is bold', ['E=mc^2']),
      (r'the $n$-th term', ['n']),
      (r"$x$'s value", ['x']),
      (r'"$x$" in quotes', ['x']),
      (r'$x$-$y$', ['x', 'y']),
      (r'$x$~', ['x']),
      (r'数学$x$是', ['x']),
      (r'公式$x$。', ['x']),
    ];
    for (final (input, expected) in cases) {
      test(input, () {
        expect(mathIn(input), expected);
        expect(rule754(input), expected);
      });
    }

    test('typographic quotes, kana, Hangul and CJK brackets too', () {
      expect(mathIn(r'$x$’s and “$y$”'), ['x', 'y']);
      expect(mathIn(r'「$x$」と$y$の値'), ['x', 'y']);
      expect(mathIn(r'$x$는 정수'), ['x']);
      expect(mathIn(r'*$a$* and _$b$_ and __$c$__'), ['a', 'b', 'c']);
    });

    test('a span that starts like a shell parameter, a quote or CJK text '
        'only closes before whitespace, ] ) , . ; : ! ? or the end', () {
      expect(mathIn(r'$*x$ end'), ['*x']);
      expect(mathIn(r'$*x$-th'), isEmpty);
      expect(mathIn(r"$'a'$."), ["'a'"]);
      expect(mathIn(r"$'a'$'s"), isEmpty);
      expect(mathIn(r'$和x$ 是'), ['和x']);
      expect(mathIn(r'$和x$是'), isEmpty);
    });
  });

  // Text that must never become math: money in the shapes models write, and
  // shell. Each case is prose under the shared rule. The rule leaves out `/`,
  // `|` and `(` after a closing `$` because of the cases marked below.
  group('price and shell text stays prose', () {
    const cases = <String>[
      r'$5 and $10',
      r'$5-$10',
      r'between $5-$10 each',
      r'$5/$10',
      r"costs $5, or $10's worth",
      r'$5*',
      r'**$5** off',
      r'$1,000-$2,000',
      r'USD $5 or CAD $7',
      r'$5 for "$10" deals',
      r'価格は$5、割引$3',
      r'price: $5. Tip: $1',
      r'$PATH and $HOME',
      r'echo $A$B',
      r'$5–$10 a night',
      r'**$5**–**$10**',
      r'_$5_ or _$10_',
      r"'$5' or '$10'",
      r'"$5"/"$10"',
      r'Only $5* or $10*',
      r'$5-ish or $10-ish',
      r'was ~~$20~~, now $15',
      r'($5) or ($10)',
      r'$5/mo or $50/yr',
      r'$5, $10, $20',
      r'Plain currency text like $65,539 USD is about ~$42.6 million.',
      r'从$5到$10之间',
      r'价格$5，会员价$4起',
      // A price written after its number, in CJK text: the span would start
      // with CJK, so the CJK after it does not close it.
      r'5$和10$之间',
      // Rules out `/` after a closing `$`.
      r'apples 5$/kg, pears 10$/kg',
      // Rules out `|`.
      r'|Apples|5$|Pears|10$|',
      r'echo "$A$B"',
      r'echo $1$2',
      r'export PATH=$HOME/bin:$PATH',
      r'cd $DIR/$SUB',
      r'echo ${A}$B',
      // Rules out `(`.
      r'echo $PREFIX$(date +%s)',
      // Shell special parameters and quoting: a span starting with one does
      // not close before `*`, `'` and the other added characters.
      r'Use "$@" instead of "$*" to keep arguments apart.',
      r'"$@","$*"',
      r"Set IFS=$'\n' or IFS=$'\t'.",
    ];
    for (final input in cases) {
      test(input, () => expect(mathIn(input), isEmpty));
    }
  });

  // Every probe runs through both rules. Where they differ, Conduit keeps the
  // shared rule; the `rule754` column records what the earlier desktop
  // renderer did.
  group('where the shared rule and #754 still disagree', () {
    const agree = <(String, List<String>)>[
      (r'Let $x^2$ be.', ['x^2']),
      (r'($x$)', ['x']),
      (r'$x$, $y$; $z$: done!', ['x', 'y', 'z']),
      (r'e.g.$x$', ['x']),
      (r'a$b$c', []),
      (r'$1$st', []),
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
      // `/`, `|` and `(` after a closing `$`: prose here, math in #754 (see
      // the price group for why).
      (r'$f$(x)', [], ['f']),
      (r'|$a$|$b$|', [], ['a', 'b']),
      (r'$x$/$y$', ['y'], ['x', 'y']),
      // `_` after a closing `$` now closes a span; #754 refused any word
      // character there and before the opening `$`.
      (r'$x$_1', ['x'], []),
      (r'_$x$_', ['x'], []),
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
        expect(mathIn(input), shared, reason: 'the shared rule');
        expect(rule754(input), earlier, reason: "#754's rule");
      });
    }
  });
}
