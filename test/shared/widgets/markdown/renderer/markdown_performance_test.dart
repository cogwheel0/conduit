import 'dart:async';
import 'dart:collection';

import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/shared/widgets/markdown/renderer/conduit_markdown_widget.dart';
import 'package:conduit/shared/widgets/markdown/streaming_markdown_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingWorkerManager extends WorkerManager {
  _RecordingWorkerManager();
  final List<String> scheduledContents = <String>[];

  @override
  Future<R> schedule<Q, R>(
    WorkerTask<Q, R> callback,
    Q message, {
    String? debugLabel,
  }) async {
    scheduledContents.add(message as String);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    return callback(message);
  }
}

class _BlockingWorkerManager extends WorkerManager {
  _BlockingWorkerManager();

  final List<String> scheduledContents = <String>[];
  final Completer<void> _release = Completer<void>();

  void release() {
    if (!_release.isCompleted) {
      _release.complete();
    }
  }

  @override
  Future<R> schedule<Q, R>(
    WorkerTask<Q, R> callback,
    Q message, {
    String? debugLabel,
  }) async {
    scheduledContents.add(message as String);
    await _release.future;
    return callback(message);
  }
}

class _SequencedBlockingWorkerManager extends WorkerManager {
  _SequencedBlockingWorkerManager();

  final List<String> scheduledContents = <String>[];
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
  Future<R> schedule<Q, R>(
    WorkerTask<Q, R> callback,
    Q message, {
    String? debugLabel,
  }) async {
    scheduledContents.add(message as String);
    final release = Completer<void>();
    _releases.add(release);
    await release.future;
    return callback(message);
  }
}

Widget _buildMarkdownHarness(String data) {
  return MaterialApp(
    home: Scaffold(body: ConduitMarkdownWidget(data: data)),
  );
}

Widget _buildStreamingHarness({
  required String content,
  required WorkerManager workerManager,
  bool isStreaming = true,
}) {
  return ProviderScope(
    overrides: [workerManagerProvider.overrideWithValue(workerManager)],
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: StreamingMarkdownWidget(
            content: content,
            isStreaming: isStreaming,
            debugTreatAsWidgetTest: false,
            debugRenderInterval: const Duration(milliseconds: 10),
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

  test('streaming markdown snapshot splits stable and trailing content', () {
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

    expect(snapshot['useCheapTail'], isTrue);
    expect((snapshot['stableContent'] as String).trim(), isNotEmpty);
    expect((snapshot['trailingContent'] as String).trim(), isNotEmpty);
    expect(snapshot['normalizedContent'], contains('Stable sentence.'));
  });

  test(
    'streaming markdown snapshot falls back to full render when a fence starts at index zero',
    () {
      final content = [
        '```dart',
        ...List<String>.filled(160, 'print("chunk");'),
      ].join('\n');

      final snapshot = buildStreamingMarkdownSnapshotForTesting(
        content,
        streaming: true,
      );

      expect(snapshot['useCheapTail'], isFalse);
      expect(snapshot['normalizedContent'], startsWith('```dart'));
    },
  );

  testWidgets('rapid streaming updates coalesce worker snapshot jobs', (
    tester,
  ) async {
    final workerManager = _RecordingWorkerManager();
    final base = List<String>.filled(180, 'stream chunk').join(' ');
    final next = '$base next';
    final latest = '$base latest';

    await tester.pumpWidget(
      _buildStreamingHarness(content: base, workerManager: workerManager),
    );

    await tester.pumpWidget(
      _buildStreamingHarness(content: next, workerManager: workerManager),
    );
    await tester.pump(const Duration(milliseconds: 4));

    await tester.pumpWidget(
      _buildStreamingHarness(content: latest, workerManager: workerManager),
    );
    await tester.pump(const Duration(milliseconds: 4));

    expect(workerManager.scheduledContents, isEmpty);

    await tester.pump(const Duration(milliseconds: 20));

    expect(workerManager.scheduledContents, <String>[latest]);
  });

  testWidgets('sync streaming updates invalidate stale worker snapshots', (
    tester,
  ) async {
    final workerManager = _BlockingWorkerManager();
    final baseContent = List<String>.filled(180, 'stream chunk').join(' ');
    final longContent = '$baseContent newer';
    const shortContent = 'short updated content';

    await tester.pumpWidget(
      _buildStreamingHarness(
        content: baseContent,
        workerManager: workerManager,
      ),
    );

    await tester.pumpWidget(
      _buildStreamingHarness(
        content: longContent,
        workerManager: workerManager,
      ),
    );
    await tester.pump(const Duration(milliseconds: 20));

    expect(workerManager.scheduledContents, <String>[longContent]);

    await tester.pumpWidget(
      _buildStreamingHarness(
        content: shortContent,
        workerManager: workerManager,
      ),
    );
    await tester.pump();

    expect(
      find.textContaining(shortContent, findRichText: true),
      findsOneWidget,
    );

    workerManager.release();
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

  testWidgets('queued streaming updates skip stale worker snapshots', (
    tester,
  ) async {
    final workerManager = _SequencedBlockingWorkerManager();
    final baseContent = List<String>.filled(180, 'stream chunk').join(' ');
    final firstContent = '$baseContent first-marker';
    final latestContent = '$baseContent latest-marker';

    await tester.pumpWidget(
      _buildStreamingHarness(
        content: baseContent,
        workerManager: workerManager,
      ),
    );

    await tester.pumpWidget(
      _buildStreamingHarness(
        content: firstContent,
        workerManager: workerManager,
      ),
    );
    await tester.pump(const Duration(milliseconds: 20));

    expect(workerManager.scheduledContents, <String>[firstContent]);

    await tester.pumpWidget(
      _buildStreamingHarness(
        content: latestContent,
        workerManager: workerManager,
      ),
    );
    await tester.pump();

    workerManager.releaseNext();
    await tester.pump();
    for (var index = 0; index < 5; index += 1) {
      if (workerManager.scheduledContents.length >= 2) {
        break;
      }
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(workerManager.scheduledContents, <String>[
      firstContent,
      latestContent,
    ]);
    expect(
      find.textContaining('first-marker', findRichText: true),
      findsNothing,
    );

    workerManager.releaseNext();
    await tester.pumpAndSettle();

    expect(
      find.textContaining('first-marker', findRichText: true),
      findsNothing,
    );
  });
}
