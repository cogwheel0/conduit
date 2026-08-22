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

final RegExp _semanticDetailsOpenPattern = RegExp(
  r'''<details\b(?=[^>]*\btype\s*=\s*["'](?:reasoning|tool_calls|code_interpreter|openai_builtin_tool)["'])''',
);

final RegExp _semanticDetailsBlockPattern = RegExp(
  r'''<details\b(?=[^>]*\btype\s*=\s*["'](?:reasoning|tool_calls|code_interpreter|openai_builtin_tool)["'])[\s\S]*?</details>\s*''',
);

bool containsRenderedSemanticDetails(String content) {
  if (!content.contains('<details')) {
    return false;
  }
  return _semanticDetailsOpenPattern.hasMatch(content);
}

String stripRenderedSemanticDetails(String content) {
  if (!content.contains('<details')) {
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
  if (!content.contains('<details')) {
    return content;
  }
  final match = _semanticDetailsOpenPattern.firstMatch(content);
  if (match == null) {
    return content;
  }
  return content.substring(0, match.start).trimRight();
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
