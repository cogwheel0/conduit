import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/shared/widgets/markdown/compiled_markdown_document.dart';
import 'package:conduit/shared/widgets/markdown/markdown_compile_service.dart';
import 'package:conduit/shared/widgets/markdown/markdown_display_part.dart';
import 'package:conduit/shared/widgets/markdown/markdown_document_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingIncrementalMarkdownCompileService
    extends MarkdownCompileService {
  _RecordingIncrementalMarkdownCompileService()
    : super(workerManager: WorkerManager());

  final List<String> singleCalls = <String>[];
  final List<List<String>> batchCalls = <List<String>>[];

  @override
  Future<CompiledMarkdownDocument> compilePrepared(
    String preparedContent, {
    bool allowSynchronous = false,
    bool widgetTest = false,
  }) async {
    singleCalls.add(preparedContent);
    return compilePreparedSynchronously(preparedContent);
  }

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

  @override
  bool shouldCompileSynchronously(
    String preparedContent, {
    bool widgetTest = false,
  }) => false;
}

Future<void> _flushAsyncWork() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  setUp(debugResetCompiledMarkdownCache);
  tearDown(debugResetCompiledMarkdownCache);

  test('splitter freezes closed blocks and leaves only the mutable tail', () {
    final split = debugSplitStreamingPreparedContentForTesting(
      'First paragraph.\n\nSecond paragraph',
    );

    expect(split['frozenPrefix'], 'First paragraph.\n\n');
    expect(split['mutableTail'], 'Second paragraph');
    expect(split['canIncrementallyCompile'], isTrue);
  });

  test('splitter freezes fenced blocks once the closing fence arrives', () {
    const content = '```dart\nprint("done");\n```';

    final split = debugSplitStreamingPreparedContentForTesting(content);

    expect(split['frozenPrefix'], content);
    expect(split['mutableTail'], isEmpty);
    expect(split['canIncrementallyCompile'], isTrue);
  });

  test(
    'splitter falls back to the full document when reference definitions are present',
    () {
      const content = 'See [docs][d].\n\n[d]: https://example.com';

      final split = debugSplitStreamingPreparedContentForTesting(content);

      expect(split['frozenPrefix'], isEmpty);
      expect(split['mutableTail'], content);
      expect(split['canIncrementallyCompile'], isFalse);
      expect(split['fallbackReason'], 'referenceDefinitions');
    },
  );

  test('splitter keeps loose list continuations in the mutable tail', () {
    const content = '- First paragraph.\n\n  Second paragraph.';

    final split = debugSplitStreamingPreparedContentForTesting(content);

    expect(split['frozenPrefix'], isEmpty);
    expect(split['mutableTail'], content);
    expect(split['canIncrementallyCompile'], isTrue);
  });

  test('splitter keeps setext headings together before freezing blocks', () {
    const content = 'Title\n---\n\nTail';

    final split = debugSplitStreamingPreparedContentForTesting(content);

    expect(split['frozenPrefix'], 'Title\n---\n\n');
    expect(split['mutableTail'], 'Tail');
    expect(split['canIncrementallyCompile'], isTrue);
  });

  test('splitter keeps lazy blockquote continuations in the same block', () {
    const content = '> quoted\ncontinued\n\nTail';

    final split = debugSplitStreamingPreparedContentForTesting(content);

    expect(split['frozenPrefix'], '> quoted\ncontinued\n\n');
    expect(split['mutableTail'], 'Tail');
    expect(split['canIncrementallyCompile'], isTrue);
  });

  test(
    'splitter keeps paragraph continuations that look like ordered lists together',
    () {
      const content = 'This wraps\n2. not a list\n\nTail';

      final split = debugSplitStreamingPreparedContentForTesting(content);

      expect(split['frozenPrefix'], 'This wraps\n2. not a list\n\n');
      expect(split['mutableTail'], 'Tail');
      expect(split['canIncrementallyCompile'], isTrue);
    },
  );

  test('splitter keeps loose multi-item lists together before freezing', () {
    const content = '- one\n\n- two\n\nTail';

    final split = debugSplitStreamingPreparedContentForTesting(content);

    expect(split['frozenPrefix'], '- one\n\n- two\n\n');
    expect(split['mutableTail'], 'Tail');
    expect(split['canIncrementallyCompile'], isTrue);
  });

  test(
    'splitter keeps indented code blocks that resemble markdown starters together',
    () {
      const firstLines = <String>[
        '# not a heading',
        '```',
        '> not a quote',
        '- not a list',
      ];

      for (final firstLine in firstLines) {
        final frozenPrefix = '    $firstLine\n    still code\n\n';
        final split = debugSplitStreamingPreparedContentForTesting(
          '${frozenPrefix}Tail',
        );

        expect(split['frozenPrefix'], frozenPrefix, reason: firstLine);
        expect(split['mutableTail'], 'Tail', reason: firstLine);
        expect(split['canIncrementallyCompile'], isTrue, reason: firstLine);
      }
    },
  );

  test('splitter keeps an unterminated heading line mutable at EOF', () {
    const content = '### Partial heading';

    final split = debugSplitStreamingPreparedContentForTesting(content);

    expect(split['frozenPrefix'], isEmpty);
    expect(split['mutableTail'], content);
    expect(split['canIncrementallyCompile'], isTrue);
  });

  test(
    'splitter keeps an unterminated closing details line mutable at EOF',
    () {
      const content = '''
<details type="reasoning" done="true">
<summary>Thinking…</summary>
Body
</details>Visible response''';

      final split = debugSplitStreamingPreparedContentForTesting(content);

      expect(split['frozenPrefix'], isEmpty);
      expect(split['mutableTail'], content);
      expect(split['canIncrementallyCompile'], isTrue);
    },
  );

  test('rebases root ids and grouped tool call block ids when composing', () {
    final toolCallsDocument = compilePreparedMarkdownSync(
      [
        '<details type="tool_calls" done="true" name="search">',
        '<summary>search</summary>',
        '</details>',
        '<details type="tool_calls" done="true" name="browser">',
        '<summary>browser</summary>',
        '</details>',
      ].join('\n'),
    ).rebaseRootIds(rootNodeOffset: 4);

    final paragraphDocument = compilePreparedMarkdownSync('After tool calls.');
    final nextRootOffset = 4 + toolCallsDocument.rootNodeCount;
    final composed = CompiledMarkdownDocument.compose(
      normalizedContent:
          '${toolCallsDocument.normalizedContent}\n\n${paragraphDocument.normalizedContent}',
      segments: <CompiledMarkdownDocument>[
        toolCallsDocument,
        paragraphDocument.rebaseRootIds(rootNodeOffset: nextRootOffset),
      ],
    );

    final group = composed.blocks.first as CompiledMarkdownDetailsGroup;
    expect(group.blockId, 'group:n4:tool_calls');
    expect(group.items.map((item) => item.blockId).toList(), <String>[
      'n4',
      'n5',
    ]);
    expect(composed.nodes.map((node) => node.nodeId).toList(), <String>[
      'n4',
      'n5',
      'n6',
    ]);
  });

  test(
    'compose regroups adjacent tool call blocks across segment boundaries',
    () {
      final firstToolCall = compilePreparedMarkdownSync(
        [
          '<details type="tool_calls" done="true" name="search">',
          '<summary>search</summary>',
          '</details>',
        ].join('\n'),
      );
      final secondToolCall = compilePreparedMarkdownSync(
        [
          '<details type="tool_calls" done="true" name="browser">',
          '<summary>browser</summary>',
          '</details>',
        ].join('\n'),
      ).rebaseRootIds(rootNodeOffset: firstToolCall.rootNodeCount);

      final composed = CompiledMarkdownDocument.compose(
        normalizedContent:
            '${firstToolCall.normalizedContent}\n${secondToolCall.normalizedContent}',
        segments: <CompiledMarkdownDocument>[firstToolCall, secondToolCall],
      );

      expect(composed.blocks, hasLength(1));
      final group = composed.blocks.single as CompiledMarkdownDetailsGroup;
      expect(group.blockId, 'group:n0:tool_calls');
      expect(group.items.map((item) => item.blockId).toList(), <String>[
        'n0',
        'n1',
      ]);
    },
  );

  test(
    'compose realigns the mutable tail index when a tool_calls details merges across the boundary',
    () {
      final frozenToolCall = compilePreparedMarkdownSync(
        [
          '<details type="tool_calls" done="true" name="search">',
          '<summary>search</summary>',
          '</details>',
        ].join('\n'),
      );
      final tail = compilePreparedMarkdownSync(
        [
          '<details type="tool_calls" done="true" name="browser">',
          '<summary>browser</summary>',
          '</details>',
          '',
          'Visible response',
        ].join('\n'),
      ).rebaseRootIds(rootNodeOffset: frozenToolCall.rootNodeCount);

      final composed = CompiledMarkdownDocument.compose(
        normalizedContent:
            '${frozenToolCall.normalizedContent}\n${tail.normalizedContent}',
        segments: <CompiledMarkdownDocument>[frozenToolCall, tail],
        // Pre-merge index: the frozen prefix contributes one block. The boundary
        // tool_calls blocks then merge into a single group, shifting the tail.
        mutableBlockStartIndex: frozenToolCall.rootBlockCount,
      );

      // Composed list is [group(search, browser), paragraph]. The merged group
      // still carries the streaming tail item, so it must be the mutable tail —
      // not left below the (pre-merge) start index and treated as frozen.
      expect(composed.blocks, hasLength(2));
      expect(composed.blocks.first, isA<CompiledMarkdownDetailsGroup>());
      expect(composed.mutableBlockStartIndex, 0);
      expect(composed.isMutableRootBlock(0), isTrue);
      expect(composed.isMutableRootBlock(1), isTrue);

      final parts = buildMarkdownDisplayParts(composed, isStreaming: true);
      expect(parts.first.isMutableTail, isTrue);
    },
  );

  test(
    'controller recompiles only the mutable tail between streaming updates',
    () async {
      final compiler = _RecordingIncrementalMarkdownCompileService();
      addTearDown(compiler.dispose);

      CompiledMarkdownDocument? latestDocument;
      final controller = MarkdownDocumentController(
        readCompiler: () => compiler,
        isWidgetTest: () => false,
        onStateChanged: (_, document) => latestDocument = document,
      );
      addTearDown(controller.dispose);

      controller.resolveStreamingPrepared('First paragraph.\n\nSecond');
      await _flushAsyncWork();

      expect(compiler.batchCalls, <List<String>>[
        <String>['First paragraph.\n\n', 'Second'],
      ]);
      expect(compiler.singleCalls, isEmpty);
      expect(latestDocument, isNotNull);
      expect(
        latestDocument!.blocks.map((block) => block.blockId).toList(),
        <String>['n0', 'n1'],
      );
      expect(latestDocument!.mutableBlockStartIndex, 1);
      expect(latestDocument!.isMutableRootBlock(0), isFalse);
      expect(latestDocument!.isMutableRootBlock(1), isTrue);

      compiler.batchCalls.clear();
      compiler.singleCalls.clear();

      controller.resolveStreamingPrepared('First paragraph.\n\nSecond grows');
      await _flushAsyncWork();

      expect(compiler.batchCalls, isEmpty);
      expect(compiler.singleCalls, <String>['Second grows']);
      expect(
        latestDocument!.blocks.map((block) => block.blockId).toList(),
        <String>['n0', 'n1'],
      );
      expect(latestDocument!.mutableBlockStartIndex, 1);
      expect(latestDocument!.isMutableRootBlock(0), isFalse);
      expect(latestDocument!.isMutableRootBlock(1), isTrue);

      compiler.batchCalls.clear();
      compiler.singleCalls.clear();

      controller.resolveStreamingPrepared(
        'First paragraph.\n\nSecond grows complete.\n\nThird',
      );
      await _flushAsyncWork();

      expect(compiler.batchCalls, <List<String>>[
        <String>['Second grows complete.\n\n', 'Third'],
      ]);
      expect(compiler.singleCalls, isEmpty);
      expect(
        latestDocument!.blocks.map((block) => block.blockId).toList(),
        <String>['n0', 'n1', 'n2'],
      );
      expect(latestDocument!.mutableBlockStartIndex, 2);
      expect(latestDocument!.isMutableRootBlock(1), isFalse);
      expect(latestDocument!.isMutableRootBlock(2), isTrue);
    },
  );

  test('controller marks a fully-frozen document with no mutable tail', () async {
    final compiler = _RecordingIncrementalMarkdownCompileService();
    addTearDown(compiler.dispose);

    CompiledMarkdownDocument? latestDocument;
    final controller = MarkdownDocumentController(
      readCompiler: () => compiler,
      isWidgetTest: () => false,
      onStateChanged: (_, document) => latestDocument = document,
    );
    addTearDown(controller.dispose);

    // A closed fenced block freezes entirely, leaving an empty mutable tail.
    controller.resolveStreamingPrepared('```dart\nprint("done");\n```');
    await _flushAsyncWork();

    expect(latestDocument, isNotNull);
    expect(latestDocument!.mutableBlockStartIndex, -1);
    expect(latestDocument!.hasMutableBlockMetadata, isFalse);
    expect(latestDocument!.isMutableRootBlock(0), isFalse);
  });

  test(
    'controller falls back to a full compile when composed latex keys collide',
    () async {
      final compiler = _RecordingIncrementalMarkdownCompileService();
      addTearDown(compiler.dispose);

      final controller = MarkdownDocumentController(
        readCompiler: () => compiler,
        isWidgetTest: () => false,
        onStateChanged: (previousDocument, nextDocument) {},
      );
      addTearDown(controller.dispose);

      controller.resolveStreamingPrepared(
        r'First paragraph with $x$.'
        '\n\n'
        r'Second paragraph with $y$.',
      );
      await _flushAsyncWork();

      expect(compiler.batchCalls, <List<String>>[
        <String>[
          r'First paragraph with $x$.'
              '\n\n',
          r'Second paragraph with $y$.',
        ],
      ]);
      expect(compiler.singleCalls, <String>[
        r'First paragraph with $x$.'
            '\n\n'
            r'Second paragraph with $y$.',
      ]);
    },
  );

  test(
    'controller recompiles the full document when reference definitions arrive later',
    () async {
      final compiler = _RecordingIncrementalMarkdownCompileService();
      addTearDown(compiler.dispose);

      final controller = MarkdownDocumentController(
        readCompiler: () => compiler,
        isWidgetTest: () => false,
        onStateChanged: (previousDocument, nextDocument) {},
      );
      addTearDown(controller.dispose);

      controller.resolveStreamingPrepared('See [docs][d].\n\nTail');
      await _flushAsyncWork();

      expect(compiler.batchCalls, <List<String>>[
        <String>['See [docs][d].\n\n', 'Tail'],
      ]);
      expect(compiler.singleCalls, isEmpty);

      compiler.batchCalls.clear();
      compiler.singleCalls.clear();

      controller.resolveStreamingPrepared(
        'See [docs][d].\n\nTail\n\n[d]: https://example.com',
      );
      await _flushAsyncWork();

      expect(compiler.batchCalls, isEmpty);
      expect(compiler.singleCalls, <String>[
        'See [docs][d].\n\nTail\n\n[d]: https://example.com',
      ]);
    },
  );

  test(
    'controller keeps indented code blocks with starter-like first lines together across streaming updates',
    () async {
      final compiler = _RecordingIncrementalMarkdownCompileService();
      addTearDown(compiler.dispose);

      CompiledMarkdownDocument? latestDocument;
      final controller = MarkdownDocumentController(
        readCompiler: () => compiler,
        isWidgetTest: () => false,
        onStateChanged: (_, document) => latestDocument = document,
      );
      addTearDown(controller.dispose);

      const partialContent = '    # not a heading\n    still code';
      controller.resolveStreamingPrepared(partialContent);
      await _flushAsyncWork();

      expect(compiler.batchCalls, isEmpty);
      expect(compiler.singleCalls, <String>[partialContent]);
      expect(latestDocument, isNotNull);
      expect(
        (latestDocument!.blocks.single as CompiledMarkdownNodeBlock).kind,
        CompiledMarkdownNodeBlockKind.codeBlock,
      );

      compiler.batchCalls.clear();
      compiler.singleCalls.clear();

      const completedContent = '    # not a heading\n    still code\n\nTail';
      controller.resolveStreamingPrepared(completedContent);
      await _flushAsyncWork();

      expect(compiler.batchCalls, <List<String>>[
        <String>['    # not a heading\n    still code\n\n', 'Tail'],
      ]);
      expect(compiler.singleCalls, isEmpty);
      expect(
        (latestDocument!.blocks.first as CompiledMarkdownNodeBlock).kind,
        CompiledMarkdownNodeBlockKind.codeBlock,
      );
      expect(
        latestDocument!.blocks.map((block) => block.blockId).toList(),
        <String>['n0', 'n1'],
      );
    },
  );

  test(
    'controller preserves setext headings when incrementally composing blocks',
    () async {
      final compiler = _RecordingIncrementalMarkdownCompileService();
      addTearDown(compiler.dispose);

      CompiledMarkdownDocument? latestDocument;
      final controller = MarkdownDocumentController(
        readCompiler: () => compiler,
        isWidgetTest: () => false,
        onStateChanged: (_, document) => latestDocument = document,
      );
      addTearDown(controller.dispose);

      controller.resolveStreamingPrepared('Title\n---\n\nTail');
      await _flushAsyncWork();

      expect(compiler.batchCalls, <List<String>>[
        <String>['Title\n---\n\n', 'Tail'],
      ]);
      expect(compiler.singleCalls, isEmpty);

      final headingBlock =
          latestDocument!.blocks.first as CompiledMarkdownNodeBlock;
      expect(headingBlock.kind, CompiledMarkdownNodeBlockKind.heading2);
      expect(
        latestDocument!.blocks.map((block) => block.blockId).toList(),
        <String>['n0', 'n1'],
      );
    },
  );

  test(
    'controller regroups adjacent tool calls that arrive across streaming updates',
    () async {
      final compiler = _RecordingIncrementalMarkdownCompileService();
      addTearDown(compiler.dispose);

      CompiledMarkdownDocument? latestDocument;
      final controller = MarkdownDocumentController(
        readCompiler: () => compiler,
        isWidgetTest: () => false,
        onStateChanged: (_, document) => latestDocument = document,
      );
      addTearDown(controller.dispose);

      controller.resolveStreamingPrepared(
        [
          '<details type="tool_calls" done="true" name="search">',
          '<summary>search</summary>',
          '</details>',
        ].join('\n'),
      );
      await _flushAsyncWork();

      expect(compiler.batchCalls, isEmpty);
      expect(compiler.singleCalls, <String>[
        [
          '<details type="tool_calls" done="true" name="search">',
          '<summary>search</summary>',
          '</details>',
        ].join('\n'),
      ]);
      expect(latestDocument!.blocks, hasLength(1));
      expect(
        latestDocument!.blocks.single,
        isA<CompiledMarkdownDetailsBlock>(),
      );

      compiler.batchCalls.clear();
      compiler.singleCalls.clear();

      controller.resolveStreamingPrepared(
        [
          '<details type="tool_calls" done="true" name="search">',
          '<summary>search</summary>',
          '</details>',
          '<details type="tool_calls" done="true" name="browser">',
          '<summary>browser</summary>',
          '</details>',
        ].join('\n'),
      );
      await _flushAsyncWork();

      expect(compiler.batchCalls, <List<String>>[
        <String>[
          [
            '<details type="tool_calls" done="true" name="search">',
            '<summary>search</summary>',
            '</details>',
            '',
          ].join('\n'),
          [
            '<details type="tool_calls" done="true" name="browser">',
            '<summary>browser</summary>',
            '</details>',
          ].join('\n'),
        ],
      ]);
      expect(compiler.singleCalls, isEmpty);
      expect(latestDocument!.blocks, hasLength(1));
      final group =
          latestDocument!.blocks.single as CompiledMarkdownDetailsGroup;
      expect(group.items.map((item) => item.name).toList(), <String>[
        'search',
        'browser',
      ]);
    },
  );

  test(
    'controller preserves lazy blockquote continuations when incrementally composing blocks',
    () async {
      final compiler = _RecordingIncrementalMarkdownCompileService();
      addTearDown(compiler.dispose);

      CompiledMarkdownDocument? latestDocument;
      final controller = MarkdownDocumentController(
        readCompiler: () => compiler,
        isWidgetTest: () => false,
        onStateChanged: (_, document) => latestDocument = document,
      );
      addTearDown(controller.dispose);

      controller.resolveStreamingPrepared('> quoted\ncontinued\n\nTail');
      await _flushAsyncWork();

      expect(compiler.batchCalls, <List<String>>[
        <String>['> quoted\ncontinued\n\n', 'Tail'],
      ]);
      expect(compiler.singleCalls, isEmpty);

      final blockquoteBlock =
          latestDocument!.blocks.first as CompiledMarkdownNodeBlock;
      expect(blockquoteBlock.kind, CompiledMarkdownNodeBlockKind.blockquote);
      expect(
        latestDocument!.blocks.map((block) => block.blockId).toList(),
        <String>['n0', 'n1'],
      );
    },
  );

  test(
    'controller preserves paragraph continuations that use non-1 ordered markers',
    () async {
      final compiler = _RecordingIncrementalMarkdownCompileService();
      addTearDown(compiler.dispose);

      CompiledMarkdownDocument? latestDocument;
      final controller = MarkdownDocumentController(
        readCompiler: () => compiler,
        isWidgetTest: () => false,
        onStateChanged: (_, document) => latestDocument = document,
      );
      addTearDown(controller.dispose);

      controller.resolveStreamingPrepared('This wraps\n2. not a list\n\nTail');
      await _flushAsyncWork();

      expect(compiler.batchCalls, <List<String>>[
        <String>['This wraps\n2. not a list\n\n', 'Tail'],
      ]);
      expect(compiler.singleCalls, isEmpty);

      final paragraphBlock =
          latestDocument!.blocks.first as CompiledMarkdownNodeBlock;
      expect(paragraphBlock.kind, CompiledMarkdownNodeBlockKind.paragraph);
      expect(
        latestDocument!.blocks.map((block) => block.blockId).toList(),
        <String>['n0', 'n1'],
      );
    },
  );

  test(
    'controller preserves loose multi-item lists when incrementally composing blocks',
    () async {
      final compiler = _RecordingIncrementalMarkdownCompileService();
      addTearDown(compiler.dispose);

      CompiledMarkdownDocument? latestDocument;
      final controller = MarkdownDocumentController(
        readCompiler: () => compiler,
        isWidgetTest: () => false,
        onStateChanged: (_, document) => latestDocument = document,
      );
      addTearDown(controller.dispose);

      controller.resolveStreamingPrepared('- one\n\n- two\n\nTail');
      await _flushAsyncWork();

      expect(compiler.batchCalls, <List<String>>[
        <String>['- one\n\n- two\n\n', 'Tail'],
      ]);
      expect(compiler.singleCalls, isEmpty);

      final listBlock =
          latestDocument!.blocks.first as CompiledMarkdownNodeBlock;
      expect(listBlock.kind, CompiledMarkdownNodeBlockKind.unorderedList);
      expect(
        latestDocument!.blocks.map((block) => block.blockId).toList(),
        <String>['n0', 'n1'],
      );
    },
  );

  test(
    'controller keeps a growing heading line in the mutable tail across updates',
    () async {
      final compiler = _RecordingIncrementalMarkdownCompileService();
      addTearDown(compiler.dispose);

      CompiledMarkdownDocument? latestDocument;
      final controller = MarkdownDocumentController(
        readCompiler: () => compiler,
        isWidgetTest: () => false,
        onStateChanged: (_, document) => latestDocument = document,
      );
      addTearDown(controller.dispose);

      controller.resolveStreamingPrepared('### Partial');
      await _flushAsyncWork();

      expect(compiler.batchCalls, isEmpty);
      expect(compiler.singleCalls, <String>['### Partial']);
      expect(latestDocument!.blocks, hasLength(1));
      expect(
        (latestDocument!.blocks.single as CompiledMarkdownNodeBlock).kind,
        CompiledMarkdownNodeBlockKind.heading3,
      );

      compiler.batchCalls.clear();
      compiler.singleCalls.clear();

      controller.resolveStreamingPrepared('### Partial heading');
      await _flushAsyncWork();

      expect(compiler.batchCalls, isEmpty);
      expect(compiler.singleCalls, <String>['### Partial heading']);
      expect(latestDocument!.blocks, hasLength(1));
      expect(
        (latestDocument!.blocks.single as CompiledMarkdownNodeBlock).kind,
        CompiledMarkdownNodeBlockKind.heading3,
      );
    },
  );

  test(
    'controller keeps same-line text after closing details in the mutable tail across updates',
    () async {
      final compiler = _RecordingIncrementalMarkdownCompileService();
      addTearDown(compiler.dispose);

      CompiledMarkdownDocument? latestDocument;
      final controller = MarkdownDocumentController(
        readCompiler: () => compiler,
        isWidgetTest: () => false,
        onStateChanged: (_, document) => latestDocument = document,
      );
      addTearDown(controller.dispose);

      const firstContent = '''
<details type="reasoning" done="true">
<summary>Thinking…</summary>
Body
</details>Visible''';
      controller.resolveStreamingPrepared(firstContent);
      await _flushAsyncWork();

      expect(compiler.batchCalls, isEmpty);
      expect(compiler.singleCalls, <String>[firstContent]);
      expect(latestDocument!.normalizedContent, firstContent);

      compiler.batchCalls.clear();
      compiler.singleCalls.clear();

      const secondContent = '''
<details type="reasoning" done="true">
<summary>Thinking…</summary>
Body
</details>Visible response''';
      controller.resolveStreamingPrepared(secondContent);
      await _flushAsyncWork();

      expect(compiler.batchCalls, isEmpty);
      expect(compiler.singleCalls, <String>[secondContent]);
      expect(latestDocument!.normalizedContent, secondContent);
    },
  );
}
