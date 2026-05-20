import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/shared/widgets/markdown/compiled_markdown_document.dart';
import 'package:conduit/shared/widgets/markdown/markdown_compile_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingBatchMarkdownCompileService extends MarkdownCompileService {
  _RecordingBatchMarkdownCompileService()
    : super(workerManager: WorkerManager());

  final List<List<String>> batchCalls = <List<String>>[];

  @override
  Future<List<CompiledMarkdownDocument>> compilePreparedBatch(
    Iterable<String> preparedContents, {
    bool allowSynchronous = false,
    bool widgetTest = false,
  }) async {
    final contents = preparedContents.toList(growable: false);
    batchCalls.add(contents);
    return contents.map(compilePreparedSynchronously).toList(growable: false);
  }
}

void main() {
  setUp(debugResetCompiledMarkdownCache);
  tearDown(debugResetCompiledMarkdownCache);

  group('compilePreparedMarkdownSync', () {
    test('classifies a plain paragraph as plainText', () {
      final document = compilePreparedMarkdownSync('Plain sentence.');

      expect(document.renderTier, MarkdownRenderTier.plainText);
      expect(document.nodes, isNotEmpty);
    });

    test('classifies a single inline-formatted paragraph as richText', () {
      final document = compilePreparedMarkdownSync(
        'Plain **bold** sentence with a [link](https://example.com).',
      );

      expect(document.renderTier, MarkdownRenderTier.richText);
      expect(document.nodes, hasLength(1));
    });

    test('classifies block content as blocks', () {
      final document = compilePreparedMarkdownSync('# Heading\n\n- one\n- two');

      expect(document.renderTier, MarkdownRenderTier.blocks);
      expect(document.nodes.length, greaterThan(1));
      expect(document.blocks, isNotEmpty);
      final headingBlock = document.blocks.first as CompiledMarkdownNodeBlock;
      expect(headingBlock.kind, CompiledMarkdownNodeBlockKind.heading1);
    });

    test('captures citation and heavy block metadata', () {
      final document = compilePreparedMarkdownSync(
        [
          'See [1] for the diagram.',
          '```mermaid',
          'graph TD',
          '  A-->B',
          '```',
        ].join('\n\n'),
      );

      expect(document.containsCitations, isTrue);
      expect(document.heavyBlockCount, 1);

      final paragraph = document.nodes.first as CompiledMarkdownElement;
      final paragraphText = paragraph.children.first as CompiledMarkdownText;
      expect(paragraphText.containsCitations, isTrue);
      expect(paragraphText.hasInlineSegments, isTrue);
      expect(
        paragraphText.inlineSegments
            .whereType<CompiledMarkdownCitationSegment>(),
        hasLength(1),
      );
      expect(
        paragraphText.inlineSegments
            .whereType<CompiledMarkdownCitationSegment>()
            .single
            .sourceIds,
        <int>[1],
      );
      expect(
        paragraphText.inlineSegments
            .whereType<CompiledMarkdownCitationSegment>()
            .single
            .rawText,
        '[1]',
      );

      final codeBlock = document.nodes.last as CompiledMarkdownElement;
      expect(codeBlock.blockKind, CompiledMarkdownBlockKind.mermaid);
      expect(codeBlock.isHeavyBlock, isTrue);
      expect(codeBlock.language, 'mermaid');
    });

    test(
      'assigns stable node ids and precompiles grouped tool call blocks',
      () {
        final document = compilePreparedMarkdownSync(
          [
            '<details type="tool_calls" done="true" name="search">',
            '<summary>search</summary>',
            'done',
            '</details>',
            '<details type="tool_calls" done="true" name="browser">',
            '<summary>browser</summary>',
            'done',
            '</details>',
          ].join('\n'),
        );

        final firstNode = document.nodes.first as CompiledMarkdownElement;
        expect(firstNode.nodeId, isNotEmpty);
        expect(firstNode.children.first.nodeId, isNotEmpty);

        expect(document.blocks, hasLength(1));
        final group = document.blocks.first as CompiledMarkdownDetailsGroup;
        expect(group.blockId, contains('group:'));
        expect(group.items, hasLength(2));
        expect(group.items.first.blockId, firstNode.nodeId);
        expect(group.items.first.name, 'search');
        expect(group.items[1].name, 'browser');
      },
    );

    test('compiles semantic tool call detail payloads', () {
      final document = compilePreparedMarkdownSync(
        [
          '<details type="tool_calls" done="true" name="search" '
              'arguments="{&quot;q&quot;:&quot;cats&quot;}" '
              'result="&quot;done&quot;" '
              'embeds="[&quot;https://example.com/embed&quot;]" '
              'files="[{&quot;type&quot;:&quot;image&quot;,&quot;url&quot;:&quot;https://example.com/cat.png&quot;}]">',
          '</details>',
        ].join('\n'),
      );

      final detailsElement = document.nodes.first as CompiledMarkdownElement;
      final detailsData = detailsElement.detailsData;
      expect(detailsData, isNotNull);
      expect(detailsData!.kind, CompiledMarkdownDetailsKind.toolCall);
      expect(detailsData.name, 'search');
      expect(detailsData.toolCallData, isNotNull);

      final toolCallData = detailsData.toolCallData!;
      expect(toolCallData.argumentEntries, hasLength(1));
      expect(toolCallData.argumentEntries.single.label, 'q');
      expect(toolCallData.argumentEntries.single.value, 'cats');
      expect(toolCallData.resultDisplayText, 'done');
      expect(toolCallData.embedSources, <String>['https://example.com/embed']);
      expect(toolCallData.imageUrls, <String>['https://example.com/cat.png']);

      final detailsBlock =
          document.blocks.first as CompiledMarkdownDetailsBlock;
      expect(detailsBlock.detailsData, detailsData);
      expect(detailsBlock.toolCallData, toolCallData);
    });
  });

  test('compilePrepared uses the async compiler backend', () async {
    final service = MarkdownCompileService(workerManager: WorkerManager());
    addTearDown(service.dispose);

    final document = await service.compilePrepared(
      'Async **compile** keeps inline formatting.',
    );

    expect(document.renderTier, MarkdownRenderTier.richText);
    expect(
      document.normalizedContent,
      'Async **compile** keeps inline formatting.',
    );
    expect(document.nodes, hasLength(1));
  });

  test(
    'prepareContent uses the async prepare backend for long streaming text',
    () async {
      MarkdownPrepareExecutionPath? executionPath;
      final service = MarkdownCompileService(
        workerManager: WorkerManager(),
        debugOnPrepareExecution: (path) => executionPath = path,
      );
      addTearDown(service.dispose);

      final longPrefix = List<String>.filled(220, 'stream chunk').join(' ');
      final content = [
        longPrefix,
        '<details type="tool_calls" name="search">',
        '<summary>Tool Executed</summary>',
        '{"q":"cats"}',
      ].join('\n\n');

      expect(
        service.shouldPrepareSynchronously(content, widgetTest: false),
        isFalse,
      );

      final prepared = await service.prepareContent(
        content,
        streaming: true,
        allowSynchronous: true,
        widgetTest: false,
      );

      expect(prepared, contains(longPrefix));
      expect(prepared, isNot(contains('<details type="tool_calls"')));
      expect(
        prepared,
        equals(prepareMarkdownContent(content, streaming: true)),
      );
      expect(executionPath, MarkdownPrepareExecutionPath.asyncBackend);
    },
  );

  test(
    'prepareContent falls back to sync when the async prepare backend fails',
    () async {
      MarkdownPrepareExecutionPath? executionPath;
      final service = MarkdownCompileService(
        workerManager: WorkerManager(),
        debugOnPrepareExecution: (path) => executionPath = path,
        debugPrepareContentOverride: (content, streaming) async {
          throw StateError(
            'prepare backend failed: streaming=$streaming length=${content.length}',
          );
        },
      );
      addTearDown(service.dispose);

      final longPrefix = List<String>.filled(220, 'stream chunk').join(' ');
      final content = [
        longPrefix,
        '<details type="tool_calls" name="search">',
        '<summary>Tool Executed</summary>',
        '{"q":"cats"}',
      ].join('\n\n');

      expect(
        service.shouldPrepareSynchronously(content, widgetTest: false),
        isFalse,
      );

      final prepared = await service.prepareContent(
        content,
        streaming: true,
        allowSynchronous: true,
        widgetTest: false,
      );

      expect(
        prepared,
        equals(prepareMarkdownContent(content, streaming: true)),
      );
      expect(executionPath, MarkdownPrepareExecutionPath.fallbackSync);
    },
  );

  test(
    'compilePreparedBatch preserves order and dedupes cache entries',
    () async {
      final service = MarkdownCompileService(workerManager: WorkerManager());
      addTearDown(service.dispose);

      final documents = await service.compilePreparedBatch(
        const <String>['First **entry**', 'Second entry', 'First **entry**'],
        allowSynchronous: true,
        widgetTest: true,
      );

      expect(documents, hasLength(3));
      expect(documents[0].normalizedContent, 'First **entry**');
      expect(documents[1].normalizedContent, 'Second entry');
      expect(documents[2].normalizedContent, 'First **entry**');
      expect(identical(documents[0], documents[2]), isTrue);
      expect(debugCompiledMarkdownCacheSize(), 2);
    },
  );

  test('prewarmPrepared batches uncached markdown slices', () async {
    final service = _RecordingBatchMarkdownCompileService();
    addTearDown(service.dispose);

    service.compilePreparedSynchronously('cached entry');
    service.prewarmPrepared(const <String>[
      'cached entry',
      'first fresh entry',
      '',
      'second fresh entry',
      'first fresh entry',
    ]);

    await Future<void>.delayed(Duration.zero);

    expect(service.batchCalls, <List<String>>[
      <String>['first fresh entry', 'second fresh entry'],
    ]);
  });
}
