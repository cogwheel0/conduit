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
  });

  final int start;
  final int end;
  final Map<String, String> attributes;

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
  );
}

/// The next `<details` opener at or after [from], semantic or not.
_DetailsOpener? _nextDetailsOpener(String content, int from) {
  var cursor = from;
  while (true) {
    final match = _detailsTagHint.matchAsPrefix(content, cursor) == null
        ? content.toLowerCase().indexOf('<details', cursor)
        : cursor;
    if (match == -1) return null;
    final opener = _parseDetailsOpener(content, match);
    if (opener != null) return opener;
    cursor = match + 1;
  }
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
