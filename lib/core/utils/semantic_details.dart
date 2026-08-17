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

/// [isStaleServerPrefix] on details-stripped renders of the two contents.
bool serverBodyTruncatesLocal(String localContent, String serverContent) {
  return isStaleServerPrefix(
    localBody: stripRenderedSemanticDetails(localContent),
    serverBody: stripRenderedSemanticDetails(serverContent),
  );
}
