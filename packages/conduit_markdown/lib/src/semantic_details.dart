/// Helpers for the rendered semantic `<details>` wrappers embedded in
/// OpenWebUI-style assistant content (reasoning, tool_calls,
/// code_interpreter, openai_builtin_tool).
///
/// Local and server renders of the same turn carry different wrapper
/// attributes (for example a locally measured reasoning duration vs the
/// server's own, or none at all), so content comparisons must strip the
/// wrappers first or length/prefix checks are defeated on otherwise
/// identical answers. Every comparison path (streaming transport, replay
/// recovery, snapshot merges) must share these definitions: divergent copies
/// of the tag patterns have caused real rendering bugs.
///
/// Opening tags are parsed with a quote-aware attribute scanner rather than
/// regular expressions over the raw tag text. The text is model output, so a
/// value such as `title=' type="reasoning"'` must not turn an ordinary
/// `<details>` into a semantic wrapper that these helpers would strip.
library;

const Set<String> _semanticDetailsTypes = {
  'reasoning',
  'tool_calls',
  'code_interpreter',
  'openai_builtin_tool',
};

/// Cheap reject for the common case of content with no `<details>` at all.
final RegExp _detailsTagHint = RegExp('<details', caseSensitive: false);

final RegExp _detailsClosePattern = RegExp(
  r'</details\s*>',
  caseSensitive: false,
);

/// One parsed `<details ...>` opening tag.
///
/// [end] is the index just past the closing `>`; for an opener that is still
/// streaming (no `>` yet) it is the content length, and [attributes] holds
/// whatever was parsed so far.
final class _DetailsOpener {
  const _DetailsOpener({
    required this.start,
    required this.end,
    required this.attributes,
    required this.closed,
  });

  final int start;
  final int end;
  final Map<String, String> attributes;

  /// Whether the scan reached the tag's unquoted `>`. False means the tag is
  /// still open at the end of the content (streaming or truncated).
  final bool closed;

  bool get isSemantic =>
      _semanticDetailsTypes.contains(attributes['type']?.toLowerCase());

  bool get isReasoning => attributes['type']?.toLowerCase() == 'reasoning';

  bool get hasDuration => (attributes['duration'] ?? '').trim().isNotEmpty;
}

bool _isNameBoundary(int unit) =>
    unit == 0x20 ||
    unit == 0x09 ||
    unit == 0x0A ||
    unit == 0x0D ||
    unit == 0x2F ||
    unit == 0x3E;

bool _isWhitespace(int unit) =>
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D;

/// Parses the `<details` opener starting at [start], or null when the text
/// there is not a `<details` tag (for example `<detailsx`).
_DetailsOpener? _parseDetailsOpener(String content, int start) {
  const tag = '<details';
  if (start + tag.length > content.length) return null;
  if (content.substring(start, start + tag.length).toLowerCase() != tag) {
    return null;
  }
  var cursor = start + tag.length;
  if (cursor < content.length && !_isNameBoundary(content.codeUnitAt(cursor))) {
    return null;
  }
  final attributes = <String, String>{};
  while (cursor < content.length) {
    final unit = content.codeUnitAt(cursor);
    if (unit == 0x3E) {
      return _DetailsOpener(
        start: start,
        end: cursor + 1,
        attributes: attributes,
        closed: true,
      );
    }
    if (_isWhitespace(unit) || unit == 0x2F) {
      cursor++;
      continue;
    }
    // Attribute name.
    final nameStart = cursor;
    while (cursor < content.length) {
      final u = content.codeUnitAt(cursor);
      if (_isWhitespace(u) || u == 0x3D || u == 0x3E || u == 0x2F) break;
      cursor++;
    }
    final name = content.substring(nameStart, cursor).toLowerCase();
    while (cursor < content.length &&
        _isWhitespace(content.codeUnitAt(cursor))) {
      cursor++;
    }
    if (cursor >= content.length || content.codeUnitAt(cursor) != 0x3D) {
      if (name.isNotEmpty) attributes.putIfAbsent(name, () => '');
      continue;
    }
    cursor++; // '='
    while (cursor < content.length &&
        _isWhitespace(content.codeUnitAt(cursor))) {
      cursor++;
    }
    if (cursor >= content.length) {
      if (name.isNotEmpty) attributes.putIfAbsent(name, () => '');
      break;
    }
    final quote = content.codeUnitAt(cursor);
    String value;
    if (quote == 0x22 || quote == 0x27) {
      final close = content.indexOf(String.fromCharCode(quote), cursor + 1);
      if (close == -1) {
        // Unterminated quoted value: still streaming. Take what is there.
        value = content.substring(cursor + 1);
        cursor = content.length;
      } else {
        value = content.substring(cursor + 1, close);
        cursor = close + 1;
      }
    } else {
      final valueStart = cursor;
      while (cursor < content.length) {
        final u = content.codeUnitAt(cursor);
        if (_isWhitespace(u) || u == 0x3E) break;
        cursor++;
      }
      value = content.substring(valueStart, cursor);
    }
    if (name.isNotEmpty) attributes.putIfAbsent(name, () => value);
  }
  return _DetailsOpener(
    start: start,
    end: content.length,
    attributes: attributes,
    closed: false,
  );
}

/// The next `<details` opener at or after [from], semantic or not.
_DetailsOpener? _nextDetailsOpener(String content, int from) {
  // Lazily walk the case-insensitive hint so each call costs only the distance
  // to the next candidate (lower-casing the whole content per call made
  // callers that visit every opener quadratic).
  for (final match in _detailsTagHint.allMatches(content, from)) {
    final opener = _parseDetailsOpener(content, match.start);
    if (opener != null) return opener;
  }
  return null;
}

/// The next semantic `<details` opener at or after [from].
_DetailsOpener? _nextSemanticDetailsOpener(String content, int from) {
  var cursor = from;
  while (true) {
    final opener = _nextDetailsOpener(content, cursor);
    if (opener == null) return null;
    if (opener.isSemantic) return opener;
    cursor = opener.end;
  }
}

bool containsRenderedSemanticDetails(String content) {
  if (!_detailsTagHint.hasMatch(content)) {
    return false;
  }
  return _nextSemanticDetailsOpener(content, 0) != null;
}

/// Removes every complete semantic `<details>` block (up to its first
/// `</details>`) together with the whitespace that follows it.
String stripRenderedSemanticDetails(String content) {
  if (!_detailsTagHint.hasMatch(content)) {
    return content;
  }
  final kept = StringBuffer();
  var cursor = 0;
  while (cursor < content.length) {
    final opener = _nextSemanticDetailsOpener(content, cursor);
    if (opener == null) break;
    final close = _detailsClosePattern.firstMatch(
      content.substring(opener.end),
    );
    if (close == null) {
      // Still open; not a complete block, leave it in place.
      kept.write(content.substring(cursor, opener.end));
      cursor = opener.end;
      continue;
    }
    kept.write(content.substring(cursor, opener.start));
    cursor = opener.end + close.end;
    while (cursor < content.length &&
        _isWhitespace(content.codeUnitAt(cursor))) {
      cursor++;
    }
  }
  if (cursor < content.length) kept.write(content.substring(cursor));
  return kept.toString().trim();
}

/// Drops the tail starting at a semantic `<details>` opener that has no
/// closing tag yet.
///
/// Mid-stream the wrapper stays open for many frames, so
/// [stripRenderedSemanticDetails] — which only matches complete blocks —
/// leaves the reasoning or tool-call body exposed. Consumers that surface
/// partial content (notably text-to-speech) must withhold everything from the
/// opener onwards until `</details>` lands and the block can be stripped
/// outright.
///
/// Run this *after* stripping complete blocks; on unstripped content the opener
/// of an already-closed block would truncate the answer that follows it.
String dropUnterminatedSemanticDetails(String content) {
  if (!_detailsTagHint.hasMatch(content)) {
    return content;
  }
  final opener = _nextSemanticDetailsOpener(content, 0);
  if (opener == null) {
    return content;
  }
  return content.substring(0, opener.start).trimRight();
}

/// Drops a trailing semantic `<details` opening tag whose `>` never arrived.
///
/// A stream interrupted mid-attributes (or a message saved at that moment)
/// ends inside the opening tag. The block parser can never match it, so the
/// partial tag would render as raw text. Only the final line is considered,
/// the opener must start that line, and its `type` must be exactly one of the
/// semantic wrapper types, so prose that merely mentions `<details` keeps
/// every character. Callers must mask code first: this does not know about
/// code spans or fences.
String dropTruncatedSemanticDetailsOpener(String content) {
  if (!_detailsTagHint.hasMatch(content)) {
    return content;
  }
  var cursor = 0;
  while (true) {
    final opener = _nextDetailsOpener(content, cursor);
    if (opener == null) return content;
    if (opener.closed) {
      cursor = opener.end;
      continue;
    }
    // An opener without its `>` consumes the rest of the content, so this is
    // the trailing tag. Leave it unless it is a whole-line semantic opener on
    // the final line.
    final lineStart = opener.start == 0
        ? 0
        : content.lastIndexOf('\n', opener.start - 1) + 1;
    final indent = content.substring(lineStart, opener.start);
    if (indent.length > 3 || indent.trim().isNotEmpty) return content;
    if (content.contains('\n', opener.start)) return content;
    if (!opener.isSemantic) return content;
    return content.substring(0, opener.start).trimRight();
  }
}

/// Semantic wrapper types Open WebUI's message renderer turns into reasoning,
/// tool-call, and code-interpreter sections.
const Set<String> _openWebUiMessageDetailsTypes = {
  'reasoning',
  'tool_calls',
  'code_interpreter',
};

/// A `<details` tag name on one line: followed by whitespace, `/`, `>`, or
/// the end of the line (the preprocessor joins such a tag with the next line).
final RegExp _detailsMarkerOnLine = RegExp(
  r'<details(?=[\s/>]|$)',
  caseSensitive: false,
);
final RegExp _detailsCloseMarker = RegExp('</details', caseSensitive: false);
final RegExp _detailsCloseLine = RegExp(
  r'^[ \t]*</details>[ \t]*$',
  caseSensitive: false,
);

/// The opening tag [DetailsBlockSyntax] counts, anchored to one whole tag.
final RegExp _rendererOpeningTag = RegExp(
  r'^<details(?:\s+[^>]*)?>$',
  caseSensitive: false,
);

/// [DetailsBlockSyntax]'s attribute pattern; its map keeps the last match.
final RegExp _rendererAttribute = RegExp(r'(\w+)="(.*?)"');

const int _detailsLineText = 0;
const int _detailsLineOpen = 1;
const int _detailsLineSemanticOpen = 2;
const int _detailsLineClose = 3;
const int _detailsLineInvalid = 4;

/// Classifies one line (without its terminator) for
/// [matchWellFormedSemanticDetailsBlocks].
int _classifyDetailsLine(String line) {
  if (!line.contains('<')) return _detailsLineText;
  final hasClose = _detailsCloseMarker.hasMatch(line);
  final openMarkers = _detailsMarkerOnLine.allMatches(line).length;
  if (!hasClose && openMarkers == 0) return _detailsLineText;
  if (hasClose) {
    return openMarkers == 0 && _detailsCloseLine.hasMatch(line)
        ? _detailsLineClose
        : _detailsLineInvalid;
  }
  if (openMarkers != 1) return _detailsLineInvalid;

  final tagStart = line.length - line.trimLeft().length;
  final opener = _parseDetailsOpener(line, tagStart);
  if (opener == null || !opener.closed) return _detailsLineInvalid;
  final tag = line.substring(opener.start, opener.end);
  final rest = line.substring(opener.end);
  // One unambiguous tag alone on its line: no `<`/`>` inside it, so the
  // renderer's per-line counting, the preprocessor's quoted-value escaping,
  // and this scanner all agree on where it ends.
  if (tag.indexOf('<', 1) != -1 ||
      tag.indexOf('>') != tag.length - 1 ||
      !_rendererOpeningTag.hasMatch(tag) ||
      rest.trim().isNotEmpty) {
    return _detailsLineInvalid;
  }

  final type = opener.attributes['type'];
  String? rendererType;
  for (final match in _rendererAttribute.allMatches(tag)) {
    if (match.group(1) == 'type') rendererType = match.group(2);
  }
  // Open WebUI's tokenizer requires the tag at column 0 followed directly by
  // a newline.
  final isSemanticOpener =
      tagStart == 0 &&
      rest.isEmpty &&
      type != null &&
      _openWebUiMessageDetailsTypes.contains(type) &&
      rendererType == type;
  return isSemanticOpener ? _detailsLineSemanticOpen : _detailsLineOpen;
}

/// Maps each line that opens a complete, well-formed semantic `<details>`
/// block (reasoning, tool_calls, or code_interpreter) to the line that closes
/// it.
///
/// Open WebUI renders these blocks from assistant message text, so a pipe or
/// server can emit them there. Only a strict shape qualifies, so every
/// consumer agrees on where the block ends:
///
/// * the opener sits at column 0, alone on its line, with an exact `type`
///   that the quote-aware scanner and the renderer's attribute pattern both
///   read the same way;
/// * every nested opener and every `</details>` sits alone on its own line,
///   and no tag contains a raw `<` or `>`;
/// * the block closes with balanced nesting before the end of [lines];
/// * no generic `<details>` wrapper encloses it.
///
/// Any other line inside the span that mentions a details tag rejects the
/// block. [lines] must not contain line terminators. This does not know
/// about code; callers must reject blocks that start inside code.
Map<int, int> matchWellFormedSemanticDetailsBlocks(List<String> lines) {
  final blocks = <int, int>{};
  final open = <int>[];
  final semanticStarts = <int>{};
  // Generic wrappers still open. Their tags are escaped, so a semantic block
  // inside one would otherwise surface on its own, out of its wrapper.
  var genericOpen = 0;
  final invalidBefore = List<int>.filled(lines.length + 1, 0);
  for (var index = 0; index < lines.length; index++) {
    final kind = _classifyDetailsLine(lines[index]);
    invalidBefore[index + 1] =
        invalidBefore[index] + (kind == _detailsLineInvalid ? 1 : 0);
    switch (kind) {
      case _detailsLineSemanticOpen:
        semanticStarts.add(index);
        open.add(index);
      case _detailsLineOpen:
        open.add(index);
        genericOpen += 1;
      case _detailsLineClose:
        if (open.isEmpty) break;
        final start = open.removeLast();
        if (!semanticStarts.contains(start)) {
          genericOpen -= 1;
        } else if (genericOpen == 0 &&
            invalidBefore[index + 1] == invalidBefore[start]) {
          blocks[start] = index;
        }
    }
  }
  return blocks;
}

/// Removes every `<details>` block, nesting included, and truncates at a
/// semantic block that has not closed yet.
///
/// For consumers that must never surface wrapper contents at all, notably
/// text-to-speech. The helpers above stop at the first `</details>`, which is
/// right for content comparisons but leaks the tail of an outer block when a
/// model nests one wrapper inside another:
/// `<details><details>x</details>leaked</details>` would keep `leaked`.
///
/// An unterminated block is only cut when it is one of the semantic wrappers,
/// matching [dropUnterminatedSemanticDetails]: an ordinary `<details>` still
/// waiting for its close tag is left alone rather than silencing the rest of
/// the answer.
String stripDetailsForSpeech(String content) {
  if (!_detailsTagHint.hasMatch(content)) {
    return content;
  }

  final kept = StringBuffer();
  var cursor = 0;
  while (cursor < content.length) {
    final open = _nextDetailsOpener(content, cursor);
    if (open == null) {
      kept.write(content.substring(cursor));
      break;
    }

    kept.write(content.substring(cursor, open.start));
    final blockEnd = _findDetailsBlockEnd(content, open.end);
    if (blockEnd == null) {
      if (open.isSemantic) {
        // Still streaming, and everything after the opener belongs to the
        // wrapper. Withhold it until the close tag arrives.
        break;
      }
      // An ordinary wrapper waiting for its close tag is no reason to silence
      // the answer, but a wrapper nested inside it still has to be handled, so
      // keep the tag and carry on from just past it.
      kept.write(content.substring(open.start, open.end));
      cursor = open.end;
      continue;
    }
    cursor = blockEnd;
  }

  return kept.toString().trim();
}

/// The index just past the `</details>` that closes the block opened before
/// [searchFrom], or null when the block is still open.
int? _findDetailsBlockEnd(String content, int searchFrom) {
  var depth = 1;
  var cursor = searchFrom;
  while (cursor < content.length) {
    final open = _nextDetailsOpener(content, cursor);
    final close = _detailsClosePattern.firstMatch(content.substring(cursor));
    if (close == null) {
      return null;
    }
    final closeStart = cursor + close.start;
    if (open != null && open.start < closeStart) {
      depth++;
      cursor = open.end;
      continue;
    }
    depth--;
    cursor = cursor + close.end;
    if (depth == 0) {
      return cursor;
    }
  }
  return null;
}

/// True when [serverBody] is a strict prefix of [localBody] — a stale or
/// mid-write server frame that must not truncate content already streamed.
/// Callers pass comparable bodies (usually already details-stripped).
bool isStaleServerPrefix({
  required String localBody,
  required String serverBody,
}) {
  return serverBody.length < localBody.length &&
      localBody.startsWith(serverBody);
}

/// The message body with rendered semantic `<details>` blocks removed and
/// trimmed, for content comparisons between local and server renders of the
/// same turn.
String comparableAssistantBody(String content) =>
    stripRenderedSemanticDetails(content).trim();

bool serverBodyDropsLocalSemanticDetails(
  String localContent,
  String serverContent,
) {
  return containsRenderedSemanticDetails(localContent) &&
      !containsRenderedSemanticDetails(serverContent) &&
      comparableAssistantBody(localContent) ==
          comparableAssistantBody(serverContent);
}

bool _hasReasoningOpener(String content, {required bool withDuration}) {
  if (!_detailsTagHint.hasMatch(content)) return false;
  var cursor = 0;
  while (true) {
    final opener = _nextDetailsOpener(content, cursor);
    if (opener == null) return false;
    if (opener.isReasoning && (!withDuration || opener.hasDuration)) {
      return true;
    }
    cursor = opener.end;
  }
}

/// True when the server's render of the same answer carries a reasoning block
/// without a duration while the local render has one. Responses-API providers
/// never tell the server how long a model thought, so the client's own
/// measurement is the only timing that exists; an otherwise identical server
/// copy must not replace it and downgrade "Thought for N seconds" to a
/// timeless label.
bool serverBodyDropsLocalReasoningTiming(
  String localContent,
  String serverContent,
) {
  if (!_hasReasoningOpener(localContent, withDuration: true)) {
    return false;
  }
  if (_hasReasoningOpener(serverContent, withDuration: true)) {
    return false;
  }
  if (!_hasReasoningOpener(serverContent, withDuration: false)) {
    // The server dropped the block entirely; that case is handled by
    // serverBodyDropsLocalSemanticDetails.
    return false;
  }
  return comparableAssistantBody(localContent) ==
      comparableAssistantBody(serverContent);
}

/// [isStaleServerPrefix] on details-stripped renders of the two contents.
bool serverBodyTruncatesLocal(String localContent, String serverContent) {
  return isStaleServerPrefix(
    localBody: stripRenderedSemanticDetails(localContent),
    serverBody: stripRenderedSemanticDetails(serverContent),
  );
}
