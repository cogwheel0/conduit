@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/widgets/markdown_view.dart';
import 'package:jaspr_test/jaspr_test.dart';

/// Reasoning and tool calls arrive inside the message as `<details>` markup,
/// in exactly the shapes below: the first is what Open WebUI
/// writes for a reasoning model, the second what it writes for a tool call,
/// attributes escaped and the arguments a JSON string holding JSON.
void main() {
  const reasoning =
      '<details type="reasoning" done="true" duration="3">\n'
      '<summary>Thought for 3 seconds</summary>\n'
      '&gt; The user wants a greeting.\n'
      '</details>\n'
      'Hello there.';

  const toolCall =
      '<details type="tool_calls" done="true" id="call_1" '
      'name="web_search" '
      'arguments="&quot;{\\&quot;query\\&quot;: \\&quot;dart\\&quot;}&quot;" '
      'result="&quot;Dart is a language&quot;">\n'
      '<summary>Tool Executed</summary>\n'
      '</details>\n'
      'Dart is a language.';

  testComponents('a reasoning block is a disclosure, not markup', (
    tester,
  ) async {
    tester.pumpComponent(const MarkdownView(reasoning));
    expect(find.tag('details'), findsOneComponent);
    expect(
      find.text(t.app.thoughtForDuration(duration: '3 seconds')),
      findsOneComponent,
    );
    // The thought is a quote inside the block, and the answer is outside it.
    expect(find.tag('blockquote'), findsOneComponent);
    expect(find.text('The user wants a greeting.'), findsOneComponent);
    expect(find.text('Hello there.'), findsOneComponent);
    expect(find.textContaining('<details'), findsNothing);
  });

  testComponents('an unfinished reasoning block says it is thinking', (
    tester,
  ) async {
    tester.pumpComponent(
      const MarkdownView(
        '<details type="reasoning" done="false">\n'
        '<summary>Thinking…</summary>\n'
        '&gt; Hmm\n'
        '</details>',
      ),
    );
    expect(find.text(t.app.thinking), findsOneComponent);
  });

  testComponents('a finished block with no timing does not invent one', (
    tester,
  ) async {
    tester.pumpComponent(
      const MarkdownView(
        '<details type="reasoning" done="true">\n'
        '<summary>Thinking…</summary>\n'
        '&gt; Hmm\n'
        '</details>',
      ),
    );
    expect(find.text(t.app.thoughts), findsOneComponent);
  });

  testComponents('a tool call names the tool and shows input and output', (
    tester,
  ) async {
    tester.pumpComponent(const MarkdownView(toolCall));
    expect(
      find.text(t.desktop.desktopToolUsed(name: 'web_search')),
      findsOneComponent,
    );
    // Decoded twice over, and indented for reading.
    expect(find.text('{\n  "query": "dart"\n}'), findsOneComponent);
    expect(find.text('Dart is a language'), findsOneComponent);
    expect(find.text('Dart is a language.'), findsOneComponent);
  });

  testComponents('a running tool call says so', (tester) async {
    tester.pumpComponent(
      const MarkdownView(
        '<details type="tool_calls" done="false" name="web_search">\n'
        '<summary>Executing...</summary>\n'
        '</details>',
      ),
    );
    expect(
      find.text(t.desktop.desktopToolRunning(name: 'web_search')),
      findsOneComponent,
    );
  });

  testComponents('a tool result is text, never markup', (tester) async {
    tester.pumpComponent(
      const MarkdownView(
        '<details type="tool_calls" done="true" name="fetch" '
        'result="&lt;script&gt;alert(1)&lt;/script&gt;">\n'
        '<summary>Tool Executed</summary>\n'
        '</details>',
      ),
    );
    expect(find.tag('script'), findsNothing);
    expect(find.text('<script>alert(1)</script>'), findsOneComponent);
  });

  testComponents('markup inside a reasoning body stays text', (tester) async {
    tester.pumpComponent(
      const MarkdownView(
        '<details type="reasoning" done="true" duration="1">\n'
        '<summary>Thought for 1 second</summary>\n'
        '&gt; &lt;img src=x onerror=alert(1)&gt;\n'
        '</details>',
      ),
    );
    expect(find.tag('img'), findsNothing);
  });
}
