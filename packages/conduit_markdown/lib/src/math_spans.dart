import 'dart:collection';

/// How a LaTeX span was delimited in the source.
enum MathDelimiter {
  /// `$…$`, inline.
  dollar,

  /// `$$…$$`, display.
  doubleDollar,

  /// `\(…\)`, inline.
  parenthesis,

  /// `\[…\]`, display.
  bracket,
}

/// One LaTeX span found by [MathTokenizer].
final class MathSpan {
  const MathSpan({
    required this.tex,
    required this.delimiter,
    required this.source,
  });

  /// The TeX between the delimiters. Display and `\(…\)` spans are trimmed;
  /// a `$…$` span cannot start or end with whitespace.
  ///
  /// When spans nest (a later rule matching across an earlier token), this
  /// can contain another span's token. [MathTokenizer.restore] undoes that.
  final String tex;

  final MathDelimiter delimiter;

  /// The matched text, delimiters included, as it appeared in the input
  /// passed to [MathTokenizer.tokenize].
  final String source;

  /// Whether the span is display math (`$$…$$` or `\[…\]`).
  bool get isDisplay =>
      delimiter == MathDelimiter.doubleDollar ||
      delimiter == MathDelimiter.bracket;

  @override
  bool operator ==(Object other) =>
      other is MathSpan &&
      other.tex == tex &&
      other.delimiter == delimiter &&
      other.source == source;

  @override
  int get hashCode => Object.hash(tex, delimiter, source);

  @override
  String toString() => 'MathSpan(${delimiter.name}, $tex)';
}

/// Conduit's one rule for finding LaTeX in model output.
///
/// The rule is the one the mobile renderer has always used. It runs four
/// passes, in this order, each over the result of the previous one:
///
/// 1. `\[…\]`, display;
/// 2. `$$…$$`, display;
/// 3. `\(…\)`, inline;
/// 4. `$…$`, inline, with guards that keep prices out.
///
/// Each match is replaced by a token. A display token is wrapped in blank
/// lines so the markdown parser sees it as its own paragraph. Later passes
/// see the tokens rather than the TeX, so the order and the exact token text
/// are part of the rule: every consumer must go through this class rather
/// than re-running the patterns.
///
/// The `$…$` guards: no whitespace just inside either delimiter, no `$` or
/// backslash just before the opening one, no newline inside, and the closing
/// `$` must be followed by whitespace, `]`, `)`, `,`, `.`, `;`, `:`, `!`, `?`
/// or the end of the input. So `$65,539 USD ... ~$42.6` stays prose, and so
/// do `$n$-th` and `**$x$**` (see the package tests for the full list of
/// cases where this differs from the rule the earlier desktop renderer used).
///
/// The tokenizer knows nothing about markdown. The mobile renderer runs it
/// over the whole message (outside `<details>` opening tags), code included;
/// [normalizeTextForPlainMarkdown] runs it over prose only.
final class MathTokenizer {
  /// A tokenizer whose first token is numbered [firstIndex]. Numbers keep
  /// rising across [tokenize] calls on one instance, so tokens never repeat.
  MathTokenizer({int firstIndex = 0}) : _next = firstIndex;

  /// Prefix of a display-math token.
  static const String blockTokenPrefix = '​​LATEX_BLOCK_';

  /// Prefix of an inline-math token.
  static const String inlineTokenPrefix = '​​LATEX_INLINE_';

  /// Suffix of every token.
  static const String tokenSuffix = '​​';

  /// Matches `\[...\]` (block LaTeX), non-greedy, multiline.
  static final _bracketBlockPattern = RegExp(
    r'\\\[([\s\S]+?)\\\]',
    multiLine: true,
  );

  /// Matches `$$...$$` (block LaTeX), non-greedy, multiline.
  static final _dollarBlockPattern = RegExp(
    r'\$\$([\s\S]+?)\$\$',
    multiLine: true,
  );

  /// Matches `\(...\)` (inline LaTeX), non-greedy.
  static final _parenInlinePattern = RegExp(r'\\\(([\s\S]+?)\\\)');

  /// Matches `$...$` (inline LaTeX).
  ///
  /// Excludes `$$`, escaped `\$`, and requires non-whitespace
  /// immediately after the opening `$` and before the closing
  /// `$`.
  ///
  /// Also requires a safe trailing boundary after the closing
  /// `$` (whitespace, punctuation, or end-of-input) so plain
  /// currency text such as `$65,539 USD ... ~$42.6` is not
  /// treated as a math span.
  static final _dollarInlinePattern = RegExp(
    r'(?<!\$)(?<!\\)\$(?!\$)(\S(?:[^\n$]*?\S)?)\$(?!\$)(?=(?:[\s\]),.;:!?]|$))',
  );

  static final _anyToken = RegExp(
    '${RegExp.escape('​​LATEX_')}(?:BLOCK|INLINE)_\\d+'
    '${RegExp.escape(tokenSuffix)}',
  );

  int _next;
  final Map<String, MathSpan> _spans = <String, MathSpan>{};

  /// The number the next token will carry.
  int get nextIndex => _next;

  /// Every span found so far, keyed by its token, in the order found.
  Map<String, MathSpan> get spans => UnmodifiableMapView(_spans);

  /// Whether [text] could hold a span at all. Every delimiter starts with
  /// `$` or a backslash.
  static bool mayContainMath(String text) =>
      text.contains(r'$') || text.contains('\\');

  /// Replaces every LaTeX span in [content] with a token and records it in
  /// [spans]. Display tokens are returned as `'\n\n<token>\n\n'`.
  String tokenize(String content) {
    if (!mayContainMath(content)) return content;
    var result = content;

    result = result.replaceAllMapped(_bracketBlockPattern, (match) {
      final key = _record(
        match,
        tex: match.group(1)!.trim(),
        delimiter: MathDelimiter.bracket,
      );
      return '\n\n$key\n\n';
    });

    result = result.replaceAllMapped(_dollarBlockPattern, (match) {
      final key = _record(
        match,
        tex: match.group(1)!.trim(),
        delimiter: MathDelimiter.doubleDollar,
      );
      return '\n\n$key\n\n';
    });

    result = result.replaceAllMapped(_parenInlinePattern, (match) {
      return _record(
        match,
        tex: match.group(1)!.trim(),
        delimiter: MathDelimiter.parenthesis,
      );
    });

    result = result.replaceAllMapped(_dollarInlinePattern, (match) {
      return _record(
        match,
        tex: match.group(1)!,
        delimiter: MathDelimiter.dollar,
      );
    });

    return result;
  }

  String _record(
    Match match, {
    required String tex,
    required MathDelimiter delimiter,
  }) {
    final display =
        delimiter == MathDelimiter.bracket ||
        delimiter == MathDelimiter.doubleDollar;
    final key =
        '${display ? blockTokenPrefix : inlineTokenPrefix}${_next++}'
        '$tokenSuffix';
    _spans[key] = MathSpan(tex: tex, delimiter: delimiter, source: match[0]!);
    return key;
  }

  /// Whether [text] contains any token this class produces.
  static bool containsToken(String text) =>
      text.contains(blockTokenPrefix) || text.contains(inlineTokenPrefix);

  /// Replaces each token in [text] using [replace], which receives the
  /// token, its span, and whether the blank lines [tokenize] wrapped around
  /// a display token are still both in place (they are consumed with the
  /// token when so). Unknown tokens are kept.
  String replaceTokens(
    String text,
    String Function(String token, MathSpan span, {required bool wrapped})
    replace,
  ) {
    if (!containsToken(text)) return text;
    final pattern = RegExp('(\n\n)?(${_anyToken.pattern})(\n\n)?');
    return text.replaceAllMapped(pattern, (match) {
      final token = match[2]!;
      final span = _spans[token];
      if (span == null) return match[0]!;
      final wrapped = span.isDisplay && match[1] != null && match[3] != null;
      final replaced = replace(token, span, wrapped: wrapped);
      if (wrapped) return replaced;
      return '${match[1] ?? ''}$replaced${match[3] ?? ''}';
    });
  }

  /// [text] with every token turned back into the source it replaced,
  /// nested tokens included. Inverts [tokenize] wherever the blank lines
  /// around display tokens are intact.
  String restore(String text) {
    var restored = text;
    // A later pass can match across an earlier token, so a span's source can
    // itself hold tokens; each round peels one level.
    for (var round = 0; round <= _spans.length; round++) {
      if (!containsToken(restored)) break;
      final next = replaceTokens(
        restored,
        (_, span, {required wrapped}) => span.source,
      );
      if (next == restored) break;
      restored = next;
    }
    return restored;
  }
}

/// A whole `<details ...>` opening tag on one line. The display preparation
/// (`prepareAssistantMarkdown`) has already joined multi-line tags and
/// escaped `<`/`>` inside quoted values.
final _detailsOpeningTag = RegExp(r'<details\b[^>\n]*>', caseSensitive: false);

/// [MathTokenizer.tokenize] over [text] except inside `<details>` opening
/// tags, as the mobile renderer extracts math.
///
/// Tool-call attributes carry JSON-encoded arguments and results whose
/// escaped text often looks like LaTeX delimiters (`\[`…`\]`, `$$`). Math
/// tokenizing them would split the tag (issue #677), so they are skipped.
String tokenizeMathOutsideDetailsTags(MathTokenizer tokenizer, String text) {
  if (!_detailsOpeningTag.hasMatch(text)) return tokenizer.tokenize(text);
  return text.splitMapJoin(
    _detailsOpeningTag,
    onMatch: (match) => match[0]!,
    onNonMatch: tokenizer.tokenize,
  );
}
