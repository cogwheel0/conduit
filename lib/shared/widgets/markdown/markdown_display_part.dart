import 'package:flutter/foundation.dart';

import 'compiled_markdown_document.dart';

enum MarkdownDisplayPartKind { markdownBlock, detailsBlock, detailsGroup }

@immutable
class MarkdownDisplayPart {
  const MarkdownDisplayPart({
    required this.partId,
    required this.kind,
    required this.sourceBlockIndex,
    required this.sourceBlockId,
    required this.isMutableTail,
    required this.document,
  });

  final String partId;
  final MarkdownDisplayPartKind kind;
  final int sourceBlockIndex;
  final String sourceBlockId;
  final bool isMutableTail;
  final CompiledMarkdownDocument document;

  MarkdownDisplayPart copyWith({CompiledMarkdownDocument? document}) {
    return MarkdownDisplayPart(
      partId: partId,
      kind: kind,
      sourceBlockIndex: sourceBlockIndex,
      sourceBlockId: sourceBlockId,
      isMutableTail: isMutableTail,
      document: document ?? this.document,
    );
  }
}

List<MarkdownDisplayPart> buildMarkdownDisplayParts(
  CompiledMarkdownDocument document, {
  required bool isStreaming,
}) {
  if (document.blocks.isEmpty) {
    return const <MarkdownDisplayPart>[];
  }

  final rootNodesById = <String, CompiledMarkdownNode>{
    for (final node in document.nodes)
      if (node.nodeId.isNotEmpty) node.nodeId: node,
  };
  final seenPartIds = <String, int>{};
  final parts = <MarkdownDisplayPart>[];

  for (var index = 0; index < document.blocks.length; index += 1) {
    final block = document.blocks[index];
    final nodes = _nodesForBlock(block, rootNodesById);
    final kind = _partKindForBlock(block);
    final partId = _dedupePartId(
      _basePartId(kind: kind, blockId: block.blockId, index: index),
      seenPartIds,
    );
    final isMutableTail = document.hasMutableBlockMetadata
        ? document.isMutableRootBlock(index)
        : isStreaming && index == document.blocks.length - 1;

    parts.add(
      MarkdownDisplayPart(
        partId: partId,
        kind: kind,
        sourceBlockIndex: index,
        sourceBlockId: block.blockId,
        isMutableTail: isMutableTail,
        document: _documentForBlock(
          source: document,
          block: block,
          nodes: nodes,
          isMutableTail: isMutableTail,
        ),
      ),
    );
  }

  return List<MarkdownDisplayPart>.unmodifiable(parts);
}

List<CompiledMarkdownNode> _nodesForBlock(
  CompiledMarkdownBlock block,
  Map<String, CompiledMarkdownNode> rootNodesById,
) {
  if (block is CompiledMarkdownNodeBlock) {
    return <CompiledMarkdownNode>[block.node];
  }
  if (block is CompiledMarkdownDetailsBlock) {
    final node = rootNodesById[block.blockId];
    return node == null
        ? const <CompiledMarkdownNode>[]
        : <CompiledMarkdownNode>[node];
  }
  if (block is CompiledMarkdownDetailsGroup) {
    return block.items
        .map((item) => rootNodesById[item.blockId])
        .whereType<CompiledMarkdownNode>()
        .toList(growable: false);
  }
  return const <CompiledMarkdownNode>[];
}

CompiledMarkdownDocument _documentForBlock({
  required CompiledMarkdownDocument source,
  required CompiledMarkdownBlock block,
  required List<CompiledMarkdownNode> nodes,
  required bool isMutableTail,
}) {
  return CompiledMarkdownDocument(
    normalizedContent: _normalizedContentForBlock(block, nodes),
    renderTier: MarkdownRenderTier.blocks,
    containsCitations: nodes.any(_compiledNodeContainsCitations),
    heavyBlockCount: _countHeavyBlocksInCompiledNodes(nodes),
    blocks: <CompiledMarkdownBlock>[block],
    nodes: nodes,
    blockLatexExpressions: source.blockLatexExpressions,
    inlineLatexExpressions: source.inlineLatexExpressions,
    mutableBlockStartIndex: isMutableTail ? 0 : -1,
  );
}

String _normalizedContentForBlock(
  CompiledMarkdownBlock block,
  List<CompiledMarkdownNode> nodes,
) {
  if (nodes.isNotEmpty) {
    return nodes.map((node) => node.textContent).join('\n\n');
  }
  if (block is CompiledMarkdownDetailsBlock) {
    return _normalizedContentForDetails(block);
  }
  if (block is CompiledMarkdownDetailsGroup) {
    return block.items.map(_normalizedContentForDetails).join('\n\n');
  }
  return block.blockId;
}

String _normalizedContentForDetails(CompiledMarkdownDetailsBlock block) {
  final summary = block.summaryText.trim();
  final body = block.bodyMarkdown.trim();
  if (summary.isEmpty) {
    return body;
  }
  if (body.isEmpty) {
    return summary;
  }
  return '$summary\n\n$body';
}

MarkdownDisplayPartKind _partKindForBlock(CompiledMarkdownBlock block) {
  if (block is CompiledMarkdownDetailsGroup) {
    return MarkdownDisplayPartKind.detailsGroup;
  }
  if (block is CompiledMarkdownDetailsBlock) {
    return MarkdownDisplayPartKind.detailsBlock;
  }
  return MarkdownDisplayPartKind.markdownBlock;
}

String _basePartId({
  required MarkdownDisplayPartKind kind,
  required String blockId,
  required int index,
}) {
  final stableBlockId = blockId.isEmpty ? 'index:$index' : blockId;
  return '${kind.name}:$stableBlockId';
}

String _dedupePartId(String basePartId, Map<String, int> seenPartIds) {
  final count = seenPartIds.update(
    basePartId,
    (value) => value + 1,
    ifAbsent: () => 0,
  );
  if (count == 0) {
    return basePartId;
  }
  return '$basePartId:$count';
}

bool _compiledNodeContainsCitations(CompiledMarkdownNode node) {
  if (node is CompiledMarkdownText) {
    return node.containsCitations;
  }
  if (node is! CompiledMarkdownElement) {
    return false;
  }
  return node.children.any(_compiledNodeContainsCitations);
}

int _countHeavyBlocksInCompiledNodes(List<CompiledMarkdownNode> nodes) {
  var heavyBlockCount = 0;
  for (final node in nodes) {
    heavyBlockCount += _countHeavyBlocksInCompiledNode(node);
  }
  return heavyBlockCount;
}

int _countHeavyBlocksInCompiledNode(CompiledMarkdownNode node) {
  if (node is! CompiledMarkdownElement) {
    return 0;
  }

  var count = node.isHeavyBlock ? 1 : 0;
  for (final child in node.children) {
    count += _countHeavyBlocksInCompiledNode(child);
  }
  return count;
}
