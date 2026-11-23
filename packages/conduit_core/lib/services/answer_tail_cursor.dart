import 'dart:convert';

// The patterns [renderSemanticMessageBlocks] walks answer text with. They
// must stay identical to the ones in semantic_message_builder.dart: the cursor
// below appends only what that escaper provably emits.
final _cursorOpeningBacktickFence = RegExp(r'^ {0,3}(`{3,})[^`]*$');
final _cursorOpeningTildeFence = RegExp(r'^ {0,3}(~{3,}).*$');
final _cursorClosingFence = RegExp(r'^ {0,3}(`{3,}|~{3,})[ \t]*$');
final _cursorIndentedCodeLine = RegExp(r'^(?:    | {0,3}\t)');
final _cursorEscapedBlockquotePrefix = RegExp(r'^ {0,3}(?:&gt;[ \t]*)+');
final _cursorSafeInlineMarkdown = RegExp(
  r'(?<!`)(`+(?!`))(.*?[^`])\1(?!`)|'
  r'<(?:[a-zA-Z][a-zA-Z\-\+\.]+):(?://)?[^\s>]*>|'
  r'''<[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9]'''
  r'''(?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?'''
  r'''(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*>''',
);
const _cursorElementEscape = HtmlEscape(HtmlEscapeMode.element);
// A line that starts like a fence may be one once it is complete.
final _cursorFenceRunStart = RegExp(r'^ {0,3}(?:`{3,}|~{3,})');
final _cursorDetailsTag = RegExp('<details', caseSensitive: false);
final _cursorInlineSensitive = RegExp('[`<>&]');
const int _cursorMaxUnstableRender = 4096;
final _cursorLineContentStart = RegExp(r'[^ \t>]');
// Markdown's blank line: only spaces and tabs. A line of other whitespace,
// such as non-breaking spaces, continues the paragraph and any code span.
final _cursorBlankLine = RegExp(r'^[ \t]*$');

/// Follows the end of a streamed answer text block so code-bearing text can
/// keep appending without a full re-render.
///
/// The full escaper walks answer text line by line: fenced code stays
/// verbatim, and other lines go through one inline transform that depends
/// only on the line itself. This cursor tracks fences with the escaper's own
/// patterns, re-renders just the current line, and appends the part of that
/// rendering that is new. [render] returns null, leaving the cursor
/// unchanged, when a delta would change what was already emitted (a closing
/// backtick, say) or when the line's rendering depends on context the cursor
/// does not follow (indented code, a line that may open a fence, multi-line
/// code spans, semantic HTML). The projector then falls back to a full
/// render.
final class AnswerTailCursor {
  AnswerTailCursor(String text) {
    var line = const _AnswerTailLine();
    var start = 0;
    for (
      var newline = text.indexOf('\n');
      newline >= 0;
      newline = text.indexOf('\n', start)
    ) {
      line = line.complete(text.substring(start, newline));
      start = newline + 1;
    }
    final partial = text.substring(start);
    // A partial line whose rendering cannot be known is kept as unknown, so
    // every delta onto it waits for a full render. The escaper drops a line's
    // trailing `\r`, which this cursor does not model.
    _line =
        (partial.contains('\r')
            ? null
            : line.extend(partial, emitted: true)?.line) ??
        line._next(
          html: line.htmlSeen || _cursorDetailsTag.hasMatch(partial),
          text: partial,
          unstableRenderedLength: null,
        );
  }

  late _AnswerTailLine _line;

  /// How the emitted text changes to take in [delta]: drop its last
  /// `remove` characters, then append `insert`. Null when the new rendering
  /// is unknown; the cursor is then left where it was.
  ({int remove, String insert})? render(String delta) {
    if (delta.contains('\r')) return null;
    final insert = StringBuffer();
    final segments = delta.split('\n');
    var remove = 0;
    var line = _line;
    for (var index = 0; index < segments.length; index++) {
      final edit = line.extend(segments[index]);
      if (edit == null) return null;
      // Only the first segment continues a line that was already emitted;
      // every later one starts a fresh line with nothing to remove.
      if (edit.remove > 0) remove = edit.remove;
      insert.write(edit.insert);
      if (index == segments.length - 1) {
        line = edit.line;
      } else {
        insert.write('\n');
        line = edit.line.complete('');
      }
    }
    _line = line;
    return (remove: remove, insert: insert.toString());
  }
}

/// The unterminated last line of a streamed answer, how much of its
/// rendering can still change, and what it inherits from the lines before.
///
/// The first [stableLength] characters of [text] render the same however the
/// line continues, so only the rest is ever rendered again, and only when a
/// delta could change it.
final class _AnswerTailLine {
  const _AnswerTailLine({
    this.fenceChar,
    this.fenceLength = 0,
    this.paragraphMayContinueCodeSpan = false,
    this.htmlSeen = false,
    this.text = '',
    this.stableLength = 0,
    this.unstableRenderedLength = 0,
  });

  final String? fenceChar;
  final int fenceLength;
  // An unmatched backtick run earlier in the paragraph may pair with one on
  // this line, turning text on both lines into a multi-line code span.
  final bool paragraphMayContinueCodeSpan;
  // Semantic `<details>` HTML can make the escaper keep whole regions
  // verbatim, including fence-like lines inside them, so the fence state is
  // no longer trustworthy once one appears.
  final bool htmlSeen;
  final String text;
  final int stableLength;
  // Length of the emitted rendering of `text.substring(stableLength)`; null
  // when that rendering is unknown.
  final int? unstableRenderedLength;

  /// This line with [segment] appended, and the edit from what was emitted
  /// for it to its new rendering: drop the last `remove` characters, then
  /// append `insert`. Null when the new rendering cannot be known without the
  /// rest of the answer. [emitted] marks text the full escaper already
  /// rendered, so no later delta is responsible for changing it.
  ({_AnswerTailLine line, int remove, String insert})? extend(
    String segment, {
    bool emitted = false,
  }) {
    if (unstableRenderedLength == null) return null;
    final updated = text + segment;
    final tail = text.length > 8 ? text.substring(text.length - 8) : text;
    final html = htmlSeen || _cursorDetailsTag.hasMatch(tail + segment);

    // Fenced lines, closing fence included, are emitted verbatim: nothing
    // already emitted can change, so the whole line is stable.
    if (fenceChar != null && !html) {
      return (
        line: _next(
          html: html,
          text: updated,
          stableLength: updated.length,
          unstableRenderedLength: 0,
        ),
        remove: 0,
        insert: segment,
      );
    }
    // A backtick here may close a span opened on an earlier line, changing
    // how text already emitted there renders.
    if (!emitted && paragraphMayContinueCodeSpan && segment.contains('`')) {
      return null;
    }
    final uncertain = _isUncertain(updated, html: html);
    // Text without a backtick or anything escapable can neither open nor
    // close inline code or an autolink, and escapes to itself, so it extends
    // the current rendering unchanged (issue #751: no re-render per delta).
    if (html == htmlSeen &&
        uncertain == _isUncertain(text, html: htmlSeen) &&
        !_cursorInlineSensitive.hasMatch(segment)) {
      return (
        line: _next(
          html: html,
          text: updated,
          unstableRenderedLength: unstableRenderedLength! + segment.length,
        ),
        remove: 0,
        insert: segment,
      );
    }
    // Re-rendering is linear in the unsettled part of the line; past this a
    // full render of the answer is the cheaper fallback.
    if (updated.length - stableLength > _cursorMaxUnstableRender) return null;
    final before = _emittedUnstable();
    if (before == null) return null;

    final String after;
    final _AnswerTailLine line;
    if (uncertain) {
      // Indented code, a fence opener, the inside of a multi-line code span or
      // semantic HTML may each leave the line verbatim instead of rendering it
      // inline. Only a line that renders the same either way is certain.
      if (stableLength > 0) return null;
      after = _cursorRenderInlineLine(updated).rendered;
      if (after != updated) return null;
      line = _next(
        html: html,
        text: updated,
        unstableRenderedLength: after.length,
      );
    } else {
      final rendered = _cursorRenderInlineLine(
        updated.substring(stableLength),
        atLineStart: stableLength == 0,
      );
      after = rendered.rendered;
      line = _next(
        html: html,
        text: updated,
        stableLength: stableLength + rendered.stableLength,
        unstableRenderedLength:
            rendered.rendered.length - rendered.stableRenderedLength,
      );
    }
    return after.startsWith(before)
        ? (line: line, remove: 0, insert: after.substring(before.length))
        : (line: line, remove: before.length, insert: after);
  }

  /// Ends this line with [segment] and returns the empty line after it.
  _AnswerTailLine complete(String segment) {
    final raw = text + segment;
    // Fence patterns see the line as the escaper does, without a CRLF's `\r`.
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    final html = htmlSeen || _cursorDetailsTag.hasMatch(line);
    final openFence = fenceChar;
    if (openFence != null) {
      final run = _cursorClosingFence.firstMatch(line)?.group(1);
      if (run != null && run[0] == openFence && run.length >= fenceLength) {
        return _AnswerTailLine(htmlSeen: html);
      }
      return _AnswerTailLine(
        fenceChar: openFence,
        fenceLength: fenceLength,
        htmlSeen: html,
      );
    }
    final open =
        _cursorOpeningBacktickFence.firstMatch(line) ??
        _cursorOpeningTildeFence.firstMatch(line);
    if (open != null) {
      final run = open.group(1)!;
      return _AnswerTailLine(
        fenceChar: run[0],
        fenceLength: run.length,
        htmlSeen: html,
      );
    }
    if (_cursorBlankLine.hasMatch(line)) return _AnswerTailLine(htmlSeen: html);
    return _AnswerTailLine(
      paragraphMayContinueCodeSpan:
          paragraphMayContinueCodeSpan ||
          line.replaceAll(_cursorSafeInlineMarkdown, '').contains('`'),
      htmlSeen: html,
    );
  }

  bool _isUncertain(String line, {required bool html}) =>
      paragraphMayContinueCodeSpan ||
      html ||
      _cursorIndentedCodeLine.hasMatch(line) ||
      _cursorFenceRunStart.hasMatch(line);

  /// What was emitted for `text.substring(stableLength)`. It is a pure
  /// function of the text, so it is recomputed rather than kept.
  String? _emittedUnstable() {
    if (unstableRenderedLength == 0) return '';
    if (_isUncertain(text, html: htmlSeen)) return text;
    return _cursorRenderInlineLine(
      text.substring(stableLength),
      atLineStart: stableLength == 0,
    ).rendered;
  }

  _AnswerTailLine _next({
    required bool html,
    required String text,
    int? stableLength,
    required int? unstableRenderedLength,
  }) => _AnswerTailLine(
    fenceChar: fenceChar,
    fenceLength: fenceLength,
    paragraphMayContinueCodeSpan: paragraphMayContinueCodeSpan,
    htmlSeen: html,
    text: text,
    stableLength: stableLength ?? this.stableLength,
    unstableRenderedLength: unstableRenderedLength,
  );
}

/// The escaper's rendering of answer text outside code blocks: inline code
/// and autolinks stay verbatim, everything else is escaped, and at the start
/// of a line a leading run of blockquote markers is restored.
///
/// Also reports the longest prefix whose rendering later text cannot change:
/// it stops before any backtick run still waiting for its closer, before any
/// `<` that could still open an autolink (whitespace or `>` rules that out),
/// and extends past the line's blockquote markers.
({String rendered, int stableLength, int stableRenderedLength})
_cursorRenderInlineLine(String text, {bool atLineStart = true}) {
  final rendered = StringBuffer();
  var stableLength = 0;
  var stableRenderedLength = 0;
  var settled = true;
  var openAngle = -1;
  var consumed = 0;
  final contentStart = atLineStart ? text.indexOf(_cursorLineContentStart) : 0;
  // A `<` outside any match may still open an autolink that swallows later
  // text, even across what now matches as code, until whitespace or `>`
  // follows it. [opens] is false inside a match, whose `<` is consumed.
  void settleAngles(String part, int end, int offset, {required bool opens}) {
    for (var index = 0; index < end; index++) {
      final unit = part.codeUnitAt(index);
      if (unit == 0x3C) {
        if (opens && openAngle < 0) openAngle = offset + index;
      } else if (unit == 0x3E || _cursorIsWhitespace(unit)) {
        openAngle = -1;
      }
    }
  }

  for (final match in _cursorSafeInlineMarkdown.allMatches(text)) {
    final gap = text.substring(consumed, match.start);
    final matched = match[0]!;
    if (settled) {
      final tick = gap.indexOf('`');
      final limit = tick < 0 ? gap.length : tick;
      settleAngles(gap, limit, consumed, opens: true);
      _cursorStablePoint(
        gap,
        start: consumed,
        end: openAngle >= 0 ? openAngle - consumed : limit,
        contentStart: contentStart,
        renderedBefore: rendered.length,
        onStable: (length, renderedLength) {
          stableLength = length;
          stableRenderedLength = renderedLength;
        },
      );
      if (tick >= 0) {
        settled = false;
      } else {
        settleAngles(matched, matched.length, match.start, opens: false);
      }
    }
    rendered
      ..write(_cursorElementEscape.convert(gap))
      ..write(matched);
    consumed = match.end;
  }
  final gap = text.substring(consumed);
  if (settled) {
    final tick = gap.indexOf('`');
    final limit = tick < 0 ? gap.length : tick;
    settleAngles(gap, limit, consumed, opens: true);
    _cursorStablePoint(
      gap,
      start: consumed,
      end: openAngle >= 0 ? openAngle - consumed : limit,
      contentStart: contentStart,
      renderedBefore: rendered.length,
      onStable: (length, renderedLength) {
        stableLength = length;
        stableRenderedLength = renderedLength;
      },
    );
  }
  rendered.write(_cursorElementEscape.convert(gap));

  if (!atLineStart) {
    return (
      rendered: rendered.toString(),
      stableLength: stableLength,
      stableRenderedLength: stableRenderedLength,
    );
  }
  // Restoring markers only shortens text before the first content character,
  // which lies inside the stable prefix whenever there is one.
  final raw = rendered.toString();
  final restored = raw.replaceFirstMapped(
    _cursorEscapedBlockquotePrefix,
    (match) => match[0]!.replaceAll('&gt;', '>'),
  );
  return (
    rendered: restored,
    stableLength: stableLength,
    stableRenderedLength: stableLength == 0
        ? 0
        : stableRenderedLength - (raw.length - restored.length),
  );
}

/// Reports `gap.substring(0, end)` as settled when it adds text past the
/// line's first content character.
void _cursorStablePoint(
  String gap, {
  required int start,
  required int end,
  required int contentStart,
  required int renderedBefore,
  required void Function(int length, int renderedLength) onStable,
}) {
  if (end <= 0 || contentStart < 0 || start + end <= contentStart) return;
  onStable(
    start + end,
    renderedBefore + _cursorElementEscape.convert(gap.substring(0, end)).length,
  );
}

/// Whether [unit] is whitespace to the escaper's `\s`, which ends any
/// autolink candidate.
bool _cursorIsWhitespace(int unit) =>
    (unit >= 0x09 && unit <= 0x0D) ||
    unit == 0x20 ||
    unit == 0xA0 ||
    unit == 0x1680 ||
    (unit >= 0x2000 && unit <= 0x200A) ||
    unit == 0x2028 ||
    unit == 0x2029 ||
    unit == 0x202F ||
    unit == 0x205F ||
    unit == 0x3000 ||
    unit == 0xFEFF;
