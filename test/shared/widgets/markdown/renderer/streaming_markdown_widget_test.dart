import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/markdown_config.dart';
import 'package:conduit/shared/widgets/markdown/streaming_markdown_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  Widget buildHarness(String content) {
    return MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: StreamingMarkdownWidget(content: content, isStreaming: false),
        ),
      ),
    );
  }

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

  testWidgets('renders previewable html code blocks with a live preview', (
    tester,
  ) async {
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

    expect(find.text('HTML Preview'), findsOneWidget);
    expect(
      find.text('Embedded content preview is unavailable in widget tests.'),
      findsOneWidget,
    );
    expect(find.text('Preview'), findsOneWidget);
    expect(find.text('html'), findsAtLeastNWidgets(1));

    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();

    expect(find.text('HTML Preview'), findsNWidgets(2));
    expect(
      find.text('Embedded content preview is unavailable in widget tests.'),
      findsNWidgets(2),
    );
  });

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
