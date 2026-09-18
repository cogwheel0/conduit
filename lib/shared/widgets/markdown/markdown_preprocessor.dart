import 'package:html_unescape/html_unescape.dart';

/// Content preprocessing, sanitization, and transformation for Markdown.
///
/// Provides:
/// - [normalize] - Prepares content for display (keeps reasoning blocks)
/// - [sanitize] - Cleans content for copy/API (removes reasoning blocks)
/// - [toPlainText] - Converts to plain text for TTS
/// - [softenInlineCode] - Breaks long inline code spans
class ConduitMarkdownPreprocessor {
  const ConduitMarkdownPreprocessor._();

  static final _htmlUnescape = HtmlUnescape();

  // ============================================================
  // Pre-compiled Patterns - Display/Sanitization
  // ============================================================

  static final _bulletFenceRegex = RegExp(
    r'^(\s*(?:[*+-]|\d+\.)\s+)```([^\s`]*)\s*$',
    multiLine: true,
  );
  static final _dedentOpenRegex = RegExp(
    r'^[ \t]+```([^\n`]*)\s*$',
    multiLine: true,
  );
  static final _dedentCloseRegex = RegExp(r'^[ \t]+```\s*$', multiLine: true);
  static final _inlineClosingRegex = RegExp(r'([^\r\n`])```(?=\s*(?:\r?\n|$))');
  static final _labelThenDashRegex = RegExp(
    r'^(\*\*[^\n*]+\*\*.*)\n(\s*-{3,}\s*$)',
    multiLine: true,
  );
  static final _atxEnumRegex = RegExp(
    r'^(\s{0,3}#{1,6}\s+\d+)\.(\s*)(\S)',
    multiLine: true,
  );
  static final _fenceAtBolRegex = RegExp(r'^\s*```', multiLine: true);
  static final _linkWithTrailingSpaces = RegExp(r'\[[^\]]+\]\([^\)]+\)\s{2,}$');
  static final _linkReferenceDefinition = RegExp(
    r'^[ ]{0,3}\[[^\]\r\n]+\]:[ \t]*(?:<[^>\r\n]*>|[^\s\r\n]+)(?:[ \t]+(?:"[^"\r\n]*"|'
    r"'[^'\r\n]*'|\([^)]+\)))?[ \t]*$",
    multiLine: true,
    caseSensitive: false,
  );
  static final _multipleNewlines = RegExp(r'\n{3,}');

  /// Combined pattern for all reasoning/thinking blocks.
  static final _reasoningBlocks = RegExp(
    r'<details\s+type="(?:reasoning|code_interpreter)"[^>]*>[\s\S]*?</details>|'
    r'<(?:think|thinking|reasoning|reason|thought|Thought)(?:\s[^>]*)?>[\s\S]*?</(?:think|thinking|reasoning|reason|thought|Thought)>|'
    r'<\|begin_of_thought\|>[\s\S]*?<\|end_of_thought\|>|'
    r'◁think▷[\s\S]*?◁/think▷',
    multiLine: true,
    dotAll: true,
  );
  static final _ttsReasoningDetailsBlocks = RegExp(
    r'<details\b[^>]*>\s*<summary>\s*(?:Thought|Thinking|Reasoning)(?:\.{3}|…)?\s*</summary>[\s\S]*?</details>',
    multiLine: true,
    dotAll: true,
    caseSensitive: false,
  );
  static final _toolCallBlocks = RegExp(
    r'<details\s+type="tool_calls"[^>]*>[\s\S]*?</details>',
    multiLine: true,
    dotAll: true,
  );
  static final _attachedToolCallDetailsOpen = RegExp(
    r'''([^\n])(<details(?=[\s/>])(?=[^>\n]*\stype\s*=\s*["']tool_calls["']))''',
    caseSensitive: false,
  );

  /// Case-insensitive `<details` marker used by the open-tag normalizer.
  /// Exact tag-name boundary so custom elements such as `<details-panel>`
  /// are never rewritten.
  static final _detailsTagMarker = RegExp(
    r'<details(?=[\s/>])',
    caseSensitive: false,
  );

  /// Upper bound on how far a spanning `<details` open tag may be joined so a
  /// malformed tag cannot trigger an unbounded scan or a giant concatenated line.
  static const _detailsOpenTagJoinLimit = 256 * 1024;

  /// Aggregate cap on scanning across all `<details` markers in one
  /// [normalize] call, so inputs with many unterminated markers cannot
  /// produce quadratic synchronous work (streaming render freeze).
  static const _detailsOpenTagTotalScanBudget = 1024 * 1024;

  /// Code spans, backtick fences, and tilde fences (`~~~`).
  ///
  /// Tilde fences are masked alongside backtick fences so transforms never
  /// rewrite literal `<details>` examples inside them. CommonMark allows
  /// 0-3 leading spaces and an info string on the opening fence; the closing
  /// fence allows only spaces (up to three), optional trailing whitespace,
  /// and a delimiter run at least as long as the opening one (matched
  /// conservatively as an equal-length run via backreference — a longer
  /// closing run simply leaves the mask open, which is safe).
  static final _codeSpanOrFence = RegExp(
    r'(`+)([\s\S]*?)\1|'
    r'^ {0,3}(~{3,})[^\n]*\n[\s\S]*?^ {0,3}\3~*[ \t]*(?=\n|$)',
    multiLine: true,
  );
  /// Semantic `<details ...>` blocks (Open WebUI tool-call / reasoning /
  /// code-interpreter blocks). Requires the `<summary>` child so literal
  /// `<details>` examples without one are never matched.
  static final _semanticDetailsOpen = RegExp(
    r'<details\s+[^>]*\btype\s*=\s*"(?:tool_calls|reasoning|code_interpreter)"[^>]*>',
    caseSensitive: false,
  );
  static final _semanticDetailsFullBlock = RegExp(
    r'<details\s+[^>]*\btype\s*=\s*"(?:tool_calls|reasoning|code_interpreter)"[^>]*>'
    r'[\s\S]*?</details>',
    caseSensitive: false,
  );
  /// Closing `</details>` tag, matched case-insensitively to mirror
  /// DetailsBlockSyntax._closingTagPattern.
  static final _closingTagCaseInsensitive = RegExp(
    r'</\s*details\s*>',
    caseSensitive: false,
  );

  /// `type=` attribute of an unterminated semantic `<details` tag, matched
  /// against a bounded window when scanning for truncated tails (issue #677).
  static final _unterminatedSemanticType = RegExp(
    "\\btype\\s*=\\s*[\"']?(?:tool_calls|reasoning|code_interpreter)",
    caseSensitive: false,
  );

  static final _detailsSummaryCheck = RegExp(
    r'<\s*summary[\s>]',
    caseSensitive: false,
  );

  static final _allDetailsBlocks = RegExp(
    r'<details[^>]*>[\s\S]*?</details>',
    multiLine: true,
    dotAll: true,
    caseSensitive: false,
  );

  // ============================================================
  // Pre-compiled Patterns - Plain Text (TTS)
  // ============================================================

  static final _codeBlock = RegExp(r'```[^\n]*\n[\s\S]*?```');
  static final _inlineCode = RegExp(r'`([^`]+)`');
  static final _image = RegExp(r'!\[[^\]]*\]\([^)]+\)');
  static final _link = RegExp(r'\[([^\]]+)\]\([^)]+\)');
  // Paired markdown formatting - only unambiguous markers for TTS
  // Single * and _ are skipped as they're ambiguous (math, variable names)
  static final _boldItalic = RegExp(r'\*\*\*([^*]+)\*\*\*');
  static final _bold = RegExp(r'\*\*([^*]+)\*\*');
  static final _strikethrough = RegExp(r'~~([^~]+)~~');
  // Single asterisk italic: only at word boundaries (space or line start/end)
  static final _italicAsterisk = RegExp(r'(?:^|\s)\*([^*\s]+)\*(?=\s|$)');
  // Single underscore italic: only when surrounded by spaces (not in identifiers)
  static final _italicUnderscore = RegExp(r'(?:^|\s)_([^_\s]+)_(?=\s|$)');
  static final _heading = RegExp(r'^#{1,6}\s+', multiLine: true);
  static final _listMarker = RegExp(
    r'^[\s]*(?:[-*+]|\d+\.)\s+',
    multiLine: true,
  );
  static final _blockquote = RegExp(r'^>\s*', multiLine: true);
  static final _horizontalRule = RegExp(
    r'^[\s]*[-*_]{3,}[\s]*$',
    multiLine: true,
  );
  static final _htmlTag = RegExp(r'<[^>]+>');

  /// Comprehensive emoji pattern for TTS cleanup.
  static final _emoji = RegExp(
    r'[\u{1F600}-\u{1F64F}]|' // Emoticons
    r'[\u{1F300}-\u{1F5FF}]|' // Misc Symbols and Pictographs
    r'[\u{1F680}-\u{1F6FF}]|' // Transport and Map
    r'[\u{1F1E0}-\u{1F1FF}]|' // Flags
    r'[\u{2600}-\u{26FF}]|' // Misc symbols
    r'[\u{2700}-\u{27BF}]|' // Dingbats
    r'[\u{1F900}-\u{1F9FF}]|' // Supplemental Symbols
    r'[\u{1FA00}-\u{1FA6F}]|' // Chess, cards
    r'[\u{1FA70}-\u{1FAFF}]|' // Symbols Extended-A
    r'[\u{FE00}-\u{FE0F}]|' // Variation Selectors
    r'[\u{1F018}-\u{1F270}]|' // Various
    r'[\u{238C}-\u{2454}]|' // Misc Technical
    r'[\u{20D0}-\u{20FF}]', // Combining Diacritical Marks
    unicode: true,
  );
  static final _whitespace = RegExp(r'\s+');

  // ============================================================
  // Public API
  // ============================================================

  /// Normalizes content for Markdown display.
  ///
  /// - Strips link reference definitions (including OpenAI annotations)
  /// - Fixes common LLM fence issues
  /// - Preserves reasoning blocks for collapsible UI rendering
  static String normalize(String input) {
    if (input.isEmpty) return input;

    var output = input.replaceAll('\r\n', '\n');

    // Strip link reference definitions using markdown package
    output = _stripLinkReferenceDefinitions(output);

    // Fix fence issues (structure only; auto-close runs after the hoister).
    output = _normalizeFenceStructure(output);

    // A model answer that leaves a fence unclosed would otherwise have
    // _autoCloseUnmatchedFence turn everything after that fence — including
    // semantic tool-call/reasoning blocks appended after the answer — into
    // a fenced code region that renders as a raw wall (issue #677). While
    // the fence is still unclosed, hoist those semantic blocks out of the
    // region, close the fence, and re-append the blocks after it on block
    // boundaries. Deliberately fenced code (a closed fence the model wrote)
    // is untouched.
    output = _hoistSemanticDetailsFromUnclosedFence(output);

    output = _autoCloseUnmatchedFence(output);

    // Fix Setext heading false positives
    output = output.replaceAllMapped(
      _labelThenDashRegex,
      (match) => '${match[1]}\n\n${match[2]}',
    );

    // Fix numeric heading parsing
    output = output.replaceAllMapped(
      _atxEnumRegex,
      (match) => '${match[1]}.\u200C${match[2]}${match[3]}',
    );

    // Separate consecutive links
    output = _separateConsecutiveLinks(output);

    // An opening `<details ...>` tag whose quoted attribute values contain
    // real newlines (legal in HTML) has no `>` on its first line, so the
    // per-line block parser never matches it and the whole block renders as
    // raw text.
    //
    // Order matters: join first (finds the quote-balanced `>` across lines),
    // then escape any bare `<`/`>` inside the tag's quoted values so the tag
    // regex reaches the real end-of-tag. Escaping first would miss spanning
    // tags, and joining without escaping would leave a raw `<`/`>` (e.g. an
    // unescaped `<br>` from a result value) acting as a false tag terminator.
    //
    // The escaper cannot use `_detailsOpenTagSingleLine` for its match: that
    // regex stops at the first raw `>`, so multiple raw `<`/`>` in quoted
    // values only get escaped up to the first one. Instead, both transforms
    // run in one quote-aware scan that locates the true end-of-tag (the first
    // `>` outside quotes), joins if needed, and escapes quoted values.
    // Everything operates outside code spans and fences.
    output = _maskCodeAndTransform(output, _normalizeDetailsOpenTags);

    // Raw model output can attach Open WebUI's tool-call block directly to
    // answer text. Put it on a Markdown block boundary without rewriting
    // literal examples inside code spans or fences.
    if (_attachedToolCallDetailsOpen.hasMatch(output)) {
      output = _replaceMatchesOutsideCode(
        output,
        _attachedToolCallDetailsOpen,
        (match) => '${match[1]}\n\n${match[2]}',
      );
    }

    // A persisted message can end inside a semantic details block (an
    // interrupted stream was saved mid-tag, or a server truncated the
    // content). The per-line block parser can never match an unterminated
    // tag, so the tail renders as raw text. The streaming path already
    // strips such tails via stripTrailingIncompleteToolCallDetailsCanonical;
    // strip here too so saved/reloaded messages heal the same way. Handles
    // both a complete-but-unclosed block and a tag truncated mid-attributes.
    output = _stripUnterminatedSemanticDetailsTail(output);

    return output;
  }

  /// Removes Markdown link reference definitions while keeping other content.
  ///
  /// This is a cheaper targeted transform than [normalize] for callers that
  /// only need to hide reference-definition lines from display.
  static String stripLinkReferenceDefinitions(String input) {
    if (input.isEmpty || !input.contains(']:')) {
      return input;
    }
    return _stripLinkReferenceDefinitions(input.replaceAll('\r\n', '\n'));
  }

  /// Sanitizes content for clipboard copy or API submission.
  ///
  /// - Strips link reference definitions (including OpenAI annotations)
  /// - Strips reasoning/thinking blocks
  /// - Normalizes whitespace
  static String sanitize(String input) {
    if (input.isEmpty) return input;

    return input
        .replaceAll('\r\n', '\n')
        .transform(_stripLinkReferenceDefinitions)
        .transform(
          (content) =>
              _replaceMatchesOutsideCode(content, _reasoningBlocks, (_) => ''),
        )
        .replaceAll(_multipleNewlines, '\n\n')
        .trim();
  }

  /// Sanitizes message content for copying while omitting internal tool calls.
  ///
  /// Tool-call markup inside code spans is preserved so documentation and
  /// examples are copied faithfully. Ordinary `<details>` blocks are also left
  /// untouched.
  static String sanitizeForClipboard(String input) {
    if (input.isEmpty) return input;

    final sanitized = sanitize(input);
    return _replaceMatchesOutsideCode(sanitized, _toolCallBlocks, (_) => '')
        // Stored assistant content is HTML-escaped for the renderer; the
        // clipboard needs the literal text back (`"` not `&quot;`). API
        // replay deliberately does NOT decode — it cannot distinguish
        // model-typed entities from presentation escaping.
        .transform(_htmlUnescape.convert)
        .replaceAll(_multipleNewlines, '\n\n')
        .trim();
  }

  /// Converts markdown to plain text for text-to-speech.
  static String toPlainText(String input) {
    if (input.trim().isEmpty) return '';

    return sanitize(input)
        .replaceAll(_ttsReasoningDetailsBlocks, '')
        .replaceAll(_toolCallBlocks, '')
        .replaceAll(_codeBlock, '') // Remove code blocks
        .replaceAllMapped(_inlineCode, (m) => m[1] ?? '') // Keep code text
        .replaceAll(_image, '') // Remove images
        .replaceAllMapped(_link, (m) => m[1] ?? '') // Keep link text
        // Strip paired markdown formatting (preserves lone * and _ in text)
        .replaceAllMapped(_boldItalic, (m) => m[1] ?? '')
        .replaceAllMapped(_bold, (m) => m[1] ?? '')
        .replaceAllMapped(_strikethrough, (m) => m[1] ?? '')
        .replaceAllMapped(_italicAsterisk, (m) => ' ${m[1] ?? ''}')
        .replaceAllMapped(_italicUnderscore, (m) => ' ${m[1] ?? ''}')
        .replaceAll(_heading, '') // Strip # markers
        .replaceAll(_listMarker, '') // Strip list markers
        .replaceAll(_blockquote, '') // Strip > markers
        .replaceAll(_horizontalRule, '') // Remove ---
        .replaceAll(_htmlTag, '') // Remove HTML
        .transform(_htmlUnescape.convert) // Decode entities
        .replaceAll(_emoji, '') // Remove emojis
        .replaceAll(_whitespace, ' ') // Normalize whitespace
        .trim();
  }

  /// Cleans assistant output the way OpenWebUI does before TTS playback.
  ///
  /// This intentionally does less than [toPlainText]: it removes common
  /// markdown formatting and emojis while preserving newline boundaries so
  /// downstream chunk splitting matches OpenWebUI.
  static String cleanText(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return '';

    // Presentation content is HTML-escaped for the renderer; TTS must speak
    // the literal text (`"` not "ampersand quot semicolon").
    return _htmlUnescape.convert(_openWebUiCleanText(trimmed)).trim();
  }

  /// Removes all `<details>` blocks the way OpenWebUI does outside code spans.
  static String removeAllDetails(String input) {
    if (input.isEmpty) return input;

    return _replaceMatchesOutsideCode(input, _allDetailsBlocks, (_) => '');
  }

  /// Breaks long inline code spans for better wrapping.
  static String softenInlineCode(String input, {int chunkSize = 24}) {
    if (input.length <= chunkSize) return input;

    final buffer = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      buffer.write(input[i]);
      if ((i + 1) % chunkSize == 0) {
        buffer.write('\u200B');
      }
    }
    return buffer.toString();
  }

  // ============================================================
  // Private Helpers
  // ============================================================

  static String _normalizeFenceStructure(String input) {
    var output = input;

    // Move fences after list markers to new line
    output = output.replaceAllMapped(
      _bulletFenceRegex,
      (match) => '${match[1]}\n```${match[2]}',
    );

    // Dedent opening fences
    output = output.replaceAllMapped(
      _dedentOpenRegex,
      (match) => '```${match[1]}',
    );

    // Dedent closing fences
    output = output.replaceAllMapped(_dedentCloseRegex, (_) => '```');

    // Ensure closing fences stand alone
    output = output.replaceAllMapped(
      _inlineClosingRegex,
      (match) => '${match[1]}\n```',
    );

    return output;
  }

  /// Appends a closing fence when the content leaves a fence open, so the
  /// region renders as code instead of swallowing everything after it.
  /// Split from [_normalizeFenceStructure] so the semantic-details hoister
  /// can run while the last fence is still unclosed (issue #677).
  static String _autoCloseUnmatchedFence(String input) {
    final fenceCount = _fenceAtBolRegex.allMatches(input).length;
    if (fenceCount.isOdd) {
      var output = input;
      if (!output.endsWith('\n')) output += '\n';
      return '$output```';
    }
    return input;
  }

  /// Hoists semantic `<details>` blocks out of an unclosed fenced code
  /// region (issue #677).
  ///
  /// When the model answer leaves a ``` fence open and semantic
  /// tool-call/reasoning blocks were appended after the answer, closing the
  /// fence first would swallow the blocks into a code region rendered as a
  /// raw wall. This pass runs BEFORE [_autoCloseUnmatchedFence]: it finds
  /// the last genuinely unclosed fence opener (no matching closer after it,
  /// parser pairing rule), moves every complete *semantic* block (typed
  /// tool_calls/reasoning/code_interpreter with a `<summary>` child) out of
  /// that region, closes the fence, and re-appends the blocks after it on
  /// block boundaries. Code text between hoisted blocks stays inside the
  /// fence; deliberately closed fences are never touched (the region only
  /// exists when a closer is missing), and blocks without `<summary>`
  /// (literal examples) stay verbatim.
  static String _hoistSemanticDetailsFromUnclosedFence(String input) {
    if (!input.contains('```') && !input.contains('~~~')) {
      return input;
    }
    if (!_semanticDetailsOpen.hasMatch(input)) {
      return input;
    }

    // Parser-faithful sequential fence walk. A fence-looking line OPENS a
    // code block when none is open; while a block is open, a line closes it
    // only when it uses the same character, is at least as long as the
    // opener run, and carries no info string (CommonMark). Anything else
    // inside an open block is code content, never a fence. After the walk,
    // the last opener seen while still open is the unclosed one.
    final fenceish = RegExp(r'^ {0,3}(`{3,}|~{3,})[^\n]*$', multiLine: true);
    String? openChar;
    var openLen = 0;
    var lastOpenStart = -1;
    String? lastOpenRun;
    for (final m in fenceish.allMatches(input)) {
      final run = m.group(1)!;
      final ch = run[0];
      if (openChar != null) {
        final info = input
            .substring(m.start, m.end)
            .replaceFirst(RegExp('^ {0,3}(`{3,}|~{3,})'), '');
        final closes =
            ch == openChar && run.length >= openLen && info.isEmpty;
        if (closes) {
          openChar = null;
          openLen = 0;
        }
        continue;
      }
      openChar = ch;
      openLen = run.length;
      lastOpenStart = m.start;
      lastOpenRun = run;
    }
    if (openChar == null || lastOpenStart == -1) return input;
    final lastUnclosedStart = lastOpenStart;
    final lastUnclosedRun = lastOpenRun!;

    final region = input.substring(lastUnclosedStart);
    if (!_semanticDetailsOpen.hasMatch(region)) return input;

    // Move each complete semantic block: keep code text in place, collect
    // blocks, then close the fence and re-append the blocks after it.
    final hoisted = StringBuffer();
    final kept = StringBuffer();
    var index = 0;
    var hoistedAny = false;
    while (index < region.length) {
      RegExpMatch? next;
      for (final m in _semanticDetailsFullBlock.allMatches(region)) {
        if (m.start >= index) {
          next = m;
          break;
        }
      }
      if (next == null) break;
      kept.write(region.substring(index, next.start));
      final block = region.substring(next.start, next.end);
      if (_detailsSummaryCheck.hasMatch(block)) {
        hoisted.write('\n\n$block');
        hoistedAny = true;
      } else {
        kept.write(block);
      }
      index = next.end;
    }
    if (!hoistedAny) return input;
    kept.write(region.substring(index));

    // Close the synthetic fence with the opener's own run and re-append the
    // hoisted blocks after it on block boundaries.
    final prefix = input.substring(0, lastUnclosedStart);
    var rebuilt = '$prefix${kept.toString()}\n$lastUnclosedRun';
    rebuilt = rebuilt.endsWith('\n') ? rebuilt : '$rebuilt\n';
    return '$rebuilt${hoisted.toString()}';
  }

  /// Strips a trailing semantic `<details …>` block that never closes
  /// (issue #677).
  ///
  /// A message persisted mid-stream can end after a semantic open tag
  /// without `</details>` ever arriving; the per-line parser renders the
  /// incomplete block as raw text. The streaming path already strips such
  /// tails via stripTrailingIncompleteToolCallDetailsCanonical; strip here
  /// too so saved/reloaded messages heal the same way. A tag truncated
  /// mid-attributes (no `>` at all) is handled inside
  /// [_normalizeDetailsOpenTags]'s unterminated-tag branch.
  static String _stripUnterminatedSemanticDetailsTail(String input) {
    if (input.isEmpty) return input;
    // Fast bail: nothing to strip without a `<details` marker, and the
    // heavy _semanticDetailsOpen regex must never run over adversarial
    // input with many unterminated markers ([^>]* backtracks per marker —
    // quadratic on streaming payloads; the bounded-work test covers it).
    if (!_detailsTagMarker.hasMatch(input)) return input;
    // Fast bail: with a closing tag present, only a tail AFTER the last
    // semantic open tag could be unterminated; find that marker via the
    // literal scan and verify it with the full pattern on the bounded tag.
    final lower = input.toLowerCase();
    var lastMarker = -1;
    var from = 0;
    while (true) {
      final i = lower.indexOf('<details', from);
      if (i == -1) break;
      lastMarker = i;
      from = i + 8;
    }
    if (lastMarker == -1) return input;

    // Quote-aware scan from the marker to its terminator (mirrors the
    // normalizer's scan). Bounded to the join limit.
    var pos = lastMarker;
    String? quote;
    var awaitingValue = false;
    var end = -1;
    final scanLimit = lastMarker + 256 * 1024 < input.length
        ? lastMarker + 256 * 1024
        : input.length;
    while (pos < scanLimit) {
      final ch = input[pos];
      if (quote != null) {
        if (ch == quote) quote = null;
      } else if (ch == '"' || ch == "'") {
        if (awaitingValue) {
          quote = ch;
          awaitingValue = false;
        }
      } else if (ch == '=') {
        awaitingValue = true;
      } else if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
        // keep awaitingValue across whitespace
      } else {
        awaitingValue = false;
      }
      if (quote == null && ch == '>') {
        end = pos;
        break;
      }
      pos++;
    }
    if (end == -1) {
      // Truncated tag: the normalizer's truncation branch already drops
      // semantic tails; nothing further here.
      return input;
    }

    final tag = input.substring(lastMarker, end + 1);
    if (!_semanticDetailsOpen.hasMatch(tag)) return input;

    final closing = _closingTagCaseInsensitive
        .allMatches(input, end + 1)
        .toList(growable: false);
    if (closing.isNotEmpty) return input;
    return input.substring(0, lastMarker).trimRight();
  }

  static String _separateConsecutiveLinks(String input) {
    final lines = input.split('\n');
    if (lines.length <= 1) return input;

    final buffer = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      buffer.write(line);
      if (i < lines.length - 1) buffer.write('\n');
      if (_linkWithTrailingSpaces.hasMatch(line)) buffer.write('\n');
    }
    return buffer.toString();
  }

  /// True when [input] contains a line shaped like a Markdown link reference
  /// definition.
  ///
  /// This is the exact trigger for [_stripLinkReferenceDefinitions]'s global
  /// rewrite (strip + newline collapse + trim), so the incremental streaming
  /// preparation engine gates on the same predicate: whenever this is false,
  /// normalization is guaranteed to have no non-local effects from reference
  /// definitions. A bare `contains(']:')` was previously used for both, which
  /// forced full re-preparation for any message merely mentioning `]:` (for
  /// example inside code).
  static bool hasLinkReferenceDefinitionLine(String input) =>
      input.contains(']:') && _linkReferenceDefinition.hasMatch(input);

  /// Strips Markdown link reference definitions outside code spans.
  static String _stripLinkReferenceDefinitions(String input) {
    if (!hasLinkReferenceDefinitionLine(input)) return input;

    final stripped = _replaceMatchesOutsideCode(
      input,
      _linkReferenceDefinition,
      (_) => '',
    );
    return stripped.replaceAll(_multipleNewlines, '\n\n').trim();
  }

  static String _openWebUiCleanText(String input) {
    return _openWebUiRemoveFormattings(_removeEmojis(input.trim()));
  }

  static String _replaceMatchesOutsideCode(
    String input,
    RegExp pattern,
    String Function(Match) replace,
  ) => _maskCodeAndTransform(
    input,
    (content) => content.replaceAllMapped(pattern, replace),
  );

  /// Case-insensitive `String.indexOf` for `<details` starting at [start].
  /// Returns -1 when not found.
  static int _nextDetailsMarker(String input, int start) {
    if (start >= input.length) return -1;
    for (final match in _detailsTagMarker.allMatches(input, start)) {
      return match.start;
    }
    return -1;
  }

  /// Masks code spans/fences and restores them after [transform] runs, so the
  /// transform never rewrites literal examples inside code.
  static String _maskCodeAndTransform(
    String input,
    String Function(String) transform,
  ) {
    final codeSpans = <String>[];
    var marker = '\u0000conduit-code-span-';
    while (input.contains(marker)) {
      marker = '\u0000$marker';
    }

    final masked = input.replaceAllMapped(_codeSpanOrFence, (match) {
      final index = codeSpans.length;
      codeSpans.add(match[0] ?? '');
      return '$marker$index\u0000';
    });
    final transformed = transform(masked);
    if (codeSpans.isEmpty) return transformed;
    // Restore every placeholder in one pass; a replaceAll per span rescans
    // the whole buffer K times. Placeholders inside removed matches no longer
    // exist, so only code from the retained content is restored.
    final placeholder = RegExp('${RegExp.escape(marker)}(\\d+)\u0000');
    return transformed.replaceAllMapped(placeholder, (match) {
      final index = int.parse(match[1]!);
      return index < codeSpans.length ? codeSpans[index] : match[0]!;
    });
  }

  /// Normalizes `<details ...>` opening tags in one quote-aware scan:
  ///
  /// 1. **Join** — an opening tag whose quoted attribute values contain real
  ///    newlines (legal in HTML) has no `>` on its first line, so the per-line
  ///    block parser can't see it. The scan walks from `<details` to the first
  ///    `>` *outside quotes* and folds any newlines inside the tag.
  /// 2. **Escape** — raw `<`/`>` inside quoted attribute values (e.g. an
  ///    unescaped `<br>` from a scraped tool result) would otherwise masquerade
  ///    as tag terminators and cause the block parser to truncate the attribute
  ///    list. They become `&lt;`/`&gt;`.
  ///
  /// Both steps need the same true end-of-tag (first unquoted `>`) — a regex
  /// like `<details\b[^>\n]*>` stops at the first raw `>` and would only
  /// repair part of the tag, so this runs as a single state-machine pass.
  /// Tag matching is case-insensitive to match [DetailsBlockSyntax] behavior.
  static String _normalizeDetailsOpenTags(String input) {
    if (!_detailsTagMarker.hasMatch(input)) {
      return input;
    }
    // Fast path: nothing to do when no newlines/raw angles exist anywhere.
    final hasNewlines = input.contains('\n');
    final hasRawAngles = input.contains('<') || input.contains('>');
    if (!hasNewlines && !hasRawAngles) {
      return input;
    }

    final buffer = StringBuffer();
    var copyFrom = 0;
    var searchFrom = 0;
    var scannedTotal = 0;
    var dropTrailing = false;
    while (true) {
      final idx = _nextDetailsMarker(input, searchFrom);
      if (idx == -1) break;

      buffer.write(input.substring(copyFrom, idx));

      // Quote-aware scan to this tag's true end-of-tag. A quote character
      // only opens an attribute value right after `=` (optionally with
      // whitespace between them, as HTML permits), so apostrophes and
      // quotes in prose or unquoted contexts (e.g. "It's") cannot corrupt
      // the quote state. Single- and double-quoted values are both tracked;
      // HTML attribute values have no backslash escaping.
      var pos = idx;
      String? quote;
      var awaitingValue = false;
      var end = -1;
      final scanLimit =
          idx + (hasNewlines ? _detailsOpenTagJoinLimit : 64 * 1024);
      while (pos < input.length && pos < scanLimit) {
        final ch = input[pos];
        if (quote != null) {
          if (ch == quote) quote = null;
        } else if (ch == '"' || ch == "'") {
          if (awaitingValue) {
            quote = ch;
            awaitingValue = false;
          }
        } else if (ch == '=') {
          awaitingValue = true;
        } else if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
          // Keep any pending "awaiting value" state across whitespace.
        } else {
          awaitingValue = false;
        }
        if (quote == null && ch == '>') {
          end = pos;
          break;
        } else if (quote == null &&
            ch == '\n' &&
            pos > idx + 16 * 1024 &&
            !hasNewlines) {
          // Not actually a spanning-tag context; bail out to avoid leaking an
          // unterminated `<details` string across the whole buffer.
          break;
        }
        pos++;
      }
      scannedTotal += pos - idx + 1;
      if (scannedTotal > _detailsOpenTagTotalScanBudget) {
        // Aggregate budget exhausted: stop normalizing and copy the rest
        // verbatim so pathological input degrades to linear work. Resume
        // marker discovery past this tag on the next normalize() flush.
        buffer.write(input.substring(idx));
        return buffer.toString();
      }
      if (end == -1) {
        // Unterminated tag. When the quote-aware scan reached EOF (pos past
        // the last character), the tag never terminates: a truncated
        // SEMANTIC tag (interrupted stream saved mid-open-tag) renders as
        // raw text no matter what, so drop the tail entirely (issue #677).
        // The type attribute sits near the start of a real tag; a bounded
        // window keeps this check O(1) per marker. When the scan was cut
        // short by the join limit instead, the tag may still close beyond
        // the limit — copy verbatim, never drop. Ordinary/literal
        // unterminated tags are also copied verbatim as before.
        final reachedEof = pos >= input.length;
        if (reachedEof) {
          final windowEnd =
              idx + 2048 < input.length ? idx + 2048 : input.length;
          if (_unterminatedSemanticType.hasMatch(
            input.substring(idx, windowEnd),
          )) {
            copyFrom = input.length;
            dropTrailing = true;
            break;
          }
        }
        buffer.write(input.substring(idx, idx + '<details'.length));
        searchFrom = idx + '<details'.length;
        copyFrom = searchFrom;
        continue;
      }

      final tag = input.substring(idx, end + 1);
      if (tag.contains('\n')) {
        // Join: fold the newlines so the per-line parser can match the tag.
        buffer.write(_escapeAnglesInQuotedValues(tag.replaceAll('\n', ' ')));
      } else {
        buffer.write(_escapeAnglesInQuotedValues(tag));
      }
      searchFrom = end + 1;
      copyFrom = end + 1;
    }
    buffer.write(input.substring(copyFrom));
    return dropTrailing
        ? buffer.toString().trimRight()
        : buffer.toString();
  }

  /// Drops a truncated SEMANTIC `<details` tail mid-attributes and trims
  /// trailing whitespace left behind by the drop (issue #677).

  /// Escapes raw `<`/`>` inside the quoted attribute values of a single-line
  /// `<details ...>` opening tag so the tag regex reaches the real
  /// end-of-tag instead of truncating at the first `>` (which silently drops
  /// attributes like `result`). Both single- and double-quoted values are
  /// tracked; a quote opens a value right after `=` (whitespace between them
  /// is permitted, as in HTML), so stray apostrophes cannot corrupt the
  /// state. HTML attribute values have no backslash escaping.
  static String _escapeAnglesInQuotedValues(String tag) {
    String? quote;
    var awaitingValue = false;
    var changed = false;
    final buffer = StringBuffer();
    for (var i = 0; i < tag.length; i++) {
      final ch = tag[i];
      if (quote != null) {
        if (ch == quote) quote = null;
        if (ch == '<') {
          buffer.write('&lt;');
          changed = true;
          continue;
        }
        if (ch == '>') {
          buffer.write('&gt;');
          changed = true;
          continue;
        }
      } else if (ch == '"' || ch == "'") {
        if (awaitingValue) {
          quote = ch;
          awaitingValue = false;
        }
      } else if (ch == '=') {
        awaitingValue = true;
      } else if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
        // Keep any pending "awaiting value" state across whitespace.
      } else {
        awaitingValue = false;
      }
      buffer.write(ch);
    }
    return changed ? buffer.toString() : tag;
  }

  static String _removeEmojis(String input) {
    return input.replaceAll(_emoji, '');
  }

  static String _openWebUiRemoveFormattings(String input) {
    return input
        .replaceAll(_codeBlock, '')
        .replaceAll(RegExp(r'^\|.*\|$', multiLine: true), '')
        .replaceAllMapped(RegExp(r'(?:\*\*|__)(.*?)(?:\*\*|__)'), (m) {
          return m[1] ?? '';
        })
        .replaceAllMapped(RegExp(r'(?:[*_])(.*?)(?:[*_])'), (m) {
          return m[1] ?? '';
        })
        .replaceAllMapped(_strikethrough, (m) => m[1] ?? '')
        .replaceAllMapped(_inlineCode, (m) => m[1] ?? '')
        .replaceAllMapped(
          RegExp(r'!?\[([^\]]*)\](?:\([^)]+\)|\[[^\]]*\])'),
          (m) => m[1] ?? '',
        )
        .replaceAll(RegExp(r'^\[[^\]]+\]:\s*.*$', multiLine: true), '')
        .replaceAll(_heading, '')
        .replaceAll(_listMarker, '')
        .replaceAll(RegExp(r'^\s*>[> ]*', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*:\s+', multiLine: true), '')
        .replaceAll(RegExp(r'\[\^[^\]]*\]'), '')
        .replaceAll(RegExp(r'\n{2,}'), '\n');
  }
}

/// Extension for chaining string transformations.
extension _StringTransform on String {
  String transform(String Function(String) fn) => fn(this);
}
