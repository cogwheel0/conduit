import '../models/chat_message.dart';
import '../utils/persisted_message_content.dart';
import 'openwebui_response_stream.dart';
import 'structured_output.dart';
import 'structured_output_renderer.dart';

/// Applies the body fields returned by an Open WebUI outlet filter.
/// The output array stays authoritative, including when a filter shortens it.
ChatMessage applyOpenWebUiOutletMessage(
  ChatMessage current,
  Map<dynamic, dynamic> patch,
) {
  final rawOutput = patch['output'];
  final output = rawOutput is List
      ? mergeOpenWebUIReasoningTiming(current.output ?? const [], [
          for (final item in rawOutput)
            if (item is Map)
              <String, dynamic>{
                for (final entry in item.entries)
                  entry.key.toString(): entry.value,
              },
        ])
      : current.output;
  final rawContent = patch['content'];
  final content = output?.isNotEmpty == true
      ? renderStructuredOutputBlocks(parseOpenWebUIStructuredOutput(output!))
      : rawContent is String
      ? rawContent
      : rawOutput is List && current.output?.isNotEmpty == true
      ? outputItemsMessageText(current.output!)
      : current.content;
  final updated = current.copyWith(content: content, output: output);
  if (updated == current) return current;
  return content == current.content
      ? updated
      : updated.copyWith(
          metadata: {...?current.metadata, 'originalContent': current.content},
        );
}
