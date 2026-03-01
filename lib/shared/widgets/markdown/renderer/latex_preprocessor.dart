import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

/// Extracts LaTeX expressions before markdown parsing and
/// restores them during widget rendering.
///
/// The markdown parser would mangle `$...$` and `$$...$$`
/// syntax, so we replace them with unique placeholder tokens
/// before parsing. During rendering, text nodes are scanned
/// for these tokens and LaTeX widgets are inserted.
///
/// Usage:
/// ```dart
/// final preprocessor = LatexPreprocessor();
/// final safe = preprocessor.extract(rawMarkdown);
/// // ... parse `safe` with the markdown package ...
/// // During inline rendering, call:
/// final segments = preprocessor.splitOnPlaceholders(text);
/// ```
class LatexPreprocessor {
  /// Creates a preprocessor instance for a single parse
  /// operation.
  LatexPreprocessor();

  /// Block-level LaTeX expressions (placeholder key to TeX).
  final _blockExpressions = <String, String>{};

  /// Inline LaTeX expressions (placeholder key to TeX).
  final _inlineExpressions = <String, String>{};

  /// Monotonically increasing counter for unique keys.
  int _counter = 0;

  // -- Placeholder tokens --
  // Use zero-width spaces to avoid collisions with real
  // content. The prefix distinguishes block from inline.

  static const _blockPrefix = '\u200B\u200BLATEX_BLOCK_';
  static const _inlinePrefix = '\u200B\u200BLATEX_INLINE_';
  static const _suffix = '\u200B\u200B';

  // -- Pre-compiled regex patterns --

  /// Matches `$$...$$` (block LaTeX), non-greedy, multiline.
  static final _blockPattern = RegExp(
    r'\$\$([\s\S]+?)\$\$',
    multiLine: true,
  );

  /// Matches `$...$` (inline LaTeX).
  ///
  /// Excludes `$$`, escaped `\$`, and requires non-whitespace
  /// immediately after the opening `$` and before the closing
  /// `$`.
  static final _inlinePattern = RegExp(
    r'(?<!\$)(?<!\\)\$(?!\$)(\S(?:[^$]*?\S)?)\$(?!\$)',
  );

  /// Whether any LaTeX was found during [extract].
  bool get hasLatex =>
      _blockExpressions.isNotEmpty ||
      _inlineExpressions.isNotEmpty;

  /// Replaces LaTeX expressions with placeholder tokens.
  ///
  /// Must be called before passing content to the markdown
  /// parser. Block LaTeX (`$$...$$`) is extracted first and
  /// surrounded by blank lines so the parser treats the
  /// placeholder as its own paragraph. Inline LaTeX (`$...$`)
  /// is extracted second.
  ///
  /// Use [splitOnPlaceholders] during rendering to recover
  /// the original LaTeX content.
  String extract(String content) {
    // Extract block LaTeX first ($$...$$).
    var result = content.replaceAllMapped(
      _blockPattern,
      (match) {
        final tex = match.group(1)!.trim();
        final key =
            '$_blockPrefix${_counter++}$_suffix';
        _blockExpressions[key] = tex;
        return '\n\n$key\n\n';
      },
    );

    // Then extract inline LaTeX ($...$).
    result = result.replaceAllMapped(
      _inlinePattern,
      (match) {
        final tex = match.group(1)!;
        final key =
            '$_inlinePrefix${_counter++}$_suffix';
        _inlineExpressions[key] = tex;
        return key;
      },
    );

    return result;
  }

  /// Returns `true` if [text] contains any placeholder token.
  ///
  /// A quick check to decide whether [splitOnPlaceholders]
  /// needs to be called.
  bool containsPlaceholder(String text) =>
      text.contains(_blockPrefix) ||
      text.contains(_inlinePrefix);

  /// Splits [text] on LaTeX placeholders into segments.
  ///
  /// Each segment is either plain text or a LaTeX expression
  /// (with an [LatexSegment.isBlock] flag). Use this during
  /// inline rendering to insert `WidgetSpan`-wrapped LaTeX
  /// widgets.
  List<LatexSegment> splitOnPlaceholders(String text) {
    final segments = <LatexSegment>[];

    final allPlaceholders = {
      ..._blockExpressions.map(
        (key, tex) =>
            MapEntry(key, (tex: tex, isBlock: true)),
      ),
      ..._inlineExpressions.map(
        (key, tex) =>
            MapEntry(key, (tex: tex, isBlock: false)),
      ),
    };

    if (allPlaceholders.isEmpty) {
      segments.add(LatexSegment.text(text));
      return segments;
    }

    // Build a regex that matches any known placeholder.
    final escapedKeys = allPlaceholders.keys
        .map(RegExp.escape)
        .join('|');
    final pattern = RegExp('($escapedKeys)');

    var lastEnd = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > lastEnd) {
        segments.add(
          LatexSegment.text(
            text.substring(lastEnd, match.start),
          ),
        );
      }
      final key = match.group(0)!;
      final expr = allPlaceholders[key]!;
      segments.add(
        LatexSegment.latex(
          expr.tex,
          isBlock: expr.isBlock,
        ),
      );
      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      segments.add(
        LatexSegment.text(text.substring(lastEnd)),
      );
    }

    return segments;
  }

  /// Builds a Flutter widget for the given TeX expression.
  ///
  /// For inline math, returns a [Math.tex] widget directly.
  /// For block math, wraps it in a horizontal
  /// [SingleChildScrollView] so wide expressions can scroll.
  static Widget buildLatexWidget(
    String tex, {
    required TextStyle textStyle,
    required bool isBlock,
  }) {
    final math = Math.tex(tex, textStyle: textStyle);
    if (!isBlock) return math;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: math,
    );
  }
}

/// A segment of text that is either plain text or a LaTeX
/// expression.
///
/// Produced by [LatexPreprocessor.splitOnPlaceholders] to
/// allow the inline renderer to interleave text spans and
/// LaTeX widget spans.
class LatexSegment {
  /// The text or TeX content of this segment.
  final String content;

  /// Whether this segment is a LaTeX expression.
  final bool isLatex;

  /// Whether this LaTeX expression is block-level.
  ///
  /// Always `false` for plain text segments.
  final bool isBlock;

  /// Creates a plain-text segment.
  const LatexSegment.text(this.content)
      : isLatex = false,
        isBlock = false;

  /// Creates a LaTeX expression segment.
  const LatexSegment.latex(
    this.content, {
    required this.isBlock,
  }) : isLatex = true;
}
