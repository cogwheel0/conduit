import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:markdown/markdown.dart' as md;

import '../../../core/services/performance_profiler.dart';
import '../../../core/services/worker_manager.dart';
import '../../../core/utils/citation_parser.dart';
import '../../../core/utils/embed_utils.dart';
import 'compiled_markdown_document.dart';
import 'markdown_preprocessor.dart';
import 'renderer/details_block_syntax.dart';
import 'renderer/latex_preprocessor.dart';
import 'renderer/mention_inline_syntax.dart';

const int markdownSynchronousCompileThreshold = 384;
const int markdownSynchronousPrepareThreshold = 768;
const Set<String> _groupableCompiledDetailTypes = {'tool_calls'};
final _detailsAttributeUnescape = HtmlUnescape();

enum MarkdownPrepareExecutionPath {
  synchronous,
  webSynchronous,
  asyncBackend,
  fallbackSync,
}

final _compiledMarkdownCache = _CompiledMarkdownCache();

void debugResetCompiledMarkdownCache() => _compiledMarkdownCache.clear();

int debugCompiledMarkdownCacheSize() => _compiledMarkdownCache.length;

List<String> debugCompiledMarkdownCacheKeys() => _compiledMarkdownCache.keys;

final markdownCompileServiceProvider = Provider<MarkdownCompileService>((ref) {
  final service = MarkdownCompileService(
    workerManager: ref.watch(workerManagerProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

String prepareMarkdownContent(String content, {required bool streaming}) {
  final normalized = ConduitMarkdownPreprocessor.normalize(content);
  final prepared = streaming
      ? stripTrailingIncompleteToolCallDetails(normalized)
      : normalized;
  return prepared;
}

String stripTrailingIncompleteToolCallDetails(String input) {
  if (input.isEmpty || !input.contains('<details')) {
    return input;
  }

  final matches = RegExp(
    r'<details\b[^>]*type="tool_calls"[^>]*>',
    caseSensitive: false,
  ).allMatches(input).toList(growable: false);
  if (matches.isEmpty) {
    return input;
  }

  final lastOpen = matches.last;
  final trailing = input.substring(lastOpen.start).toLowerCase();
  if (trailing.contains('</details>')) {
    return input;
  }

  return input.substring(0, lastOpen.start).trimRight();
}

CompiledMarkdownDocument compilePreparedMarkdownSync(String preparedContent) {
  final cached = _compiledMarkdownCache.read(preparedContent);
  if (cached != null) {
    return cached;
  }
  final compiled = _compilePreparedMarkdownDocument(preparedContent);
  return _compiledMarkdownCache.write(preparedContent, compiled);
}

class MarkdownCompileService {
  MarkdownCompileService({
    required WorkerManager workerManager,
    @visibleForTesting this.debugOnPrepareExecution,
    @visibleForTesting this.debugPrepareContentOverride,
  }) : _workerManager = workerManager,
       _backend = _MarkdownCompilerBackend(),
       _prepareBackend = _MarkdownPrepareBackend();

  final WorkerManager _workerManager;
  final _MarkdownCompilerBackend _backend;
  final _MarkdownPrepareBackend _prepareBackend;
  final Map<String, Future<CompiledMarkdownDocument>> _inFlight =
      <String, Future<CompiledMarkdownDocument>>{};
  @visibleForTesting
  final void Function(MarkdownPrepareExecutionPath path)?
  debugOnPrepareExecution;
  @visibleForTesting
  final Future<String> Function(String content, bool streaming)?
  debugPrepareContentOverride;
  bool _disposed = false;

  CompiledMarkdownDocument? peekPrepared(String preparedContent) =>
      _compiledMarkdownCache.read(preparedContent);

  bool shouldCompileSynchronously(
    String preparedContent, {
    bool widgetTest = false,
  }) =>
      widgetTest ||
      preparedContent.length <= markdownSynchronousCompileThreshold;

  bool shouldPrepareSynchronously(String content, {bool widgetTest = false}) =>
      widgetTest || content.length <= markdownSynchronousPrepareThreshold;

  CompiledMarkdownDocument compilePreparedSynchronously(
    String preparedContent,
  ) => compilePreparedMarkdownSync(preparedContent);

  Future<String> prepareContent(
    String content, {
    required bool streaming,
    bool allowSynchronous = false,
    bool widgetTest = false,
  }) async {
    if (content.isEmpty) {
      return '';
    }

    if (allowSynchronous &&
        shouldPrepareSynchronously(content, widgetTest: widgetTest)) {
      debugOnPrepareExecution?.call(MarkdownPrepareExecutionPath.synchronous);
      return prepareMarkdownContent(content, streaming: streaming);
    }

    if (kIsWeb) {
      debugOnPrepareExecution?.call(
        MarkdownPrepareExecutionPath.webSynchronous,
      );
      return prepareMarkdownContent(content, streaming: streaming);
    }

    final taskKey = PerformanceProfiler.instance.startTask(
      'markdown_prepare',
      scope: 'markdown',
      key: 'markdown_prepare:${content.hashCode}:${content.length}:$streaming',
      data: {'length': content.length, 'streaming': streaming},
    );

    try {
      final prepared =
          await debugPrepareContentOverride?.call(content, streaming) ??
          await _prepareBackend.prepareContent(content, streaming: streaming);
      debugOnPrepareExecution?.call(MarkdownPrepareExecutionPath.asyncBackend);
      PerformanceProfiler.instance.finishTask(
        taskKey,
        data: {
          'status': 'ok',
          'streaming': streaming,
          'preparedLength': prepared.length,
        },
      );
      return prepared;
    } catch (error) {
      final fallback = prepareMarkdownContent(content, streaming: streaming);
      debugOnPrepareExecution?.call(MarkdownPrepareExecutionPath.fallbackSync);
      PerformanceProfiler.instance.finishTask(
        taskKey,
        data: {
          'status': 'fallback_sync',
          'streaming': streaming,
          'preparedLength': fallback.length,
          'error': error.toString(),
        },
      );
      return fallback;
    }
  }

  Future<CompiledMarkdownDocument> compilePrepared(
    String preparedContent, {
    bool allowSynchronous = false,
    bool widgetTest = false,
  }) {
    if (preparedContent.trim().isEmpty) {
      return SynchronousFuture(const CompiledMarkdownDocument.empty());
    }

    final cached = _compiledMarkdownCache.read(preparedContent);
    if (cached != null) {
      PerformanceProfiler.instance.instant(
        'markdown_cache_hit',
        scope: 'markdown',
        data: {'length': preparedContent.length},
      );
      return SynchronousFuture(cached);
    }

    if (allowSynchronous &&
        shouldCompileSynchronously(preparedContent, widgetTest: widgetTest)) {
      return SynchronousFuture(compilePreparedSynchronously(preparedContent));
    }

    if (kIsWeb) {
      return SynchronousFuture(compilePreparedSynchronously(preparedContent));
    }

    final inFlight = _inFlight[preparedContent];
    if (inFlight != null) {
      return inFlight;
    }

    final taskKey = PerformanceProfiler.instance.startTask(
      'markdown_compile',
      scope: 'markdown',
      key: 'markdown:${preparedContent.hashCode}:${preparedContent.length}',
      data: {'length': preparedContent.length},
    );
    final future = _backend
        .compilePrepared(preparedContent)
        .then(CompiledMarkdownDocument.fromMap)
        .catchError((Object error, StackTrace stackTrace) async {
          try {
            final workerResult = await _workerManager
                .schedule<Map<String, Object?>, Map<String, Object?>>(
                  _compilePreparedMarkdownDocumentWorker,
                  <String, Object?>{'preparedContent': preparedContent},
                  debugLabel: 'markdown_compile_fallback',
                );
            PerformanceProfiler.instance.instant(
              'markdown_compile_fallback_worker',
              scope: 'markdown',
              data: {'length': preparedContent.length},
            );
            return CompiledMarkdownDocument.fromMap(workerResult);
          } catch (_) {
            final fallback = compilePreparedSynchronously(preparedContent);
            PerformanceProfiler.instance.finishTask(
              taskKey,
              data: {
                'status': 'fallback',
                'error': error.toString(),
                'nodes': fallback.nodes.length,
              },
            );
            return fallback;
          }
        })
        .then((document) {
          if (_disposed) {
            return document;
          }
          final cachedDocument = _compiledMarkdownCache.write(
            preparedContent,
            document,
          );
          PerformanceProfiler.instance.finishTask(
            taskKey,
            data: {
              'status': 'ok',
              'nodes': cachedDocument.nodes.length,
              'weight': cachedDocument.estimatedWeight,
            },
          );
          return cachedDocument;
        })
        .whenComplete(() {
          _inFlight.remove(preparedContent);
        });

    _inFlight[preparedContent] = future;
    return future;
  }

  Future<List<CompiledMarkdownDocument>> compilePreparedBatch(
    Iterable<String> preparedContents, {
    bool allowSynchronous = false,
    bool widgetTest = false,
  }) async {
    final contents = preparedContents.toList(growable: false);
    if (contents.isEmpty) {
      return const <CompiledMarkdownDocument>[];
    }

    final resolved = List<CompiledMarkdownDocument?>.filled(
      contents.length,
      null,
    );
    final pendingByContent = <String, Future<CompiledMarkdownDocument>>{};
    final asyncMisses = <String>{};

    for (var index = 0; index < contents.length; index += 1) {
      final preparedContent = contents[index];
      if (preparedContent.trim().isEmpty) {
        resolved[index] = const CompiledMarkdownDocument.empty();
        continue;
      }

      final cached = _compiledMarkdownCache.read(preparedContent);
      if (cached != null) {
        PerformanceProfiler.instance.instant(
          'markdown_cache_hit',
          scope: 'markdown',
          data: {'length': preparedContent.length},
        );
        resolved[index] = cached;
        continue;
      }

      if (allowSynchronous &&
          shouldCompileSynchronously(preparedContent, widgetTest: widgetTest)) {
        resolved[index] = compilePreparedSynchronously(preparedContent);
        continue;
      }

      if (kIsWeb) {
        resolved[index] = compilePreparedSynchronously(preparedContent);
        continue;
      }

      final inFlight = _inFlight[preparedContent];
      if (inFlight != null) {
        pendingByContent[preparedContent] = inFlight;
        continue;
      }

      asyncMisses.add(preparedContent);
    }

    if (asyncMisses.isNotEmpty) {
      pendingByContent.addAll(
        _startBatchCompile(asyncMisses.toList(growable: false)),
      );
    }

    final indexedPending =
        <({int index, Future<CompiledMarkdownDocument> future})>[];
    for (var index = 0; index < contents.length; index += 1) {
      if (resolved[index] != null) {
        continue;
      }
      final future = pendingByContent[contents[index]];
      if (future == null) {
        resolved[index] = const CompiledMarkdownDocument.empty();
        continue;
      }
      indexedPending.add((index: index, future: future));
    }

    if (indexedPending.isNotEmpty) {
      final documents = await Future.wait(
        indexedPending.map((entry) => entry.future),
      );
      for (var index = 0; index < indexedPending.length; index += 1) {
        resolved[indexedPending[index].index] = documents[index];
      }
    }

    return List<CompiledMarkdownDocument>.unmodifiable(
      resolved.cast<CompiledMarkdownDocument>(),
    );
  }

  void prewarmPrepared(Iterable<String> preparedContents) {
    if (_disposed) {
      return;
    }
    final pendingContents = <String>{};
    for (final preparedContent in preparedContents) {
      if (preparedContent.trim().isEmpty ||
          _compiledMarkdownCache.contains(preparedContent) ||
          _inFlight.containsKey(preparedContent)) {
        continue;
      }
      pendingContents.add(preparedContent);
    }
    if (pendingContents.isEmpty) {
      return;
    }
    unawaited(compilePreparedBatch(pendingContents));
  }

  void dispose() {
    _disposed = true;
    _inFlight.clear();
    _backend.dispose();
    _prepareBackend.dispose();
  }

  Map<String, Future<CompiledMarkdownDocument>> _startBatchCompile(
    List<String> preparedContents,
  ) {
    if (preparedContents.isEmpty) {
      return const <String, Future<CompiledMarkdownDocument>>{};
    }
    if (preparedContents.length == 1) {
      final preparedContent = preparedContents.single;
      return <String, Future<CompiledMarkdownDocument>>{
        preparedContent: compilePrepared(preparedContent),
      };
    }

    final requestContents = List<String>.unmodifiable(preparedContents);
    final requestIndexByContent = <String, int>{
      for (var index = 0; index < requestContents.length; index += 1)
        requestContents[index]: index,
    };
    final totalLength = requestContents.fold<int>(
      0,
      (sum, value) => sum + value.length,
    );
    final taskKey = PerformanceProfiler.instance.startTask(
      'markdown_compile_batch',
      scope: 'markdown',
      key:
          'markdown_batch:${requestContents.length}:$totalLength:${Object.hashAll(requestContents)}',
      data: {'count': requestContents.length, 'totalLength': totalLength},
    );

    final sharedFuture = _compilePreparedBatchAsync(requestContents, taskKey);
    final entryFutures = <String, Future<CompiledMarkdownDocument>>{};
    for (final preparedContent in requestContents) {
      final documentIndex = requestIndexByContent[preparedContent]!;
      late final Future<CompiledMarkdownDocument> entryFuture;
      entryFuture = sharedFuture
          .then((documents) => documents[documentIndex])
          .whenComplete(() {
            if (_inFlight[preparedContent] == entryFuture) {
              _inFlight.remove(preparedContent);
            }
          });
      _inFlight[preparedContent] = entryFuture;
      entryFutures[preparedContent] = entryFuture;
    }
    return entryFutures;
  }

  Future<List<CompiledMarkdownDocument>> _compilePreparedBatchAsync(
    List<String> preparedContents,
    String taskKey,
  ) async {
    try {
      final resultMaps = await _backend.compilePreparedBatch(preparedContents);
      final documents = _documentsFromBatchMaps(resultMaps);
      return _cacheCompiledBatchDocuments(
        preparedContents,
        documents,
        taskKey: taskKey,
        status: 'ok',
      );
    } catch (error) {
      try {
        final workerResult = await _workerManager
            .schedule<Map<String, Object?>, List<Map<String, Object?>>>(
              _compilePreparedMarkdownDocumentsWorker,
              <String, Object?>{'preparedContents': preparedContents},
              debugLabel: 'markdown_compile_batch_fallback',
            );
        PerformanceProfiler.instance.instant(
          'markdown_compile_batch_fallback_worker',
          scope: 'markdown',
          data: {
            'count': preparedContents.length,
            'totalLength': preparedContents.fold<int>(
              0,
              (sum, value) => sum + value.length,
            ),
          },
        );
        final documents = _documentsFromBatchMaps(workerResult);
        return _cacheCompiledBatchDocuments(
          preparedContents,
          documents,
          taskKey: taskKey,
          status: 'fallback_worker',
        );
      } catch (_) {
        final documents = preparedContents
            .map(compilePreparedSynchronously)
            .toList(growable: false);
        PerformanceProfiler.instance.finishTask(
          taskKey,
          data: {
            'status': 'fallback_sync',
            'error': error.toString(),
            'count': documents.length,
            'totalWeight': documents.fold<int>(
              0,
              (sum, document) => sum + document.estimatedWeight,
            ),
          },
        );
        return documents;
      }
    }
  }

  List<CompiledMarkdownDocument> _cacheCompiledBatchDocuments(
    List<String> preparedContents,
    List<CompiledMarkdownDocument> documents, {
    required String taskKey,
    required String status,
  }) {
    if (preparedContents.length != documents.length) {
      throw StateError(
        'Batch markdown compile returned ${documents.length} documents for '
        '${preparedContents.length} requests.',
      );
    }
    if (_disposed) {
      return documents;
    }

    final cachedDocuments = <CompiledMarkdownDocument>[];
    for (var index = 0; index < preparedContents.length; index += 1) {
      cachedDocuments.add(
        _compiledMarkdownCache.write(preparedContents[index], documents[index]),
      );
    }
    PerformanceProfiler.instance.finishTask(
      taskKey,
      data: {
        'status': status,
        'count': cachedDocuments.length,
        'totalWeight': cachedDocuments.fold<int>(
          0,
          (sum, document) => sum + document.estimatedWeight,
        ),
      },
    );
    return List<CompiledMarkdownDocument>.unmodifiable(cachedDocuments);
  }
}

Map<String, Object?> _compilePreparedMarkdownDocumentWorker(
  Map<String, Object?> payload,
) {
  final preparedContent = (payload['preparedContent'] ?? '') as String;
  return _compilePreparedMarkdownDocument(preparedContent).toMap();
}

List<Map<String, Object?>> _compilePreparedMarkdownDocumentsWorker(
  Map<String, Object?> payload,
) {
  final rawContents =
      payload['preparedContents'] as List<dynamic>? ?? const <dynamic>[];
  final preparedContents = rawContents
      .map((value) => value.toString())
      .toList(growable: false);
  return preparedContents
      .map(
        (preparedContent) => _compilePreparedMarkdownDocument(preparedContent),
      )
      .map((document) => document.toMap())
      .toList(growable: false);
}

List<CompiledMarkdownDocument> _documentsFromBatchMaps(
  List<Map<String, Object?>> maps,
) {
  return maps.map(CompiledMarkdownDocument.fromMap).toList(growable: false);
}

CompiledMarkdownDocument _compilePreparedMarkdownDocument(
  String preparedContent,
) {
  if (preparedContent.trim().isEmpty) {
    return const CompiledMarkdownDocument.empty();
  }

  final latexPreprocessor = LatexPreprocessor();
  final preprocessed = latexPreprocessor.extract(preparedContent);

  final document = md.Document(
    extensionSet: md.ExtensionSet.gitHubWeb,
    blockSyntaxes: const [DetailsBlockSyntax()],
    inlineSyntaxes: [MentionInlineSyntax()],
    encodeHtml: false,
  );
  final nodes = document.parse(preprocessed);
  final compiledNodes = <CompiledMarkdownNode>[];
  for (var index = 0; index < nodes.length; index += 1) {
    compiledNodes.add(
      _compileNodeFromMarkdownNode(
        nodes[index],
        latexPreprocessor,
        nodeId: 'n$index',
      ),
    );
  }
  return CompiledMarkdownDocument(
    normalizedContent: preparedContent,
    renderTier: _classifyRenderTier(nodes, latexPreprocessor),
    containsCitations: compiledNodes.any(_compiledNodeContainsCitations),
    heavyBlockCount: _countHeavyBlocksInCompiledNodes(compiledNodes),
    blocks: _compileDocumentBlocks(compiledNodes),
    nodes: compiledNodes,
    blockLatexExpressions: latexPreprocessor.blockExpressions,
    inlineLatexExpressions: latexPreprocessor.inlineExpressions,
  );
}

CompiledMarkdownNode _compileNodeFromMarkdownNode(
  md.Node node,
  LatexPreprocessor latexPreprocessor, {
  required String nodeId,
}) {
  if (node is md.Text) {
    final inlineSegments = _compileInlineSegments(node.text, latexPreprocessor);
    return CompiledMarkdownText(
      node.text,
      nodeId: nodeId,
      containsLatexPlaceholders: latexPreprocessor.containsPlaceholder(
        node.text,
      ),
      containsCitations: CitationParser.hasCitations(node.text),
      inlineSegments: inlineSegments,
    );
  }
  if (node is md.Element) {
    final codeMetadata = _extractCodeBlockMetadata(node);
    final compiledChildren = _compileMarkdownChildren(
      node.children ?? const <md.Node>[],
      latexPreprocessor,
      parentNodeId: nodeId,
    );
    final attributes = Map<String, String>.from(node.attributes);
    return CompiledMarkdownElement(
      nodeId: nodeId,
      tag: node.tag,
      blockKind: codeMetadata.blockKind,
      language: codeMetadata.language,
      inlinePreview: codeMetadata.inlinePreview,
      detailsData: node.tag == 'details'
          ? _buildCompiledDetailsData(
              attributes: attributes,
              children: compiledChildren,
            )
          : null,
      attributes: attributes,
      children: compiledChildren,
    );
  }
  final inlineSegments = _compileInlineSegments(
    node.textContent,
    latexPreprocessor,
  );
  return CompiledMarkdownText(
    node.textContent,
    nodeId: nodeId,
    containsLatexPlaceholders: latexPreprocessor.containsPlaceholder(
      node.textContent,
    ),
    containsCitations: CitationParser.hasCitations(node.textContent),
    inlineSegments: inlineSegments,
  );
}

List<CompiledMarkdownNode> _compileMarkdownChildren(
  List<md.Node> nodes,
  LatexPreprocessor latexPreprocessor, {
  required String parentNodeId,
}) {
  final compiledChildren = <CompiledMarkdownNode>[];
  for (var index = 0; index < nodes.length; index += 1) {
    compiledChildren.add(
      _compileNodeFromMarkdownNode(
        nodes[index],
        latexPreprocessor,
        nodeId: '$parentNodeId.$index',
      ),
    );
  }
  return List<CompiledMarkdownNode>.unmodifiable(compiledChildren);
}

List<CompiledMarkdownInlineSegment> _compileInlineSegments(
  String text,
  LatexPreprocessor latexPreprocessor,
) {
  if (text.isEmpty) {
    return const <CompiledMarkdownInlineSegment>[];
  }

  final spans = <CompiledMarkdownInlineSegment>[];
  final latexSegments = latexPreprocessor.containsPlaceholder(text)
      ? latexPreprocessor.splitOnPlaceholders(text)
      : <LatexSegment>[LatexSegment.text(text)];

  for (final latexSegment in latexSegments) {
    if (latexSegment.isLatex) {
      spans.add(
        CompiledMarkdownLatexSegment(
          tex: latexSegment.content,
          isBlock: latexSegment.isBlock,
        ),
      );
      continue;
    }

    final content = latexSegment.content;
    if (content.isEmpty) {
      continue;
    }
    final citationSegments = CitationParser.parse(content);
    if (citationSegments == null || citationSegments.isEmpty) {
      spans.add(CompiledMarkdownTextSegment(content));
      continue;
    }

    for (final citationSegment in citationSegments) {
      if (citationSegment.isText) {
        final textSegment = citationSegment.text ?? '';
        if (textSegment.isNotEmpty) {
          spans.add(CompiledMarkdownTextSegment(textSegment));
        }
        continue;
      }
      final citation = citationSegment.citation;
      if (citation != null && citation.sourceIds.isNotEmpty) {
        spans.add(
          CompiledMarkdownCitationSegment(
            citation.sourceIds,
            rawText: citation.raw,
          ),
        );
      }
    }
  }

  if (spans.length == 1 &&
      spans.first is CompiledMarkdownTextSegment &&
      (spans.first as CompiledMarkdownTextSegment).text == text) {
    return const <CompiledMarkdownInlineSegment>[];
  }

  return List<CompiledMarkdownInlineSegment>.unmodifiable(spans);
}

MarkdownRenderTier _classifyRenderTier(
  List<md.Node> nodes,
  LatexPreprocessor latexPreprocessor,
) {
  if (nodes.isEmpty) {
    return MarkdownRenderTier.plainText;
  }
  if (nodes.length != 1) {
    return MarkdownRenderTier.blocks;
  }

  final node = nodes.first;
  if (node is md.Text) {
    return _isPlainRenderText(node.text, latexPreprocessor)
        ? MarkdownRenderTier.plainText
        : MarkdownRenderTier.richText;
  }

  if (node is! md.Element || node.tag != 'p') {
    return MarkdownRenderTier.blocks;
  }

  final children = node.children ?? const <md.Node>[];
  if (_isPlainInlineNodes(children, latexPreprocessor)) {
    return MarkdownRenderTier.plainText;
  }
  if (_isInlineCompatibleNodes(children)) {
    return MarkdownRenderTier.richText;
  }
  return MarkdownRenderTier.blocks;
}

bool _isPlainInlineNodes(
  List<md.Node> nodes,
  LatexPreprocessor latexPreprocessor,
) {
  if (nodes.length != 1) {
    return false;
  }
  final node = nodes.first;
  return node is md.Text && _isPlainRenderText(node.text, latexPreprocessor);
}

bool _isPlainRenderText(String text, LatexPreprocessor latexPreprocessor) {
  return !latexPreprocessor.containsPlaceholder(text) &&
      !CitationParser.hasCitations(text);
}

bool _isInlineCompatibleNodes(List<md.Node> nodes) {
  for (final node in nodes) {
    if (node is md.Text) {
      continue;
    }
    if (node is! md.Element) {
      return false;
    }
    if (!_isInlineCompatibleElement(node)) {
      return false;
    }
  }
  return true;
}

bool _isInlineCompatibleElement(md.Element element) {
  switch (element.tag) {
    case 'strong':
    case 'em':
    case 'del':
    case 'code':
    case 'a':
    case 'mention':
    case 'br':
      return _isInlineCompatibleNodes(element.children ?? const <md.Node>[]);
    default:
      return false;
  }
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

List<CompiledMarkdownBlock> _compileDocumentBlocks(
  List<CompiledMarkdownNode> nodes,
) {
  final blocks = <CompiledMarkdownBlock>[];
  var index = 0;
  while (index < nodes.length) {
    final detailBlock = _tryBuildCompiledDetailsBlock(nodes[index]);
    if (detailBlock == null) {
      blocks.add(
        CompiledMarkdownNodeBlock.fromNode(
          blockId: nodes[index].nodeId.isEmpty
              ? 'node:$index'
              : nodes[index].nodeId,
          node: nodes[index],
        ),
      );
      index += 1;
      continue;
    }

    final shouldGroup = _groupableCompiledDetailTypes.contains(
      detailBlock.type,
    );
    if (!shouldGroup) {
      blocks.add(detailBlock);
      index += 1;
      continue;
    }

    final groupedItems = <CompiledMarkdownDetailsBlock>[detailBlock];
    var lookahead = index + 1;
    while (lookahead < nodes.length) {
      final nextDetailBlock = _tryBuildCompiledDetailsBlock(nodes[lookahead]);
      if (nextDetailBlock == null || nextDetailBlock.type != detailBlock.type) {
        break;
      }
      groupedItems.add(nextDetailBlock);
      lookahead += 1;
    }

    if (groupedItems.length == 1) {
      blocks.add(detailBlock);
    } else {
      blocks.add(
        CompiledMarkdownDetailsGroup(
          blockId:
              'group:${groupedItems.first.blockId}:${groupedItems.first.type}',
          items: groupedItems,
        ),
      );
    }
    index = lookahead;
  }
  return List<CompiledMarkdownBlock>.unmodifiable(blocks);
}

CompiledMarkdownDetailsBlock? _tryBuildCompiledDetailsBlock(
  CompiledMarkdownNode node,
) {
  if (node is! CompiledMarkdownElement || node.tag != 'details') {
    return null;
  }
  return _buildCompiledDetailsBlock(node);
}

CompiledMarkdownDetailsBlock _buildCompiledDetailsBlock(
  CompiledMarkdownElement element,
) {
  assert(
    element.detailsData != null,
    'Expected details elements to carry compiled details metadata.',
  );
  return CompiledMarkdownDetailsBlock(
    blockId: element.nodeId.isEmpty ? 'details' : element.nodeId,
    detailsData: element.detailsData!,
  );
}

CompiledMarkdownDetailsData _buildCompiledDetailsData({
  required Map<String, String> attributes,
  required List<CompiledMarkdownNode> children,
}) {
  var summaryText = '';
  var bodyStartIndex = 0;

  if (children.isNotEmpty) {
    final firstChild = children.first;
    if (firstChild is CompiledMarkdownElement && firstChild.tag == 'summary') {
      summaryText = firstChild.textContent.trim();
      bodyStartIndex = 1;
    }
  }

  final bodyMarkdown = _decodeDetailAttribute(attributes['body_markdown']);
  final type = attributes['type']?.trim() ?? '';
  final name = attributes['name']?.trim() ?? '';
  final done = attributes['done'];
  final isDone = done == 'true';
  final isPending = done != null && done != 'true';
  final durationSeconds = int.tryParse(attributes['duration'] ?? '0') ?? 0;

  return CompiledMarkdownDetailsData(
    summaryText: summaryText,
    bodyMarkdown: bodyMarkdown,
    bodyStartIndex: bodyStartIndex,
    hasBody: bodyMarkdown.trim().isNotEmpty,
    kind: _detailsKindForType(type),
    type: type,
    name: name,
    isDone: isDone,
    isPending: isPending,
    durationSeconds: durationSeconds,
    toolCallData: type == 'tool_calls'
        ? _compileToolCallData(attributes)
        : null,
  );
}

CompiledMarkdownDetailsKind _detailsKindForType(String type) {
  return switch (type) {
    'tool_calls' => CompiledMarkdownDetailsKind.toolCall,
    'reasoning' => CompiledMarkdownDetailsKind.reasoning,
    'code_interpreter' => CompiledMarkdownDetailsKind.codeInterpreter,
    _ => CompiledMarkdownDetailsKind.generic,
  };
}

CompiledMarkdownToolCallData _compileToolCallData(
  Map<String, String> attributes,
) {
  final argumentsText = _decodeDetailAttribute(attributes['arguments']);
  final resultText = _decodeDetailAttribute(attributes['result']);
  final parsedArguments = _parseDetailJsonString(argumentsText);
  final parsedResult = _parseDetailJsonString(resultText);
  final rawFiles = _parseDetailJsonString(
    _decodeDetailAttribute(attributes['files']),
  );
  final rawEmbeds = _parseDetailJsonString(
    _decodeDetailAttribute(attributes['embeds']),
  );

  final argumentEntries = parsedArguments is Map
      ? parsedArguments.entries
            .map(
              (entry) => CompiledMarkdownToolCallArgumentEntry(
                label: entry.key.toString(),
                value: _stringifyDetailValue(entry.value),
              ),
            )
            .toList(growable: false)
      : const <CompiledMarkdownToolCallArgumentEntry>[];

  final argumentsCode = argumentsText.isEmpty || parsedArguments is Map
      ? ''
      : _formatDetailJsonString(argumentsText);

  final resultCode = parsedResult is Map || parsedResult is List
      ? const JsonEncoder.withIndent('  ').convert(parsedResult)
      : '';
  final resultDisplayText = resultText.isEmpty || resultCode.isNotEmpty
      ? ''
      : _stringifyDetailValue(parsedResult);

  final embeds = normalizeEmbedList(rawEmbeds)
      .map(extractEmbedSource)
      .whereType<String>()
      .where((value) => value.isNotEmpty)
      .toList(growable: false);

  final imageUrls = _extractToolCallImageUrls(rawFiles);

  return CompiledMarkdownToolCallData(
    argumentsText: argumentsText,
    resultText: resultText,
    argumentEntries: argumentEntries,
    argumentsCode: argumentsCode,
    resultCode: resultCode,
    resultDisplayText: resultDisplayText,
    embedSources: embeds,
    imageUrls: imageUrls,
  );
}

String _decodeDetailAttribute(String? input) {
  if (input == null || input.isEmpty) {
    return '';
  }
  return _detailsAttributeUnescape.convert(input);
}

Object? _parseDetailJsonString(String input) {
  if (input.isEmpty) {
    return '';
  }
  try {
    final decoded = json.decode(input);
    if (decoded is String && decoded != input) {
      return _parseDetailJsonString(decoded);
    }
    return decoded;
  } catch (_) {
    return input;
  }
}

String _stringifyDetailValue(Object? value) {
  if (value == null) {
    return '';
  }
  if (value is String) {
    return value;
  }
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value.toString();
  }
}

String _formatDetailJsonString(String raw) {
  final parsed = _parseDetailJsonString(raw);
  if (parsed is String) {
    return parsed;
  }
  try {
    return const JsonEncoder.withIndent('  ').convert(parsed);
  } catch (_) {
    return raw;
  }
}

List<String> _extractToolCallImageUrls(Object? rawFiles) {
  if (rawFiles is! List) {
    return const <String>[];
  }

  final imageUrls = <String>[];
  for (final entry in rawFiles) {
    final uri = _tryToolCallImageUri(entry);
    if (uri != null) {
      imageUrls.add(uri.toString());
    }
  }
  return List<String>.unmodifiable(imageUrls);
}

Uri? _tryToolCallImageUri(Object? value) {
  if (value is String) {
    if (!value.startsWith('data:image/') &&
        !value.startsWith('http://') &&
        !value.startsWith('https://')) {
      return null;
    }
    return Uri.tryParse(value);
  }

  if (value is Map) {
    final type = value['type']?.toString();
    final contentType = value['content_type']?.toString() ?? '';
    final url = value['url']?.toString();
    final isImage = type == 'image' || contentType.startsWith('image/');
    if (!isImage || url == null || url.isEmpty) {
      return null;
    }
    return Uri.tryParse(url);
  }

  return null;
}

({CompiledMarkdownBlockKind blockKind, String language, bool inlinePreview})
_extractCodeBlockMetadata(md.Element element) {
  if (element.tag != 'pre') {
    return (
      blockKind: CompiledMarkdownBlockKind.none,
      language: '',
      inlinePreview: false,
    );
  }

  final codeElement = _extractCodeChild(element);
  final language = _extractLanguage(codeElement) ?? '';
  final code = (codeElement ?? element).textContent;
  if (language == 'mermaid') {
    return (
      blockKind: CompiledMarkdownBlockKind.mermaid,
      language: language,
      inlinePreview: false,
    );
  }
  if (language == 'html' && _containsChartJs(code)) {
    return (
      blockKind: CompiledMarkdownBlockKind.chartJs,
      language: language,
      inlinePreview: false,
    );
  }

  final previewable = _isPreviewableCodeBlock(language, code);
  return (
    blockKind: previewable
        ? CompiledMarkdownBlockKind.previewableCode
        : CompiledMarkdownBlockKind.code,
    language: language,
    inlinePreview: previewable && _shouldInlinePreviewCodeBlock(language, code),
  );
}

md.Element? _extractCodeChild(md.Element pre) {
  for (final child in pre.children ?? const <md.Node>[]) {
    if (child is md.Element && child.tag == 'code') {
      return child;
    }
  }
  return null;
}

String? _extractLanguage(md.Element? code) {
  if (code == null) {
    return null;
  }
  final cls = code.attributes['class'] ?? '';
  if (!cls.startsWith('language-')) {
    return null;
  }
  return cls.substring('language-'.length);
}

bool _containsChartJs(String html) {
  return html.contains('new Chart(') || html.contains('Chart.');
}

bool _isPreviewableCodeBlock(String language, String code) {
  final normalized = language.trim().toLowerCase();
  return normalized == 'html' ||
      normalized == 'svg' ||
      (normalized == 'xml' && code.contains('<svg'));
}

bool _shouldInlinePreviewCodeBlock(String language, String code) {
  final normalized = language.trim().toLowerCase();
  return normalized == 'svg' || (normalized == 'xml' && code.contains('<svg'));
}

class _MarkdownCompilerBackend {
  Isolate? _isolate;
  ReceivePort? _receivePort;
  SendPort? _sendPort;
  Future<SendPort>? _startupFuture;
  final Map<int, Completer<Map<String, Object?>>> _pendingSingle =
      <int, Completer<Map<String, Object?>>>{};
  final Map<int, Completer<List<Map<String, Object?>>>> _pendingBatch =
      <int, Completer<List<Map<String, Object?>>>>{};
  int _requestCounter = 0;
  bool _disposed = false;

  Future<Map<String, Object?>> compilePrepared(String preparedContent) async {
    final sendPort = await _ensureStarted();
    if (_disposed) {
      throw StateError('Markdown compiler backend disposed');
    }

    final requestId = ++_requestCounter;
    final completer = Completer<Map<String, Object?>>();
    _pendingSingle[requestId] = completer;
    sendPort.send(<String, Object?>{
      'id': requestId,
      'preparedContent': preparedContent,
    });
    return completer.future;
  }

  Future<List<Map<String, Object?>>> compilePreparedBatch(
    List<String> preparedContents,
  ) async {
    final sendPort = await _ensureStarted();
    if (_disposed) {
      throw StateError('Markdown compiler backend disposed');
    }

    final requestId = ++_requestCounter;
    final completer = Completer<List<Map<String, Object?>>>();
    _pendingBatch[requestId] = completer;
    sendPort.send(<String, Object?>{
      'id': requestId,
      'preparedContents': preparedContents,
    });
    return completer.future;
  }

  Future<SendPort> _ensureStarted() {
    final existing = _sendPort;
    if (existing != null) {
      return SynchronousFuture(existing);
    }
    final startup = _startupFuture;
    if (startup != null) {
      return startup;
    }
    final future = _spawnIsolate();
    _startupFuture = future;
    return future;
  }

  Future<SendPort> _spawnIsolate() async {
    final receivePort = ReceivePort();
    _receivePort = receivePort;
    final completer = Completer<SendPort>();

    receivePort.listen((dynamic message) {
      if (message is SendPort) {
        if (!completer.isCompleted) {
          _sendPort = message;
          completer.complete(message);
        }
        return;
      }
      _handleResponse(message);
    });

    try {
      _isolate = await Isolate.spawn<SendPort>(
        _markdownCompilerIsolateMain,
        receivePort.sendPort,
        debugName: 'markdown_compiler',
      );
      return await completer.future.timeout(const Duration(seconds: 5));
    } catch (error) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
      rethrow;
    } finally {
      _startupFuture = null;
    }
  }

  void _handleResponse(dynamic message) {
    if (message is! Map) {
      return;
    }
    final typed = message.cast<Object?, Object?>();
    final requestId = typed['id'];
    if (requestId is! int) {
      return;
    }

    final error = typed['error'];
    if (error != null) {
      final stackTrace = StackTrace.fromString(
        (typed['stackTrace'] ?? '').toString(),
      );
      final singleCompleter = _pendingSingle.remove(requestId);
      if (singleCompleter != null && !singleCompleter.isCompleted) {
        singleCompleter.completeError(Exception(error.toString()), stackTrace);
      }
      final batchCompleter = _pendingBatch.remove(requestId);
      if (batchCompleter != null && !batchCompleter.isCompleted) {
        batchCompleter.completeError(Exception(error.toString()), stackTrace);
      }
      return;
    }

    final result = typed['result'];
    if (result is Map<Object?, Object?>) {
      final completer = _pendingSingle.remove(requestId);
      if (completer != null && !completer.isCompleted) {
        completer.complete(result.cast<String, Object?>());
      }
      return;
    }
    if (result is List<dynamic>) {
      final completer = _pendingBatch.remove(requestId);
      if (completer == null || completer.isCompleted) {
        return;
      }
      final typedResults = result
          .cast<Map<Object?, Object?>>()
          .map((entry) => entry.cast<String, Object?>())
          .toList(growable: false);
      completer.complete(typedResults);
      return;
    }

    final invalidResponseError = StateError(
      'Invalid markdown compiler response: $message',
    );
    final singleCompleter = _pendingSingle.remove(requestId);
    if (singleCompleter != null && !singleCompleter.isCompleted) {
      singleCompleter.completeError(invalidResponseError);
    }
    final batchCompleter = _pendingBatch.remove(requestId);
    if (batchCompleter != null && !batchCompleter.isCompleted) {
      batchCompleter.completeError(invalidResponseError);
    }
  }

  void dispose() {
    _disposed = true;
    final pendingSingle = List<Completer<Map<String, Object?>>>.from(
      _pendingSingle.values,
    );
    final pendingBatch = List<Completer<List<Map<String, Object?>>>>.from(
      _pendingBatch.values,
    );
    _pendingSingle.clear();
    _pendingBatch.clear();
    for (final completer in pendingSingle) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('Markdown compiler backend disposed'),
        );
      }
    }
    for (final completer in pendingBatch) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('Markdown compiler backend disposed'),
        );
      }
    }
    _receivePort?.close();
    _receivePort = null;
    _sendPort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _startupFuture = null;
  }
}

class _MarkdownPrepareBackend {
  Isolate? _isolate;
  ReceivePort? _receivePort;
  SendPort? _sendPort;
  Future<SendPort>? _startupFuture;
  final Map<int, Completer<String>> _pendingPrepared =
      <int, Completer<String>>{};
  int _requestCounter = 0;
  bool _disposed = false;

  Future<String> prepareContent(
    String content, {
    required bool streaming,
  }) async {
    final sendPort = await _ensureStarted();
    if (_disposed) {
      throw StateError('Markdown prepare backend disposed');
    }

    final requestId = ++_requestCounter;
    final completer = Completer<String>();
    _pendingPrepared[requestId] = completer;
    sendPort.send(<String, Object?>{
      'id': requestId,
      'content': content,
      'streaming': streaming,
    });
    return completer.future;
  }

  Future<SendPort> _ensureStarted() {
    final existing = _sendPort;
    if (existing != null) {
      return SynchronousFuture(existing);
    }
    final startup = _startupFuture;
    if (startup != null) {
      return startup;
    }
    final future = _spawnIsolate();
    _startupFuture = future;
    return future;
  }

  Future<SendPort> _spawnIsolate() async {
    final receivePort = ReceivePort();
    _receivePort = receivePort;
    final completer = Completer<SendPort>();

    receivePort.listen((dynamic message) {
      if (message is SendPort) {
        if (!completer.isCompleted) {
          _sendPort = message;
          completer.complete(message);
        }
        return;
      }
      _handleResponse(message);
    });

    try {
      _isolate = await Isolate.spawn<SendPort>(
        _markdownPrepareIsolateMain,
        receivePort.sendPort,
        debugName: 'markdown_prepare',
      );
      return await completer.future.timeout(const Duration(seconds: 5));
    } catch (error) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
      rethrow;
    } finally {
      _startupFuture = null;
    }
  }

  void _handleResponse(dynamic message) {
    if (message is! Map) {
      return;
    }
    final typed = message.cast<Object?, Object?>();
    final requestId = typed['id'];
    if (requestId is! int) {
      return;
    }

    final error = typed['error'];
    if (error != null) {
      final stackTrace = StackTrace.fromString(
        (typed['stackTrace'] ?? '').toString(),
      );
      final completer = _pendingPrepared.remove(requestId);
      if (completer != null && !completer.isCompleted) {
        completer.completeError(Exception(error.toString()), stackTrace);
      }
      return;
    }

    final result = typed['result'];
    if (result is String) {
      final completer = _pendingPrepared.remove(requestId);
      if (completer != null && !completer.isCompleted) {
        completer.complete(result);
      }
      return;
    }

    final invalidResponseError = StateError(
      'Invalid markdown prepare response: $message',
    );
    final completer = _pendingPrepared.remove(requestId);
    if (completer != null && !completer.isCompleted) {
      completer.completeError(invalidResponseError);
    }
  }

  void dispose() {
    _disposed = true;
    final pendingPrepared = List<Completer<String>>.from(
      _pendingPrepared.values,
    );
    _pendingPrepared.clear();
    for (final completer in pendingPrepared) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('Markdown prepare backend disposed'),
        );
      }
    }
    _receivePort?.close();
    _receivePort = null;
    _sendPort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _startupFuture = null;
  }
}

@pragma('vm:entry-point')
void _markdownCompilerIsolateMain(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  receivePort.listen((dynamic message) {
    if (message is! Map) {
      return;
    }
    final typed = message.cast<Object?, Object?>();
    final requestId = typed['id'];
    if (requestId is! int) {
      return;
    }
    try {
      final rawPreparedContents =
          typed['preparedContents'] as List<dynamic>? ?? const <dynamic>[];
      if (rawPreparedContents.isNotEmpty) {
        final preparedContents = rawPreparedContents
            .map((value) => value.toString())
            .toList(growable: false);
        final result = preparedContents
            .map(_compilePreparedMarkdownDocument)
            .map((document) => document.toMap())
            .toList(growable: false);
        mainSendPort.send(<String, Object?>{'id': requestId, 'result': result});
        return;
      }

      final preparedContent = (typed['preparedContent'] ?? '') as String;
      final result = _compilePreparedMarkdownDocument(preparedContent).toMap();
      mainSendPort.send(<String, Object?>{'id': requestId, 'result': result});
    } catch (error, stackTrace) {
      mainSendPort.send(<String, Object?>{
        'id': requestId,
        'error': error.toString(),
        'stackTrace': stackTrace.toString(),
      });
    }
  });
}

@pragma('vm:entry-point')
void _markdownPrepareIsolateMain(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  receivePort.listen((dynamic message) {
    if (message is! Map) {
      return;
    }
    final typed = message.cast<Object?, Object?>();
    final requestId = typed['id'];
    if (requestId is! int) {
      return;
    }
    try {
      final content = (typed['content'] ?? '') as String;
      final streaming = typed['streaming'] == true;
      final result = prepareMarkdownContent(content, streaming: streaming);
      mainSendPort.send(<String, Object?>{'id': requestId, 'result': result});
    } catch (error, stackTrace) {
      mainSendPort.send(<String, Object?>{
        'id': requestId,
        'error': error.toString(),
        'stackTrace': stackTrace.toString(),
      });
    }
  });
}

class _CompiledMarkdownCache {
  static const int _maxWeight = 512000;

  final LinkedHashMap<String, CompiledMarkdownDocument> _entries =
      LinkedHashMap<String, CompiledMarkdownDocument>();
  int _currentWeight = 0;

  bool contains(String preparedContent) =>
      _entries.containsKey(preparedContent);

  CompiledMarkdownDocument? read(String preparedContent) {
    final cached = _entries.remove(preparedContent);
    if (cached == null) {
      return null;
    }
    _entries[preparedContent] = cached;
    return cached;
  }

  CompiledMarkdownDocument write(
    String preparedContent,
    CompiledMarkdownDocument document,
  ) {
    final previous = _entries.remove(preparedContent);
    if (previous != null) {
      _currentWeight -= _entryWeight(previous);
    }

    _entries[preparedContent] = document;
    _currentWeight += _entryWeight(document);
    _evictIfNeeded();
    return document;
  }

  void clear() {
    _entries.clear();
    _currentWeight = 0;
  }

  int get length => _entries.length;

  List<String> get keys => List<String>.unmodifiable(_entries.keys);

  int _entryWeight(CompiledMarkdownDocument document) =>
      document.estimatedWeight;

  void _evictIfNeeded() {
    while (_entries.length > 32 || _currentWeight > _maxWeight) {
      final firstKey = _entries.keys.first;
      final removed = _entries.remove(firstKey);
      if (removed == null) {
        continue;
      }
      _currentWeight -= _entryWeight(removed);
    }
  }
}
