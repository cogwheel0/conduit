/// Comparing two copies of one Open WebUI answer, as this device and the
/// server each hold it: which holds more, and what a stored copy shows when
/// it is read again.
library;

import 'package:conduit_markdown/conduit_markdown.dart'
    show
        comparableAssistantBody,
        containsRenderedSemanticDetails,
        serverBodyDropsLocalReasoningTiming;

import 'package:conduit_core/services/direct_replay_output.dart'
    show parseConduitDirectReplayOutput;
import 'package:conduit_core/services/structured_output.dart'
    show parseOpenWebUIStructuredOutput;
import 'package:conduit_core/services/structured_output_renderer.dart'
    show renderStructuredOutputBlocks;

/// Whether an answer's [content] and [output] hold more than another copy of
/// it ([otherContent], [otherOutput]): more text, or, with as much text, more
/// text in its reasoning and tool blocks, more output items, a block where
/// the copy has none, or the reasoning's duration the copy lacks. Text is
/// compared without those blocks, which two renders of one answer write
/// differently, and they never outweigh more text.
bool answerHoldsMoreThan(
  String content,
  List<Object?>? output,
  String otherContent,
  List<Object?>? otherOutput,
) {
  final text = comparableAssistantBody(content).length;
  final otherText = comparableAssistantBody(otherContent).length;
  if (text != otherText) return text > otherText;
  final blockText = answerBlockTextLength(content);
  final otherBlockText = answerBlockTextLength(otherContent);
  if (blockText != otherBlockText) return blockText > otherBlockText;
  final items = output?.length ?? 0;
  final otherItems = otherOutput?.length ?? 0;
  if (items != otherItems) return items > otherItems;
  return (containsRenderedSemanticDetails(content) &&
          !containsRenderedSemanticDetails(otherContent)) ||
      serverBodyDropsLocalReasoningTiming(content, otherContent);
}

final RegExp _detailsMarkup = RegExp(
  r'<details\b[^>]*>|</details>|<summary\b[^>]*>[\s\S]*?</summary>',
  caseSensitive: false,
);
final RegExp _whitespace = RegExp(r'\s+');

/// How much text [content]'s reasoning and tool blocks hold, without their
/// tags and summaries, which carry the duration and so differ between two
/// renders of one block.
int answerBlockTextLength(String content) =>
    content.replaceAll(_detailsMarkup, '').replaceAll(_whitespace, '').length -
    comparableAssistantBody(content).replaceAll(_whitespace, '').length;

/// What a stored answer with [content] and [output] shows when it is read
/// again: its output rendered, as the chat's parser and Open WebUI's web
/// client take it, or [content] when it has none.
String storedAnswerShows(String content, List<Map<String, dynamic>>? output) =>
    output == null ||
        output.isEmpty ||
        parseConduitDirectReplayOutput(output) != null
    ? content
    : renderStructuredOutputBlocks(parseOpenWebUIStructuredOutput(output));

/// Whether a stored copy of an answer ([content], [output]) shows more when
/// read again than another ([otherContent], [otherOutput]), by
/// [answerHoldsMoreThan]: each copy's output rendered with its text, so its
/// items are not counted twice.
bool storedAnswerHoldsMoreThan(
  String content,
  List<Map<String, dynamic>>? output,
  String otherContent,
  List<Map<String, dynamic>>? otherOutput,
) => answerHoldsMoreThan(
  storedAnswerShows(content, output),
  null,
  storedAnswerShows(otherContent, otherOutput),
  null,
);
