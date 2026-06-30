import 'semantic_message_builder.dart';
import 'structured_output.dart';

String renderStructuredOutputBlocks(List<StructuredOutputBlock> blocks) {
  return renderSemanticMessageBlocks(
    structuredOutputBlocksToSemanticMessage(blocks),
  );
}

String renderStructuredOutputBlocksWithContent(
  List<StructuredOutputBlock> blocks,
  String content,
) {
  return renderSemanticMessageBlocks(
    structuredOutputBlocksToSemanticMessage(blocks, replacementText: content),
  );
}

bool structuredOutputBlocksContainDetails(List<StructuredOutputBlock> blocks) {
  return blocks.any((block) => block is! StructuredOutputTextBlock);
}

List<SemanticMessageBlock> structuredOutputBlocksToSemanticMessage(
  List<StructuredOutputBlock> blocks, {
  String? replacementText,
}) {
  if (blocks.isEmpty && (replacementText == null || replacementText.isEmpty)) {
    return const [];
  }

  final semanticBlocks = <SemanticMessageBlock>[];
  var insertedReplacementText = false;

  for (final block in blocks) {
    switch (block) {
      case StructuredOutputTextBlock(:final text):
        if (replacementText != null) {
          if (!insertedReplacementText) {
            semanticBlocks.add(SemanticTextBlock(replacementText));
            insertedReplacementText = true;
          }
        } else {
          semanticBlocks.add(SemanticTextBlock(text));
        }
      case StructuredOutputReasoningBlock(
        :final text,
        :final done,
        :final duration,
      ):
        semanticBlocks.add(
          SemanticDetailsBlock.reasoning(
            text: text,
            done: done,
            duration: duration,
          ),
        );
      case StructuredOutputToolCallBlock(
        :final id,
        :final name,
        :final arguments,
        :final done,
        :final result,
        :final files,
        :final embeds,
      ):
        semanticBlocks.add(
          SemanticDetailsBlock.toolCall(
            id: id,
            name: name,
            arguments: arguments,
            done: done,
            result: result,
            files: files,
            embeds: embeds,
          ),
        );
      case StructuredOutputCodeInterpreterBlock(
        :final code,
        :final language,
        :final done,
        :final duration,
        :final output,
      ):
        semanticBlocks.add(
          SemanticDetailsBlock.codeInterpreter(
            code: code,
            language: language,
            done: done,
            duration: duration,
            output: output,
          ),
        );
    }
  }

  if (replacementText != null && !insertedReplacementText) {
    semanticBlocks.insert(0, SemanticTextBlock(replacementText));
  }

  return semanticBlocks;
}
