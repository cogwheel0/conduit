import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/compiled_markdown_document.dart';
import 'package:conduit/shared/widgets/markdown/markdown_config.dart';
import 'package:conduit/shared/widgets/markdown/markdown_compile_service.dart';
import 'package:conduit/shared/widgets/markdown/markdown_loading_skeleton.dart';
import 'package:conduit/shared/widgets/markdown/renderer/inline_renderer.dart';
import 'package:conduit/shared/widgets/markdown/streaming_markdown_widget.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordedPlatformCall {
  const _RecordedPlatformCall(this.method, this.arguments);

  final String method;
  final Object? arguments;
}

Iterable<_RecordedPlatformCall> _mediumImpactCalls(
  List<_RecordedPlatformCall> calls,
) => calls.where(
  (call) =>
      call.method == 'HapticFeedback.vibrate' &&
      call.arguments == 'HapticFeedbackType.mediumImpact',
);

Iterable<_RecordedPlatformCall> _hapticFeedbackCalls(
  List<_RecordedPlatformCall> calls,
) => calls.where((call) => call.method == 'HapticFeedback.vibrate');

/// Returns `true` if [text] contains any unpaired UTF-16 surrogate, which would
/// render as a tofu/replacement glyph (the regression the fade-split snap
/// guards against).
bool _hasLoneSurrogate(String text) {
  for (var index = 0; index < text.length; index += 1) {
    final unit = text.codeUnitAt(index);
    final isHigh = unit >= 0xD800 && unit <= 0xDBFF;
    final isLow = unit >= 0xDC00 && unit <= 0xDFFF;
    if (isHigh) {
      final hasLowFollower =
          index + 1 < text.length &&
          text.codeUnitAt(index + 1) >= 0xDC00 &&
          text.codeUnitAt(index + 1) <= 0xDFFF;
      if (!hasLowFollower) {
        return true;
      }
      index += 1;
    } else if (isLow) {
      return true;
    }
  }
  return false;
}

Iterable<TextSpan> _textSpanLeaves(InlineSpan span) sync* {
  if (span is! TextSpan) {
    return;
  }
  final children = span.children;
  if (children == null || children.isEmpty) {
    yield span;
    return;
  }
  for (final child in children) {
    yield* _textSpanLeaves(child);
  }
}

class _TestTextToSpeechController extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

class _ImmediateWorkerManager extends WorkerManager {
  _ImmediateWorkerManager() : super(maxConcurrentTasks: 1);

  @override
  Future<R> schedule<Q, R>(
    WorkerTask<Q, R> callback,
    Q message, {
    String? debugLabel,
  }) {
    return Future<R>.value(callback(message));
  }
}

class _DelayedMarkdownCompileService extends MarkdownCompileService {
  _DelayedMarkdownCompileService() : super(workerManager: WorkerManager());

  final Completer<void> _release = Completer<void>();

  void release() {
    if (!_release.isCompleted) {
      _release.complete();
    }
  }

  @override
  Future<CompiledMarkdownDocument> compilePrepared(
    String preparedContent, {
    bool allowSynchronous = false,
    bool widgetTest = false,
  }) async {
    await _release.future;
    return compilePreparedSynchronously(preparedContent);
  }

  @override
  bool shouldCompileSynchronously(
    String preparedContent, {
    bool widgetTest = false,
  }) => false;
}

class _SelectiveDelayedMarkdownCompileService extends MarkdownCompileService {
  _SelectiveDelayedMarkdownCompileService({
    required this.delayedPreparedContent,
  }) : super(workerManager: WorkerManager());

  final String delayedPreparedContent;
  final Completer<void> _release = Completer<void>();

  void release() {
    if (!_release.isCompleted) {
      _release.complete();
    }
  }

  @override
  Future<CompiledMarkdownDocument> compilePrepared(
    String preparedContent, {
    bool allowSynchronous = false,
    bool widgetTest = false,
  }) async {
    if (preparedContent == delayedPreparedContent) {
      await _release.future;
    }
    return compilePreparedSynchronously(preparedContent);
  }

  @override
  bool shouldCompileSynchronously(
    String preparedContent, {
    bool widgetTest = false,
  }) => preparedContent != delayedPreparedContent;
}

class _PrepareCountingMarkdownCompileService extends MarkdownCompileService {
  _PrepareCountingMarkdownCompileService()
    : super(workerManager: WorkerManager());

  int prepareCallCount = 0;
  int compileCallCount = 0;

  @override
  Future<String> prepareContent(
    String content, {
    required bool streaming,
    bool allowSynchronous = false,
    bool widgetTest = false,
  }) async {
    prepareCallCount += 1;
    return prepareMarkdownContent(content, streaming: streaming);
  }

  @override
  bool shouldPrepareSynchronously(String content, {bool widgetTest = false}) =>
      false;

  @override
  bool shouldCompileSynchronously(
    String preparedContent, {
    bool widgetTest = false,
  }) => true;

  @override
  CompiledMarkdownDocument compilePreparedSynchronously(
    String preparedContent,
  ) {
    compileCallCount += 1;
    return super.compilePreparedSynchronously(preparedContent);
  }
}

// Forces the deferred streaming path (async prepare) AND delays the compile of
// one target prepared content, so a streaming scope change exercises the
// `_pendingClearStaleDocument` flag and the streaming async-clear branch.
class _DeferredStreamingCompileService extends MarkdownCompileService {
  _DeferredStreamingCompileService({required this.delayedPreparedContent})
    : super(workerManager: WorkerManager());

  final String delayedPreparedContent;
  final Completer<void> _release = Completer<void>();

  void release() {
    if (!_release.isCompleted) {
      _release.complete();
    }
  }

  @override
  bool shouldPrepareSynchronously(String content, {bool widgetTest = false}) =>
      false;

  @override
  Future<String> prepareContent(
    String content, {
    required bool streaming,
    bool allowSynchronous = false,
    bool widgetTest = false,
  }) async => prepareMarkdownContent(content, streaming: streaming);

  @override
  bool shouldCompileSynchronously(
    String preparedContent, {
    bool widgetTest = false,
  }) => preparedContent != delayedPreparedContent;

  @override
  Future<CompiledMarkdownDocument> compilePrepared(
    String preparedContent, {
    bool allowSynchronous = false,
    bool widgetTest = false,
  }) async {
    if (preparedContent == delayedPreparedContent) {
      await _release.future;
    }
    return compilePreparedSynchronously(preparedContent);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('preserves authored chart canvases in preview documents', () {
    const htmlContent = '''
<div class="charts">
  <canvas id="bar"></canvas>
  <canvas id="line"></canvas>
  <canvas id="pie"></canvas>
</div>
<script>
  new Chart(document.getElementById('bar'), {type: 'bar', data: {}});
  new Chart(document.getElementById('line'), {type: 'line', data: {}});
  new Chart(document.getElementById('pie'), {type: 'pie', data: {}});
</script>
''';

    final document = ChartJsDiagram.buildPreviewHtmlForTesting(
      htmlContent: htmlContent,
    );

    expect(document, contains('<canvas id="bar"></canvas>'));
    expect(document, contains('<canvas id="line"></canvas>'));
    expect(document, contains('<canvas id="pie"></canvas>'));
    expect(document, isNot(contains('<canvas id="chart-canvas"></canvas>')));
    expect(document, isNot(contains('Chart.defaults.color')));
    expect(document, isNot(contains('padding: 8px')));
    expect(
      document,
      isNot(contains("return _origGet(id) || _origGet('chart-canvas');")),
    );
  });

  test('adds the fallback canvas when preview markup has none', () {
    const htmlContent = '''
<script>
  new Chart(document.getElementById('missing'), {type: 'bar', data: {}});
</script>
''';

    final document = ChartJsDiagram.buildPreviewHtmlForTesting(
      htmlContent: htmlContent,
    );

    expect(document, contains('<canvas id="chart-canvas"></canvas>'));
    expect(
      document,
      contains("return _origGet(id) || _origGet('chart-canvas');"),
    );
  });

  Widget buildHarness(
    String content, {
    bool isStreaming = false,
    String? stateScopeId,
    List<ChatSourceReference> sources = const <ChatSourceReference>[],
    Locale? locale,
    Duration? debugRenderInterval,
    VoidCallback? onCompiledViewMounted,
    VoidCallback? onCompiledViewDisposed,
    VoidCallback? onStreamingRefreshFrame,
    VoidCallback? onBaseRender,
    MarkdownLinkTapCallback? onTapLink,
  }) {
    return ProviderScope(
      child: MaterialApp(
        locale: locale,
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: StreamingMarkdownWidget(
              content: content,
              isStreaming: isStreaming,
              stateScopeId: stateScopeId,
              sources: sources,
              onTapLink: onTapLink,
              debugRenderInterval: debugRenderInterval,
              debugOnCompiledViewMounted: onCompiledViewMounted,
              debugOnCompiledViewDisposed: onCompiledViewDisposed,
              debugOnStreamingRefreshFrame: onStreamingRefreshFrame,
              debugOnBaseRender: onBaseRender,
            ),
          ),
        ),
      ),
    );
  }

  Widget buildAssistantHarness({
    required ProviderContainer container,
    required ChatMessage message,
    required bool isStreaming,
    bool disableAnimations = false,
    bool suppressStreamingHaptics = false,
  }) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(disableAnimations: disableAnimations),
            child: AssistantMessageWidget(
              message: message,
              isStreaming: isStreaming,
              showFollowUps: false,
              suppressStreamingHaptics: suppressStreamingHaptics,
              onDelete: () {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'defers heavy mermaid previews while the message is still streaming',
    (tester) async {
      const content = '''
```mermaid
graph TD
  A-->B
```
''';

      await tester.pumpWidget(buildHarness(content, isStreaming: true));

      expect(find.text('Preview deferred for large content.'), findsOneWidget);
      expect(find.byType(MermaidDiagram), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('mermaid'), findsNothing);
    },
  );

  testWidgets(
    'keeps small heavy mermaid previews eager after streaming completes',
    (tester) async {
      const content = '''
```mermaid
graph TD
  A-->B
```
''';

      await tester.pumpWidget(buildHarness(content));

      expect(find.byType(MermaidDiagram), findsOneWidget);
      expect(find.text('Preview deferred for large content.'), findsNothing);
      expect(find.text('Open preview'), findsNothing);
    },
  );

  testWidgets(
    'automatically opens oversized heavy mermaid previews after streaming ends',
    (tester) async {
      final lines = List<String>.generate(
        160,
        (index) => '  N$index-->N${index + 1}',
      );
      final content = ['```mermaid', 'graph TD', ...lines, '```'].join('\n');

      await tester.pumpWidget(buildHarness(content, isStreaming: true));

      expect(find.text('Preview deferred for large content.'), findsOneWidget);
      expect(find.text('Open preview'), findsNothing);
      expect(find.byType(MermaidDiagram), findsNothing);

      await tester.pumpWidget(buildHarness(content, isStreaming: false));
      await tester.pump();

      expect(find.byType(MermaidDiagram), findsOneWidget);
      expect(find.text('Preview deferred for large content.'), findsNothing);
      expect(find.text('Open preview'), findsNothing);
    },
  );

  testWidgets(
    'streaming completion does not remount the compiled markdown subtree',
    (tester) async {
      var mountedCount = 0;
      var disposedCount = 0;

      await tester.pumpWidget(
        buildHarness(
          'Settled response',
          isStreaming: true,
          onCompiledViewMounted: () => mountedCount += 1,
          onCompiledViewDisposed: () => disposedCount += 1,
        ),
      );
      await tester.pump();

      expect(mountedCount, 1);
      expect(disposedCount, 0);

      await tester.pumpWidget(
        buildHarness(
          'Settled response',
          isStreaming: false,
          onCompiledViewMounted: () => mountedCount += 1,
          onCompiledViewDisposed: () => disposedCount += 1,
        ),
      );
      await tester.pump();

      expect(mountedCount, 1);
      expect(disposedCount, 0);
    },
  );

  testWidgets(
    'automatically opens multiple heavy previews after streaming ends',
    (tester) async {
      const content = '''
```mermaid
graph TD
  A-->B
```

```mermaid
graph TD
  C-->D
```
''';

      await tester.pumpWidget(buildHarness(content, isStreaming: true));

      expect(
        find.text('Preview deferred for large content.'),
        findsNWidgets(2),
      );
      expect(find.byType(MermaidDiagram), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNWidgets(2));

      await tester.pumpWidget(buildHarness(content, isStreaming: false));
      await tester.pump();

      expect(find.byType(MermaidDiagram), findsNWidgets(2));
      expect(find.text('Preview deferred for large content.'), findsNothing);
      expect(find.text('Open preview'), findsNothing);
    },
  );

  testWidgets(
    'renders loose list item paragraphs inline like the web renderer',
    (tester) async {
      const content = '- First paragraph.\n\n  Second paragraph.';

      await tester.pumpWidget(buildHarness(content));

      final row = tester.widget<Row>(
        find.ancestor(of: find.text('•'), matching: find.byType(Row)),
      );
      final expanded = row.children.last as Expanded;
      final textWidget = expanded.child as Text;

      expect(
        textWidget.textSpan?.toPlainText(),
        'First paragraph. Second paragraph.',
      );
    },
  );

  testWidgets(
    'renders loose list item paragraphs inline while streaming long content',
    (tester) async {
      final firstParagraph = List<String>.filled(
        40,
        'First paragraph.',
      ).join(' ');
      final secondParagraph = List<String>.filled(
        40,
        'Second paragraph.',
      ).join(' ');
      final content = '- $firstParagraph\n\n  $secondParagraph';

      await tester.pumpWidget(buildHarness(content, isStreaming: true));
      await tester.pumpAndSettle();

      // While streaming, the loose list-item inline run is rendered through a
      // FadableRichText (so its suffix can fade), which builds a Text.rich
      // internally. Locate that rendered Text regardless of the wrapper.
      final textWidget = tester.widget<Text>(
        find.descendant(
          of: find.byType(FadableRichText),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Text &&
                widget.textSpan?.toPlainText() ==
                    '$firstParagraph $secondParagraph',
          ),
        ),
      );

      expect(
        textWidget.textSpan?.toPlainText(),
        '$firstParagraph $secondParagraph',
      );
    },
  );

  testWidgets(
    'inline citation badges prefer normalized labels and use compact text',
    (tester) async {
      const sources = <ChatSourceReference>[
        ChatSourceReference(
          title: 'crypto.com',
          url: 'https://vertexaisearch.cloud.google.com/result',
        ),
      ];

      await tester.pumpWidget(buildHarness('See [1]', sources: sources));

      expect(find.text('crypto.com'), findsOneWidget);
      expect(find.textContaining('vertexaisearch'), findsNothing);

      final chipText = tester.widget<Text>(find.text('crypto.com'));
      expect(chipText.style?.fontSize, AppTypography.labelSmall);
    },
  );

  testWidgets('citation-like text stays literal when sources are absent', (
    tester,
  ) async {
    await tester.pumpWidget(buildHarness('Refs [1][2] and array[3].'));

    expect(
      find.text('Refs [1][2] and array[3].', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('keeps paragraph spacing between blocks but trims the end', (
    tester,
  ) async {
    await tester.pumpWidget(buildHarness('First\n\nSecond'));

    final paragraphPaddings = tester
        .widgetList<Padding>(
          find.byWidgetPredicate((widget) {
            if (widget is! Padding || widget.child is! Text) {
              return false;
            }
            final text = widget.child as Text;
            final plainText = text.textSpan?.toPlainText() ?? text.data;
            return plainText == 'First' || plainText == 'Second';
          }),
        )
        .toList(growable: false);

    expect(paragraphPaddings, hasLength(2));
    expect(
      (paragraphPaddings.first.padding as EdgeInsets).bottom,
      greaterThan(0),
    );
    expect((paragraphPaddings.last.padding as EdgeInsets).bottom, 0);
  });

  testWidgets('streaming markdown fades newly appended rendered text', (
    tester,
  ) async {
    await tester.pumpWidget(buildHarness('Hello', isStreaming: true));
    await tester.pump();

    await tester.pumpWidget(buildHarness('Hello **world**', isStreaming: true));
    await tester.pump();

    Text renderedText() {
      return tester.widget<Text>(
        find.byWidgetPredicate((widget) {
          return widget is Text &&
              widget.textSpan?.toPlainText() == 'Hello world';
        }),
      );
    }

    final fadingLeaves = _textSpanLeaves(renderedText().textSpan!).toList();
    final fadingWorld = fadingLeaves.singleWhere(
      (span) => span.text == 'world',
    );
    expect(fadingWorld.style?.fontWeight, FontWeight.bold);
    expect(fadingWorld.style?.color?.a, lessThan(1));

    await tester.pump(const Duration(milliseconds: 360));

    final settledLeaves = _textSpanLeaves(renderedText().textSpan!).toList();
    final settledWorld = settledLeaves.singleWhere(
      (span) => span.text == 'world',
    );
    expect(settledWorld.style?.fontWeight, FontWeight.bold);
    expect(settledWorld.style?.color?.a ?? 1, 1);
  });

  testWidgets('streaming markdown fades newly appended plain text', (
    tester,
  ) async {
    await tester.pumpWidget(buildHarness('Hello', isStreaming: true));
    await tester.pump();

    await tester.pumpWidget(buildHarness('Hello world', isStreaming: true));
    await tester.pump();

    Text renderedText() {
      return tester.widget<Text>(
        find.byWidgetPredicate((widget) {
          return widget is Text &&
              widget.textSpan?.toPlainText() == 'Hello world';
        }),
      );
    }

    final fadingLeaves = _textSpanLeaves(renderedText().textSpan!).toList();
    final fadingSuffix = fadingLeaves.singleWhere(
      (span) => span.text == ' world',
    );
    expect(fadingSuffix.style?.color?.a, lessThan(1));

    await tester.pump(const Duration(milliseconds: 360));

    final settledLeaves = _textSpanLeaves(renderedText().textSpan!).toList();
    expect(settledLeaves.map((span) => span.text).join(), 'Hello world');
    expect(
      settledLeaves.every((span) => (span.style?.color?.a ?? 1) == 1),
      isTrue,
    );
  });

  testWidgets(
    'fade reuses the cached base span tree instead of rebuilding per frame',
    (tester) async {
      var baseRenders = 0;
      Widget harness(String content) => buildHarness(
        content,
        isStreaming: true,
        onBaseRender: () => baseRenders += 1,
      );

      await tester.pumpWidget(harness('Hello'));
      await tester.pump();
      expect(baseRenders, 1, reason: 'base render once for the first content');

      await tester.pumpWidget(harness('Hello **world**'));
      await tester.pump();
      final beforeFade = baseRenders;
      expect(
        beforeFade,
        greaterThanOrEqualTo(2),
        reason: 'at least one additional base render for the new content',
      );

      // Sweep the 320ms fade across ~20 frames. The base span tree is produced
      // once per content change and the fade reuses that cache, so a pure fade
      // (unchanged document) must add at most ONE base render (the settle pass)
      // and never one-per-frame. A small constant bound — independent of the
      // frame count — catches partial (every-other-frame) regressions that the
      // old `frames ~/ 2` bound tolerated.
      var frames = 0;
      for (var elapsed = 0; elapsed < 320; elapsed += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        frames += 1;
      }
      expect(
        baseRenders - beforeFade,
        lessThanOrEqualTo(1),
        reason:
            'base render is not driven per fade frame ($frames frames swept)',
      );

      final afterFade = baseRenders;
      await tester.pump(const Duration(milliseconds: 400));
      expect(baseRenders, afterFade, reason: 'settling adds no base render');
    },
  );

  testWidgets('only the faded suffix changes alpha and recognizers are stable', (
    tester,
  ) async {
    void onTap(String url, String title) {}
    var baseRenders = 0;
    await tester.pumpWidget(
      buildHarness(
        'See [docs](https://a.test)',
        isStreaming: true,
        onTapLink: onTap,
        onBaseRender: () => baseRenders += 1,
      ),
    );
    await tester.pump();

    await tester.pumpWidget(
      buildHarness(
        'See [docs](https://a.test) and **more**',
        isStreaming: true,
        onTapLink: onTap,
        onBaseRender: () => baseRenders += 1,
      ),
    );
    await tester.pump();

    Text renderedText() {
      return tester.widget<Text>(
        find.byWidgetPredicate((widget) {
          return widget is Text &&
              (widget.textSpan?.toPlainText() ?? '') == 'See docs and more';
        }),
      );
    }

    final fadingLeaves = _textSpanLeaves(renderedText().textSpan!).toList();
    // The link prefix recognizer is captured to assert identity stability.
    final docsLeaf = fadingLeaves.singleWhere((span) => span.text == 'docs');
    final docsRecognizer = docsLeaf.recognizer;
    expect(docsRecognizer, isNotNull);

    // The stable prefix is the common 'See docs' text. Everything appended after
    // it (' and ' + 'more') is the streaming suffix and fades together; the
    // prefix stays fully opaque.
    const suffixTexts = {' and ', 'more'};
    var sawFadedSuffix = false;
    for (final leaf in fadingLeaves) {
      final alpha = leaf.style?.color?.a ?? 1;
      if (suffixTexts.contains(leaf.text)) {
        expect(alpha, lessThan(1), reason: 'suffix fades in: "${leaf.text}"');
        sawFadedSuffix = true;
      } else {
        expect(alpha, 1, reason: 'prefix stays opaque: "${leaf.text}"');
      }
    }
    expect(sawFadedSuffix, isTrue);

    // Step the fade frame-by-frame and assert recognizer identity is stable
    // across consecutive reuse frames (frames that do NOT re-resolve the base
    // span tree). applyFadeOpacity must never recreate the recognizer, so a
    // reuse frame's recognizer must be identical to the previous reuse frame's.
    // We require at least one such cross-frame comparison so the assertion can
    // never be silently skipped: a regression that rebuilds the span tree on
    // every fade frame would leave `reuseFrameComparisons` zero and fail the
    // test — the failure mode the old single-frame `if` guard let pass green.
    Object? previousReuseRecognizer = docsRecognizer;
    var reuseFrameComparisons = 0;
    for (var i = 0; i < 12; i++) {
      final rendersBeforeFrame = baseRenders;
      await tester.pump(const Duration(milliseconds: 16));
      final frameLeaves = _textSpanLeaves(renderedText().textSpan!).toList();
      final frameDocs = frameLeaves.singleWhere((span) => span.text == 'docs');
      if (baseRenders != rendersBeforeFrame) {
        // This frame re-resolved the document, so a fresh recognizer is
        // expected; reset the baseline and only compare across reuse frames.
        previousReuseRecognizer = frameDocs.recognizer;
        continue;
      }
      reuseFrameComparisons++;
      expect(
        identical(frameDocs.recognizer, previousReuseRecognizer),
        isTrue,
        reason: 'link recognizer identity is stable across fade frames',
      );
      previousReuseRecognizer = frameDocs.recognizer;
    }
    expect(
      reuseFrameComparisons,
      greaterThan(0),
      reason:
          'at least one fade frame must reuse the cached span tree (otherwise '
          'the recognizer-stability assertion is silently skipped)',
    );

    await tester.pump(const Duration(milliseconds: 360));
    final settledLeaves = _textSpanLeaves(renderedText().textSpan!).toList();
    expect(
      settledLeaves.every((span) => (span.style?.color?.a ?? 1) == 1),
      isTrue,
      reason: 'every span settles to full opacity',
    );
    final settledDocs = settledLeaves.singleWhere(
      (span) => span.text == 'docs',
    );
    expect(
      settledDocs.recognizer,
      isNotNull,
      reason: 'the link recognizer survives the fade',
    );
  });

  testWidgets('faded suffix begins after a fenced code block prefix', (
    tester,
  ) async {
    const prefix = 'Intro\n\n```\ncode body\n```\n\nTail';
    await tester.pumpWidget(buildHarness(prefix, isStreaming: true));
    await tester.pump();

    await tester.pumpWidget(
      buildHarness('$prefix appended', isStreaming: true),
    );
    await tester.pump();

    Text tailText() {
      return tester.widget<Text>(
        find.byWidgetPredicate((widget) {
          return widget is Text &&
              (widget.textSpan?.toPlainText() ?? '') == 'Tail appended';
        }),
      );
    }

    final leaves = _textSpanLeaves(tailText().textSpan!).toList();
    // The code body precedes the tail in document coordinates; the fade offset
    // must still land exactly on the appended ' appended' suffix, so the stable
    // 'Tail' text never re-fades.
    final stable = leaves.where((span) => span.text == 'Tail');
    final faded = leaves.where((span) => (span.style?.color?.a ?? 1) < 1);
    expect(stable.every((span) => (span.style?.color?.a ?? 1) == 1), isTrue);
    expect(faded.map((span) => span.text).join(), contains('appended'));

    await tester.pump(const Duration(milliseconds: 360));
    final settled = _textSpanLeaves(tailText().textSpan!).toList();
    expect(settled.every((span) => (span.style?.color?.a ?? 1) == 1), isTrue);
  });

  testWidgets('surrogate-pair boundary never splits mid-emoji while fading', (
    tester,
  ) async {
    // Append text right after a non-BMP emoji; the fade split must snap off the
    // surrogate pair so no lone-surrogate/replacement glyph appears.
    await tester.pumpWidget(buildHarness('Hi \u{1F600}', isStreaming: true));
    await tester.pump();

    await tester.pumpWidget(
      buildHarness('Hi \u{1F600} there', isStreaming: true),
    );
    await tester.pump();

    Text renderedText() {
      return tester.widget<Text>(
        find.byWidgetPredicate((widget) {
          return widget is Text &&
              (widget.textSpan?.toPlainText() ?? '') == 'Hi \u{1F600} there';
        }),
      );
    }

    for (var elapsed = 0; elapsed < 320; elapsed += 40) {
      final leaves = _textSpanLeaves(renderedText().textSpan!).toList();
      final joined = leaves.map((span) => span.text ?? '').join();
      // The emoji round-trips intact (no replacement char, no lone surrogate).
      expect(joined, 'Hi \u{1F600} there');
      expect(joined.contains('�'), isFalse);
      for (final leaf in leaves) {
        final text = leaf.text;
        if (text == null || text.isEmpty) continue;
        expect(
          _hasLoneSurrogate(text),
          isFalse,
          reason: 'leaf "$text" must not split the emoji surrogate pair',
        );
      }
      await tester.pump(const Duration(milliseconds: 40));
    }

    await tester.pump(const Duration(milliseconds: 360));
    final settled = _textSpanLeaves(renderedText().textSpan!).toList();
    expect(settled.map((span) => span.text ?? '').join(), 'Hi \u{1F600} there');
    expect(settled.every((span) => (span.style?.color?.a ?? 1) == 1), isTrue);
  });

  testWidgets('renders OpenWebUI mentions without placeholder leakage', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          home: Scaffold(
            body: StreamingMarkdownWidget(
              content:
                  'Hi <@U:user-id|Tuna>, see [<@M:model-id|Model>](https://a.test).',
              isStreaming: false,
              onTapLink: (_, _) {},
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('@Tuna', findRichText: true), findsOneWidget);
    expect(find.textContaining('@Model', findRichText: true), findsOneWidget);
    expect(
      find.textContaining('{{conduit_mention_', findRichText: true),
      findsNothing,
    );

    final richTexts = tester.widgetList<RichText>(find.byType(RichText));
    final modelSpan = richTexts
        .map((richText) => _findTextSpan(richText.text, '@Model'))
        .nonNulls
        .single;
    expect(modelSpan.recognizer, isNotNull);
  });

  testWidgets('does not alter mention-like content in inline code', (
    tester,
  ) async {
    await tester.pumpWidget(buildHarness('Use `<@U:user-id|Tuna>` literally.'));

    expect(find.text('<@U:user-id|Tuna>'), findsOneWidget);
    expect(
      find.textContaining('{{conduit_mention_', findRichText: true),
      findsNothing,
    );
  });

  testWidgets(
    'preserves literal text that resembles old mention placeholders',
    (tester) async {
      await tester.pumpWidget(
        buildHarness('{{conduit_mention_0}} <@U:user-id|Tuna>'),
      );

      expect(
        find.textContaining('{{conduit_mention_0}}', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('@Tuna', findRichText: true), findsOneWidget);
    },
  );

  testWidgets(
    'renders tool call details through markdown and expands attributes',
    (tester) async {
      const content = '''
Before

<details type="tool_calls" done="true" name="search" arguments="{&quot;q&quot;:&quot;cats&quot;}" result="&quot;done&quot;">
<summary>Tool Executed</summary>
</details>

After
''';

      await tester.pumpWidget(buildHarness(content));

      expect(find.text('View Result from search'), findsOneWidget);
      expect(find.textContaining('<details'), findsNothing);
      expect(find.text('Input'), findsNothing);

      await tester.tap(find.text('View Result from search'));
      await tester.pumpAndSettle();

      expect(find.text('Input'), findsOneWidget);
      expect(find.text('Output'), findsOneWidget);
      expect(find.text('cats'), findsOneWidget);
      expect(find.text('done'), findsOneWidget);
    },
  );

  testWidgets(
    'uses tool call body content as structured output without leaking raw text',
    (tester) async {
      const content = '''
Before

<details type="tool_calls" done="true" name="search" arguments="{&quot;q&quot;:&quot;cats&quot;}">
<summary>Tool Executed</summary>
&quot;done&quot;
</details>

After
''';

      await tester.pumpWidget(buildHarness(content));

      expect(find.text('View Result from search'), findsOneWidget);
      expect(find.text('done'), findsNothing);
      expect(find.text('After'), findsOneWidget);

      await tester.tap(find.text('View Result from search'));
      await tester.pumpAndSettle();

      expect(find.text('Input'), findsOneWidget);
      expect(find.text('Output'), findsOneWidget);
      expect(find.text('cats'), findsOneWidget);
      expect(find.text('done'), findsOneWidget);
    },
  );

  testWidgets('collapses consecutive tool calls into a grouped summary', (
    tester,
  ) async {
    const content = '''
<details type="tool_calls" done="true" name="search" result="&quot;one&quot;">
<summary>Tool Executed</summary>
</details>
<details type="tool_calls" done="true" name="browser" result="&quot;two&quot;">
<summary>Tool Executed</summary>
</details>
''';

    await tester.pumpWidget(buildHarness(content));

    expect(find.text('Explored search, browser'), findsOneWidget);
    expect(find.text('View Result from search'), findsNothing);
    expect(find.text('View Result from browser'), findsNothing);

    await tester.tap(find.text('Explored search, browser'));
    await tester.pumpAndSettle();

    expect(find.text('View Result from search'), findsOneWidget);
    expect(find.text('View Result from browser'), findsOneWidget);
  });

  testWidgets('localizes grouped tool call titles', (tester) async {
    const content = '''
<details type="tool_calls" done="true" name="search" result="&quot;one&quot;">
<summary>Tool Executed</summary>
</details>
<details type="tool_calls" done="true" name="browser" result="&quot;two&quot;">
<summary>Tool Executed</summary>
</details>
''';

    await tester.pumpWidget(buildHarness(content, locale: const Locale('es')));

    expect(find.text('Explorado search, browser'), findsOneWidget);
  });

  testWidgets(
    'keeps grouped tool calls expanded when new tool calls stream in after remount',
    (tester) async {
      final bucket = PageStorageBucket();
      var content = '''
<details type="tool_calls" done="true" name="search" result="&quot;one&quot;">
<summary>Tool Executed</summary>
</details>
<details type="tool_calls" done="true" name="browser" result="&quot;two&quot;">
<summary>Tool Executed</summary>
</details>
''';
      var revision = 0;
      late void Function(VoidCallback fn) rebuild;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return PageStorage(
                    bucket: bucket,
                    child: KeyedSubtree(
                      key: ValueKey(revision),
                      child: SingleChildScrollView(
                        child: StreamingMarkdownWidget(
                          content: content,
                          isStreaming: true,
                          stateScopeId: 'message-1',
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Explored search, browser'));
      await tester.pumpAndSettle();

      expect(find.text('View Result from search'), findsOneWidget);
      expect(find.text('View Result from browser'), findsOneWidget);

      rebuild(() {
        revision += 1;
        content = '''
<details type="tool_calls" done="true" name="search" result="&quot;one&quot;">
<summary>Tool Executed</summary>
</details>
<details type="tool_calls" done="true" name="browser" result="&quot;two&quot;">
<summary>Tool Executed</summary>
</details>
<details type="tool_calls" done="true" name="files" result="&quot;three&quot;">
<summary>Tool Executed</summary>
</details>
''';
      });
      await tester.pumpAndSettle();

      expect(find.text('View Result from search'), findsOneWidget);
      expect(find.text('View Result from browser'), findsOneWidget);
      expect(find.text('View Result from files'), findsOneWidget);
    },
  );

  testWidgets(
    'keeps expanded reasoning blocks open while only the streaming tail changes',
    (tester) async {
      final bucket = PageStorageBucket();
      var content = '''
<details type="reasoning" done="false">
<summary>Reasoning</summary>
First step
</details>

Tail
''';
      late void Function(VoidCallback fn) rebuild;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return PageStorage(
                    bucket: bucket,
                    child: SingleChildScrollView(
                      child: StreamingMarkdownWidget(
                        content: content,
                        isStreaming: true,
                        stateScopeId: 'message-1',
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Reasoning'));
      await tester.pumpAndSettle();
      expect(find.text('First step'), findsOneWidget);

      rebuild(() {
        content = '''
<details type="reasoning" done="false">
<summary>Reasoning</summary>
First step
</details>

Tail keeps growing
''';
      });
      await tester.pumpAndSettle();

      expect(find.text('First step'), findsOneWidget);
    },
  );

  testWidgets('does not leak incomplete tool call details while streaming', (
    tester,
  ) async {
    final content = [
      List<String>.filled(80, 'Stable sentence.').join(' '),
      '<details type="tool_calls" done="true" name="run_command" arguments="&quot;{&quot;command&quot;:&quot;python&quot;}&quot;">',
      '<summary>Tool Executed</summary>',
      '&quot;{',
      '&quot;status&quot;:&quot;running&quot;,',
    ].join('\n\n');

    await tester.pumpWidget(buildHarness(content, isStreaming: true));

    expect(find.textContaining('<details'), findsNothing);
    expect(find.textContaining('type="tool_calls"'), findsNothing);
    expect(find.textContaining('Stable sentence.'), findsWidgets);
  });

  testWidgets(
    'skips recompiling when async prepare resolves to the current snapshot',
    (tester) async {
      debugResetCompiledMarkdownCache();
      final compiler = _PrepareCountingMarkdownCompileService();
      addTearDown(compiler.dispose);
      final baseContent = List<String>.filled(80, 'Stable sentence.').join(' ');
      final hiddenTrailingToolCall = [
        baseContent,
        '<details type="tool_calls" done="true" name="run_command">',
        '<summary>Tool Executed</summary>',
      ].join('\n\n');

      Widget buildCountingHarness(String content) {
        return ProviderScope(
          overrides: [
            markdownCompileServiceProvider.overrideWithValue(compiler),
          ],
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(
                child: StreamingMarkdownWidget(
                  content: content,
                  isStreaming: true,
                ),
              ),
            ),
          ),
        );
      }

      await tester.pumpWidget(buildCountingHarness(baseContent));
      await tester.pump();

      expect(compiler.prepareCallCount, 0);
      expect(compiler.compileCallCount, 1);

      await tester.pumpWidget(buildCountingHarness(hiddenTrailingToolCall));
      await tester.pump();
      await tester.pump();

      expect(compiler.prepareCallCount, 1);
      expect(compiler.compileCallCount, 1);
    },
  );

  testWidgets(
    'pauses streaming refresh while another route obscures the chat',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      var content = 'First pass';
      var refreshFrameCount = 0;
      late void Function(VoidCallback fn) rebuildHome;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: StatefulBuilder(
              builder: (context, setState) {
                rebuildHome = setState;
                return Scaffold(
                  body: SingleChildScrollView(
                    child: StreamingMarkdownWidget(
                      content: content,
                      isStreaming: true,
                      debugOnStreamingRefreshFrame: () {
                        refreshFrameCount += 1;
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();

      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: SizedBox.shrink()),
        ),
      );
      await tester.pumpAndSettle();

      rebuildHome(() {
        content = 'Second pass while hidden';
      });
      await tester.pump();
      await tester.pump();

      expect(refreshFrameCount, 0);

      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.pump();

      expect(refreshFrameCount, 1);
    },
  );

  testWidgets('keeps streaming refresh active while the app is inactive', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.instance;
    var content = 'First pass';
    var refreshFrameCount = 0;
    late void Function(VoidCallback fn) rebuildHome;

    addTearDown(() {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuildHome = setState;
              return Scaffold(
                body: SingleChildScrollView(
                  child: StreamingMarkdownWidget(
                    content: content,
                    isStreaming: true,
                    debugOnStreamingRefreshFrame: () {
                      refreshFrameCount += 1;
                    },
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);

    rebuildHome(() {
      content = 'Second pass while inactive';
    });
    await tester.pump();
    await tester.pump();

    expect(refreshFrameCount, 1);
  });

  testWidgets(
    'assistant streaming haptics fire for content arrival and completion',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(const AppSettings()),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final platformCalls = <_RecordedPlatformCall>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        platformCalls.add(_RecordedPlatformCall(call.method, call.arguments));
        return null;
      });

      final message = ChatMessage(
        id: 'streaming-message',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2026),
      );

      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: true,
            disableAnimations: true,
          ),
        );

        container.read(streamingContentProvider.notifier).set('Hello');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message.copyWith(content: 'Hello'),
            isStreaming: false,
            disableAnimations: true,
          ),
        );
        await tester.pump();

        expect(_mediumImpactCalls(platformCalls), hasLength(4));
      } finally {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        container.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'assistant streaming haptics stay silent when disabled in settings',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(disableHapticsWhileStreaming: true),
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final platformCalls = <_RecordedPlatformCall>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        platformCalls.add(_RecordedPlatformCall(call.method, call.arguments));
        return null;
      });

      final message = ChatMessage(
        id: 'streaming-message',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2026),
      );

      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: true,
            disableAnimations: true,
          ),
        );

        container.read(streamingContentProvider.notifier).set('Hello');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message.copyWith(content: 'Hello'),
            isStreaming: false,
            disableAnimations: true,
          ),
        );
        await tester.pump();

        expect(_mediumImpactCalls(platformCalls), isEmpty);
      } finally {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        container.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'assistant streaming haptics stay silent when suppressed by voice mode',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(const AppSettings()),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final platformCalls = <_RecordedPlatformCall>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        platformCalls.add(_RecordedPlatformCall(call.method, call.arguments));
        return null;
      });

      final message = ChatMessage(
        id: 'voice-streaming-message',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2026),
      );

      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: true,
            disableAnimations: true,
            suppressStreamingHaptics: true,
          ),
        );

        container.read(streamingContentProvider.notifier).set('Hello');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message.copyWith(content: 'Hello'),
            isStreaming: false,
            disableAnimations: true,
            suppressStreamingHaptics: true,
          ),
        );
        await tester.pump();

        check(_hapticFeedbackCalls(platformCalls)).isEmpty();
      } finally {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        container.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'assistant streaming markdown does not add a shader fade on chunk updates',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(disableHapticsWhileStreaming: true),
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );

      final message = ChatMessage(
        id: 'streaming-message',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2026),
      );

      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: true,
          ),
        );

        container.read(streamingContentProvider.notifier).set('Hello');
        await tester.pump();
        await tester.pump();

        expect(find.text('Hello', findRichText: true), findsOneWidget);
        expect(find.byType(ShaderMask), findsNothing);

        container.read(streamingContentProvider.notifier).set('Hello world');
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));

        expect(find.text('Hello world', findRichText: true), findsOneWidget);
        expect(find.byType(ShaderMask), findsNothing);
      } finally {
        container.dispose();
      }
    },
  );

  testWidgets(
    'assistant streams long plain content through markdown rendering',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(disableHapticsWhileStreaming: true),
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );

      final message = ChatMessage(
        id: 'streaming-plain-message',
        role: 'assistant',
        content: List<String>.filled(80, 'Plain streaming sentence.').join(' '),
        timestamp: DateTime(2026),
      );

      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: true,
          ),
        );
        await tester.pump();

        expect(find.byType(StreamingMarkdownWidget), findsOneWidget);
        expect(
          find.textContaining('Plain streaming sentence.'),
          findsOneWidget,
        );
      } finally {
        container.dispose();
      }
    },
  );

  testWidgets(
    'assistant streaming markdown renderer omits reference definitions',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(disableHapticsWhileStreaming: true),
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );
      final content = [
        List<String>.filled(80, 'Plain streaming sentence.').join(' '),
        '[docs]: https://example.com',
      ].join('\n\n');
      final message = ChatMessage(
        id: 'streaming-reference-definition-message',
        role: 'assistant',
        content: content,
        timestamp: DateTime(2026),
      );

      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: true,
          ),
        );
        await tester.pump();

        expect(find.byType(StreamingMarkdownWidget), findsOneWidget);
        expect(
          find.textContaining('[docs]: https://example.com'),
          findsNothing,
        );
        expect(
          find.textContaining('Plain streaming sentence.'),
          findsOneWidget,
        );
      } finally {
        container.dispose();
      }
    },
  );

  testWidgets(
    'assistant keeps markdown rendering for long streaming reference-style link content',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(disableHapticsWhileStreaming: true),
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );
      final markdownContent = [
        List<String>.filled(80, 'Paragraph text.').join(' '),
        'See [docs][d] for more details.',
        '[d]: https://example.com',
      ].join('\n\n');
      final message = ChatMessage(
        id: 'streaming-reference-style-link-message',
        role: 'assistant',
        content: markdownContent,
        timestamp: DateTime(2026),
      );

      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: true,
          ),
        );
        await tester.pump();

        expect(find.byType(StreamingMarkdownWidget), findsOneWidget);
      } finally {
        container.dispose();
      }
    },
  );

  testWidgets(
    'assistant keeps markdown rendering for long streaming markdown content',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(disableHapticsWhileStreaming: true),
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );
      final markdownContent = [
        List<String>.filled(80, 'Paragraph text.').join(' '),
        '[Reference](https://example.com)',
      ].join('\n\n');
      final message = ChatMessage(
        id: 'streaming-markdown-message',
        role: 'assistant',
        content: markdownContent,
        timestamp: DateTime(2026),
      );

      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: true,
          ),
        );
        await tester.pump();

        expect(find.byType(StreamingMarkdownWidget), findsOneWidget);
      } finally {
        container.dispose();
      }
    },
  );

  testWidgets(
    'assistant keeps markdown rendering for long streaming autolink content',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(disableHapticsWhileStreaming: true),
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );
      final markdownContent = [
        List<String>.filled(80, 'Paragraph text.').join(' '),
        '<https://example.com>',
      ].join('\n\n');
      final message = ChatMessage(
        id: 'streaming-autolink-message',
        role: 'assistant',
        content: markdownContent,
        timestamp: DateTime(2026),
      );

      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: true,
          ),
        );
        await tester.pump();

        expect(find.byType(StreamingMarkdownWidget), findsOneWidget);
      } finally {
        container.dispose();
      }
    },
  );

  testWidgets(
    'assistant keeps markdown rendering for long streaming bare autolink content',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(disableHapticsWhileStreaming: true),
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );
      final markdownContent = [
        List<String>.filled(80, 'Paragraph text.').join(' '),
        'Visit https://example.com or email hello@example.com',
      ].join('\n\n');
      final message = ChatMessage(
        id: 'streaming-bare-autolink-message',
        role: 'assistant',
        content: markdownContent,
        timestamp: DateTime(2026),
      );

      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: true,
          ),
        );
        await tester.pump();

        expect(find.byType(StreamingMarkdownWidget), findsOneWidget);
      } finally {
        container.dispose();
      }
    },
  );

  testWidgets(
    'assistant keeps markdown rendering for long streaming indented code block content',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(disableHapticsWhileStreaming: true),
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );
      final markdownContent = [
        List<String>.filled(80, 'Paragraph text.').join(' '),
        ['    final answer = 42;', '    print(answer);'].join('\n'),
      ].join('\n\n');
      final message = ChatMessage(
        id: 'streaming-indented-code-message',
        role: 'assistant',
        content: markdownContent,
        timestamp: DateTime(2026),
      );

      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: true,
          ),
        );
        await tester.pump();

        expect(find.byType(StreamingMarkdownWidget), findsOneWidget);
      } finally {
        container.dispose();
      }
    },
  );

  testWidgets(
    'assistant keeps markdown rendering for long streaming italic markdown content',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(disableHapticsWhileStreaming: true),
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );
      final markdownContent = [
        List<String>.filled(80, 'Paragraph text.').join(' '),
        '*italic emphasis*',
      ].join('\n\n');
      final message = ChatMessage(
        id: 'streaming-italic-markdown-message',
        role: 'assistant',
        content: markdownContent,
        timestamp: DateTime(2026),
      );

      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: true,
          ),
        );
        await tester.pump();

        expect(find.byType(StreamingMarkdownWidget), findsOneWidget);
      } finally {
        container.dispose();
      }
    },
  );

  testWidgets(
    'assistant keeps markdown rendering for long streaming block latex content',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(disableHapticsWhileStreaming: true),
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );
      final markdownContent = [
        List<String>.filled(80, 'Paragraph text.').join(' '),
        r'$$',
        r'x^2 + y^2',
        r'$$',
      ].join('\n\n');
      final message = ChatMessage(
        id: 'streaming-block-latex-message',
        role: 'assistant',
        content: markdownContent,
        timestamp: DateTime(2026),
      );

      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: true,
          ),
        );
        await tester.pump();

        expect(find.byType(StreamingMarkdownWidget), findsOneWidget);
      } finally {
        container.dispose();
      }
    },
  );

  testWidgets(
    'assistant keeps markdown rendering for long streaming ordered lists with paren markers',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(disableHapticsWhileStreaming: true),
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );
      final markdownContent = [
        List<String>.filled(80, 'Paragraph text.').join(' '),
        '1) First item',
        '2) Second item',
      ].join('\n\n');
      final message = ChatMessage(
        id: 'streaming-paren-ordered-list-message',
        role: 'assistant',
        content: markdownContent,
        timestamp: DateTime(2026),
      );

      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: true,
          ),
        );
        await tester.pump();

        expect(find.byType(StreamingMarkdownWidget), findsOneWidget);
      } finally {
        container.dispose();
      }
    },
  );

  testWidgets(
    'assistant keeps markdown rendering for long streaming GFM tables with spaced dividers',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(disableHapticsWhileStreaming: true),
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );
      final markdownContent = [
        List<String>.filled(80, 'Paragraph text.').join(' '),
        '| A | B |',
        '| --- | --- |',
        '| 1 | 2 |',
      ].join('\n\n');
      final message = ChatMessage(
        id: 'streaming-gfm-table-message',
        role: 'assistant',
        content: markdownContent,
        timestamp: DateTime(2026),
      );

      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: true,
          ),
        );
        await tester.pump();

        expect(find.byType(StreamingMarkdownWidget), findsOneWidget);
      } finally {
        container.dispose();
      }
    },
  );

  testWidgets(
    'assistant keeps markdown rendering for long streaming inline html content',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(disableHapticsWhileStreaming: true),
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );
      final markdownContent = [
        List<String>.filled(80, 'Paragraph text.').join(' '),
        'Line one<br>Line two <a href="https://example.com">link</a>',
      ].join('\n\n');
      final message = ChatMessage(
        id: 'streaming-inline-html-message',
        role: 'assistant',
        content: markdownContent,
        timestamp: DateTime(2026),
      );

      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: true,
          ),
        );
        await tester.pump();

        expect(find.byType(StreamingMarkdownWidget), findsOneWidget);
      } finally {
        container.dispose();
      }
    },
  );

  testWidgets(
    'assistant returns to full markdown rendering after streaming completes',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(disableHapticsWhileStreaming: true),
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );
      final plainContent = List<String>.filled(
        80,
        'Settled plain response sentence.',
      ).join(' ');
      final message = ChatMessage(
        id: 'completed-plain-message',
        role: 'assistant',
        content: plainContent,
        timestamp: DateTime(2026),
      );

      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: true,
          ),
        );
        await tester.pump();

        expect(find.byType(StreamingMarkdownWidget), findsOneWidget);

        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: false,
          ),
        );
        await tester.pump();

        expect(find.byType(StreamingMarkdownWidget), findsOneWidget);
      } finally {
        container.dispose();
      }
    },
  );

  testWidgets(
    'assistant streaming content keeps updating while the app is inactive',
    (tester) async {
      final binding = TestWidgetsFlutterBinding.instance;
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(disableHapticsWhileStreaming: true),
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );

      final message = ChatMessage(
        id: 'streaming-message',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2026),
      );

      addTearDown(() {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      });

      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: true,
          ),
        );
        await tester.pump();

        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);

        container.read(streamingContentProvider.notifier).set('Hello');
        await tester.pump();
        await tester.pump();

        expect(find.text('Hello', findRichText: true), findsOneWidget);
      } finally {
        container.dispose();
      }
    },
  );

  testWidgets(
    'assistant builds TTS plain text when streaming ends with unchanged content',
    (tester) async {
      final workerManager = _ImmediateWorkerManager();
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(disableHapticsWhileStreaming: true),
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
          workerManagerProvider.overrideWithValue(workerManager),
        ],
      );

      final message = ChatMessage(
        id: 'streaming-message',
        role: 'assistant',
        content: 'Hello',
        timestamp: DateTime(2026),
      );

      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: true,
          ),
        );
        await tester.pump();

        final l10n = AppLocalizations.of(
          tester.element(find.byType(AssistantMessageWidget)),
        )!;
        expect(find.bySemanticsLabel(l10n.ttsListen), findsNothing);

        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: message,
            isStreaming: false,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.bySemanticsLabel(l10n.ttsListen), findsOneWidget);
      } finally {
        workerManager.dispose();
        container.dispose();
      }
    },
  );

  testWidgets(
    'assistant typing indicator updates when a same-length status row flips to done',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(disableHapticsWhileStreaming: true),
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );
      final pendingMessage = ChatMessage(
        id: 'streaming-status-message',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2026),
        statusHistory: const [
          ChatStatusUpdate(
            action: 'search',
            description: 'Searching',
            done: false,
          ),
        ],
      );
      final completedStatusMessage = pendingMessage.copyWith(
        statusHistory: const [
          ChatStatusUpdate(
            action: 'search',
            description: 'Searching',
            done: true,
          ),
        ],
      );

      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: pendingMessage,
            isStreaming: true,
            disableAnimations: true,
          ),
        );
        await tester.pump();

        expect(find.byKey(const ValueKey('typing')), findsNothing);

        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: completedStatusMessage,
            isStreaming: true,
            disableAnimations: true,
          ),
        );
        await tester.pump();

        expect(find.byKey(const ValueKey('typing')), findsNothing);

        await tester.pump(const Duration(milliseconds: 149));
        expect(find.byKey(const ValueKey('typing')), findsNothing);

        await tester.pump(const Duration(milliseconds: 1));
        expect(find.byKey(const ValueKey('typing')), findsOneWidget);
      } finally {
        container.dispose();
      }
    },
  );

  testWidgets(
    'typing indicator holds the footer slot while content streams, then swaps '
    'to the action row on completion',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(disableHapticsWhileStreaming: true),
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );
      final streaming = ChatMessage(
        id: 'footer-slot-message',
        role: 'assistant',
        content: 'Partial answer',
        timestamp: DateTime(2026),
      );
      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: streaming,
            isStreaming: true,
            disableAnimations: true,
          ),
        );

        // Before the 150ms gate, neither the indicator nor the action row shows.
        await tester.pump();
        expect(find.byKey(const ValueKey('typing')), findsNothing);
        expect(find.byKey(const ValueKey('actions')), findsNothing);

        // After the gate the typing indicator occupies the footer (action-row)
        // slot even though content is already streaming in above it.
        await tester.pump(const Duration(milliseconds: 150));
        expect(find.byKey(const ValueKey('typing')), findsOneWidget);
        expect(find.byKey(const ValueKey('actions')), findsNothing);

        // Completion swaps the indicator for the action row.
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: streaming.copyWith(content: 'Full answer'),
            isStreaming: false,
            disableAnimations: true,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byKey(const ValueKey('typing')), findsNothing);
        expect(find.byKey(const ValueKey('actions')), findsOneWidget);
      } finally {
        container.dispose();
      }
    },
  );

  testWidgets(
    'action row shows immediately for a completed message that never streamed',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AppSettings(disableHapticsWhileStreaming: true),
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
        ],
      );
      final completed = ChatMessage(
        id: 'history-message',
        role: 'assistant',
        content: 'A finished answer',
        timestamp: DateTime(2026),
      );
      try {
        await tester.pumpWidget(
          buildAssistantHarness(
            container: container,
            message: completed,
            isStreaming: false,
            disableAnimations: true,
          ),
        );
        await tester.pump();
        expect(find.byKey(const ValueKey('typing')), findsNothing);
        expect(find.byKey(const ValueKey('actions')), findsOneWidget);
      } finally {
        container.dispose();
      }
    },
  );

  testWidgets(
    'shows a loading skeleton when a completed document mounts before async compile finishes',
    (tester) async {
      final compiler = _DelayedMarkdownCompileService();
      addTearDown(compiler.dispose);
      final skeletonFinder = find.byType(MarkdownLoadingSkeleton);

      Widget buildDelayedHarness() {
        return ProviderScope(
          overrides: [
            markdownCompileServiceProvider.overrideWithValue(compiler),
          ],
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(
                child: const StreamingMarkdownWidget(
                  content: 'Completed response',
                  isStreaming: false,
                ),
              ),
            ),
          ),
        );
      }

      await tester.pumpWidget(buildDelayedHarness());
      await tester.pump();

      expect(skeletonFinder, findsOneWidget);
      expect(find.text('Completed response', findRichText: true), findsNothing);

      compiler.release();
      await tester.pump();
      await tester.pump();

      expect(skeletonFinder, findsNothing);
      expect(
        find.text('Completed response', findRichText: true),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'streaming markdown resolves the final document when streaming ends',
    (tester) async {
      final compiler = _DelayedMarkdownCompileService();
      addTearDown(compiler.dispose);
      final skeletonFinder = find.byType(MarkdownLoadingSkeleton);

      Widget buildDelayedHarness(bool isStreaming) {
        return ProviderScope(
          overrides: [
            markdownCompileServiceProvider.overrideWithValue(compiler),
          ],
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(
                child: StreamingMarkdownWidget(
                  content: 'Final response',
                  isStreaming: isStreaming,
                ),
              ),
            ),
          ),
        );
      }

      await tester.pumpWidget(buildDelayedHarness(true));
      await tester.pump();

      expect(find.text('Final response', findRichText: true), findsNothing);
      expect(skeletonFinder, findsNothing);

      await tester.pumpWidget(buildDelayedHarness(false));
      await tester.pump();

      expect(skeletonFinder, findsOneWidget);
      expect(find.text('Final response', findRichText: true), findsNothing);

      compiler.release();
      await tester.pump();
      await tester.pump();

      expect(skeletonFinder, findsNothing);
      expect(find.text('Final response', findRichText: true), findsOneWidget);
    },
  );

  testWidgets(
    'keeps the last streaming render visible while the final long document compiles',
    (tester) async {
      final streamingContent = List<String>.generate(
        40,
        (index) => 'Line $index',
      ).join('\n');
      final finalContent = '$streamingContent\n\nFinal settling line';
      final compiler = _SelectiveDelayedMarkdownCompileService(
        delayedPreparedContent: prepareMarkdownContent(
          finalContent,
          streaming: false,
        ),
      );
      addTearDown(compiler.dispose);
      final skeletonFinder = find.byType(MarkdownLoadingSkeleton);

      Widget buildSelectiveHarness(String content, bool isStreaming) {
        return ProviderScope(
          overrides: [
            markdownCompileServiceProvider.overrideWithValue(compiler),
          ],
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(
                child: StreamingMarkdownWidget(
                  content: content,
                  isStreaming: isStreaming,
                ),
              ),
            ),
          ),
        );
      }

      await tester.pumpWidget(buildSelectiveHarness(streamingContent, true));
      await tester.pump();

      expect(find.textContaining('Line 0', findRichText: true), findsOneWidget);
      expect(
        find.text('Final settling line', findRichText: true),
        findsNothing,
      );

      await tester.pumpWidget(buildSelectiveHarness(finalContent, false));
      await tester.pump();

      expect(skeletonFinder, findsNothing);
      expect(find.textContaining('Line 0', findRichText: true), findsOneWidget);
      expect(
        find.text('Final settling line', findRichText: true),
        findsNothing,
      );

      compiler.release();
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Final settling line', findRichText: true),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'keeps rendered content visible when non-streaming content grows mid-response',
    (tester) async {
      // Reproduces issue #540: during the responseDone gap the turn phase
      // latches to completed (isStreaming:false to the body) while answer tokens
      // keep arriving. Each non-streaming content growth must NOT regress the
      // already-rendered body to a loading skeleton (the ~13Hz strobe).
      const firstContent = 'Settled answer paragraph.';
      const grownContent = 'Settled answer paragraph.\n\nFollow-up sentence.';
      final compiler = _SelectiveDelayedMarkdownCompileService(
        delayedPreparedContent: prepareMarkdownContent(
          grownContent,
          streaming: false,
        ),
      );
      addTearDown(compiler.dispose);
      final skeletonFinder = find.byType(MarkdownLoadingSkeleton);

      Widget buildSelectiveHarness(String content) {
        return ProviderScope(
          overrides: [
            markdownCompileServiceProvider.overrideWithValue(compiler),
          ],
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(
                child: StreamingMarkdownWidget(
                  content: content,
                  // The body already treats the turn as settled (responseDone
                  // gap), so isStreaming is false for both frames.
                  isStreaming: false,
                ),
              ),
            ),
          ),
        );
      }

      // Frame 1: first settled content compiles immediately and renders. A
      // fresh non-streaming document is selectable.
      await tester.pumpWidget(buildSelectiveHarness(firstContent));
      await tester.pump();
      expect(skeletonFinder, findsNothing);
      expect(
        find.textContaining('Settled answer paragraph', findRichText: true),
        findsOneWidget,
      );
      expect(find.byType(SelectionArea), findsOneWidget);

      // Frame 2: content grows while still non-streaming; the grown content's
      // compile is delayed. The previously-rendered body must stay visible, but
      // the stale document must NOT be wrapped in SelectionArea (that would
      // re-enable the concurrent-modification crash during ongoing updates).
      await tester.pumpWidget(buildSelectiveHarness(grownContent));
      await tester.pump();

      expect(skeletonFinder, findsNothing);
      expect(
        find.textContaining('Settled answer paragraph', findRichText: true),
        findsOneWidget,
      );
      expect(find.byType(SelectionArea), findsNothing);

      compiler.release();
      await tester.pump();
      await tester.pump();

      expect(skeletonFinder, findsNothing);
      expect(
        find.textContaining('Follow-up sentence', findRichText: true),
        findsOneWidget,
      );
      // Once the compile settles, the document becomes selectable again.
      expect(find.byType(SelectionArea), findsOneWidget);
    },
  );

  testWidgets(
    'clears stale content when the scope changes to a new message/version',
    (tester) async {
      // #540 follow-up: a scope change (new message/version) must NOT keep the
      // previous scope's rendered content on screen while the new body compiles;
      // the skeleton covers the gap instead (same-scope growth keeps content).
      const firstVersion = 'First version answer.';
      const secondVersion = 'Second version answer.';
      final compiler = _SelectiveDelayedMarkdownCompileService(
        delayedPreparedContent: prepareMarkdownContent(
          secondVersion,
          streaming: false,
        ),
      );
      addTearDown(compiler.dispose);
      final skeletonFinder = find.byType(MarkdownLoadingSkeleton);

      Widget buildScopedHarness(String content, String scope) {
        return ProviderScope(
          overrides: [
            markdownCompileServiceProvider.overrideWithValue(compiler),
          ],
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(
                child: StreamingMarkdownWidget(
                  content: content,
                  isStreaming: false,
                  stateScopeId: scope,
                ),
              ),
            ),
          ),
        );
      }

      await tester.pumpWidget(
        buildScopedHarness(firstVersion, 'msg|version:0'),
      );
      await tester.pump();
      expect(
        find.textContaining('First version', findRichText: true),
        findsOneWidget,
      );

      // Switch to a different version: scope + content change, compile delayed.
      await tester.pumpWidget(
        buildScopedHarness(secondVersion, 'msg|version:1'),
      );
      await tester.pump();
      expect(
        find.textContaining('First version', findRichText: true),
        findsNothing,
      );
      expect(skeletonFinder, findsOneWidget);

      compiler.release();
      await tester.pump();
      await tester.pump();
      expect(
        find.textContaining('Second version', findRichText: true),
        findsOneWidget,
      );
      expect(skeletonFinder, findsNothing);
    },
  );

  testWidgets(
    'clears stale content when the scope changes while streaming',
    (tester) async {
      // #541 follow-up: the scope-change clear must also run on the deferred
      // streaming path (e.g. switching from an old version back to the live,
      // streaming current). The previous scope's document must not flash under
      // the new scope while the streaming body compiles.
      const oldVersion = 'Old version body.';
      const liveResponse = 'Live streaming response.';
      final compiler = _DeferredStreamingCompileService(
        delayedPreparedContent: prepareMarkdownContent(
          liveResponse,
          streaming: true,
        ),
      );
      addTearDown(compiler.dispose);
      final skeletonFinder = find.byType(MarkdownLoadingSkeleton);

      Widget buildScopedHarness(
        String content,
        String scope,
        bool streaming,
      ) {
        return ProviderScope(
          overrides: [
            markdownCompileServiceProvider.overrideWithValue(compiler),
          ],
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(
                child: StreamingMarkdownWidget(
                  // Shared key: the second pump must reuse this State so the
                  // switch goes through didUpdateWidget's scope-change clear,
                  // not a remount (which would hide the old content for the
                  // wrong reason).
                  key: const ValueKey('streaming-markdown-under-test'),
                  content: content,
                  isStreaming: streaming,
                  stateScopeId: scope,
                ),
              ),
            ),
          ),
        );
      }

      await tester.pumpWidget(
        buildScopedHarness(oldVersion, 'msg|version:0', false),
      );
      await tester.pump();
      expect(
        find.textContaining('Old version', findRichText: true),
        findsOneWidget,
      );

      // Switch to the live, still-streaming current version: scope + content
      // change with the new body needing an async compile.
      await tester.pumpWidget(
        buildScopedHarness(liveResponse, 'msg|current', true),
      );
      // The very first frame after the switch — before the scheduled streaming
      // refresh runs — must already be clear of the old scope. A deferred clear
      // would let the old document paint for this one frame under the new scope,
      // which is exactly the flash this guards against (#541).
      expect(
        find.textContaining('Old version', findRichText: true),
        findsNothing,
      );
      // Streaming never shows the skeleton; the gap is blank until the compile
      // settles.
      expect(skeletonFinder, findsNothing);

      // Let the scheduled streaming refresh frame fire and the async prepare
      // resolve; the old scope must stay gone throughout.
      await tester.pump();
      await tester.pump();
      expect(
        find.textContaining('Old version', findRichText: true),
        findsNothing,
      );
      expect(skeletonFinder, findsNothing);
      // The compile is still blocked, so the new body must NOT have appeared
      // yet — this proves the gap is a genuine async wait, not a synchronous
      // swap that would mask whether the clear happened at the right time.
      expect(
        find.textContaining('Live streaming response', findRichText: true),
        findsNothing,
      );

      compiler.release();
      await tester.pump();
      await tester.pump();
      expect(
        find.textContaining('Live streaming response', findRichText: true),
        findsOneWidget,
      );
    },
  );

  testWidgets('defers tool call embeds until the details view opens', (
    tester,
  ) async {
    const content = '''
<details type="tool_calls" done="true" name="browser" embeds="[&quot;https://example.com/embed&quot;]">
<summary>Tool Executed</summary>
</details>
''';

    await tester.pumpWidget(buildHarness(content));

    expect(find.text('View Result from browser'), findsOneWidget);
    expect(find.byKey(const ValueKey('tool-call-embed-0')), findsNothing);
    expect(find.text('Input'), findsNothing);
    expect(find.text('Output'), findsNothing);

    await tester.tap(find.text('View Result from browser'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('tool-call-embed-0')), findsOneWidget);
  });

  testWidgets('does not surface raw html text for tool call embeds', (
    tester,
  ) async {
    const content = '''
<details type="tool_calls" done="true" name="browser" embeds="[&quot;&lt;div&gt;hello&lt;/div&gt;&quot;]">
<summary>Tool Executed</summary>
</details>
''';

    await tester.pumpWidget(buildHarness(content));

    expect(find.byKey(const ValueKey('tool-call-embed-0')), findsNothing);
    await tester.tap(find.text('View Result from browser'));
    await tester.pumpAndSettle();
    expect(find.textContaining('<div>hello</div>'), findsNothing);
    expect(find.text('Input'), findsNothing);
    expect(find.text('Output'), findsNothing);
    expect(find.byKey(const ValueKey('tool-call-embed-0')), findsOneWidget);
  });

  testWidgets(
    'keeps tool call embeds deferred while the message is streaming',
    (tester) async {
      const content = '''
<details type="tool_calls" done="true" name="browser" embeds="[&quot;https://example.com/embed&quot;]">
<summary>Tool Executed</summary>
</details>
''';

      await tester.pumpWidget(buildHarness(content, isStreaming: true));

      expect(find.text('View Result from browser'), findsOneWidget);
      expect(find.byKey(const ValueKey('tool-call-embed-0')), findsNothing);

      await tester.tap(find.text('View Result from browser'));
      await tester.pumpAndSettle();

      expect(
        find.text('Preview will be available after streaming completes.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('tool-call-embed-0')), findsNothing);
    },
  );

  testWidgets(
    'renders previewable html code blocks only in the preview sheet',
    (tester) async {
      const content = '''
```html
<!DOCTYPE html>
<html>
  <body>
    <h1>Hello preview</h1>
  </body>
</html>
```
''';

      await tester.pumpWidget(buildHarness(content));

      expect(find.text('Preview'), findsOneWidget);
      expect(find.text('html'), findsAtLeastNWidgets(1));
      expect(find.text('HTML Preview'), findsNothing);
      expect(
        find.text('Embedded content preview is unavailable in widget tests.'),
        findsNothing,
      );

      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();

      expect(find.text('HTML Preview'), findsOneWidget);
      expect(
        find.text('Embedded content preview is unavailable in widget tests.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'renders oversized svg previews inline without the deferred open-preview card',
    (tester) async {
      final circles = List<String>.generate(
        1800,
        (index) => '<circle cx="${index % 100}" cy="${index % 100}" r="2" />',
      ).join('\n');
      final content =
          '''
```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
$circles
</svg>
```
''';

      await tester.pumpWidget(buildHarness(content));

      expect(find.text('SVG Preview'), findsNothing);
      expect(
        find.text('Embedded content preview is unavailable in widget tests.'),
        findsOneWidget,
      );
      expect(find.text('Open preview'), findsNothing);
      expect(find.text('Preview deferred for large content.'), findsNothing);
    },
  );

  testWidgets('renders reasoning details inline with localized summary text', (
    tester,
  ) async {
    const content = '''
<details type="reasoning" done="true" duration="5">
<summary>Thinking…</summary>
Reasoning body
</details>
''';

    await tester.pumpWidget(buildHarness(content));

    expect(find.text('Thought for 5 seconds'), findsOneWidget);
    expect(find.text('Reasoning body'), findsNothing);

    await tester.tap(find.text('Thought for 5 seconds'));
    await tester.pumpAndSettle();

    expect(find.text('Reasoning body'), findsOneWidget);
  });

  testWidgets(
    'shows completed reasoning with separate header and body surfaces',
    (tester) async {
      const content = '''
<details type="reasoning" done="true" duration="5">
<summary>Thinking…</summary>
Reasoning body
</details>
''';

      await tester.pumpWidget(buildHarness(content));
      await tester.tap(find.text('Thought for 5 seconds'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('reasoning-details-sheet-header')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('reasoning-details-sheet-body')),
        findsOneWidget,
      );
      expect(find.byType(ConduitModalSheetSurface), findsNothing);
      expect(find.text('Reasoning body'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey<String>('reasoning-details-sheet-body'),
          ),
          matching: find.text('Reasoning body'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'renders text that trails a closing details tag on the same line',
    (tester) async {
      const content = '''
<details type="reasoning" done="true" duration="5">
<summary>Thinking…</summary>
Reasoning body
</details>Visible response
''';

      await tester.pumpWidget(buildHarness(content));

      expect(find.text('Thought for 5 seconds'), findsOneWidget);
      expect(find.text('Visible response'), findsOneWidget);
    },
  );

  testWidgets(
    'keeps reasoning inline while streaming and moves it to the modal when done',
    (tester) async {
      var content = '''
<details type="reasoning" done="false">
<summary>Thinking…</summary>
First step
</details>
''';
      late void Function(VoidCallback fn) rebuild;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return SingleChildScrollView(
                    child: StreamingMarkdownWidget(
                      content: content,
                      isStreaming: true,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );

      expect(find.text('First step'), findsNothing);

      await tester.tap(find.textContaining('Thinking'));
      await tester.pumpAndSettle();

      expect(find.text('First step'), findsOneWidget);
      expect(find.byType(DraggableScrollableSheet), findsNothing);

      rebuild(() {
        content = '''
<details type="reasoning" done="false">
<summary>Thinking…</summary>
First step
Second step
</details>
''';
      });
      await tester.pumpAndSettle();

      expect(find.text('Second step'), findsOneWidget);
      expect(find.byType(DraggableScrollableSheet), findsNothing);

      rebuild(() {
        content = '''
<details type="reasoning" done="true" duration="5">
<summary>Thinking…</summary>
First step
Second step
</details>
''';
      });
      await tester.pumpAndSettle();

      expect(find.text('Thought for 5 seconds'), findsOneWidget);
      expect(find.text('Second step'), findsNothing);

      await tester.tap(find.text('Thought for 5 seconds'));
      await tester.pumpAndSettle();

      expect(find.byType(DraggableScrollableSheet), findsOneWidget);
      expect(find.text('Second step'), findsOneWidget);
    },
  );

  testWidgets(
    'restores expanded inline reasoning after the markdown subtree remounts',
    (tester) async {
      final bucket = PageStorageBucket();
      var content = '''
<details type="reasoning" done="false">
<summary>Thinking…</summary>
First step
</details>
''';
      var revision = 0;
      late void Function(VoidCallback fn) rebuild;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return PageStorage(
                    bucket: bucket,
                    child: KeyedSubtree(
                      key: ValueKey(revision),
                      child: SingleChildScrollView(
                        child: StreamingMarkdownWidget(
                          content: content,
                          isStreaming: true,
                          stateScopeId: 'message-1',
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.textContaining('Thinking'));
      await tester.pumpAndSettle();

      expect(find.text('First step'), findsOneWidget);

      rebuild(() {
        revision += 1;
        content = '''
<details type="reasoning" done="false">
<summary>Thinking…</summary>
First step
Second step
</details>
''';
      });
      await tester.pumpAndSettle();

      expect(find.text('First step'), findsOneWidget);
      expect(find.text('Second step'), findsOneWidget);
      expect(find.byType(DraggableScrollableSheet), findsNothing);
    },
  );

  testWidgets(
    'keeps inline reasoning state isolated across version-specific scopes',
    (tester) async {
      final bucket = PageStorageBucket();
      const content = '''
<details type="reasoning" done="false">
<summary>Thinking…</summary>
Shared reasoning
</details>
''';
      var stateScopeId = 'message-1|version:v1';
      late void Function(VoidCallback fn) rebuild;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return PageStorage(
                    bucket: bucket,
                    child: SingleChildScrollView(
                      child: StreamingMarkdownWidget(
                        content: content,
                        isStreaming: true,
                        stateScopeId: stateScopeId,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.textContaining('Thinking'));
      await tester.pumpAndSettle();

      expect(find.text('Shared reasoning'), findsOneWidget);

      rebuild(() {
        stateScopeId = 'message-1|version:v2';
      });
      await tester.pumpAndSettle();

      expect(find.text('Shared reasoning'), findsNothing);

      rebuild(() {
        stateScopeId = 'message-1|version:v1';
      });
      await tester.pumpAndSettle();

      expect(find.text('Shared reasoning'), findsOneWidget);
    },
  );

  testWidgets(
    'assistant message keeps reasoning expansion isolated per version',
    (tester) async {
      final timestamp = DateTime(2026);
      final message = ChatMessage(
        id: 'message-1',
        role: 'assistant',
        content: '''
<details type="reasoning" done="false">
<summary>Thinking…</summary>
Current reasoning
</details>
''',
        timestamp: timestamp,
        versions: [
          ChatMessageVersion(
            id: 'version-1',
            content: '''
<details type="reasoning" done="false">
<summary>Thinking…</summary>
Version reasoning
</details>
''',
            timestamp: timestamp,
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            textToSpeechControllerProvider.overrideWith(
              _TestTextToSpeechController.new,
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: AssistantMessageWidget(
                message: message,
                isStreaming: false,
                showFollowUps: false,
                onDelete: () {},
              ),
            ),
          ),
        ),
      );

      Future<void> tapVersionControl({
        required IconData visibleIcon,
        required String overflowLabel,
      }) async {
        final visibleFinder = find.byIcon(visibleIcon);
        if (visibleFinder.evaluate().isNotEmpty) {
          await tester.tap(visibleFinder);
          await tester.pumpAndSettle();
          return;
        }

        await tester.tap(find.byIcon(Icons.more_horiz_rounded));
        await tester.pumpAndSettle();
        await tester.tap(find.text(overflowLabel));
        await tester.pumpAndSettle();
      }

      await tester.tap(find.textContaining('Thinking'));
      await tester.pumpAndSettle();

      expect(find.text('Current reasoning'), findsOneWidget);

      await tapVersionControl(
        visibleIcon: Icons.chevron_left,
        overflowLabel: 'Prev',
      );

      expect(find.text('Current reasoning'), findsNothing);
      expect(find.text('Version reasoning'), findsNothing);

      await tester.tap(find.textContaining('Thinking'));
      await tester.pumpAndSettle();

      expect(find.text('Version reasoning'), findsOneWidget);

      await tapVersionControl(
        visibleIcon: Icons.chevron_right,
        overflowLabel: 'Next',
      );

      expect(find.text('Version reasoning'), findsNothing);
      expect(find.text('Current reasoning'), findsOneWidget);
    },
  );

  testWidgets(
    'allows duplicate inline reasoning summaries to expand independently',
    (tester) async {
      const content = '''
<details type="reasoning" done="false">
<summary>Thinking…</summary>
First reasoning block
</details>

<details type="reasoning" done="false">
<summary>Thinking…</summary>
Second reasoning block
</details>
''';

      await tester.pumpWidget(
        buildHarness(
          content,
          isStreaming: true,
          stateScopeId: 'message-1|current',
        ),
      );

      final headers = find.textContaining('Thinking');
      expect(headers, findsNWidgets(2));

      await tester.tap(headers.first);
      await tester.pumpAndSettle();

      expect(find.text('First reasoning block'), findsOneWidget);
      expect(find.text('Second reasoning block'), findsNothing);

      await tester.tap(headers.last);
      await tester.pumpAndSettle();

      expect(find.text('First reasoning block'), findsOneWidget);
      expect(find.text('Second reasoning block'), findsOneWidget);
    },
  );

  testWidgets(
    'renders generic details bodies through the shared markdown pipeline',
    (tester) async {
      const content = '''
Start

<details>
<summary>More</summary>
Expanded content
</details>
''';

      await tester.pumpWidget(buildHarness(content));

      expect(find.text('More'), findsOneWidget);
      expect(find.text('Expanded content'), findsNothing);

      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();

      expect(find.text('Expanded content'), findsOneWidget);
    },
  );
}

TextSpan? _findTextSpan(InlineSpan span, String text) {
  if (span is! TextSpan) return null;
  if (span.text == text) return span;

  final children = span.children;
  if (children == null) return null;
  for (final child in children) {
    final match = _findTextSpan(child, text);
    if (match != null) return match;
  }
  return null;
}
