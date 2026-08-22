/// Helpers for the rendered semantic `<details>` wrappers embedded in
/// OpenWebUI-style assistant content (reasoning, tool_calls,
/// code_interpreter, openai_builtin_tool).
///
/// Local and server renders of the same turn carry different wrapper
/// attributes (for example a locally injected reasoning `duration="0"` vs
/// the server's real duration), so content comparisons must strip the
/// wrappers first or length/prefix checks are defeated on otherwise
/// identical answers. Every comparison path (streaming transport, replay
/// recovery, snapshot merges) must share these definitions: divergent copies
/// of the tag patterns have caused real rendering bugs.
library;

// HTML tag and attribute names are case-insensitive, and the text these
// patterns run over is model output, so an uppercase wrapper has to be caught
// as well: a missed opener means a reasoning body reaches the reader or the
// speaker.
final RegExp _semanticDetailsOpenPattern = RegExp(
  r'''<details\b(?=[^>]*\btype\s*=\s*["'](?:reasoning|tool_calls|code_interpreter|openai_builtin_tool)["'])''',
  caseSensitive: false,
);

final RegExp _semanticDetailsBlockPattern = RegExp(
  r'''<details\b(?=[^>]*\btype\s*=\s*["'](?:reasoning|tool_calls|code_interpreter|openai_builtin_tool)["'])[\s\S]*?</details>\s*''',
  caseSensitive: false,
);

/// Cheap reject for the common case of content with no `<details>` at all.
final RegExp _detailsTagHint = RegExp('<details', caseSensitive: false);

bool containsRenderedSemanticDetails(String content) {
  if (!_detailsTagHint.hasMatch(content)) {
    return false;
  }
  return _semanticDetailsOpenPattern.hasMatch(content);
}

String stripRenderedSemanticDetails(String content) {
  if (!_detailsTagHint.hasMatch(content)) {
    return content;
  }
  return content.replaceAll(_semanticDetailsBlockPattern, '').trim();
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
  final match = _semanticDetailsOpenPattern.firstMatch(content);
  if (match == null) {
    return content;
  }
  return content.substring(0, match.start).trimRight();
}

final RegExp _anyDetailsOpenPattern = RegExp(
  r'<details\b[^>]*>',
  caseSensitive: false,
);

final RegExp _detailsClosePattern = RegExp(
  r'</details\s*>',
  caseSensitive: false,
);

/// Removes every `<details>` block, nesting included, and truncates at a
/// semantic block that has not closed yet.
///
/// For consumers that must never surface wrapper contents at all, notably
/// text-to-speech. The pattern-based helpers above stop at the first
/// `</details>`, which is right for content comparisons but leaks the tail of
/// an outer block when a model nests one wrapper inside another:
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
    final open = _anyDetailsOpenPattern.firstMatch(content.substring(cursor));
    if (open == null) {
      kept.write(content.substring(cursor));
      break;
    }

    final openStart = cursor + open.start;
    kept.write(content.substring(cursor, openStart));
    final blockEnd = _findDetailsBlockEnd(content, cursor + open.end);
    if (blockEnd == null) {
      final isSemantic = _semanticDetailsOpenPattern.matchAsPrefix(
        content,
        openStart,
      );
      if (isSemantic != null) {
        // Still streaming, and everything after the opener belongs to the
        // wrapper. Withhold it until the close tag arrives.
        break;
      }
      kept.write(content.substring(openStart));
      break;
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
    final open = _anyDetailsOpenPattern.firstMatch(content.substring(cursor));
    final close = _detailsClosePattern.firstMatch(content.substring(cursor));
    if (close == null) {
      return null;
    }
    if (open != null && open.start < close.start) {
      depth++;
      cursor += open.end;
      continue;
    }
    depth--;
    cursor += close.end;
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

/// [isStaleServerPrefix] on details-stripped renders of the two contents.
bool serverBodyTruncatesLocal(String localContent, String serverContent) {
  return isStaleServerPrefix(
    localBody: stripRenderedSemanticDetails(localContent),
    serverBody: stripRenderedSemanticDetails(serverContent),
  );
}
