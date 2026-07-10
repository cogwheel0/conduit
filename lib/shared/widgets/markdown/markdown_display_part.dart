import 'package:flutter/foundation.dart';

import 'compiled_markdown_document.dart';

enum MarkdownDisplayPartKind { markdownBlock, detailsBlock, detailsGroup }

@immutable
class MarkdownDisplayPart {
  const MarkdownDisplayPart({
    required this.partId,
    required this.isMutableTail,
    required this.document,
  });

  final String partId;
  final bool isMutableTail;
  final CompiledMarkdownDocument document;

  MarkdownDisplayPart copyWith({CompiledMarkdownDocument? document}) {
    return MarkdownDisplayPart(
      partId: partId,
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
    final nodeResolution = _nodesForBlock(block, rootNodesById);
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
        isMutableTail: isMutableTail,
        document: _documentForBlock(
          source: document,
          block: block,
          nodeResolution: nodeResolution,
          isMutableTail: isMutableTail,
        ),
      ),
    );
  }

  return List<MarkdownDisplayPart>.unmodifiable(parts);
}

@immutable
class _BlockNodeResolution {
  const _BlockNodeResolution(this.nodes, {required this.isComplete});

  final List<CompiledMarkdownNode> nodes;
  final bool isComplete;
}

_BlockNodeResolution _nodesForBlock(
  CompiledMarkdownBlock block,
  Map<String, CompiledMarkdownNode> rootNodesById,
) {
  if (block is CompiledMarkdownNodeBlock) {
    return _BlockNodeResolution(<CompiledMarkdownNode>[
      block.node,
    ], isComplete: true);
  }
  if (block is CompiledMarkdownDetailsBlock) {
    final node = rootNodesById[block.blockId];
    return _BlockNodeResolution(
      node == null
          ? const <CompiledMarkdownNode>[]
          : <CompiledMarkdownNode>[node],
      isComplete: node != null,
    );
  }
  if (block is CompiledMarkdownDetailsGroup) {
    final nodes = <CompiledMarkdownNode>[];
    for (final item in block.items) {
      final node = rootNodesById[item.blockId];
      if (node == null) {
        return const _BlockNodeResolution(
          <CompiledMarkdownNode>[],
          isComplete: false,
        );
      }
      nodes.add(node);
    }
    return _BlockNodeResolution(
      List<CompiledMarkdownNode>.unmodifiable(nodes),
      isComplete: true,
    );
  }
  return const _BlockNodeResolution(
    <CompiledMarkdownNode>[],
    isComplete: false,
  );
}

CompiledMarkdownDocument _documentForBlock({
  required CompiledMarkdownDocument source,
  required CompiledMarkdownBlock block,
  required _BlockNodeResolution nodeResolution,
  required bool isMutableTail,
}) {
  // A details group is only node-backed when every item resolves. Mixing a
  // partial node list with the full details group silently drops unresolved
  // text and metadata, so exceptional partial documents fall back atomically
  // to the details data carried by the block.
  final nodes = nodeResolution.isComplete
      ? nodeResolution.nodes
      : const <CompiledMarkdownNode>[];
  final normalizedContent = _normalizedContentForBlock(block, nodes);

  return CompiledMarkdownDocument(
    normalizedContent: normalizedContent,
    renderTier: MarkdownRenderTier.blocks,
    containsCitations: nodeResolution.isComplete
        ? nodes.any(_compiledNodeContainsCitations)
        : source.containsCitations,
    heavyBlockCount: nodeResolution.isComplete
        ? _countHeavyBlocksInCompiledNodes(nodes)
        : source.heavyBlockCount,
    blocks: <CompiledMarkdownBlock>[block],
    nodes: nodes,
    blockLatexExpressions: _filterLatexExpressions(
      source.blockLatexExpressions,
      normalizedContent,
    ),
    inlineLatexExpressions: _filterLatexExpressions(
      source.inlineLatexExpressions,
      normalizedContent,
    ),
    mutableBlockStartIndex: isMutableTail ? 0 : -1,
  );
}

Map<String, String> _filterLatexExpressions(
  Map<String, String> expressions,
  String content,
) {
  if (expressions.isEmpty || content.isEmpty) {
    return const <String, String>{};
  }
  final filtered = <String, String>{};
  for (final entry in expressions.entries) {
    if (_containsCompletePlaceholder(content, entry.key)) {
      filtered[entry.key] = entry.value;
    }
  }
  return filtered;
}

bool _containsCompletePlaceholder(String content, String key) {
  if (key.isEmpty || content.isEmpty) {
    return false;
  }

  var searchStart = 0;
  while (searchStart <= content.length - key.length) {
    final matchStart = content.indexOf(key, searchStart);
    if (matchStart < 0) {
      return false;
    }
    final matchEnd = matchStart + key.length;
    final leadingBoundary =
        !_isPlaceholderIdentifierCodeUnit(key.codeUnitAt(0)) ||
        matchStart == 0 ||
        !_isPlaceholderIdentifierCodeUnit(content.codeUnitAt(matchStart - 1));
    final trailingBoundary =
        !_isPlaceholderIdentifierCodeUnit(key.codeUnitAt(key.length - 1)) ||
        matchEnd == content.length ||
        !_isPlaceholderIdentifierCodeUnit(content.codeUnitAt(matchEnd));
    if (leadingBoundary && trailingBoundary) {
      return true;
    }
    searchStart = matchStart + 1;
  }
  return false;
}

bool _isPlaceholderIdentifierCodeUnit(int codeUnit) {
  final isDigit = codeUnit >= 0x30 && codeUnit <= 0x39;
  final isUppercase = codeUnit >= 0x41 && codeUnit <= 0x5A;
  final isLowercase = codeUnit >= 0x61 && codeUnit <= 0x7A;
  return isDigit || isUppercase || isLowercase || codeUnit == 0x5F;
}

String _normalizedContentForBlock(
  CompiledMarkdownBlock block,
  List<CompiledMarkdownNode> nodes,
) {
  if (nodes.isNotEmpty) {
    final joined = nodes.map((node) => node.textContent).join('\n\n');
    if (joined.trim().isNotEmpty) {
      return joined;
    }
    // Nodes with no text content (e.g. a standalone image block) still need a
    // non-empty normalizedContent so ConduitMarkdownWidget.build does not
    // short-circuit on `prepared.trim().isEmpty` and drop the block before the
    // BlockRenderer can render it.
    return block.blockId;
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
  // Match `_normalizedContentForBlock`: a blank details block still needs a
  // non-empty normalizedContent so ConduitMarkdownWidget does not shrink it
  // away before the details renderer can paint the chrome.
  if (summary.isEmpty && body.isEmpty) {
    return block.blockId;
  }
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
