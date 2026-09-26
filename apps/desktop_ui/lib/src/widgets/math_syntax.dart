import 'package:markdown/markdown.dart' as md;

/// LaTeX delimiters, as an inline markdown syntax.
///
/// `package:markdown` has no notion of math, and models write it four ways:
/// `$x$`, `$$x$$`, `\(x\)` and `\[x\]`. Each becomes a `math` element with a
/// `display` attribute, which the renderer hands to the sandbox.
///
/// The delimiters are matched conservatively, because the cost of the two
/// errors is not symmetric: a missed formula renders as the LaTeX the model
/// wrote, which is readable, while a false positive turns a sentence into a
/// formula and loses it.
class MathSyntax extends md.InlineSyntax {
  MathSyntax._(super.pattern, {required this.display});

  /// `$$...$$` and `\[...\]`. Tried first: `$$` also matches the single-`$`
  /// pattern, and whichever is registered first wins.
  factory MathSyntax.display() =>
      MathSyntax._(r'\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]', display: true);

  /// `$...$` and `\(...\)`.
  ///
  /// The guards on the `$` form are what keep prices out of it. "I paid $5
  /// and $10" would otherwise become the formula "5 and 10":
  ///
  ///  * no whitespace just inside either delimiter, so `$ x $` is prose;
  ///  * no word character just outside either, so the `$` in `US$5` opens
  ///    nothing and the one before `10` closes nothing;
  ///  * no newline inside, because inline math does not wrap.
  factory MathSyntax.inline() => MathSyntax._(
    r'(?<![\w$])\$(?![\s$])([^$\n]+?)(?<![\s\\])\$(?![\w$])'
    r'|\\\(([\s\S]+?)\\\)',
    display: false,
  );

  final bool display;

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    // Two alternations per pattern, so the content is in whichever group
    // fired. A match with neither is not possible, but returning false
    // rather than asserting means a surprising input is left as text.
    final source = match[1] ?? match[2];
    if (source == null || source.trim().isEmpty) return false;
    parser.addNode(
      md.Element.text('math', source.trim())
        ..attributes['display'] = display ? 'block' : 'inline',
    );
    return true;
  }
}
