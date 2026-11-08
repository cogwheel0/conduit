import 'package:conduit_markdown/conduit_markdown.dart' show MathTokenizer;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_tex/flutter_tex.dart';

import '../../horizontal_gesture_ownership.dart';
import 'latex_rendering_server.dart';

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
  LatexPreprocessor()
    : _blockExpressions = <String, String>{},
      _inlineExpressions = <String, String>{},
      _tokenizer = MathTokenizer();

  LatexPreprocessor.fromExpressions(
    Map<String, String> blockExpressions,
    Map<String, String> inlineExpressions,
  ) : _blockExpressions = Map<String, String>.from(blockExpressions),
      _inlineExpressions = Map<String, String>.from(inlineExpressions),
      _tokenizer = MathTokenizer(
        firstIndex: blockExpressions.length + inlineExpressions.length,
      );

  /// Block-level LaTeX expressions (placeholder key to TeX).
  final Map<String, String> _blockExpressions;

  /// Inline LaTeX expressions (placeholder key to TeX).
  final Map<String, String> _inlineExpressions;

  /// Conduit's shared delimiter rule (`conduit_markdown`); it numbers the
  /// placeholders and keeps them unique across [extract] calls.
  final MathTokenizer _tokenizer;

  /// Whether any LaTeX was found during [extract].
  bool get hasLatex =>
      _blockExpressions.isNotEmpty || _inlineExpressions.isNotEmpty;

  Map<String, String> get blockExpressions =>
      Map<String, String>.unmodifiable(_blockExpressions);

  Map<String, String> get inlineExpressions =>
      Map<String, String>.unmodifiable(_inlineExpressions);

  /// Replaces LaTeX expressions with placeholder tokens.
  ///
  /// Must be called before passing content to the markdown
  /// parser. All block variants (`\[...\]` and `$$...$$`) are
  /// extracted first, surrounded by blank lines so the parser
  /// treats them as their own paragraphs. Then inline variants
  /// (`\(...\)` and `$...$`) are extracted. The delimiter rule
  /// itself is [MathTokenizer]'s.
  ///
  /// Use [splitOnPlaceholders] during rendering to recover
  /// the original LaTeX content.
  String extract(String content) {
    final known = _tokenizer.spans.length;
    final result = _tokenizer.tokenize(content);
    for (final entry in _tokenizer.spans.entries.skip(known)) {
      final expressions = entry.value.isDisplay
          ? _blockExpressions
          : _inlineExpressions;
      expressions[entry.key] = entry.value.tex;
    }
    return result;
  }

  /// Returns `true` if [text] contains any placeholder token.
  ///
  /// A quick check to decide whether [splitOnPlaceholders]
  /// needs to be called.
  bool containsPlaceholder(String text) => MathTokenizer.containsToken(text);

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
        (key, tex) => MapEntry(key, (tex: tex, isBlock: true)),
      ),
      ..._inlineExpressions.map(
        (key, tex) => MapEntry(key, (tex: tex, isBlock: false)),
      ),
    };

    if (allPlaceholders.isEmpty) {
      segments.add(LatexSegment.text(text));
      return segments;
    }

    // Build a regex that matches any known placeholder.
    final escapedKeys = allPlaceholders.keys.map(RegExp.escape).join('|');
    final pattern = RegExp('($escapedKeys)');

    var lastEnd = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > lastEnd) {
        segments.add(LatexSegment.text(text.substring(lastEnd, match.start)));
      }
      final key = match.group(0)!;
      final expr = allPlaceholders[key]!;
      segments.add(
        LatexSegment.latex(
          expr.tex,
          isBlock: expr.isBlock,
          placeholderLength: key.length,
        ),
      );
      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      segments.add(LatexSegment.text(text.substring(lastEnd)));
    }

    return segments;
  }

  /// Builds a Flutter widget for the given TeX expression.
  ///
  /// Uses [Math2SVG] from `flutter_tex` (MathJax-powered) for
  /// broader LaTeX coverage. The [formulaWidgetBuilder] callback
  /// parses the `ex`-unit height from the MathJax SVG output and
  /// converts it to logical pixels so the expression scales with
  /// the surrounding text. A [ColorFiltered] layer applies the
  /// current text color for light/dark theme support. Block math
  /// is wrapped in a horizontal [SingleChildScrollView].
  static Widget buildLatexWidget(
    String tex, {
    required TextStyle textStyle,
    required bool isBlock,
    Future<void>? startupFuture,
  }) {
    final color = textStyle.color ?? Colors.black;
    final baseFontSize = textStyle.fontSize ?? 14.0;

    Widget buildMath() {
      return Math2SVG(
        math: tex,
        // `flutter_tex` caches rendered SVGs internally; keep alive preserves
        // that state for still-mounted formulas so scrolling back through a
        // math-heavy transcript re-shows the rendered SVG instead of flashing
        // the plain-text fallback and shifting row extents mid-scroll.
        wantKeepAlive: true,
        loadingWidgetBuilder: (_) => _buildLatexFallback(tex, textStyle),
        errorWidgetBuilder: (_, _) => _buildLatexFallback(tex, textStyle),
        formulaWidgetBuilder: (context, svg) {
          final scaledFontSize = MediaQuery.textScalerOf(context)
              .scale(baseFontSize);
          final height = _svgExToPixels(svg, scaledFontSize);
          return ColorFiltered(
            colorFilter: ColorFilter.mode(color, BlendMode.srcATop),
            child: SvgPicture.string(
              svg,
              height: height,
              fit: BoxFit.contain,
              alignment: Alignment.center,
            ),
          );
        },
      );
    }

    final math = LatexRenderingServer.isStarted
        ? buildMath()
        : FutureBuilder<void>(
            future: startupFuture ?? LatexRenderingServer.ensureStarted(),
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done ||
                  snapshot.hasError) {
                return _buildLatexFallback(tex, textStyle);
              }
              return buildMath();
            },
          );

    return _wrapLatexWidget(math, isBlock: isBlock);
  }

  static Widget _wrapLatexWidget(Widget child, {required bool isBlock}) {
    if (!isBlock) return child;
    return HorizontalScrollGestureBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }

  static Widget _buildLatexFallback(String tex, TextStyle textStyle) =>
      Text(tex, style: textStyle);

  /// Converts MathJax's SVG `ex`-unit height to logical pixels.
  ///
  /// MathJax outputs `<svg height="N.NNex" ...>` where `ex` is
  /// the font's x-height — roughly 0.5 × [fontSize]. Flutter's
  /// SVG renderer ignores unknown units and falls back to the raw
  /// viewBox, which is in thousands of internal units and renders
  /// huge. Parsing and scaling here keeps math proportional to
  /// the surrounding text.
  static double _svgExToPixels(String svg, double fontSize) {
    final match = RegExp(r'height="([\d.]+)ex"').firstMatch(svg);
    if (match == null) return fontSize * 1.5;
    final exValue = double.tryParse(match.group(1)!) ?? 1.5;
    return exValue * fontSize * 0.5;
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

  /// The length of the placeholder token consumed from the source text for
  /// this segment.
  ///
  /// For plain-text segments this is the length of [content]. For LaTeX
  /// segments [content] holds the recovered TeX, which is unrelated to the
  /// placeholder token's length, so this records the token length instead.
  /// Streaming-fade offset accounting must advance by the placeholder token
  /// length to stay in the document-wide `textContent` coordinate space.
  final int placeholderLength;

  /// Creates a plain-text segment.
  const LatexSegment.text(this.content)
    : isLatex = false,
      isBlock = false,
      placeholderLength = content.length;

  /// Creates a LaTeX expression segment.
  const LatexSegment.latex(
    this.content, {
    required this.isBlock,
    required this.placeholderLength,
  }) : isLatex = true;
}
