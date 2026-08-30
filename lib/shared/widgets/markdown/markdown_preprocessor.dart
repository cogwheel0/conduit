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
    r'''([^\n])(<details\b(?=[^>]*\btype\s*=\s*["']tool_calls["']))''',
    caseSensitive: false,
  );
  /// Case-insensitive `<details` marker used by the open-tag normalizer.
  static final _detailsTagMarker = RegExp(
    r'<details\b',
    caseSensitive: false,
  );
  /// Upper bound on how far a spanning `<details` open tag may be joined so a
  /// malformed tag cannot trigger an unbounded scan or a giant concatenated line.
  static const _detailsOpenTagJoinLimit = 256 * 1024;
  static final _codeSpanOrFence = RegExp(r'(`+)([\s\S]*?)\1');
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

    // Fix fence issues
    output = _normalizeFences(output);

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

  static String _normalizeFences(String input) {
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

    // Auto-close unmatched fence
    final fenceCount = _fenceAtBolRegex.allMatches(output).length;
    if (fenceCount.isOdd) {
      if (!output.endsWith('\n')) output += '\n';
      output += '```';
    }

    return output;
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
    var output = masked.replaceAllMapped(pattern, replace);

    // Placeholders inside removed matches no longer exist, so only code from
    // the retained content is restored.
    for (var index = 0; index < codeSpans.length; index++) {
      output = output.replaceAll('$marker$index\u0000', codeSpans[index]);
    }
    return output;
  }

  /// Case-insensitive `String.indexOf` for `<details` starting at [start].
  /// Returns -1 when not found.
  static int _nextDetailsMarker(String input, int start) {
    if (start >= input.length) return -1;
    for (final match in _detailsTagMarker.allMatches(input, start)) {
      return match.start;
    }
    return -1;
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
  /// Masks code spans/fences and restores them after [transform] runs, so the
  /// transform above never rewrites literal examples inside code.
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
    var output = transformed;
    for (var index = 0; index < codeSpans.length; index++) {
      output = output.replaceAll('$marker$index\u0000', codeSpans[index]);
    }
    return output;
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
    while (true) {
      final idx = _nextDetailsMarker(input, searchFrom);
      if (idx == -1) break;

      buffer.write(input.substring(copyFrom, idx));

      // Quote-aware scan to this tag's true end-of-tag.
      var pos = idx;
      var inQuote = false;
      var end = -1;
      final scanLimit =
          idx + (hasNewlines ? _detailsOpenTagJoinLimit : 64 * 1024);
      while (pos < input.length && pos < scanLimit) {
        final ch = input[pos];
        if (inQuote) {
          if (ch == '"') inQuote = false;
        } else if (ch == '"') {
          inQuote = true;
        } else if (ch == '>') {
          end = pos;
          break;
        } else if (ch == '\n' && pos > idx + 16 * 1024 && !hasNewlines) {
          // Not actually a spanning-tag context; bail out to avoid leaking an
          // unterminated `<details` string across the whole buffer.
          break;
        }
        pos++;
      }
      if (end == -1) {
        // Unterminated tag — copy verbatim and continue after the marker.
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
    return buffer.toString();
  }

  /// Escapes raw `<`/`>` inside the quoted attribute values of a single-line
  /// `<details ...>` opening tag so the tag regex reaches the real
  /// end-of-tag instead of truncating at the first `>` (which silently drops
  /// attributes like `result`). Quote state toggles on bare quotes only —
  /// HTML attribute values have no backslash escaping.
  static String _escapeAnglesInQuotedValues(String tag) {
    var inQuote = false;
    var changed = false;
    final buffer = StringBuffer();
    for (var i = 0; i < tag.length; i++) {
      final ch = tag[i];
      if (inQuote) {
        if (ch == '"') inQuote = false;
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
      } else if (ch == '"') {
        inQuote = true;
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
