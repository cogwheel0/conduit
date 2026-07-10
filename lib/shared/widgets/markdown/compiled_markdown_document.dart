import 'package:flutter/foundation.dart';

import 'renderer/latex_preprocessor.dart';

enum MarkdownRenderTier { plainText, richText, blocks }

enum CompiledMarkdownBlockKind { none, code, mermaid, chartJs, previewableCode }

enum CompiledMarkdownDetailsKind {
  generic,
  reasoning,
  codeInterpreter,
  toolCall,
}

enum CompiledMarkdownNodeBlockKind {
  text,
  paragraph,
  heading1,
  heading2,
  heading3,
  heading4,
  heading5,
  heading6,
  codeBlock,
  blockquote,
  unorderedList,
  orderedList,
  listItem,
  table,
  horizontalRule,
  div,
  section,
  details,
  image,
  fallback,
}

@immutable
class CompiledMarkdownDocument {
  CompiledMarkdownDocument({
    required this.normalizedContent,
    required this.renderTier,
    required this.containsCitations,
    required this.heavyBlockCount,
    required List<CompiledMarkdownBlock> blocks,
    required List<CompiledMarkdownNode> nodes,
    required Map<String, String> blockLatexExpressions,
    required Map<String, String> inlineLatexExpressions,
    this.mutableBlockStartIndex = -1,
  }) : blocks = List<CompiledMarkdownBlock>.unmodifiable(blocks),
       nodes = List<CompiledMarkdownNode>.unmodifiable(nodes),
       blockLatexExpressions = Map<String, String>.unmodifiable(
         blockLatexExpressions,
       ),
       inlineLatexExpressions = Map<String, String>.unmodifiable(
         inlineLatexExpressions,
       );

  const CompiledMarkdownDocument.empty()
    : normalizedContent = '',
      renderTier = MarkdownRenderTier.plainText,
      containsCitations = false,
      heavyBlockCount = 0,
      blocks = const <CompiledMarkdownBlock>[],
      nodes = const <CompiledMarkdownNode>[],
      blockLatexExpressions = const <String, String>{},
      inlineLatexExpressions = const <String, String>{},
      mutableBlockStartIndex = -1;

  final String normalizedContent;
  final MarkdownRenderTier renderTier;
  final bool containsCitations;
  final int heavyBlockCount;
  final List<CompiledMarkdownBlock> blocks;
  final List<CompiledMarkdownNode> nodes;
  final Map<String, String> blockLatexExpressions;
  final Map<String, String> inlineLatexExpressions;

  /// Index of the first root block that may still be replaced by streaming.
  ///
  /// A negative value means the document has no mutable-tail metadata. When
  /// segments are combined, [compose] rebases this boundary to the composed
  /// block list so every block at or after it remains mutable.
  final int mutableBlockStartIndex;

  bool get isEmpty =>
      normalizedContent.trim().isEmpty || (nodes.isEmpty && blocks.isEmpty);

  bool get hasHeavyBlocks => heavyBlockCount > 0;

  bool get hasLatex =>
      blockLatexExpressions.isNotEmpty || inlineLatexExpressions.isNotEmpty;

  int get rootNodeCount => nodes.length;

  int get rootBlockCount => blocks.length;

  bool get hasMutableBlockMetadata =>
      mutableBlockStartIndex >= 0 && mutableBlockStartIndex < blocks.length;

  /// Whether [index] lies on or after the streaming mutation boundary.
  bool isMutableRootBlock(int index) {
    if (!hasMutableBlockMetadata) {
      return false;
    }
    return index >= mutableBlockStartIndex && index < blocks.length;
  }

  int get estimatedWeight {
    final blockWeight = blocks.fold<int>(0, (sum, block) => sum + block.weight);
    final nodeWeight = nodes.fold<int>(0, (sum, node) => sum + node.weight);
    final latexWeight =
        blockLatexExpressions.values.fold<int>(
          0,
          (sum, value) => sum + value.length,
        ) +
        inlineLatexExpressions.values.fold<int>(
          0,
          (sum, value) => sum + value.length,
        );
    return normalizedContent.length + blockWeight + nodeWeight + latexWeight;
  }

  LatexPreprocessor buildLatexPreprocessor() =>
      LatexPreprocessor.fromExpressions(
        blockLatexExpressions,
        inlineLatexExpressions,
      );

  CompiledMarkdownDocument rebaseRootIds({required int rootNodeOffset}) {
    if (rootNodeOffset == 0 || nodes.isEmpty) {
      return this;
    }

    final rebasedRootNodes = <CompiledMarkdownNode>[];
    final rebasedRootNodesByOldId = <String, CompiledMarkdownNode>{};
    for (final node in nodes) {
      final rebasedNode = _rebaseCompiledMarkdownNode(node, rootNodeOffset);
      rebasedRootNodes.add(rebasedNode);
      if (node.nodeId.isNotEmpty) {
        rebasedRootNodesByOldId[node.nodeId] = rebasedNode;
      }
    }

    return CompiledMarkdownDocument(
      normalizedContent: normalizedContent,
      renderTier: renderTier,
      containsCitations: containsCitations,
      heavyBlockCount: heavyBlockCount,
      blocks: blocks
          .map(
            (block) => _rebaseCompiledMarkdownBlock(
              block,
              rootNodeOffset,
              rebasedRootNodesByOldId,
            ),
          )
          .toList(growable: false),
      nodes: rebasedRootNodes,
      blockLatexExpressions: blockLatexExpressions,
      inlineLatexExpressions: inlineLatexExpressions,
      mutableBlockStartIndex: mutableBlockStartIndex,
    );
  }

  static CompiledMarkdownDocument compose({
    required String normalizedContent,
    required Iterable<CompiledMarkdownDocument> segments,
    int mutableBlockStartIndex = -1,
  }) {
    final segmentList = segments
        .where((segment) => !segment.isEmpty)
        .toList(growable: false);
    if (segmentList.isEmpty) {
      return normalizedContent.trim().isEmpty
          ? const CompiledMarkdownDocument.empty()
          : CompiledMarkdownDocument(
              normalizedContent: normalizedContent,
              renderTier: MarkdownRenderTier.plainText,
              containsCitations: false,
              heavyBlockCount: 0,
              blocks: const <CompiledMarkdownBlock>[],
              nodes: const <CompiledMarkdownNode>[],
              blockLatexExpressions: const <String, String>{},
              inlineLatexExpressions: const <String, String>{},
              mutableBlockStartIndex: mutableBlockStartIndex,
            );
    }
    if (segmentList.length == 1) {
      final segment = segmentList.single;
      if (segment.normalizedContent == normalizedContent &&
          segment.mutableBlockStartIndex == mutableBlockStartIndex) {
        return segment;
      }
      return CompiledMarkdownDocument(
        normalizedContent: normalizedContent,
        renderTier: segment.renderTier,
        containsCitations: segment.containsCitations,
        heavyBlockCount: segment.heavyBlockCount,
        blocks: segment.blocks,
        nodes: segment.nodes,
        blockLatexExpressions: segment.blockLatexExpressions,
        inlineLatexExpressions: segment.inlineLatexExpressions,
        mutableBlockStartIndex: mutableBlockStartIndex,
      );
    }

    final nodes = <CompiledMarkdownNode>[];
    final blocks = <CompiledMarkdownBlock>[];
    var containsCitations = false;
    var heavyBlockCount = 0;
    final blockLatexExpressions = <String, String>{};
    final inlineLatexExpressions = <String, String>{};

    // `mutableBlockStartIndex` is supplied as a block index into the naive
    // concatenation of the segments. _appendComposedCompiledMarkdownBlock can
    // merge a groupable tool_calls block into the previous block — collapsing
    // the boundary between the frozen prefix and the mutable tail — which
    // shifts composed indices. Recompute the effective index from the composed
    // list so the mutable tail block keeps its streaming-fade classification.
    final tracksMutableTail = mutableBlockStartIndex >= 0;
    var naiveBlockIndex = 0;
    var effectiveMutableBlockStartIndex = mutableBlockStartIndex;

    for (final segment in segmentList) {
      nodes.addAll(segment.nodes);
      for (final block in segment.blocks) {
        final blockCountBeforeAppend = blocks.length;
        _appendComposedCompiledMarkdownBlock(blocks, block);
        if (tracksMutableTail && naiveBlockIndex == mutableBlockStartIndex) {
          // First block of the mutable tail. If it merged into the preceding
          // (frozen) block, that merged block is the mutable boundary;
          // otherwise it sits at its freshly appended position.
          final merged = blocks.length == blockCountBeforeAppend;
          effectiveMutableBlockStartIndex = merged
              ? blockCountBeforeAppend - 1
              : blockCountBeforeAppend;
        }
        naiveBlockIndex += 1;
      }
      containsCitations = containsCitations || segment.containsCitations;
      heavyBlockCount += segment.heavyBlockCount;
      _mergeLatexExpressions(
        blockLatexExpressions,
        segment.blockLatexExpressions,
      );
      _mergeLatexExpressions(
        inlineLatexExpressions,
        segment.inlineLatexExpressions,
      );
    }

    return CompiledMarkdownDocument(
      normalizedContent: normalizedContent,
      renderTier: MarkdownRenderTier.blocks,
      containsCitations: containsCitations,
      heavyBlockCount: heavyBlockCount,
      blocks: blocks,
      nodes: nodes,
      blockLatexExpressions: blockLatexExpressions,
      inlineLatexExpressions: inlineLatexExpressions,
      mutableBlockStartIndex: effectiveMutableBlockStartIndex,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'normalizedContent': normalizedContent,
    'renderTier': renderTier.name,
    'containsCitations': containsCitations,
    'heavyBlockCount': heavyBlockCount,
    'blocks': blocks.map((block) => block.toMap()).toList(growable: false),
    'nodes': nodes.map((node) => node.toMap()).toList(growable: false),
    'blockLatexExpressions': blockLatexExpressions,
    'inlineLatexExpressions': inlineLatexExpressions,
    'mutableBlockStartIndex': mutableBlockStartIndex,
  };

  factory CompiledMarkdownDocument.fromMap(Map<String, Object?> map) {
    final nodes = (map['nodes'] as List<dynamic>? ?? const <dynamic>[])
        .cast<Map<Object?, Object?>>()
        .map(
          (entry) =>
              CompiledMarkdownNode.fromMap(entry.cast<String, Object?>()),
        )
        .toList(growable: false);
    final blocks = (map['blocks'] as List<dynamic>? ?? const <dynamic>[])
        .cast<Map<Object?, Object?>>()
        .map(
          (entry) =>
              CompiledMarkdownBlock.fromMap(entry.cast<String, Object?>()),
        )
        .toList(growable: false);
    final blockLatex =
        (map['blockLatexExpressions'] as Map<Object?, Object?>? ??
                const <Object?, Object?>{})
            .map(
              (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
            );
    final inlineLatex =
        (map['inlineLatexExpressions'] as Map<Object?, Object?>? ??
                const <Object?, Object?>{})
            .map(
              (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
            );
    return CompiledMarkdownDocument(
      normalizedContent: (map['normalizedContent'] ?? '') as String,
      renderTier: _renderTierFromName((map['renderTier'] ?? '') as String),
      containsCitations: (map['containsCitations'] ?? false) as bool,
      heavyBlockCount: (map['heavyBlockCount'] ?? 0) as int,
      blocks: blocks.isEmpty ? _fallbackBlocksFromNodes(nodes) : blocks,
      nodes: nodes,
      blockLatexExpressions: blockLatex,
      inlineLatexExpressions: inlineLatex,
      mutableBlockStartIndex:
          (map['mutableBlockStartIndex'] as num?)?.toInt() ?? -1,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is CompiledMarkdownDocument &&
        other.normalizedContent == normalizedContent &&
        other.renderTier == renderTier &&
        other.containsCitations == containsCitations &&
        other.heavyBlockCount == heavyBlockCount &&
        listEquals(other.blocks, blocks) &&
        listEquals(other.nodes, nodes) &&
        mapEquals(other.blockLatexExpressions, blockLatexExpressions) &&
        mapEquals(other.inlineLatexExpressions, inlineLatexExpressions) &&
        other.mutableBlockStartIndex == mutableBlockStartIndex;
  }

  @override
  int get hashCode => Object.hash(
    normalizedContent,
    renderTier,
    containsCitations,
    heavyBlockCount,
    Object.hashAll(blocks),
    Object.hashAll(nodes),
    Object.hashAllUnordered(blockLatexExpressions.entries),
    Object.hashAllUnordered(inlineLatexExpressions.entries),
    mutableBlockStartIndex,
  );
}

CompiledMarkdownNode _rebaseCompiledMarkdownNode(
  CompiledMarkdownNode node,
  int rootNodeOffset,
) {
  if (node is CompiledMarkdownText) {
    return CompiledMarkdownText(
      node.text,
      nodeId: _rebaseCompiledMarkdownPathId(node.nodeId, rootNodeOffset),
      containsLatexPlaceholders: node.containsLatexPlaceholders,
      containsCitations: node.containsCitations,
      inlineSegments: node.inlineSegments,
    );
  }
  if (node is CompiledMarkdownElement) {
    return CompiledMarkdownElement(
      nodeId: _rebaseCompiledMarkdownPathId(node.nodeId, rootNodeOffset),
      tag: node.tag,
      blockKind: node.blockKind,
      language: node.language,
      inlinePreview: node.inlinePreview,
      detailsData: node.detailsData,
      attributes: node.attributes,
      children: node.children
          .map((child) => _rebaseCompiledMarkdownNode(child, rootNodeOffset))
          .toList(growable: false),
    );
  }
  return node;
}

CompiledMarkdownBlock _rebaseCompiledMarkdownBlock(
  CompiledMarkdownBlock block,
  int rootNodeOffset,
  Map<String, CompiledMarkdownNode> rebasedRootNodesByOldId,
) {
  if (block is CompiledMarkdownNodeBlock) {
    final rebasedNode = block.node.nodeId.isNotEmpty
        ? rebasedRootNodesByOldId[block.node.nodeId]
        : null;
    return CompiledMarkdownNodeBlock(
      blockId: _rebaseCompiledMarkdownPathId(block.blockId, rootNodeOffset),
      kind: block.kind,
      node:
          rebasedNode ??
          _rebaseCompiledMarkdownNode(block.node, rootNodeOffset),
    );
  }
  if (block is CompiledMarkdownDetailsBlock) {
    // A details block's only rebaseable id is its blockId, which mirrors the
    // matching root node's nodeId. detailsData carries no node ids, so it is
    // reused unchanged. If a future details payload gains node ids that feed
    // rootNodesById lookups in buildMarkdownDisplayParts, rebase them here too.
    return CompiledMarkdownDetailsBlock(
      blockId: _rebaseCompiledMarkdownPathId(block.blockId, rootNodeOffset),
      detailsData: block.detailsData,
    );
  }
  if (block is CompiledMarkdownDetailsGroup) {
    final items = block.items
        .map(
          (item) =>
              _rebaseCompiledMarkdownBlock(
                    item,
                    rootNodeOffset,
                    rebasedRootNodesByOldId,
                  )
                  as CompiledMarkdownDetailsBlock,
        )
        .toList(growable: false);
    final blockId = items.isEmpty
        ? _rebaseCompiledMarkdownPathId(block.blockId, rootNodeOffset)
        : 'group:${items.first.blockId}:${items.first.type}';
    return CompiledMarkdownDetailsGroup(blockId: blockId, items: items);
  }
  return block;
}

String _rebaseCompiledMarkdownPathId(String value, int rootNodeOffset) {
  if (value.isEmpty || rootNodeOffset == 0) {
    return value;
  }

  final groupMatch = RegExp(r'^group:(n\d+(?:\.\d+)*):(.*)$').firstMatch(value);
  if (groupMatch != null) {
    final firstBlockId = _rebaseCompiledMarkdownPathId(
      groupMatch.group(1)!,
      rootNodeOffset,
    );
    return 'group:$firstBlockId:${groupMatch.group(2)!}';
  }

  final nodeMatch = RegExp(r'^n(\d+)(.*)$').firstMatch(value);
  if (nodeMatch == null) {
    return value;
  }
  final rootIndex = int.parse(nodeMatch.group(1)!);
  return 'n${rootIndex + rootNodeOffset}${nodeMatch.group(2)!}';
}

void _mergeLatexExpressions(
  Map<String, String> target,
  Map<String, String> source,
) {
  for (final entry in source.entries) {
    final existing = target[entry.key];
    if (existing != null && existing != entry.value) {
      throw ArgumentError(
        'Cannot compose markdown documents with colliding latex placeholders.',
      );
    }
    target[entry.key] = entry.value;
  }
}

void _appendComposedCompiledMarkdownBlock(
  List<CompiledMarkdownBlock> blocks,
  CompiledMarkdownBlock block,
) {
  final groupableItems = _groupableCompiledMarkdownDetailsItems(block);
  if (groupableItems == null || groupableItems.isEmpty) {
    blocks.add(block);
    return;
  }

  final previousItems = blocks.isEmpty
      ? null
      : _groupableCompiledMarkdownDetailsItems(blocks.last);
  if (previousItems == null ||
      previousItems.isEmpty ||
      previousItems.first.type != groupableItems.first.type) {
    blocks.add(block);
    return;
  }

  final mergedItems = <CompiledMarkdownDetailsBlock>[
    ...previousItems,
    ...groupableItems,
  ];
  blocks[blocks.length - 1] = _buildCompiledMarkdownDetailsGroup(mergedItems);
}

List<CompiledMarkdownDetailsBlock>? _groupableCompiledMarkdownDetailsItems(
  CompiledMarkdownBlock block,
) {
  if (block is CompiledMarkdownDetailsBlock &&
      _shouldGroupComposedCompiledMarkdownDetailsType(block.type)) {
    return <CompiledMarkdownDetailsBlock>[block];
  }
  if (block is CompiledMarkdownDetailsGroup &&
      block.items.isNotEmpty &&
      block.items.every(
        (item) => _shouldGroupComposedCompiledMarkdownDetailsType(item.type),
      )) {
    return block.items;
  }
  return null;
}

bool _shouldGroupComposedCompiledMarkdownDetailsType(String type) =>
    type == 'tool_calls';

CompiledMarkdownDetailsGroup _buildCompiledMarkdownDetailsGroup(
  List<CompiledMarkdownDetailsBlock> items,
) {
  assert(items.isNotEmpty, 'Cannot build a details group without items.');
  return CompiledMarkdownDetailsGroup(
    blockId: 'group:${items.first.blockId}:${items.first.type}',
    items: items,
  );
}

@immutable
abstract class CompiledMarkdownNode {
  const CompiledMarkdownNode();

  String get nodeId;

  int get weight;

  String get textContent;

  Map<String, Object?> toMap();

  static CompiledMarkdownNode fromMap(Map<String, Object?> map) {
    final kind = (map['kind'] ?? 'text') as String;
    return switch (kind) {
      'element' => CompiledMarkdownElement.fromMap(map),
      _ => CompiledMarkdownText.fromMap(map),
    };
  }
}

@immutable
abstract class CompiledMarkdownInlineSegment {
  const CompiledMarkdownInlineSegment();

  int get weight;

  Map<String, Object?> toMap();

  static CompiledMarkdownInlineSegment fromMap(Map<String, Object?> map) {
    final kind = (map['kind'] ?? 'text') as String;
    return switch (kind) {
      'citation' => CompiledMarkdownCitationSegment.fromMap(map),
      'latex' => CompiledMarkdownLatexSegment.fromMap(map),
      _ => CompiledMarkdownTextSegment.fromMap(map),
    };
  }
}

@immutable
class CompiledMarkdownTextSegment extends CompiledMarkdownInlineSegment {
  const CompiledMarkdownTextSegment(this.text);

  final String text;

  @override
  int get weight => text.length;

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'kind': 'text',
    'text': text,
  };

  factory CompiledMarkdownTextSegment.fromMap(Map<String, Object?> map) =>
      CompiledMarkdownTextSegment((map['text'] ?? '') as String);

  @override
  bool operator ==(Object other) =>
      other is CompiledMarkdownTextSegment && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

@immutable
class CompiledMarkdownCitationSegment extends CompiledMarkdownInlineSegment {
  CompiledMarkdownCitationSegment(List<int> sourceIds, {required this.rawText})
    : sourceIds = List<int>.unmodifiable(sourceIds);

  final List<int> sourceIds;
  final String rawText;

  @override
  int get weight => rawText.length;

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'kind': 'citation',
    'sourceIds': sourceIds,
    'rawText': rawText,
  };

  factory CompiledMarkdownCitationSegment.fromMap(Map<String, Object?> map) =>
      CompiledMarkdownCitationSegment(
        ((map['sourceIds'] as List<dynamic>? ?? const <dynamic>[]))
            .map((value) => (value as num).toInt())
            .toList(growable: false),
        rawText:
            (map['rawText'] as String?) ??
            _fallbackCitationRawText(
              ((map['sourceIds'] as List<dynamic>? ?? const <dynamic>[]))
                  .map((value) => (value as num).toInt())
                  .toList(growable: false),
            ),
      );

  @override
  bool operator ==(Object other) =>
      other is CompiledMarkdownCitationSegment &&
      listEquals(other.sourceIds, sourceIds) &&
      other.rawText == rawText;

  @override
  int get hashCode => Object.hash(Object.hashAll(sourceIds), rawText);
}

String _fallbackCitationRawText(List<int> sourceIds) {
  if (sourceIds.isEmpty) {
    return '';
  }
  return '[${sourceIds.join(',')}]';
}

@immutable
class CompiledMarkdownLatexSegment extends CompiledMarkdownInlineSegment {
  const CompiledMarkdownLatexSegment({
    required this.tex,
    required this.isBlock,
    this.placeholderLength = 0,
  });

  final String tex;
  final bool isBlock;

  /// The length of the placeholder token this segment was recovered from in
  /// the node's `textContent`.
  ///
  /// Streaming-fade offset accounting advances by this length so the visible
  /// text offset stays aligned with the document-wide `textContent`
  /// coordinate space (which still contains the placeholder tokens).
  final int placeholderLength;

  @override
  int get weight => tex.length + (isBlock ? 1 : 0);

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'kind': 'latex',
    'tex': tex,
    'isBlock': isBlock,
    'placeholderLength': placeholderLength,
  };

  factory CompiledMarkdownLatexSegment.fromMap(Map<String, Object?> map) =>
      CompiledMarkdownLatexSegment(
        tex: (map['tex'] ?? '') as String,
        isBlock: (map['isBlock'] ?? false) as bool,
        placeholderLength: (map['placeholderLength'] as num?)?.toInt() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is CompiledMarkdownLatexSegment &&
      other.tex == tex &&
      other.isBlock == isBlock &&
      other.placeholderLength == placeholderLength;

  @override
  int get hashCode => Object.hash(tex, isBlock, placeholderLength);
}

@immutable
class CompiledMarkdownText extends CompiledMarkdownNode {
  CompiledMarkdownText(
    this.text, {
    this.nodeId = '',
    this.containsLatexPlaceholders = false,
    this.containsCitations = false,
    List<CompiledMarkdownInlineSegment> inlineSegments =
        const <CompiledMarkdownInlineSegment>[],
  }) : inlineSegments = List<CompiledMarkdownInlineSegment>.unmodifiable(
         inlineSegments,
       );

  final String text;
  @override
  final String nodeId;
  final bool containsLatexPlaceholders;
  final bool containsCitations;
  final List<CompiledMarkdownInlineSegment> inlineSegments;

  bool get hasInlineSegments => inlineSegments.isNotEmpty;

  @override
  int get weight =>
      nodeId.length +
      text.length +
      inlineSegments.fold<int>(0, (sum, segment) => sum + segment.weight);

  @override
  String get textContent => text;

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'kind': 'text',
    'nodeId': nodeId,
    'text': text,
    'containsLatexPlaceholders': containsLatexPlaceholders,
    'containsCitations': containsCitations,
    'inlineSegments': inlineSegments
        .map((segment) => segment.toMap())
        .toList(growable: false),
  };

  factory CompiledMarkdownText.fromMap(Map<String, Object?> map) {
    final inlineSegments =
        (map['inlineSegments'] as List<dynamic>? ?? const <dynamic>[])
            .cast<Map<Object?, Object?>>()
            .map(
              (entry) => CompiledMarkdownInlineSegment.fromMap(
                entry.cast<String, Object?>(),
              ),
            )
            .toList(growable: false);
    return CompiledMarkdownText(
      (map['text'] ?? '') as String,
      nodeId: (map['nodeId'] ?? '') as String,
      containsLatexPlaceholders:
          (map['containsLatexPlaceholders'] ?? false) as bool,
      containsCitations: (map['containsCitations'] ?? false) as bool,
      inlineSegments: inlineSegments,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CompiledMarkdownText &&
      other.nodeId == nodeId &&
      other.text == text &&
      other.containsLatexPlaceholders == containsLatexPlaceholders &&
      other.containsCitations == containsCitations &&
      listEquals(other.inlineSegments, inlineSegments);

  @override
  int get hashCode => Object.hash(
    nodeId,
    text,
    containsLatexPlaceholders,
    containsCitations,
    Object.hashAll(inlineSegments),
  );
}

@immutable
class CompiledMarkdownElement extends CompiledMarkdownNode {
  CompiledMarkdownElement({
    this.nodeId = '',
    required this.tag,
    this.blockKind = CompiledMarkdownBlockKind.none,
    this.language = '',
    this.inlinePreview = false,
    this.detailsData,
    required Map<String, String> attributes,
    required List<CompiledMarkdownNode> children,
  }) : attributes = Map<String, String>.unmodifiable(attributes),
       children = List<CompiledMarkdownNode>.unmodifiable(children);

  @override
  final String nodeId;
  final String tag;
  final CompiledMarkdownBlockKind blockKind;
  final String language;
  final bool inlinePreview;
  final CompiledMarkdownDetailsData? detailsData;
  final Map<String, String> attributes;
  final List<CompiledMarkdownNode> children;

  bool get isHeavyBlock =>
      blockKind == CompiledMarkdownBlockKind.mermaid ||
      blockKind == CompiledMarkdownBlockKind.chartJs;

  @override
  int get weight =>
      nodeId.length +
      tag.length +
      blockKind.name.length +
      language.length +
      (detailsData?.weight ?? 0) +
      attributes.entries.fold<int>(
        0,
        (sum, entry) => sum + entry.key.length + entry.value.length,
      ) +
      children.fold<int>(0, (sum, child) => sum + child.weight);

  @override
  String get textContent => children.map((child) => child.textContent).join();

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'kind': 'element',
    'nodeId': nodeId,
    'tag': tag,
    'blockKind': blockKind.name,
    'language': language,
    'inlinePreview': inlinePreview,
    'detailsData': detailsData?.toMap(),
    'attributes': attributes,
    'children': children.map((child) => child.toMap()).toList(growable: false),
  };

  factory CompiledMarkdownElement.fromMap(Map<String, Object?> map) {
    final attributes =
        (map['attributes'] as Map<Object?, Object?>? ??
                const <Object?, Object?>{})
            .map(
              (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
            );
    final children = (map['children'] as List<dynamic>? ?? const <dynamic>[])
        .cast<Map<Object?, Object?>>()
        .map(
          (entry) =>
              CompiledMarkdownNode.fromMap(entry.cast<String, Object?>()),
        )
        .toList(growable: false);
    final detailsDataMap = map['detailsData'] as Map<Object?, Object?>?;
    return CompiledMarkdownElement(
      nodeId: (map['nodeId'] ?? '') as String,
      tag: (map['tag'] ?? '') as String,
      blockKind: _blockKindFromName((map['blockKind'] ?? '') as String),
      language: (map['language'] ?? '') as String,
      inlinePreview: (map['inlinePreview'] ?? false) as bool,
      detailsData: detailsDataMap == null
          ? null
          : CompiledMarkdownDetailsData.fromMap(
              detailsDataMap.cast<String, Object?>(),
            ),
      attributes: attributes,
      children: children,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is CompiledMarkdownElement &&
        other.nodeId == nodeId &&
        other.tag == tag &&
        other.blockKind == blockKind &&
        other.language == language &&
        other.inlinePreview == inlinePreview &&
        other.detailsData == detailsData &&
        mapEquals(other.attributes, attributes) &&
        listEquals(other.children, children);
  }

  @override
  int get hashCode => Object.hash(
    nodeId,
    tag,
    blockKind,
    language,
    inlinePreview,
    detailsData,
    Object.hashAllUnordered(attributes.entries),
    Object.hashAll(children),
  );
}

@immutable
class CompiledMarkdownToolCallArgumentEntry {
  const CompiledMarkdownToolCallArgumentEntry({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  int get weight => label.length + value.length;

  Map<String, Object?> toMap() => <String, Object?>{
    'label': label,
    'value': value,
  };

  factory CompiledMarkdownToolCallArgumentEntry.fromMap(
    Map<String, Object?> map,
  ) => CompiledMarkdownToolCallArgumentEntry(
    label: (map['label'] ?? '') as String,
    value: (map['value'] ?? '') as String,
  );

  @override
  bool operator ==(Object other) =>
      other is CompiledMarkdownToolCallArgumentEntry &&
      other.label == label &&
      other.value == value;

  @override
  int get hashCode => Object.hash(label, value);
}

@immutable
class CompiledMarkdownToolCallData {
  CompiledMarkdownToolCallData({
    required this.argumentsText,
    required this.resultText,
    required List<CompiledMarkdownToolCallArgumentEntry> argumentEntries,
    this.argumentsCode = '',
    this.resultCode = '',
    this.resultDisplayText = '',
    required List<String> embedSources,
    required List<String> imageUrls,
  }) : argumentEntries =
           List<CompiledMarkdownToolCallArgumentEntry>.unmodifiable(
             argumentEntries,
           ),
       embedSources = List<String>.unmodifiable(embedSources),
       imageUrls = List<String>.unmodifiable(imageUrls);

  final String argumentsText;
  final String resultText;
  final List<CompiledMarkdownToolCallArgumentEntry> argumentEntries;
  final String argumentsCode;
  final String resultCode;
  final String resultDisplayText;
  final List<String> embedSources;
  final List<String> imageUrls;

  bool get hasEmbeds => embedSources.isNotEmpty;

  bool get hasImages => imageUrls.isNotEmpty;

  bool get hasDeferredPreviewContent => hasEmbeds || hasImages;

  bool get hasExpandableContent =>
      argumentsText.trim().isNotEmpty || resultText.trim().isNotEmpty;

  int get weight =>
      argumentsText.length +
      resultText.length +
      argumentsCode.length +
      resultCode.length +
      resultDisplayText.length +
      argumentEntries.fold<int>(0, (sum, entry) => sum + entry.weight) +
      embedSources.fold<int>(0, (sum, entry) => sum + entry.length) +
      imageUrls.fold<int>(0, (sum, entry) => sum + entry.length);

  Map<String, Object?> toMap() => <String, Object?>{
    'argumentsText': argumentsText,
    'resultText': resultText,
    'argumentEntries': argumentEntries
        .map((entry) => entry.toMap())
        .toList(growable: false),
    'argumentsCode': argumentsCode,
    'resultCode': resultCode,
    'resultDisplayText': resultDisplayText,
    'embedSources': embedSources,
    'imageUrls': imageUrls,
  };

  factory CompiledMarkdownToolCallData.fromMap(Map<String, Object?> map) {
    final argumentEntries =
        (map['argumentEntries'] as List<dynamic>? ?? const <dynamic>[])
            .cast<Map<Object?, Object?>>()
            .map(
              (entry) => CompiledMarkdownToolCallArgumentEntry.fromMap(
                entry.cast<String, Object?>(),
              ),
            )
            .toList(growable: false);
    return CompiledMarkdownToolCallData(
      argumentsText: (map['argumentsText'] ?? '') as String,
      resultText: (map['resultText'] ?? '') as String,
      argumentEntries: argumentEntries,
      argumentsCode: (map['argumentsCode'] ?? '') as String,
      resultCode: (map['resultCode'] ?? '') as String,
      resultDisplayText: (map['resultDisplayText'] ?? '') as String,
      embedSources:
          ((map['embedSources'] as List<dynamic>? ?? const <dynamic>[]))
              .map((value) => value.toString())
              .toList(growable: false),
      imageUrls: ((map['imageUrls'] as List<dynamic>? ?? const <dynamic>[]))
          .map((value) => value.toString())
          .toList(growable: false),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is CompiledMarkdownToolCallData &&
        other.argumentsText == argumentsText &&
        other.resultText == resultText &&
        listEquals(other.argumentEntries, argumentEntries) &&
        other.argumentsCode == argumentsCode &&
        other.resultCode == resultCode &&
        other.resultDisplayText == resultDisplayText &&
        listEquals(other.embedSources, embedSources) &&
        listEquals(other.imageUrls, imageUrls);
  }

  @override
  int get hashCode => Object.hash(
    argumentsText,
    resultText,
    Object.hashAll(argumentEntries),
    argumentsCode,
    resultCode,
    resultDisplayText,
    Object.hashAll(embedSources),
    Object.hashAll(imageUrls),
  );
}

@immutable
class CompiledMarkdownDetailsData {
  const CompiledMarkdownDetailsData({
    required this.summaryText,
    required this.bodyMarkdown,
    required this.bodyStartIndex,
    required this.hasBody,
    required this.kind,
    required this.type,
    required this.name,
    required this.isDone,
    required this.isPending,
    required this.durationSeconds,
    this.toolCallData,
  });

  final String summaryText;
  final String bodyMarkdown;
  final int bodyStartIndex;
  final bool hasBody;
  final CompiledMarkdownDetailsKind kind;
  final String type;
  final String name;
  final bool isDone;
  final bool isPending;
  final int durationSeconds;
  final CompiledMarkdownToolCallData? toolCallData;

  bool get supportsInlineExpansion =>
      kind == CompiledMarkdownDetailsKind.reasoning ||
      kind == CompiledMarkdownDetailsKind.codeInterpreter;

  bool get usesInlineExpansion => supportsInlineExpansion && isPending;

  bool get canExpand {
    if (kind != CompiledMarkdownDetailsKind.toolCall) {
      return hasBody;
    }
    final data = toolCallData;
    if (data == null) {
      return hasBody;
    }
    return data.hasExpandableContent ||
        data.hasDeferredPreviewContent ||
        hasBody;
  }

  int get weight =>
      summaryText.length +
      bodyMarkdown.length +
      bodyStartIndex +
      kind.name.length +
      type.length +
      name.length +
      durationSeconds +
      (toolCallData?.weight ?? 0);

  Map<String, Object?> toMap() => <String, Object?>{
    'summaryText': summaryText,
    'bodyMarkdown': bodyMarkdown,
    'bodyStartIndex': bodyStartIndex,
    'hasBody': hasBody,
    'kind': kind.name,
    'type': type,
    'name': name,
    'isDone': isDone,
    'isPending': isPending,
    'durationSeconds': durationSeconds,
    'toolCallData': toolCallData?.toMap(),
  };

  factory CompiledMarkdownDetailsData.fromMap(Map<String, Object?> map) {
    final toolCallDataMap = map['toolCallData'] as Map<Object?, Object?>?;
    final bodyMarkdown = (map['bodyMarkdown'] ?? '') as String;
    return CompiledMarkdownDetailsData(
      summaryText: (map['summaryText'] ?? '') as String,
      bodyMarkdown: bodyMarkdown,
      bodyStartIndex: (map['bodyStartIndex'] ?? 0) as int,
      hasBody:
          (map['hasBody'] ?? false) as bool || bodyMarkdown.trim().isNotEmpty,
      kind: _detailsKindFromName((map['kind'] ?? '') as String),
      type: (map['type'] ?? '') as String,
      name: (map['name'] ?? '') as String,
      isDone: (map['isDone'] ?? false) as bool,
      isPending: (map['isPending'] ?? false) as bool,
      durationSeconds: (map['durationSeconds'] ?? 0) as int,
      toolCallData: toolCallDataMap == null
          ? null
          : CompiledMarkdownToolCallData.fromMap(
              toolCallDataMap.cast<String, Object?>(),
            ),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is CompiledMarkdownDetailsData &&
        other.summaryText == summaryText &&
        other.bodyMarkdown == bodyMarkdown &&
        other.bodyStartIndex == bodyStartIndex &&
        other.hasBody == hasBody &&
        other.kind == kind &&
        other.type == type &&
        other.name == name &&
        other.isDone == isDone &&
        other.isPending == isPending &&
        other.durationSeconds == durationSeconds &&
        other.toolCallData == toolCallData;
  }

  @override
  int get hashCode => Object.hash(
    summaryText,
    bodyMarkdown,
    bodyStartIndex,
    hasBody,
    kind,
    type,
    name,
    isDone,
    isPending,
    durationSeconds,
    toolCallData,
  );
}

@immutable
abstract class CompiledMarkdownBlock {
  const CompiledMarkdownBlock(this.blockId);

  final String blockId;

  int get weight;

  Map<String, Object?> toMap();

  static CompiledMarkdownBlock fromMap(Map<String, Object?> map) {
    final kind = (map['kind'] ?? 'node') as String;
    return switch (kind) {
      'details' => CompiledMarkdownDetailsBlock.fromMap(map),
      'detailsGroup' => CompiledMarkdownDetailsGroup.fromMap(map),
      _ => CompiledMarkdownNodeBlock.fromMap(map),
    };
  }
}

@immutable
class CompiledMarkdownNodeBlock extends CompiledMarkdownBlock {
  const CompiledMarkdownNodeBlock({
    required String blockId,
    required this.kind,
    required this.node,
  }) : super(blockId);

  factory CompiledMarkdownNodeBlock.fromNode({
    required String blockId,
    required CompiledMarkdownNode node,
  }) {
    return CompiledMarkdownNodeBlock(
      blockId: blockId,
      kind: _nodeBlockKindForNode(node),
      node: node,
    );
  }

  final CompiledMarkdownNodeBlockKind kind;
  final CompiledMarkdownNode node;

  @override
  int get weight => blockId.length + kind.name.length + node.weight;

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'kind': 'node',
    'blockId': blockId,
    'nodeBlockKind': kind.name,
    'node': node.toMap(),
  };

  factory CompiledMarkdownNodeBlock.fromMap(Map<String, Object?> map) {
    final node = CompiledMarkdownNode.fromMap(
      (map['node'] as Map<Object?, Object?>? ?? const <Object?, Object?>{})
          .cast<String, Object?>(),
    );
    return CompiledMarkdownNodeBlock(
      blockId: (map['blockId'] ?? '') as String,
      kind: _nodeBlockKindFromName(
        (map['nodeBlockKind'] ?? '') as String,
        fallbackNode: node,
      ),
      node: node,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CompiledMarkdownNodeBlock &&
      other.blockId == blockId &&
      other.kind == kind &&
      other.node == node;

  @override
  int get hashCode => Object.hash(blockId, kind, node);
}

@immutable
class CompiledMarkdownDetailsBlock extends CompiledMarkdownBlock {
  const CompiledMarkdownDetailsBlock({
    required String blockId,
    required this.detailsData,
  }) : super(blockId);

  final CompiledMarkdownDetailsData detailsData;

  String get summaryText => detailsData.summaryText;

  String get bodyMarkdown => detailsData.bodyMarkdown;

  String get type => detailsData.type;

  String get name => detailsData.name;

  bool get isDone => detailsData.isDone;

  bool get isPending => detailsData.isPending;

  bool get hasBody => detailsData.hasBody;

  bool get supportsInlineExpansion => detailsData.supportsInlineExpansion;

  bool get usesInlineExpansion => detailsData.usesInlineExpansion;

  CompiledMarkdownToolCallData? get toolCallData => detailsData.toolCallData;

  @override
  int get weight => blockId.length + detailsData.weight;

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'kind': 'details',
    'blockId': blockId,
    'detailsData': detailsData.toMap(),
  };

  factory CompiledMarkdownDetailsBlock.fromMap(Map<String, Object?> map) {
    final detailsDataMap =
        (map['detailsData'] as Map<Object?, Object?>? ??
                const <Object?, Object?>{})
            .cast<String, Object?>();
    return CompiledMarkdownDetailsBlock(
      blockId: (map['blockId'] ?? '') as String,
      detailsData: CompiledMarkdownDetailsData.fromMap(detailsDataMap),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is CompiledMarkdownDetailsBlock &&
        other.blockId == blockId &&
        other.detailsData == detailsData &&
        other.type == type &&
        other.name == name;
  }

  @override
  int get hashCode => Object.hash(blockId, detailsData, type, name);
}

@immutable
class CompiledMarkdownDetailsGroup extends CompiledMarkdownBlock {
  CompiledMarkdownDetailsGroup({
    required String blockId,
    required List<CompiledMarkdownDetailsBlock> items,
  }) : items = List<CompiledMarkdownDetailsBlock>.unmodifiable(items),
       super(blockId);

  final List<CompiledMarkdownDetailsBlock> items;

  @override
  int get weight =>
      blockId.length + items.fold<int>(0, (sum, item) => sum + item.weight);

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'kind': 'detailsGroup',
    'blockId': blockId,
    'items': items.map((item) => item.toMap()).toList(growable: false),
  };

  factory CompiledMarkdownDetailsGroup.fromMap(Map<String, Object?> map) {
    final items = (map['items'] as List<dynamic>? ?? const <dynamic>[])
        .cast<Map<Object?, Object?>>()
        .map(
          (entry) => CompiledMarkdownDetailsBlock.fromMap(
            entry.cast<String, Object?>(),
          ),
        )
        .toList(growable: false);
    return CompiledMarkdownDetailsGroup(
      blockId: (map['blockId'] ?? '') as String,
      items: items,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CompiledMarkdownDetailsGroup &&
      other.blockId == blockId &&
      listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(blockId, Object.hashAll(items));
}

List<CompiledMarkdownBlock> _fallbackBlocksFromNodes(
  List<CompiledMarkdownNode> nodes,
) {
  final blocks = <CompiledMarkdownBlock>[];
  for (var index = 0; index < nodes.length; index += 1) {
    final node = nodes[index];
    blocks.add(
      CompiledMarkdownNodeBlock.fromNode(
        blockId: node.nodeId.isEmpty ? 'node:$index' : node.nodeId,
        node: node,
      ),
    );
  }
  return List<CompiledMarkdownBlock>.unmodifiable(blocks);
}

MarkdownRenderTier _renderTierFromName(String name) {
  return MarkdownRenderTier.values.firstWhere(
    (value) => value.name == name,
    orElse: () => MarkdownRenderTier.blocks,
  );
}

CompiledMarkdownBlockKind _blockKindFromName(String name) {
  return CompiledMarkdownBlockKind.values.firstWhere(
    (value) => value.name == name,
    orElse: () => CompiledMarkdownBlockKind.none,
  );
}

CompiledMarkdownDetailsKind _detailsKindFromName(String name) {
  return CompiledMarkdownDetailsKind.values.firstWhere(
    (value) => value.name == name,
    orElse: () => CompiledMarkdownDetailsKind.generic,
  );
}

CompiledMarkdownNodeBlockKind _nodeBlockKindFromName(
  String name, {
  required CompiledMarkdownNode fallbackNode,
}) {
  return CompiledMarkdownNodeBlockKind.values.firstWhere(
    (value) => value.name == name,
    orElse: () => _nodeBlockKindForNode(fallbackNode),
  );
}

CompiledMarkdownNodeBlockKind _nodeBlockKindForNode(CompiledMarkdownNode node) {
  if (node is CompiledMarkdownText) {
    return CompiledMarkdownNodeBlockKind.text;
  }
  if (node is! CompiledMarkdownElement) {
    return CompiledMarkdownNodeBlockKind.fallback;
  }
  return switch (node.tag) {
    'p' => CompiledMarkdownNodeBlockKind.paragraph,
    'h1' => CompiledMarkdownNodeBlockKind.heading1,
    'h2' => CompiledMarkdownNodeBlockKind.heading2,
    'h3' => CompiledMarkdownNodeBlockKind.heading3,
    'h4' => CompiledMarkdownNodeBlockKind.heading4,
    'h5' => CompiledMarkdownNodeBlockKind.heading5,
    'h6' => CompiledMarkdownNodeBlockKind.heading6,
    'pre' => CompiledMarkdownNodeBlockKind.codeBlock,
    'blockquote' => CompiledMarkdownNodeBlockKind.blockquote,
    'ul' => CompiledMarkdownNodeBlockKind.unorderedList,
    'ol' => CompiledMarkdownNodeBlockKind.orderedList,
    'li' => CompiledMarkdownNodeBlockKind.listItem,
    'table' => CompiledMarkdownNodeBlockKind.table,
    'hr' => CompiledMarkdownNodeBlockKind.horizontalRule,
    'div' => CompiledMarkdownNodeBlockKind.div,
    'section' => CompiledMarkdownNodeBlockKind.section,
    'details' => CompiledMarkdownNodeBlockKind.details,
    'img' => CompiledMarkdownNodeBlockKind.image,
    _ => CompiledMarkdownNodeBlockKind.fallback,
  };
}
