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

String structuredOutputBlocksPlainText(List<StructuredOutputBlock> blocks) {
  return blocks
      .whereType<StructuredOutputTextBlock>()
      .map((block) => block.text)
      .join();
}

List<SemanticMessageBlock> structuredOutputBlocksToSemanticMessage(
  List<StructuredOutputBlock> blocks, {
  String? replacementText,
}) {
  if (blocks.isEmpty && (replacementText == null || replacementText.isEmpty)) {
    return const [];
  }

  final semanticBlocks = <SemanticMessageBlock>[];
  final replacementTextParts = replacementText == null
      ? null
      : _replacementTextParts(blocks, replacementText);
  var replacementTextIndex = 0;

  for (final block in blocks) {
    switch (block) {
      case StructuredOutputTextBlock(:final text):
        if (replacementTextParts != null) {
          final replacementPart = replacementTextParts[replacementTextIndex++];
          if (replacementPart.isNotEmpty) {
            semanticBlocks.add(SemanticTextBlock(replacementPart));
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

  if (replacementText != null && replacementTextParts == null) {
    semanticBlocks.add(SemanticTextBlock(replacementText));
  }

  return semanticBlocks;
}

List<String>? _replacementTextParts(
  List<StructuredOutputBlock> blocks,
  String replacementText,
) {
  final textBlocks = blocks.whereType<StructuredOutputTextBlock>().toList();
  if (textBlocks.isEmpty) {
    return null;
  }
  if (textBlocks.length == 1) {
    return [replacementText];
  }

  final originalText = textBlocks.map((block) => block.text).join();
  if (originalText == replacementText) {
    return textBlocks.map((block) => block.text).toList(growable: false);
  }

  final parts = <String>[];
  var offset = 0;
  for (var index = 0; index < textBlocks.length; index += 1) {
    if (index == textBlocks.length - 1) {
      parts.add(replacementText.substring(offset));
      break;
    }
    final requestedNextOffset = offset + textBlocks[index].text.length;
    final nextOffset = requestedNextOffset > replacementText.length
        ? replacementText.length
        : requestedNextOffset;
    parts.add(replacementText.substring(offset, nextOffset));
    offset = nextOffset;
  }
  return parts;
}
