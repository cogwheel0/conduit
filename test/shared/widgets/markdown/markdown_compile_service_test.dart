import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/shared/widgets/markdown/compiled_markdown_document.dart';
import 'package:conduit/shared/widgets/markdown/markdown_compile_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingBatchMarkdownCompileService extends MarkdownCompileService {
  _RecordingBatchMarkdownCompileService()
    : super(workerManager: WorkerManager());

  final List<List<String>> batchCalls = <List<String>>[];
  final List<bool> synchronousBatchInputs = <bool>[];
  final List<bool> widgetTestBatchInputs = <bool>[];
  final List<String> preparedInputs = <String>[];
  final List<bool> synchronousPreparationInputs = <bool>[];
  final List<String> events = <String>[];

  @override
  Future<String> prepareContent(
    String content, {
    required bool streaming,
    bool allowSynchronous = false,
    bool widgetTest = false,
  }) async {
    preparedInputs.add(content);
    synchronousPreparationInputs.add(allowSynchronous);
    events.add('prepare:$content');
    return prepareMarkdownContent(content, streaming: streaming);
  }

  @override
  Future<List<CompiledMarkdownDocument>> compilePreparedBatch(
    Iterable<String> preparedContents, {
    bool allowSynchronous = false,
    bool widgetTest = false,
  }) async {
    final contents = preparedContents.toList(growable: false);
    batchCalls.add(contents);
    synchronousBatchInputs.add(allowSynchronous);
    widgetTestBatchInputs.add(widgetTest);
    events.add('compile:${contents.join('|')}');
    return contents.map(compilePreparedSynchronously).toList(growable: false);
  }
}

class _GatedBatchMarkdownCompileService
    extends _RecordingBatchMarkdownCompileService {
  final Completer<void> firstCompileStarted = Completer<void>();
  final Completer<void> releaseFirstCompile = Completer<void>();
  var compileCalls = 0;

  @override
  Future<List<CompiledMarkdownDocument>> compilePreparedBatch(
    Iterable<String> preparedContents, {
    bool allowSynchronous = false,
    bool widgetTest = false,
  }) async {
    compileCalls += 1;
    if (compileCalls == 1) {
      firstCompileStarted.complete();
      await releaseFirstCompile.future;
    }
    return super.compilePreparedBatch(
      preparedContents,
      allowSynchronous: allowSynchronous,
      widgetTest: widgetTest,
    );
  }
}

List<CompiledMarkdownLatexSegment> _collectLatexSegments(
  Iterable<CompiledMarkdownNode> nodes,
) {
  final segments = <CompiledMarkdownLatexSegment>[];
  for (final node in nodes) {
    if (node is CompiledMarkdownText) {
      segments.addAll(
        node.inlineSegments.whereType<CompiledMarkdownLatexSegment>(),
      );
      continue;
    }
    if (node is CompiledMarkdownElement) {
      segments.addAll(_collectLatexSegments(node.children));
    }
  }
  return segments;
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

    test('captures inline latex segments and marks documents as latex', () {
      final document = compilePreparedMarkdownSync(
        r'The area is $r^2$ and \(x+y\).',
      );

      expect(document.hasLatex, isTrue);
      expect(
        document.inlineLatexExpressions.values,
        unorderedEquals(<String>['r^2', 'x+y']),
      );

      final latexSegments = _collectLatexSegments(document.nodes);
      expect(latexSegments, hasLength(2));
      expect(latexSegments.map((segment) => segment.tex).toList(), <String>[
        'r^2',
        'x+y',
      ]);
      expect(latexSegments.every((segment) => segment.isBlock), isFalse);
    });

    test('captures block latex expressions during compilation', () {
      final document = compilePreparedMarkdownSync(
        r'Before'
        '\n\n'
        r'$$'
        '\n'
        r'x^2 + y^2'
        '\n'
        r'$$'
        '\n\n'
        r'After',
      );

      expect(document.hasLatex, isTrue);
      expect(document.blockLatexExpressions.values, <String>['x^2 + y^2']);

      final latexSegments = _collectLatexSegments(document.nodes);
      expect(latexSegments.where((segment) => segment.isBlock), hasLength(1));
      expect(
        latexSegments.where((segment) => segment.isBlock).single.tex,
        'x^2 + y^2',
      );
    });

    test('does not treat currency text as latex', () {
      final document = compilePreparedMarkdownSync(
        r'Plain currency text like $65,539 USD is about ~$42.6 million.',
      );

      expect(document.hasLatex, isFalse);
      expect(document.blockLatexExpressions, isEmpty);
      expect(document.inlineLatexExpressions, isEmpty);
      expect(_collectLatexSegments(document.nodes), isEmpty);
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
      expect(detailsData.bodyMarkdown, isEmpty);
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

    test('stores details bodies as lazy markdown payloads', () {
      final document = compilePreparedMarkdownSync(
        [
          '<details type="reasoning" done="false">',
          '<summary>Thinking…</summary>',
          'First step',
          'Second step',
          '</details>',
        ].join('\n'),
      );

      final detailsElement = document.nodes.first as CompiledMarkdownElement;
      final detailsData = detailsElement.detailsData;
      expect(detailsData, isNotNull);
      expect(detailsData!.summaryText, 'Thinking…');
      expect(detailsData.bodyMarkdown, 'First step\n\nSecond step');

      final detailsBlock =
          document.blocks.first as CompiledMarkdownDetailsBlock;
      expect(detailsBlock.bodyMarkdown, 'First step\n\nSecond step');
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

    check(service.batchCalls).deepEquals(<List<String>>[
      <String>['first fresh entry', 'second fresh entry'],
    ]);
  });

  test(
    'prewarmContents prepares raw slices before batch compilation',
    () async {
      final service = _RecordingBatchMarkdownCompileService();
      addTearDown(service.dispose);

      const rawInputs = <String>['first **raw**\r\nentry', 'second raw\rentry'];
      final preparedInputs = rawInputs
          .map((value) => prepareMarkdownContent(value, streaming: false))
          .toList(growable: false);
      await service.prewarmContents(rawInputs, streaming: false);

      check(service.preparedInputs).deepEquals(rawInputs);
      check(service.synchronousPreparationInputs).deepEquals([false, false]);
      check(service.batchCalls).deepEquals(<List<String>>[preparedInputs]);
      check(service.events).deepEquals(<String>[
        for (final input in rawInputs) 'prepare:$input',
        'compile:${preparedInputs.join('|')}',
      ]);
    },
  );

  test('widget-test prewarming keeps batch compilation synchronous', () async {
    final service = _RecordingBatchMarkdownCompileService();
    addTearDown(service.dispose);

    await service.prewarmContents(
      const <String>['widget-test markdown'],
      streaming: false,
      widgetTest: true,
    );

    check(service.synchronousBatchInputs).deepEquals([true]);
    check(service.widgetTestBatchInputs).deepEquals([true]);
  });

  test('prewarmContents bounds preparation batches', () async {
    final service = _RecordingBatchMarkdownCompileService();
    addTearDown(service.dispose);
    final contents = List<String>.generate(
      17,
      (index) => 'bounded prewarm entry $index',
    );

    await service.prewarmContents(contents, streaming: false);
    await Future<void>.delayed(Duration.zero);

    check(service.preparedInputs).deepEquals(contents);
    check(
      service.batchCalls.map((batch) => batch.length),
    ).deepEquals([8, 8, 1]);
  });

  test('prewarmContents yields before admitting the next raw batch', () async {
    final firstPreparationStarted = Completer<void>();
    final releaseFirstPreparation = Completer<void>();
    var preparationCalls = 0;
    var admittedInputs = 0;
    final service = MarkdownCompileService(
      workerManager: WorkerManager(),
      debugPrepareContentOverride: (content, streaming) async {
        preparationCalls++;
        if (preparationCalls == 1) {
          firstPreparationStarted.complete();
          await releaseFirstPreparation.future;
        }
        return content;
      },
    );
    addTearDown(service.dispose);
    addTearDown(() {
      if (!releaseFirstPreparation.isCompleted) {
        releaseFirstPreparation.complete();
      }
    });

    Iterable<String> lazyInputs() sync* {
      for (var index = 0; index < 17; index++) {
        admittedInputs++;
        yield 'lazy prewarm entry $index';
      }
    }

    final prewarm = service.prewarmContents(lazyInputs(), streaming: false);
    await firstPreparationStarted.future;

    check(admittedInputs).equals(8);
    releaseFirstPreparation.complete();
    await prewarm;
    check(admittedInputs).equals(17);
  });

  test(
    'prewarmContents waits for each compiled batch before admitting more',
    () async {
      final service = _GatedBatchMarkdownCompileService();
      addTearDown(service.dispose);
      addTearDown(() {
        if (!service.releaseFirstCompile.isCompleted) {
          service.releaseFirstCompile.complete();
        }
      });
      var admittedInputs = 0;

      Iterable<String> lazyInputs() sync* {
        for (var index = 0; index < 17; index++) {
          admittedInputs += 1;
          yield 'compile-gated prewarm entry $index';
        }
      }

      final prewarm = service.prewarmContents(lazyInputs(), streaming: false);
      await service.firstCompileStarted.future;

      check(admittedInputs).equals(8);
      check(service.compileCalls).equals(1);
      service.releaseFirstCompile.complete();
      await prewarm;

      check(admittedInputs).equals(17);
      check(service.compileCalls).equals(3);
    },
  );
}
