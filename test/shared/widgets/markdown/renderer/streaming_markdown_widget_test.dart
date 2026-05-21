import 'dart:async';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/compiled_markdown_document.dart';
import 'package:conduit/shared/widgets/markdown/markdown_config.dart';
import 'package:conduit/shared/widgets/markdown/markdown_compile_service.dart';
import 'package:conduit/shared/widgets/markdown/markdown_loading_skeleton.dart';
import 'package:conduit/shared/widgets/markdown/streaming_markdown_widget.dart';
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
              debugRenderInterval: debugRenderInterval,
              debugOnCompiledViewMounted: onCompiledViewMounted,
              debugOnCompiledViewDisposed: onCompiledViewDisposed,
              debugOnStreamingRefreshFrame: onStreamingRefreshFrame,
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
      expect(chipText.style?.fontSize, 10);
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

      expect(find.text('SVG Preview'), findsOneWidget);
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
