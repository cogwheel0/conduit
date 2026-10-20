import 'tool_calls_parser.dart';
import 'reasoning_parser.dart';

/// Unified segment representing ordered pieces of a message:
/// - `text`: plain text/markdown to render
/// - `toolCall`: a parsed tool call entry to render as a tile
/// - `reasoning`: a parsed reasoning entry to render as a tile
class MessageSegment {
  final String? text;
  final ToolCallEntry? toolCall;
  final ReasoningEntry? reasoning;

  const MessageSegment._({this.text, this.toolCall, this.reasoning});

  factory MessageSegment.text(String text) => MessageSegment._(text: text);
  factory MessageSegment.tool(ToolCallEntry tool) =>
      MessageSegment._(toolCall: tool);
  factory MessageSegment.reason(ReasoningEntry entry) =>
      MessageSegment._(reasoning: entry);

  bool get isText => text != null;
  bool get isTool => toolCall != null;
  bool get isReasoning => reasoning != null;
}
