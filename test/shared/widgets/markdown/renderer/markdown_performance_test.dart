import 'dart:async';
import 'dart:collection';

import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/shared/widgets/markdown/compiled_markdown_document.dart';
import 'package:conduit/shared/widgets/markdown/markdown_compile_service.dart';
import 'package:conduit/shared/widgets/markdown/markdown_loading_skeleton.dart';
import 'package:conduit/shared/widgets/markdown/renderer/conduit_markdown_widget.dart';
import 'package:conduit/shared/widgets/markdown/streaming_markdown_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _ImmediateMarkdownCompileService extends MarkdownCompileService {
  _ImmediateMarkdownCompileService() : super(workerManager: WorkerManager());

  @override
  Future<CompiledMarkdownDocument> compilePrepared(
    String preparedContent, {
    bool allowSynchronous = false,
    bool widgetTest = false,
  }) async {
    return compilePreparedSynchronously(preparedContent);
  }

  @override
  bool shouldCompileSynchronously(
    String preparedContent, {
    bool widgetTest = false,
  }) => true;
}

class _RecordingPrepareMarkdownCompileService
    extends _ImmediateMarkdownCompileService {
  final List<String> preparedContents = <String>[];

  @override
  Future<String> prepareContent(
    String content, {
    required bool streaming,
    bool allowSynchronous = false,
    bool widgetTest = false,
  }) async {
    preparedContents.add(content);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    return prepareMarkdownContent(content, streaming: streaming);
  }
}

class _BlockingPrepareMarkdownCompileService
    extends _ImmediateMarkdownCompileService {
  final List<String> preparedContents = <String>[];
  final Completer<void> _release = Completer<void>();

  void release() {
    if (!_release.isCompleted) {
      _release.complete();
    }
  }

  @override
  Future<String> prepareContent(
    String content, {
    required bool streaming,
    bool allowSynchronous = false,
    bool widgetTest = false,
  }) async {
    preparedContents.add(content);
    await _release.future;
    return prepareMarkdownContent(content, streaming: streaming);
  }
}

class _SequencedBlockingPrepareMarkdownCompileService
    extends _ImmediateMarkdownCompileService {
  final List<String> preparedContents = <String>[];
  final Queue<Completer<void>> _releases = Queue<Completer<void>>();

  void releaseNext() {
    if (_releases.isEmpty) {
      return;
    }
    final next = _releases.removeFirst();
    if (!next.isCompleted) {
      next.complete();
    }
  }

  @override
  Future<String> prepareContent(
    String content, {
    required bool streaming,
    bool allowSynchronous = false,
    bool widgetTest = false,
  }) async {
    preparedContents.add(content);
    final release = Completer<void>();
    _releases.add(release);
    await release.future;
    return prepareMarkdownContent(content, streaming: streaming);
  }
}

class _SequencedBlockingMarkdownCompileService extends MarkdownCompileService {
  _SequencedBlockingMarkdownCompileService()
    : super(workerManager: WorkerManager());

  final Queue<Completer<void>> _releases = Queue<Completer<void>>();

  void releaseNext() {
    if (_releases.isEmpty) {
      return;
    }
    final next = _releases.removeFirst();
    if (!next.isCompleted) {
      next.complete();
    }
  }

  @override
  Future<CompiledMarkdownDocument> compilePrepared(
    String preparedContent, {
    bool allowSynchronous = false,
    bool widgetTest = false,
  }) async {
    final release = Completer<void>();
    _releases.add(release);
    await release.future;
    return compilePreparedSynchronously(preparedContent);
  }

  @override
  bool shouldCompileSynchronously(
    String preparedContent, {
    bool widgetTest = false,
  }) => false;
}

Widget _buildMarkdownHarness(String data) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(body: ConduitMarkdownWidget(data: data)),
    ),
  );
}

Widget _buildAsyncMarkdownHarness({
  required String data,
  required MarkdownCompileService compileService,
}) {
  return ProviderScope(
    overrides: [
      markdownCompileServiceProvider.overrideWithValue(compileService),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: ConduitMarkdownWidget(data: data, debugTreatAsWidgetTest: false),
      ),
    ),
  );
}

Widget _buildStreamingHarness({
  required String content,
  required MarkdownCompileService compileService,
  bool isStreaming = true,
  Duration? debugRenderInterval = const Duration(milliseconds: 10),
  VoidCallback? onStreamingRefreshFrame,
}) {
  return ProviderScope(
    overrides: [
      markdownCompileServiceProvider.overrideWithValue(compileService),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: StreamingMarkdownWidget(
            content: content,
            isStreaming: isStreaming,
            debugTreatAsWidgetTest: false,
            debugRenderInterval: debugRenderInterval,
            debugOnStreamingRefreshFrame: onStreamingRefreshFrame,
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(debugResetParsedMarkdownCache);
  tearDown(debugResetParsedMarkdownCache);

  testWidgets('parsed markdown cache keeps recently reused entries', (
    tester,
  ) async {
    for (var index = 0; index < 32; index += 1) {
      await tester.pumpWidget(_buildMarkdownHarness('Message $index'));
    }

    expect(debugParsedMarkdownCacheSize(), 32);

    await tester.pumpWidget(_buildMarkdownHarness('Message 0'));
    expect(debugParsedMarkdownCacheKeys().last, 'Message 0');

    await tester.pumpWidget(_buildMarkdownHarness('Message 32'));

    expect(debugParsedMarkdownCacheSize(), 32);
    expect(debugParsedMarkdownCacheKeys(), isNot(contains('Message 1')));
    expect(
      debugParsedMarkdownCacheKeys(),
      containsAll(<String>['Message 0', 'Message 32']),
    );
  });

  testWidgets(
    'conduit markdown shows a skeleton while async compile is pending',
    (tester) async {
      final compileService = _SequencedBlockingMarkdownCompileService();
      addTearDown(compileService.dispose);

      await tester.pumpWidget(
        _buildAsyncMarkdownHarness(
          data: 'Long completed channel message',
          compileService: compileService,
        ),
      );
      await tester.pump();

      expect(find.byType(MarkdownLoadingSkeleton), findsOneWidget);
      expect(
        find.textContaining(
          'Long completed channel message',
          findRichText: true,
        ),
        findsNothing,
      );

      compileService.releaseNext();
      await tester.pumpAndSettle();

      expect(find.byType(MarkdownLoadingSkeleton), findsNothing);
      expect(
        find.textContaining(
          'Long completed channel message',
          findRichText: true,
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'conduit markdown async compile flow discards stale prepared content',
    (tester) async {
      final compileService = _SequencedBlockingMarkdownCompileService();
      addTearDown(compileService.dispose);

      await tester.pumpWidget(
        _buildAsyncMarkdownHarness(
          data: 'First async response',
          compileService: compileService,
        ),
      );
      await tester.pump();

      expect(
        find.textContaining('First async response', findRichText: true),
        findsNothing,
      );

      await tester.pumpWidget(
        _buildAsyncMarkdownHarness(
          data: 'Second async response',
          compileService: compileService,
        ),
      );
      await tester.pump();

      compileService.releaseNext();
      await tester.pump();

      expect(
        find.textContaining('First async response', findRichText: true),
        findsNothing,
      );

      compileService.releaseNext();
      await tester.pumpAndSettle();

      expect(
        find.textContaining('First async response', findRichText: true),
        findsNothing,
      );
      expect(
        find.textContaining('Second async response', findRichText: true),
        findsOneWidget,
      );
    },
  );

  test('streaming markdown snapshot keeps full normalized content', () {
    final content = [
      'Intro paragraph.',
      List<String>.filled(80, 'Stable sentence.').join(' '),
      '```dart',
      List<String>.filled(40, 'print("chunk");').join('\n'),
    ].join('\n\n');

    final snapshot = buildStreamingMarkdownSnapshotForTesting(
      content,
      streaming: true,
    );

    expect(snapshot['normalizedContent'], contains('Stable sentence.'));
    expect(snapshot['normalizedContent'], contains('```dart'));
  });

  test('streaming markdown snapshot preserves fence-first content', () {
    final content = [
      '```dart',
      ...List<String>.filled(160, 'print("chunk");'),
    ].join('\n');

    final snapshot = buildStreamingMarkdownSnapshotForTesting(
      content,
      streaming: true,
    );

    expect(snapshot['normalizedContent'], startsWith('```dart'));
  });

  testWidgets('rapid streaming updates coalesce prepare snapshot jobs', (
    tester,
  ) async {
    final compileService = _RecordingPrepareMarkdownCompileService();
    addTearDown(compileService.dispose);
    final base = List<String>.filled(180, 'stream chunk').join(' ');
    final next = '$base next';
    final latest = '$base latest';

    await tester.pumpWidget(
      _buildStreamingHarness(content: base, compileService: compileService),
    );

    await tester.pumpWidget(
      _buildStreamingHarness(content: next, compileService: compileService),
    );
    await tester.pump(const Duration(milliseconds: 4));

    await tester.pumpWidget(
      _buildStreamingHarness(content: latest, compileService: compileService),
    );
    await tester.pump(const Duration(milliseconds: 4));

    expect(compileService.preparedContents, isEmpty);

    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 1));

    expect(compileService.preparedContents, <String>[latest]);
  });

  testWidgets('sync streaming updates invalidate stale prepare snapshots', (
    tester,
  ) async {
    final compileService = _BlockingPrepareMarkdownCompileService();
    addTearDown(compileService.dispose);
    final baseContent = List<String>.filled(180, 'stream chunk').join(' ');
    final longContent = '$baseContent newer';
    const shortContent = 'short updated content';

    await tester.pumpWidget(
      _buildStreamingHarness(
        content: baseContent,
        compileService: compileService,
      ),
    );

    await tester.pumpWidget(
      _buildStreamingHarness(
        content: longContent,
        compileService: compileService,
      ),
    );
    await tester.pump(const Duration(milliseconds: 20));

    expect(compileService.preparedContents, <String>[longContent]);

    await tester.pumpWidget(
      _buildStreamingHarness(
        content: shortContent,
        compileService: compileService,
      ),
    );
    await tester.pump();

    expect(
      find.textContaining(shortContent, findRichText: true),
      findsOneWidget,
    );

    compileService.release();
    await tester.pumpAndSettle();

    expect(
      find.textContaining(shortContent, findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('stream chunk', findRichText: true),
      findsNothing,
    );
  });

  testWidgets('queued streaming updates skip stale prepare snapshots', (
    tester,
  ) async {
    final compileService = _SequencedBlockingPrepareMarkdownCompileService();
    addTearDown(compileService.dispose);
    final baseContent = List<String>.filled(180, 'stream chunk').join(' ');
    final firstContent = '$baseContent first-marker';
    final latestContent = '$baseContent latest-marker';

    await tester.pumpWidget(
      _buildStreamingHarness(
        content: baseContent,
        compileService: compileService,
      ),
    );

    await tester.pumpWidget(
      _buildStreamingHarness(
        content: firstContent,
        compileService: compileService,
      ),
    );
    await tester.pump(const Duration(milliseconds: 20));

    expect(compileService.preparedContents, <String>[firstContent]);

    await tester.pumpWidget(
      _buildStreamingHarness(
        content: latestContent,
        compileService: compileService,
      ),
    );
    await tester.pump();

    compileService.releaseNext();
    await tester.pump();
    for (var index = 0; index < 5; index += 1) {
      if (compileService.preparedContents.length >= 2) {
        break;
      }
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(compileService.preparedContents, <String>[
      firstContent,
      latestContent,
    ]);
    expect(
      find.textContaining('first-marker', findRichText: true),
      findsNothing,
    );

    compileService.releaseNext();
    await tester.pumpAndSettle();

    expect(
      find.textContaining('first-marker', findRichText: true),
      findsNothing,
    );
  });

  testWidgets(
    'streaming A-B-A updates reschedule when the latest content matches the in-flight request',
    (tester) async {
      final compileService = _SequencedBlockingPrepareMarkdownCompileService();
      addTearDown(compileService.dispose);
      const seedContent = 'seed snapshot';
      final baseContent = List<String>.filled(180, 'stream chunk').join(' ');
      final aContent = '$baseContent alpha-marker';
      final bContent = '$baseContent beta-marker';

      await tester.pumpWidget(
        _buildStreamingHarness(
          content: seedContent,
          compileService: compileService,
        ),
      );
      await tester.pump();

      expect(
        find.textContaining(seedContent, findRichText: true),
        findsOneWidget,
      );

      await tester.pumpWidget(
        _buildStreamingHarness(
          content: aContent,
          compileService: compileService,
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));

      expect(compileService.preparedContents, <String>[aContent]);

      await tester.pumpWidget(
        _buildStreamingHarness(
          content: bContent,
          compileService: compileService,
        ),
      );
      await tester.pump();

      await tester.pumpWidget(
        _buildStreamingHarness(
          content: aContent,
          compileService: compileService,
        ),
      );
      await tester.pump();

      compileService.releaseNext();
      await tester.pump();

      for (var index = 0; index < 5; index += 1) {
        if (compileService.preparedContents.length >= 2) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(compileService.preparedContents, <String>[aContent, aContent]);
      expect(
        find.textContaining(seedContent, findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('alpha-marker', findRichText: true),
        findsNothing,
      );

      compileService.releaseNext();
      await tester.pumpAndSettle();

      expect(
        find.textContaining(seedContent, findRichText: true),
        findsNothing,
      );
      expect(
        find.textContaining('alpha-marker', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('beta-marker', findRichText: true),
        findsNothing,
      );
    },
  );

  testWidgets(
    'streaming markdown keeps one pending refresh pass while async prepare is in flight',
    (tester) async {
      final compileService = _SequencedBlockingPrepareMarkdownCompileService();
      addTearDown(compileService.dispose);
      const seedContent = 'seed snapshot';
      final baseContent = List<String>.filled(180, 'stream chunk').join(' ');
      final firstContent = '$baseContent first-marker';
      final latestContent = '$baseContent latest-marker';
      var refreshFrameCount = 0;

      await tester.pumpWidget(
        _buildStreamingHarness(
          content: seedContent,
          compileService: compileService,
          debugRenderInterval: Duration.zero,
          onStreamingRefreshFrame: () => refreshFrameCount += 1,
        ),
      );
      await tester.pump();

      expect(
        find.textContaining(seedContent, findRichText: true),
        findsOneWidget,
      );

      await tester.pumpWidget(
        _buildStreamingHarness(
          content: firstContent,
          compileService: compileService,
          debugRenderInterval: Duration.zero,
          onStreamingRefreshFrame: () => refreshFrameCount += 1,
        ),
      );
      await tester.pump();

      expect(compileService.preparedContents, <String>[firstContent]);
      expect(refreshFrameCount, 1);

      await tester.pumpWidget(
        _buildStreamingHarness(
          content: '$baseContent mid-marker',
          compileService: compileService,
          debugRenderInterval: Duration.zero,
          onStreamingRefreshFrame: () => refreshFrameCount += 1,
        ),
      );
      await tester.pump();
      await tester.pumpWidget(
        _buildStreamingHarness(
          content: latestContent,
          compileService: compileService,
          debugRenderInterval: Duration.zero,
          onStreamingRefreshFrame: () => refreshFrameCount += 1,
        ),
      );
      await tester.pump();

      expect(compileService.preparedContents, <String>[firstContent]);
      expect(refreshFrameCount, 1);

      compileService.releaseNext();
      await tester.pump();
      await tester.pump();

      expect(compileService.preparedContents, <String>[
        firstContent,
        latestContent,
      ]);
      expect(refreshFrameCount, 2);

      compileService.releaseNext();
      await tester.pumpAndSettle();

      expect(
        find.textContaining(latestContent, findRichText: true),
        findsOneWidget,
      );
    },
  );
}
