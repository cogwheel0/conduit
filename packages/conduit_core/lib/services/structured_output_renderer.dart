import 'dart:collection';
import 'dart:convert';

import 'semantic_message_builder.dart';
import 'structured_output.dart';

/// A bounded-cost update for projecting cumulative Open WebUI `output`
/// snapshots into the active assistant message.
sealed class StructuredOutputStreamingProjection {
  const StructuredOutputStreamingProjection({required this.content});

  final String content;
}

/// Appends newly observed rendered and plain-text suffixes without rebuilding
/// either visible prefix.
final class StructuredOutputStreamingAppend
    extends StructuredOutputStreamingProjection {
  const StructuredOutputStreamingAppend({
    required super.content,
    required this.plainContentDelta,
  });

  final String plainContentDelta;
}

/// Replaces the visible snapshot when its semantic structure changed or an
/// append cannot preserve the authoritative Markdown representation.
final class StructuredOutputStreamingReplace
    extends StructuredOutputStreamingProjection {
  const StructuredOutputStreamingReplace({
    required super.content,
    required this.plainContent,
  });

  final String plainContent;
}

enum StructuredOutputReplacementReason { initial, forced, immediate, geometric }

class StructuredOutputStreamingMetrics {
  const StructuredOutputStreamingMetrics({
    required this.snapshotCount,
    required this.appendProjectionCount,
    required this.tailRewriteProjectionCount,
    required this.fullProjectionCount,
    required this.deferredProjectionCount,
    required this.observedWithoutProjectionCount,
    required this.initialReplacementCount,
    required this.forcedReplacementCount,
    required this.immediateReplacementCount,
    required this.geometricReplacementCount,
    required this.fullProjectionCharacterCount,
    required this.appendProjectionPlainCharacterCount,
    required this.prefixValidationCount,
    required this.prefixValidationCandidateCharacterCount,
    required this.terminalRenderCount,
    required this.terminalExactCacheHitCount,
  });

  final int snapshotCount;
  final int appendProjectionCount;

  /// Code-bearing deltas applied by splicing the answer's last line rather
  /// than re-rendering it.
  final int tailRewriteProjectionCount;
  final int fullProjectionCount;
  final int deferredProjectionCount;
  final int observedWithoutProjectionCount;
  final int initialReplacementCount;
  final int forcedReplacementCount;
  final int immediateReplacementCount;
  final int geometricReplacementCount;
  final int fullProjectionCharacterCount;
  final int appendProjectionPlainCharacterCount;
  final int prefixValidationCount;
  final int prefixValidationCandidateCharacterCount;
  final int terminalRenderCount;
  final int terminalExactCacheHitCount;
}

/// Projects cumulative structured-output snapshots with bounded rendering
/// work.
///
/// Open WebUI sends the complete accumulated `output` list on each event. A
/// naive renderer therefore re-parses an ever-growing answer for every token.
/// Plain trailing text is instead appended after fragment-safe HTML escaping.
/// Once the answer contains Markdown code delimiters, trailing text keeps
/// appending only where [_AnswerTailCursor] proves the fragment renders the
/// same as the full escaper would render it. Structure-sensitive updates
/// (reasoning, tools, or text the cursor cannot place) receive spaced
/// authoritative replacements, plus immediate replacements for
/// structural/status transitions. [finish] always performs one final
/// authoritative render so streamed approximations cannot change persisted
/// Markdown semantics.
final class StructuredOutputStreamingProjector {
  List<StructuredOutputBlock> _latestBlocks = const [];
  List<StructuredOutputBlock> _projectedBlocks = const [];
  String? _latestReplacementText;
  String? _projectedReplacementText;
  StructuredOutputStreamingReplace? _latestExactProjection;
  bool _hasLatestSnapshot = false;
  bool _hasProjection = false;
  bool _appendIsPlain = true;
  bool _finished = false;
  int _nextFullProjectionLength = 1;
  // A tail delta the cursor refuses cannot wait for the periodic threshold:
  // every later delta includes it, so the visible answer would stall until
  // then (issue #751). Re-render sooner, on a denser but still bounded step.
  int _nextRefusedAppendProjectionLength = 1;
  // While the answer carries code delimiters, the exact visible rendering and
  // a cursor at its end let deltas extend it without a full render. The
  // cursor is built lazily from the projected tail; both are dropped whenever
  // a replacement changes that tail.
  StringBuffer? _exactVisible;
  _AnswerTailCursor? _tailCursor;
  int _snapshotRevision = 0;
  int _latestExactProjectionRevision = -1;
  int _snapshotCount = 0;
  int _fullProjectionCount = 0;
  int _appendProjectionCount = 0;
  int _tailRewriteCount = 0;
  int _deferredProjectionCount = 0;
  int _observedWithoutProjectionCount = 0;
  int _initialReplacementCount = 0;
  int _forcedReplacementCount = 0;
  int _immediateReplacementCount = 0;
  int _geometricReplacementCount = 0;
  int _fullProjectionCharacterCount = 0;
  int _appendProjectionPlainCharacterCount = 0;
  int _prefixValidationCount = 0;
  int _prefixValidationCandidateCharacterCount = 0;
  int _terminalRenderCount = 0;
  int _terminalExactCacheHitCount = 0;

  /// Counts streaming replacements, excluding the final authoritative render.
  int get fullProjectionCount => _fullProjectionCount;

  int get appendProjectionCount => _appendProjectionCount;

  /// Total raw plain-text suffix characters carried by append projections.
  int get appendProjectionPlainCharacterCount =>
      _appendProjectionPlainCharacterCount;

  /// Total characters materialized by streaming replacements. This is a
  /// deterministic complexity guard that is more stable than wall-clock tests.
  int get fullProjectionCharacterCount => _fullProjectionCharacterCount;

  StructuredOutputStreamingMetrics get metrics =>
      StructuredOutputStreamingMetrics(
        snapshotCount: _snapshotCount,
        appendProjectionCount: _appendProjectionCount,
        tailRewriteProjectionCount: _tailRewriteCount,
        fullProjectionCount: _fullProjectionCount,
        deferredProjectionCount: _deferredProjectionCount,
        observedWithoutProjectionCount: _observedWithoutProjectionCount,
        initialReplacementCount: _initialReplacementCount,
        forcedReplacementCount: _forcedReplacementCount,
        immediateReplacementCount: _immediateReplacementCount,
        geometricReplacementCount: _geometricReplacementCount,
        fullProjectionCharacterCount: _fullProjectionCharacterCount,
        appendProjectionPlainCharacterCount:
            _appendProjectionPlainCharacterCount,
        prefixValidationCount: _prefixValidationCount,
        prefixValidationCandidateCharacterCount:
            _prefixValidationCandidateCharacterCount,
        terminalRenderCount: _terminalRenderCount,
        terminalExactCacheHitCount: _terminalExactCacheHitCount,
      );

  StructuredOutputStreamingProjection? project(
    List<StructuredOutputBlock> blocks, {
    String? replacementText,
    bool canAppend = true,
    bool forceReplace = false,
  }) {
    if (_finished) return null;

    final snapshot = _recordLatestSnapshot(blocks, replacementText);
    if (!_hasLatestSnapshot) return null;

    final logicalLength = _logicalLength(snapshot, replacementText);
    if (!_hasProjection) {
      return _replace(
        snapshot,
        replacementText,
        logicalLength,
        reason: StructuredOutputReplacementReason.initial,
      );
    }
    if (forceReplace) {
      return _replace(
        snapshot,
        replacementText,
        logicalLength,
        reason: StructuredOutputReplacementReason.forced,
      );
    }

    final appendDelta = _plainTailAppendDelta(
      _projectedBlocks,
      snapshot,
      previousReplacementText: _projectedReplacementText,
      replacementText: replacementText,
      onPrefixValidation: _recordPrefixValidation,
    );
    final hasTailDelta = appendDelta != null && appendDelta.isNotEmpty;
    if (hasTailDelta && _closesDetailsTag(_projectedBlocks, appendDelta)) {
      // A pipe can stream its own tool calls as semantic <details> blocks in
      // the answer text, and a complete one renders as a tool tile, not text
      // (issue #677). Appends escape it, so only a full render shows it.
      return _replace(
        snapshot,
        replacementText,
        logicalLength,
        reason: StructuredOutputReplacementReason.immediate,
      );
    }
    if (hasTailDelta &&
        _appendIsPlain &&
        (appendDelta.contains('`') || appendDelta.contains('~'))) {
      // Plain fragments cannot place code-bearing text. Render once so the
      // visible text is exact, and let the tail cursor extend it from there,
      // rather than hold the tail until the doubling threshold plain appends
      // were expected to reach (issue #751).
      return _replace(
        snapshot,
        replacementText,
        logicalLength,
        reason: StructuredOutputReplacementReason.immediate,
      );
    }

    if (canAppend &&
        hasTailDelta &&
        logicalLength < _nextFullProjectionLength) {
      final projection = _appendIsPlain
          ? _appendPlainTail(snapshot, appendDelta)
          : _extendCodeBearingTail(snapshot, appendDelta);
      if (projection != null) return projection;
    }

    final requiresImmediateReplacement = _requiresImmediateReplacement(
      _projectedBlocks,
      snapshot,
      previousReplacementText: _projectedReplacementText,
      replacementText: replacementText,
      onPrefixValidation: _recordPrefixValidation,
    );
    if (requiresImmediateReplacement) {
      return _replace(
        snapshot,
        replacementText,
        logicalLength,
        reason: StructuredOutputReplacementReason.immediate,
      );
    }
    if (logicalLength >= _nextFullProjectionLength ||
        (canAppend &&
            hasTailDelta &&
            !_appendIsPlain &&
            logicalLength >= _nextRefusedAppendProjectionLength)) {
      return _replace(
        snapshot,
        replacementText,
        logicalLength,
        reason: StructuredOutputReplacementReason.geometric,
      );
    }

    _deferredProjectionCount += 1;
    return null;
  }

  StructuredOutputStreamingAppend _appendPlainTail(
    List<StructuredOutputBlock> snapshot,
    String delta,
  ) {
    _projectedBlocks = snapshot;
    _appendProjectionCount += 1;
    _appendProjectionPlainCharacterCount += delta.length;
    return StructuredOutputStreamingAppend(
      content: renderSemanticPlainTextFragment(delta),
      plainContentDelta: delta,
    );
  }

  StructuredOutputStreamingProjection? _extendCodeBearingTail(
    List<StructuredOutputBlock> snapshot,
    String delta,
  ) {
    final visible = _exactVisible;
    // A tail delta implies the projected tail is a text block.
    final tail = (_projectedBlocks.last as StructuredOutputTextBlock).text;
    // An empty tail renders as nothing, not even the blank line that will
    // separate it from the block before once it has text.
    if (visible == null || (tail.isEmpty && _projectedBlocks.length > 1)) {
      return null;
    }
    final cursor = _tailCursor ??= _AnswerTailCursor(tail);
    final edit = cursor.render(delta);
    if (edit == null) return null;
    _projectedBlocks = snapshot;
    if (edit.remove == 0) {
      visible.write(edit.insert);
      _appendProjectionCount += 1;
      _appendProjectionPlainCharacterCount += delta.length;
      return StructuredOutputStreamingAppend(
        content: edit.insert,
        plainContentDelta: delta,
      );
    }
    // The delta changed how the current line renders (a closing backtick, a
    // completed autolink). Splice that line instead of re-rendering the whole
    // answer.
    final current = visible.toString();
    final content =
        current.substring(0, current.length - edit.remove) + edit.insert;
    _exactVisible = StringBuffer(content);
    _tailRewriteCount += 1;
    return StructuredOutputStreamingReplace(
      content: content,
      plainContent: _plainText(snapshot, null),
    );
  }

  /// Materializes the latest observed snapshot as a full replacement when the
  /// current projection is stale — i.e. a deferred [project] call left the
  /// visible content behind the logical content. Returns null when the
  /// projection is already up to date (or nothing was observed yet).
  ///
  /// Callers use this before switching the visible content basis away from
  /// the projector (e.g. appending a plain delta), so the deferred middle of
  /// the response cannot be silently dropped.
  StructuredOutputStreamingReplace? syncProjectionToLatest() {
    if (_finished || !_hasLatestSnapshot) return null;
    // Only the projector's own projections can be stale. When snapshots were
    // merely observed (observe-only basis: the caller kept visible content
    // that may be a superset of the snapshot render), materializing the
    // snapshot here would SHRINK the visible content and drop that surplus.
    if (!_hasProjection) return null;
    if (identical(_projectedBlocks, _latestBlocks) &&
        _projectedReplacementText == _latestReplacementText) {
      return null;
    }
    // This sync materializes deferred content before the caller switches the
    // visible basis away from the projector. It must not re-arm the geometric
    // backoff to 2x the full length: with the append path disabled after a
    // plain chunk, subsequent snapshots would all defer until the response
    // doubled — freezing the visible tail for the rest of the turn.
    final preservedThreshold = _nextFullProjectionLength;
    final projection = _replace(
      _latestBlocks,
      _latestReplacementText,
      _logicalLength(_latestBlocks, _latestReplacementText),
      reason: StructuredOutputReplacementReason.forced,
    );
    _nextFullProjectionLength = preservedThreshold;
    return projection;
  }

  void observeLatest(
    List<StructuredOutputBlock> blocks, {
    String? replacementText,
  }) {
    if (_finished) return;
    _recordLatestSnapshot(blocks, replacementText);
    _projectedBlocks = const [];
    _projectedReplacementText = null;
    _hasProjection = false;
    _exactVisible = null;
    _tailCursor = null;
    _appendIsPlain = true;
    _nextFullProjectionLength = 1;
    _observedWithoutProjectionCount += 1;
  }

  /// Produces the exact terminal representation once, regardless of which
  /// bounded streaming projections were visible along the way.
  StructuredOutputStreamingReplace? finish() {
    if (_finished || !_hasLatestSnapshot) return null;
    _finished = true;
    if (_latestExactProjectionRevision == _snapshotRevision &&
        _latestExactProjection != null) {
      _terminalExactCacheHitCount += 1;
      return _latestExactProjection;
    }
    _terminalRenderCount += 1;
    return StructuredOutputStreamingReplace(
      content: _render(_latestBlocks, _latestReplacementText),
      plainContent: _plainText(_latestBlocks, _latestReplacementText),
    );
  }

  List<StructuredOutputBlock> _recordLatestSnapshot(
    List<StructuredOutputBlock> blocks,
    String? replacementText,
  ) {
    final snapshot = List<StructuredOutputBlock>.unmodifiable(blocks);
    _snapshotRevision += 1;
    _snapshotCount += 1;
    _latestBlocks = snapshot;
    _latestReplacementText = replacementText;
    _hasLatestSnapshot = snapshot.isNotEmpty || replacementText != null;
    return snapshot;
  }

  void _recordPrefixValidation(int candidateCharacters) {
    _prefixValidationCount += 1;
    _prefixValidationCandidateCharacterCount += candidateCharacters;
  }

  StructuredOutputStreamingReplace _replace(
    List<StructuredOutputBlock> blocks,
    String? replacementText,
    int logicalLength, {
    required StructuredOutputReplacementReason reason,
  }) {
    final content = _render(blocks, replacementText);
    final plainContent = _plainText(blocks, replacementText);
    _projectedBlocks = blocks;
    _projectedReplacementText = replacementText;
    _hasProjection = true;
    _appendIsPlain = !plainContent.contains('`') && !plainContent.contains('~');
    _exactVisible = _appendIsPlain ? null : StringBuffer(content);
    _tailCursor = null;
    // With plain appends available, geometric backoff is safe — appends carry
    // the tail between full renders. Code-bearing text only extends through
    // the tail cursor, so it refreshes on a bounded additive step, and sooner
    // still once the cursor refuses a delta.
    _nextFullProjectionLength = logicalLength == 0
        ? 1
        : _appendIsPlain
        ? logicalLength * 2
        : logicalLength +
              ((logicalLength >> 3) > 64 ? (logicalLength >> 3) : 64);
    _nextRefusedAppendProjectionLength =
        logicalLength + ((logicalLength >> 5) > 64 ? (logicalLength >> 5) : 64);
    _fullProjectionCount += 1;
    _fullProjectionCharacterCount += content.length;
    switch (reason) {
      case StructuredOutputReplacementReason.initial:
        _initialReplacementCount += 1;
      case StructuredOutputReplacementReason.forced:
        _forcedReplacementCount += 1;
      case StructuredOutputReplacementReason.immediate:
        _immediateReplacementCount += 1;
      case StructuredOutputReplacementReason.geometric:
        _geometricReplacementCount += 1;
    }
    final projection = StructuredOutputStreamingReplace(
      content: content,
      plainContent: plainContent,
    );
    _latestExactProjection = projection;
    _latestExactProjectionRevision = _snapshotRevision;
    return projection;
  }
}

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
final class _AnswerTailCursor {
  _AnswerTailCursor(String text) {
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
    // every delta onto it waits for a full render.
    _line =
        line.extend(partial, emitted: true)?.line ??
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
    final line = text + segment;
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
    if (line.trim().isEmpty) return _AnswerTailLine(htmlSeen: html);
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

String _render(List<StructuredOutputBlock> blocks, String? replacementText) {
  return replacementText == null
      ? renderStructuredOutputBlocks(blocks)
      : renderStructuredOutputBlocksWithContent(blocks, replacementText);
}

String _plainText(List<StructuredOutputBlock> blocks, String? replacementText) {
  return replacementText ?? structuredOutputBlocksPlainText(blocks);
}

final _closingDetailsTag = RegExp('</details', caseSensitive: false);

/// Whether [delta] completes a `</details` closing tag at the end of the
/// projected text tail, including one split across deltas.
bool _closesDetailsTag(List<StructuredOutputBlock> projected, String delta) {
  final tail = (projected.last as StructuredOutputTextBlock).text;
  // Eight characters is one short of the tag, so a match needs the delta.
  final overlap = tail.length > 8 ? tail.substring(tail.length - 8) : tail;
  return _closingDetailsTag.hasMatch(overlap + delta);
}

int _logicalLength(
  List<StructuredOutputBlock> blocks,
  String? replacementText,
) {
  if (replacementText != null) return replacementText.length;
  var length = 0;
  for (final block in blocks) {
    switch (block) {
      case StructuredOutputTextBlock(:final text):
        length += text.length;
      case StructuredOutputReasoningBlock(:final text):
        length += text.length;
      case StructuredOutputToolCallBlock(
        :final id,
        :final name,
        :final arguments,
        :final result,
        :final files,
        :final embeds,
      ):
        length +=
            id.length +
            name.length +
            _valueLogicalLength(arguments) +
            _valueLogicalLength(result) +
            _valueLogicalLength(files) +
            _valueLogicalLength(embeds) +
            1;
      case StructuredOutputCodeInterpreterBlock(:final code, :final output):
        length += code.length + _valueLogicalLength(output);
    }
  }
  return length;
}

const int _maxStructuredValueDepth = 64;
const int _maxStructuredValueNodes = 100000;
const int _saturatedValueLogicalLength = 1 << 30;

int _valueLogicalLength(Object? value) =>
    _StructuredValueLengthTraversal().measure(value);

/// Measures JSON-like values without allowing untrusted nesting, fan-out, or
/// cycles to make streaming projection traversal unbounded.
///
/// The active-path set, rather than a global visited set, preserves the old
/// behavior for acyclic graphs that reuse the same collection in multiple
/// places: every occurrence still contributes to the logical length.
final class _StructuredValueLengthTraversal {
  final Set<Object> _activeContainers = HashSet<Object>.identity();
  int _nodes = 0;
  bool _saturated = false;

  int measure(Object? value) {
    final length = _measure(value, 0);
    return _saturated ? _saturatedValueLogicalLength : length;
  }

  int _measure(Object? value, int depth) {
    if (_saturated) return 0;
    if (depth > _maxStructuredValueDepth ||
        ++_nodes > _maxStructuredValueNodes) {
      _saturated = true;
      return 0;
    }
    if (value == null) return 0;

    return switch (value) {
      String() => value.length,
      num() || bool() => value.toString().length,
      List() => _measureList(value, depth),
      Map() => _measureMap(value, depth),
      _ => value.toString().length,
    };
  }

  int _measureList(List<dynamic> value, int depth) {
    if (!_activeContainers.add(value)) {
      _saturated = true;
      return 0;
    }
    var length = 0;
    try {
      for (final item in value) {
        length = _add(length, _measure(item, depth + 1));
        if (_saturated) break;
      }
    } finally {
      _activeContainers.remove(value);
    }
    return length;
  }

  int _measureMap(Map<dynamic, dynamic> value, int depth) {
    if (!_activeContainers.add(value)) {
      _saturated = true;
      return 0;
    }
    var length = 0;
    try {
      for (final entry in value.entries) {
        length = _add(length, entry.key.toString().length);
        length = _add(length, _measure(entry.value, depth + 1));
        if (_saturated) break;
      }
    } finally {
      _activeContainers.remove(value);
    }
    return length;
  }

  int _add(int left, int right) {
    if (_saturated || right >= _saturatedValueLogicalLength - left) {
      _saturated = true;
      return _saturatedValueLogicalLength;
    }
    return left + right;
  }
}

String? _plainTailAppendDelta(
  List<StructuredOutputBlock> previous,
  List<StructuredOutputBlock> current, {
  required String? previousReplacementText,
  required String? replacementText,
  required void Function(int candidateCharacters) onPrefixValidation,
}) {
  if (previousReplacementText != null ||
      replacementText != null ||
      previous.length != current.length ||
      previous.isEmpty) {
    return null;
  }

  for (var index = 0; index < previous.length - 1; index += 1) {
    if (!_blocksEquivalent(
      previous[index],
      current[index],
      onPrefixValidation: onPrefixValidation,
    )) {
      return null;
    }
  }

  final previousTail = previous.last;
  final currentTail = current.last;
  if (previousTail is! StructuredOutputTextBlock ||
      currentTail is! StructuredOutputTextBlock ||
      !_hasStableCumulativePrefix(
        previousTail.text,
        currentTail.text,
        onPrefixValidation: onPrefixValidation,
      )) {
    return null;
  }
  return currentTail.text.substring(previousTail.text.length);
}

bool _requiresImmediateReplacement(
  List<StructuredOutputBlock> previous,
  List<StructuredOutputBlock> current, {
  required String? previousReplacementText,
  required String? replacementText,
  required void Function(int candidateCharacters) onPrefixValidation,
}) {
  if ((previousReplacementText == null) != (replacementText == null)) {
    return true;
  }
  if (previousReplacementText != null && replacementText != null) {
    if (!_hasStableCumulativePrefix(
      previousReplacementText,
      replacementText,
      onPrefixValidation: onPrefixValidation,
    )) {
      return true;
    }
  }
  if (previous.length != current.length) return true;

  for (var index = 0; index < previous.length; index += 1) {
    final before = previous[index];
    final after = current[index];
    if (before.runtimeType != after.runtimeType) return true;
    switch ((before, after)) {
      case (
        StructuredOutputTextBlock(text: final beforeText),
        StructuredOutputTextBlock(text: final afterText),
      ):
        if (beforeText.length == afterText.length) {
          if (beforeText != afterText) return true;
          continue;
        }
        if (!_hasStableCumulativePrefix(
          beforeText,
          afterText,
          onPrefixValidation: onPrefixValidation,
        )) {
          return true;
        }
      case (
        StructuredOutputReasoningBlock(
          text: final beforeText,
          done: final beforeDone,
          duration: final beforeDuration,
        ),
        StructuredOutputReasoningBlock(
          text: final afterText,
          done: final afterDone,
          duration: final afterDuration,
        ),
      ):
        if (beforeDone != afterDone || beforeDuration != afterDuration) {
          return true;
        }
        if (beforeText.length == afterText.length) {
          if (beforeText != afterText) return true;
          continue;
        }
        if (!_hasStableCumulativePrefix(
          beforeText,
          afterText,
          onPrefixValidation: onPrefixValidation,
        )) {
          return true;
        }
      case (
        StructuredOutputToolCallBlock(
          id: final beforeId,
          name: final beforeName,
          arguments: final beforeArguments,
          done: final beforeDone,
          result: final beforeResult,
          files: final beforeFiles,
          embeds: final beforeEmbeds,
        ),
        StructuredOutputToolCallBlock(
          id: final afterId,
          name: final afterName,
          arguments: final afterArguments,
          done: final afterDone,
          result: final afterResult,
          files: final afterFiles,
          embeds: final afterEmbeds,
        ),
      ):
        if (beforeId != afterId ||
            beforeName != afterName ||
            beforeDone != afterDone ||
            _valueUpdateRequiresImmediateReplacement(
              beforeArguments,
              afterArguments,
              onPrefixValidation: onPrefixValidation,
            ) ||
            _valueUpdateRequiresImmediateReplacement(
              beforeResult,
              afterResult,
              onPrefixValidation: onPrefixValidation,
            ) ||
            _valueUpdateRequiresImmediateReplacement(
              beforeFiles,
              afterFiles,
              onPrefixValidation: onPrefixValidation,
            ) ||
            _valueUpdateRequiresImmediateReplacement(
              beforeEmbeds,
              afterEmbeds,
              onPrefixValidation: onPrefixValidation,
            )) {
          return true;
        }
      case (
        StructuredOutputCodeInterpreterBlock(
          code: final beforeCode,
          language: final beforeLanguage,
          done: final beforeDone,
          duration: final beforeDuration,
          output: final beforeOutput,
        ),
        StructuredOutputCodeInterpreterBlock(
          code: final afterCode,
          language: final afterLanguage,
          done: final afterDone,
          duration: final afterDuration,
          output: final afterOutput,
        ),
      ):
        if (beforeLanguage != afterLanguage ||
            beforeDone != afterDone ||
            beforeDuration != afterDuration ||
            _valueUpdateRequiresImmediateReplacement(
              beforeOutput,
              afterOutput,
              onPrefixValidation: onPrefixValidation,
            )) {
          return true;
        }
        if (beforeCode.length == afterCode.length) {
          if (beforeCode != afterCode) return true;
          continue;
        }
        if (!_hasStableCumulativePrefix(
          beforeCode,
          afterCode,
          onPrefixValidation: onPrefixValidation,
        )) {
          return true;
        }
      default:
        return true;
    }
  }
  return false;
}

bool _valueUpdateRequiresImmediateReplacement(
  Object? before,
  Object? after, {
  required void Function(int candidateCharacters) onPrefixValidation,
}) {
  if (_deepEquals(before, after)) return false;
  if (before is String && after is String) {
    return !_hasStableCumulativePrefix(
      before,
      after,
      onPrefixValidation: onPrefixValidation,
    );
  }
  return _valueLogicalLength(after) <= _valueLogicalLength(before);
}

bool _hasStableCumulativePrefix(
  String previous,
  String current, {
  void Function(int candidateCharacters)? onPrefixValidation,
}) {
  final isIdentical = identical(previous, current);
  onPrefixValidation?.call(isIdentical ? 0 : previous.length);
  if (isIdentical) return true;
  if (current.length < previous.length) return false;
  if (previous.isEmpty) return true;
  // Structured snapshots are normally cumulative, but the server remains
  // authoritative. Validate the complete prior value before appending so a
  // simultaneous middle rewrite and tail growth cannot leave temporarily
  // stale visible content. Delta-based text streams use their separate
  // accumulator path and do not pay for this snapshot validation.
  return current.startsWith(previous);
}

bool _blocksEquivalent(
  StructuredOutputBlock left,
  StructuredOutputBlock right, {
  required void Function(int candidateCharacters) onPrefixValidation,
}) {
  if (identical(left, right)) return true;
  return switch ((left, right)) {
    (
      StructuredOutputTextBlock(text: final a),
      StructuredOutputTextBlock(text: final b),
    ) =>
      _boundedStringEquals(a, b, onPrefixValidation: onPrefixValidation),
    (
      StructuredOutputReasoningBlock(
        text: final aText,
        done: final aDone,
        duration: final aDuration,
      ),
      StructuredOutputReasoningBlock(
        text: final bText,
        done: final bDone,
        duration: final bDuration,
      ),
    ) =>
      aDone == bDone &&
          aDuration == bDuration &&
          _boundedStringEquals(
            aText,
            bText,
            onPrefixValidation: onPrefixValidation,
          ),
    (
      StructuredOutputToolCallBlock(
        id: final aId,
        name: final aName,
        arguments: final aArguments,
        done: final aDone,
        result: final aResult,
        files: final aFiles,
        embeds: final aEmbeds,
      ),
      StructuredOutputToolCallBlock(
        id: final bId,
        name: final bName,
        arguments: final bArguments,
        done: final bDone,
        result: final bResult,
        files: final bFiles,
        embeds: final bEmbeds,
      ),
    ) =>
      aId == bId &&
          aName == bName &&
          aDone == bDone &&
          _deepEquals(aArguments, bArguments) &&
          _deepEquals(aResult, bResult) &&
          _deepEquals(aFiles, bFiles) &&
          _deepEquals(aEmbeds, bEmbeds),
    (
      StructuredOutputCodeInterpreterBlock(
        code: final aCode,
        language: final aLanguage,
        done: final aDone,
        duration: final aDuration,
        output: final aOutput,
      ),
      StructuredOutputCodeInterpreterBlock(
        code: final bCode,
        language: final bLanguage,
        done: final bDone,
        duration: final bDuration,
        output: final bOutput,
      ),
    ) =>
      aLanguage == bLanguage &&
          aDone == bDone &&
          aDuration == bDuration &&
          _boundedStringEquals(
            aCode,
            bCode,
            onPrefixValidation: onPrefixValidation,
          ) &&
          _deepEquals(aOutput, bOutput),
    _ => false,
  };
}

bool _boundedStringEquals(
  String left,
  String right, {
  required void Function(int candidateCharacters) onPrefixValidation,
}) {
  return left.length == right.length &&
      _hasStableCumulativePrefix(
        left,
        right,
        onPrefixValidation: onPrefixValidation,
      );
}

bool _deepEquals(Object? left, Object? right) =>
    _BoundedStructuredValueEquality().equals(left, right);

/// Fail-closed equality for JSON-like values received from streaming events.
///
/// Returning false when the traversal budget is exhausted may cause one extra
/// authoritative projection, but can never hide a server-side revision. Active
/// identity pairs make equivalent cyclic graphs safe without changing the
/// comparison of ordinary acyclic values.
final class _BoundedStructuredValueEquality {
  final Map<Object, Set<Object>> _activePairs =
      HashMap<Object, Set<Object>>.identity();
  int _nodes = 0;

  bool equals(Object? left, Object? right) => _equals(left, right, 0);

  bool _equals(Object? left, Object? right, int depth) {
    if (depth > _maxStructuredValueDepth ||
        ++_nodes > _maxStructuredValueNodes) {
      return false;
    }
    if (identical(left, right) || left == right) return true;

    if (left is List && right is List) {
      if (left.length != right.length) return false;
      if (!_beginPair(left, right)) return true;
      try {
        for (var index = 0; index < left.length; index += 1) {
          if (!_equals(left[index], right[index], depth + 1)) return false;
        }
        return true;
      } finally {
        _endPair(left, right);
      }
    }
    if (left is Map && right is Map) {
      if (left.length != right.length) return false;
      if (!_beginPair(left, right)) return true;
      try {
        for (final entry in left.entries) {
          if (!right.containsKey(entry.key) ||
              !_equals(entry.value, right[entry.key], depth + 1)) {
            return false;
          }
        }
        return true;
      } finally {
        _endPair(left, right);
      }
    }
    return false;
  }

  bool _beginPair(Object left, Object right) {
    final rights = _activePairs.putIfAbsent(
      left,
      () => HashSet<Object>.identity(),
    );
    return rights.add(right);
  }

  void _endPair(Object left, Object right) {
    final rights = _activePairs[left];
    if (rights == null) return;
    rights.remove(right);
    if (rights.isEmpty) _activePairs.remove(left);
  }
}

String renderStructuredOutputBlocks(List<StructuredOutputBlock> blocks) {
  return renderSemanticMessageBlocks(
    structuredOutputBlocksToSemanticMessage(blocks),
  );
}

String renderStructuredOutputBlocksWithContent(
  List<StructuredOutputBlock> blocks,
  String content,
) {
  return renderSemanticMessageBlocks(
    structuredOutputBlocksToSemanticMessage(blocks, replacementText: content),
  );
}

bool structuredOutputBlocksContainDetails(List<StructuredOutputBlock> blocks) {
  return blocks.any((block) => block is! StructuredOutputTextBlock);
}

String structuredOutputBlocksPlainText(List<StructuredOutputBlock> blocks) {
  return blocks
      .whereType<StructuredOutputTextBlock>()
      .map((block) => block.text)
      .join();
}

List<SemanticMessageBlock> structuredOutputBlocksToSemanticMessage(
  List<StructuredOutputBlock> blocks, {
  String? replacementText,
}) {
  if (blocks.isEmpty && (replacementText == null || replacementText.isEmpty)) {
    return const [];
  }

  final semanticBlocks = <SemanticMessageBlock>[];
  final replacementTextParts = replacementText == null
      ? null
      : _replacementTextParts(blocks, replacementText);
  var replacementTextIndex = 0;

  for (final block in blocks) {
    switch (block) {
      case StructuredOutputTextBlock(:final text):
        if (replacementTextParts != null) {
          final replacementPart = replacementTextParts[replacementTextIndex++];
          if (replacementPart.isNotEmpty) {
            semanticBlocks.add(SemanticTextBlock.openWebUI(replacementPart));
          }
        } else {
          semanticBlocks.add(SemanticTextBlock.openWebUI(text));
        }
      case StructuredOutputReasoningBlock(
        :final text,
        :final done,
        :final duration,
      ):
        semanticBlocks.add(
          SemanticDetailsBlock.reasoning(
            text: text,
            done: done,
            duration: duration,
          ),
        );
      case StructuredOutputToolCallBlock(
        :final id,
        :final name,
        :final arguments,
        :final done,
        :final result,
        :final files,
        :final embeds,
      ):
        semanticBlocks.add(
          SemanticDetailsBlock.toolCall(
            id: id,
            name: name,
            arguments: arguments,
            done: done,
            result: result,
            files: files,
            embeds: embeds,
          ),
        );
      case StructuredOutputCodeInterpreterBlock(
        :final code,
        :final language,
        :final done,
        :final duration,
        :final output,
      ):
        semanticBlocks.add(
          SemanticDetailsBlock.codeInterpreter(
            code: code,
            language: language,
            done: done,
            duration: duration,
            output: output,
          ),
        );
    }
  }

  if (replacementText != null && replacementTextParts == null) {
    semanticBlocks.add(SemanticTextBlock.openWebUI(replacementText));
  }

  return semanticBlocks;
}

List<String>? _replacementTextParts(
  List<StructuredOutputBlock> blocks,
  String replacementText,
) {
  final textBlocks = blocks.whereType<StructuredOutputTextBlock>().toList();
  if (textBlocks.isEmpty) {
    return null;
  }
  if (textBlocks.length == 1) {
    return [replacementText];
  }

  final originalText = textBlocks.map((block) => block.text).join();
  if (originalText == replacementText) {
    return textBlocks.map((block) => block.text).toList(growable: false);
  }

  final parts = <String>[];
  var offset = 0;
  for (var index = 0; index < textBlocks.length; index += 1) {
    if (index == textBlocks.length - 1) {
      parts.add(replacementText.substring(offset));
      break;
    }
    final requestedNextOffset = offset + textBlocks[index].text.length;
    final nextOffset = requestedNextOffset > replacementText.length
        ? replacementText.length
        : requestedNextOffset;
    parts.add(replacementText.substring(offset, nextOffset));
    offset = nextOffset;
  }
  return parts;
}
