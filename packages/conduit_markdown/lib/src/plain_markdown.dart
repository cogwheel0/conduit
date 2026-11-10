import 'package:html_unescape/html_unescape.dart';
import 'package:markdown/markdown.dart' as md;

import 'markdown_code_regions.dart';
import 'math_spans.dart';
import 'message_blocks.dart';

final _mathUnescape = HtmlUnescape();

// CitationParser's pattern: one or more adjacent [N], [N,M] or [N#suffix].
final _citationPattern = RegExp(
  r'(\[(?:\d+(?:#[^,\]\s]+)?(?:,\s*\d+(?:#[^,\]\s]+)?)*)\])+',
);
final _citationGroup = RegExp(r'\[([^\]]+)\]');
final _citationId = RegExp(r'^(\d+)(?:#.+)?$');
// An inline link's or image's `(destination "title")` after its `]`: a
// destination without spaces whose parentheses balance (one level deep), an
// optional one-line title, then `)`.
final _linkDestination = RegExp(
  r'''\]\([ \t]*(?:[^\s()\\]|\\.|\((?:[^\s()\\]|\\.)*\))*'''
  r'''(?:[ \t]+(?:"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|'''
  r'''\((?:[^()\\\n]|\\.)*\)))?[ \t]*\)''',
);
// A one-line link reference definition, as the preprocessor strips them.
final _referenceDefinition = RegExp(
  r'''^ {0,3}\[[^\]\n]+\]:[ \t]*\S+'''
  r'''(?:[ \t]+(?:"[^"\n]*"|'[^'\n]*'|\([^()\n]*\)))?[ \t]*$''',
  multiLine: true,
);
final _newlineRun = RegExp(r'[ \t]*\n[ \t]*');

/// Rewrites one text block's markdown for a renderer that understands only
/// plain CommonMark + GFM + `$` math, such as GPUI Kit's TextView, so it shows
/// what the mobile renderer shows. Code spans, fenced and indented code, and
/// angle autolinks are never touched (see [findVerbatimMarkdownRanges]).
///
/// Outside them:
///
/// * **Math.** Spans the shared rule ([MathTokenizer]) claims become `$tex$`
///   inline and a `$$` fenced block for display (`\(…\)` and `\[…\]` are
///   converted). The TeX is entity-decoded once, because stored answer text
///   is HTML-escaped (`$a &lt; b$`) and a math renderer does not decode it.
///   A span that would swallow code stays prose.
/// * **Dollars.** Every other `$` is escaped as `\$` (one already escaped by
///   an odd run of backslashes is left alone): a plain renderer treats any
///   `$…$` as math, while the shared rule keeps prices as prose.
/// * **Raw HTML.** Every `<` becomes `&lt;` (one already escaped by an odd
///   run of backslashes is left alone), so tags show as text, as they do
///   on mobile, instead of being interpreted. `&` is left alone: stored text
///   is already escaped once and both renderers decode entities once, so
///   escaping it again would show `&lt;` (issue #728).
/// * **Citations.** With [hasSources], `[1]`, `[1,2]` and adjacent `[1][2]`
///   become links such as `[1,2](conduit-cite:1,2)`, following
///   [CitationParser]: not footnotes (`[^1]`, `^[1]`), not a link's own text
///   (`[1](…)`), not inside a link's or image's destination or title, not in
///   a reference definition (`[1]: …`), not a label a definition left in the
///   text names (`[1]` or `[text][1]` link to it). With [sourceCount],
///   a marker naming a source past it stays text, as the mobile renderer
///   draws a chip only when every number it names has a source.
///
/// The result is meant only for display; keep the original for copying.
String normalizeTextForPlainMarkdown(
  String markdown, {
  required bool hasSources,
  int? sourceCount,
}) {
  if (markdown.isEmpty) return markdown;
  final text = markdown.replaceAll('\r\n', '\n');
  final mask = VerbatimMask(text, findVerbatimMarkdownRanges(text));
  final tokenizer = MathTokenizer();
  final tokenized = tokenizeMathOutsideDetailsTags(tokenizer, mask.masked);

  var prose = _escapeProse(tokenized);
  if (hasSources) prose = _linkCitations(prose, sourceCount);

  final withMath = tokenizer.replaceTokens(prose, (
    _,
    span, {
    required wrapped,
  }) {
    final source = tokenizer.restore(span.source);
    if (mask.hasToken(source)) {
      // Math that would swallow code: code wins, the delimiters stay prose.
      return _escapeProse(source);
    }
    final tex = _mathUnescape.convert(tokenizer.restore(span.tex));
    if (!span.isDisplay) return _inlineMath(tex);
    final block = _displayMath(tex);
    return wrapped ? '\n\n$block\n\n' : block;
  });
  return mask.restore(withMath);
}

/// [blocks] with every markdown field run through
/// [normalizeTextForPlainMarkdown]: text blocks (with [hasSources] and
/// [sourceCount]), reasoning bodies, code-interpreter output and other
/// sections' bodies. Tool-call arguments and results are data, not markdown,
/// and code is code; both are left as they are.
List<MessageBlock> normalizeBlocksForPlainMarkdown(
  List<MessageBlock> blocks, {
  required bool hasSources,
  int? sourceCount,
}) {
  String plain(String markdown, {bool sources = false}) =>
      normalizeTextForPlainMarkdown(
        markdown,
        hasSources: sources,
        sourceCount: sources ? sourceCount : null,
      );
  return List<MessageBlock>.unmodifiable([
    for (final block in blocks)
      switch (block) {
        TextMessageBlock(:final markdown) => TextMessageBlock(
          plain(markdown, sources: hasSources),
        ),
        ReasoningMessageBlock() => ReasoningMessageBlock(
          summary: block.summary,
          durationSeconds: block.durationSeconds,
          done: block.done,
          pending: block.pending,
          body: plain(block.body),
        ),
        CodeInterpreterMessageBlock() => CodeInterpreterMessageBlock(
          code: block.code,
          language: block.language,
          output: plain(block.output),
          done: block.done,
          pending: block.pending,
        ),
        DetailsMessageBlock() => DetailsMessageBlock(
          type: block.type,
          summary: block.summary,
          body: plain(block.body),
          done: block.done,
          pending: block.pending,
        ),
        ToolCallsMessageBlock() => block,
      },
  ]);
}

/// Escapes unclaimed `$` and unescaped `<` in masked, math-tokenized prose.
String _escapeProse(String prose) {
  if (!prose.contains(r'$') && !prose.contains('<') && !prose.contains(r'\')) {
    return prose;
  }
  final out = StringBuffer();
  var backslashes = 0;
  for (var index = 0; index < prose.length; index++) {
    final char = prose[index];
    if (backslashes.isOdd &&
        prose.startsWith(MathTokenizer.inlineTokenPrefix, index)) {
      // `\\(x\)` leaves a lone backslash before the math; in front of a
      // `$` it would escape the delimiter.
      out.write(r'\');
    }
    if (char == r'$' && backslashes.isEven) {
      out.write(r'\$');
    } else if (char == '<' && backslashes.isEven) {
      // `\<` already shows as text; an entity after the backslash would
      // show as `&lt;`.
      out.write('&lt;');
    } else {
      out.write(char);
    }
    backslashes = char == r'\' ? backslashes + 1 : 0;
  }
  return out.toString();
}

String _linkCitations(String prose, int? sourceCount) {
  if (!prose.contains('[')) return prose;
  // A link's destination and title and a reference definition are never
  // shown as text, so the mobile renderer finds no citations in them.
  final hidden = <SourceRange>[
    for (final match in _linkDestination.allMatches(prose))
      SourceRange(match.start + 1, match.end),
    for (final match in _referenceDefinition.allMatches(prose))
      SourceRange(match.start, match.end),
  ];
  final defined = _definedLabels(prose);
  final out = StringBuffer();
  var cursor = 0;
  for (final match in _citationPattern.allMatches(prose)) {
    final raw = match[0]!;
    var start = match.start;
    if (hidden.any((range) => start >= range.start && start < range.end)) {
      continue;
    }
    final after = match.end < prose.length ? prose[match.end] : '';
    if (start > 0 && prose[start - 1] == '^') continue;
    if (after == ':' && _startsLine(prose, start)) continue; // A definition.
    final groups = _citationGroup
        .allMatches(raw)
        .map((group) => group[0]!)
        .toList();
    // A defined label is a link's (`[1]`, `[text][1]`, `[1][2]`), so markdown
    // shows link text there, not the brackets the mobile renderer cites.
    if (defined.isNotEmpty &&
        groups.any(
          (group) => defined.contains(
            group.substring(1, group.length - 1).trim().toLowerCase(),
          ),
        )) {
      continue;
    }
    // The last group of `[1][2](https://…)` is a link's text.
    final tail = after == '(' ? groups.removeLast() : '';
    final ids = <int>[
      for (final group in groups)
        for (final part in group.substring(1, group.length - 1).split(','))
          ?int.tryParse(_citationId.firstMatch(part.trim())?.group(1) ?? ''),
    ].where((id) => id > 0).toList(growable: false);
    if (ids.isEmpty) continue;
    if (sourceCount != null && ids.any((id) => id > sourceCount)) continue;
    // `\[1]` reads `[1]` once markdown drops the escape, and the mobile
    // renderer finds citations in that text; drop the escape here too.
    if (_escapedAt(prose, start)) start -= 1;
    if (start < cursor) continue;
    final label = ids.join(',');
    out
      ..write(prose.substring(cursor, start))
      ..write('[$label](conduit-cite:$label)$tail');
    cursor = match.end;
  }
  if (cursor == 0) return prose;
  out.write(prose.substring(cursor));
  return out.toString();
}

/// The labels of the link reference definitions still in [prose], as
/// markdown keys them. The preprocessor strips one-line definitions; one
/// whose destination or title runs onto the next line stays, and markdown
/// links the labels that name it.
Set<String> _definedLabels(String prose) {
  if (!prose.contains(']:')) return const <String>{};
  final document = md.Document()..parseLines(prose.split('\n'));
  return document.linkReferences.keys.toSet();
}

/// Whether the character at [index] is escaped by an odd run of
/// backslashes.
bool _escapedAt(String text, int index) {
  var count = 0;
  for (var cursor = index - 1; cursor >= 0 && text[cursor] == r'\'; cursor--) {
    count++;
  }
  return count.isOdd;
}

bool _startsLine(String text, int index) {
  var cursor = index - 1;
  var spaces = 0;
  while (cursor >= 0 && text[cursor] == ' ') {
    cursor--;
    spaces++;
  }
  return spaces <= 3 && (cursor < 0 || text[cursor] == '\n');
}

String _longestRun(String text, String char) {
  var longest = 0;
  var current = 0;
  for (var index = 0; index < text.length; index++) {
    if (text[index] == char) {
      current++;
      if (current > longest) longest = current;
    } else {
      current = 0;
    }
  }
  return char * longest;
}

/// `$tex$`, with a longer delimiter run when the TeX holds dollars and a
/// space of padding when it starts or ends with one (as with code spans).
String _inlineMath(String tex) {
  final flat = tex.replaceAll(_newlineRun, ' ');
  final fence = '${_longestRun(flat, r'$')}\$';
  final pad = flat.startsWith(r'$') || flat.endsWith(r'$') ? ' ' : '';
  return '$fence$pad$flat$pad$fence';
}

/// A `$$` math block, its fence longer than any `$` run inside.
String _displayMath(String tex) {
  final inner = _longestRun(tex, r'$');
  final fence = inner.length >= 2 ? '$inner\$' : r'$$';
  return '$fence\n$tex\n$fence';
}
