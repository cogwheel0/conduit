import 'package:html_unescape/html_unescape.dart';
import 'package:markdown/markdown.dart' as md;

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
  static final _inlineClosingRegex =
      RegExp(r'([^\r\n`])```(?=\s*(?:\r?\n|$))');
  static final _labelThenDashRegex = RegExp(
    r'^(\*\*[^\n*]+\*\*.*)\n(\s*-{3,}\s*$)',
    multiLine: true,
  );
  static final _atxEnumRegex = RegExp(
    r'^(\s{0,3}#{1,6}\s+\d+)\.(\s*)(\S)',
    multiLine: true,
  );
  static final _fenceAtBolRegex = RegExp(r'^\s*```', multiLine: true);
  static final _linkWithTrailingSpaces =
      RegExp(r'\[[^\]]+\]\([^\)]+\)\s{2,}$');
  static final _multipleNewlines = RegExp(r'\n{3,}');

  /// Combined pattern for all reasoning/thinking blocks.
  static final _reasoningBlocks = RegExp(
    r'<details\s+type="(?:reasoning|code_interpreter)"[^>]*>[\s\S]*?</details>|'
    r'<(?:think|thinking|reasoning)(?:\s[^>]*)?>[\s\S]*?</(?:think|thinking|reasoning)>',
    multiLine: true,
    dotAll: true,
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
  static final _listMarker = RegExp(r'^[\s]*(?:[-*+]|\d+\.)\s+', multiLine: true);
  static final _blockquote = RegExp(r'^>\s*', multiLine: true);
  static final _horizontalRule = RegExp(r'^[\s]*[-*_]{3,}[\s]*$', multiLine: true);
  static final _htmlTag = RegExp(r'<[^>]+>');
  /// Comprehensive emoji pattern for TTS cleanup.
  static final _emoji = RegExp(
    r'[\u{1F600}-\u{1F64F}]|'  // Emoticons
    r'[\u{1F300}-\u{1F5FF}]|'  // Misc Symbols and Pictographs
    r'[\u{1F680}-\u{1F6FF}]|'  // Transport and Map
    r'[\u{1F1E0}-\u{1F1FF}]|'  // Flags
    r'[\u{2600}-\u{26FF}]|'    // Misc symbols
    r'[\u{2700}-\u{27BF}]|'    // Dingbats
    r'[\u{1F900}-\u{1F9FF}]|'  // Supplemental Symbols
    r'[\u{1FA00}-\u{1FA6F}]|'  // Chess, cards
    r'[\u{1FA70}-\u{1FAFF}]|'  // Symbols Extended-A
    r'[\u{FE00}-\u{FE0F}]|'    // Variation Selectors
    r'[\u{1F018}-\u{1F270}]|'  // Various
    r'[\u{238C}-\u{2454}]|'    // Misc Technical
    r'[\u{20D0}-\u{20FF}]',    // Combining Diacritical Marks
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

    return output;
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
        .replaceAll(_reasoningBlocks, '')
        .replaceAll(_multipleNewlines, '\n\n')
        .trim();
  }

  /// Converts markdown to plain text for text-to-speech.
  static String toPlainText(String input) {
    if (input.trim().isEmpty) return '';

    return sanitize(input)
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

  /// Strips link reference definitions using the `markdown` package.
  static String _stripLinkReferenceDefinitions(String input) {
    if (!input.contains('[')) return input;

    final document = md.Document();
    document.parseLines(input.split('\n'));

    final refLabels = document.linkReferences.keys.toSet();
    if (refLabels.isEmpty) return input;

    final labelPatterns =
        refLabels.map((label) => RegExp.escape(label)).join('|');

    final refDefRegex = RegExp(
      r'^[ ]{0,3}\[(?:' +
          labelPatterns +
          r')\]:[ \t]*(?:<[^>]*>|[^\s]*)(?:[ \t]+(?:"[^"]*"|' +
          r"'[^']*'" +
          r'|\([^)]*\)))?[ \t]*$',
      multiLine: true,
      caseSensitive: false,
    );

    return input
        .replaceAll(refDefRegex, '')
        .replaceAll(_multipleNewlines, '\n\n')
        .trim();
  }
}

/// Extension for chaining string transformations.
extension _StringTransform on String {
  String transform(String Function(String) fn) => fn(this);
}
