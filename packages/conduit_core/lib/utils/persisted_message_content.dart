import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/services/direct_replay_output.dart';
import 'package:conduit_markdown/conduit_markdown.dart';

/// The `content` string Conduit persists for [message] in Open WebUI chat
/// payloads and the local message rows that feed them.
///
/// Open WebUI's own web client stores `content = getOutputText(output)` (the
/// joined text of `type == 'message'` output items) and rebuilds the
/// reasoning / tool-call `<details>` presentation from `output` on load
/// (`Chat.svelte`, `structuredOutput.ts`). Conduit renders those wrappers
/// into `ChatMessage.content` locally, so persisting it verbatim leaks the
/// markup into shares, exports, and anything else that reads `content`
/// (issue #703). `conversation_parsing.dart` re-synthesizes the wrappers
/// from `output` on load, so a clean `content` plus an intact `output`
/// round-trips for display.
///
/// The content is returned untouched when it is the only representation the
/// message has:
///
/// * `output` is null or empty (older servers, Hermes, legacy shapes);
/// * `output` is Conduit's direct replay mirror, because on load the mirror
///   short-circuits the structured-output re-synthesis and the rendered
///   `content` is what the UI shows;
/// * `output` yields no message text and the content has no prose outside
///   its `<details>` wrappers.
String persistedMessageContent(ChatMessage message) {
  final content = message.content;
  if (message.role != 'assistant') return content;
  final output = message.output;
  if (output == null || output.isEmpty) return content;
  if (parseConduitDirectReplayOutput(output) != null) return content;

  final outputText = outputItemsMessageText(output);
  if (outputText.trim().isNotEmpty) return outputText;

  final stripped = stripRenderedSemanticDetails(content);
  if (stripped.trim().isNotEmpty) return stripped;
  return content;
}

/// Mirrors Open WebUI's `getOutputText`: the text of every `type == 'message'`
/// item (its `content[].text` parts concatenated), skipping blank items and
/// joining the rest with a single newline.
String outputItemsMessageText(List<dynamic> output) {
  final texts = <String>[];
  for (final item in output) {
    if (item is! Map || item['type'] != 'message') continue;
    final text = _messageItemText(item);
    if (text.trim().isEmpty) continue;
    texts.add(text);
  }
  return texts.join('\n');
}

String _messageItemText(Map<dynamic, dynamic> item) {
  final content = item['content'];
  if (content is! List) return '';
  final buffer = StringBuffer();
  for (final part in content) {
    if (part is! Map) continue;
    final text = part['text'];
    if (text == null) continue;
    buffer.write(text is String ? text : text.toString());
  }
  return buffer.toString();
}
