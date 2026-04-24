import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/markdown_config.dart';
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
  }) {
    return MaterialApp(
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
          ),
        ),
      ),
    );
  }

  Widget buildAssistantHarness({
    required ProviderContainer container,
    required ChatMessage message,
    required bool isStreaming,
  }) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AssistantMessageWidget(
            message: message,
            isStreaming: isStreaming,
            showFollowUps: false,
          ),
        ),
      ),
    );
  }

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

  testWidgets('renders tool call embeds inline like upstream', (tester) async {
    const content = '''
<details type="tool_calls" done="true" name="browser" embeds="[&quot;https://example.com/embed&quot;]">
<summary>Tool Executed</summary>
</details>
''';

    await tester.pumpWidget(buildHarness(content));

    expect(find.text('browser'), findsOneWidget);
    expect(find.text('View Result from browser'), findsNothing);
    expect(find.byKey(const ValueKey('tool-call-embed-0')), findsOneWidget);
    expect(find.text('Input'), findsNothing);
    expect(find.text('Output'), findsNothing);
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

    expect(find.byKey(const ValueKey('tool-call-embed-0')), findsOneWidget);
    expect(find.textContaining('<div>hello</div>'), findsNothing);
    expect(find.text('Input'), findsNothing);
    expect(find.text('Output'), findsNothing);
  });

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
        MaterialApp(
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
        MaterialApp(
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
        MaterialApp(
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
