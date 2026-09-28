@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/widgets/markdown_view.dart';
import 'package:conduit_desktop_ui/src/widgets/sources_list.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_test/jaspr_test.dart';

/// `[1]` in an answer that has sources. The shapes are Open
/// WebUI's; the live test found `[1]` sitting in a reply as raw text.
void main() {
  const sources = <ChatSourceDto>[
    ChatSourceDto(label: 'Dart overview', url: 'https://www.dart.dev/overview'),
    ChatSourceDto(label: 'notes.txt'),
  ];

  testComponents('a citation becomes a chip naming its source', (tester) async {
    tester.pumpComponent(
      const MarkdownView('Dart compiles to JS [1].', sources: sources),
    );
    expect(find.text('dart.dev'), findsOneComponent);
    expect(find.textContaining('[1]'), findsNothing);
    // A link out, opened in the real browser.
    expect(find.tag('a'), findsOneComponent);
  });

  testComponents('several at once name the first and count the rest', (
    tester,
  ) async {
    tester.pumpComponent(
      const MarkdownView('Both say so [1][2].', sources: sources),
    );
    expect(find.text('dart.dev +1'), findsOneComponent);
  });

  testComponents('a file source is named, not linked', (tester) async {
    tester.pumpComponent(
      const MarkdownView('From the file [2].', sources: sources),
    );
    expect(find.text('notes.txt'), findsOneComponent);
    expect(find.tag('a'), findsNothing);
  });

  testComponents('a number past the list stays text', (tester) async {
    tester.pumpComponent(const MarkdownView('Nowhere [7].', sources: sources));
    expect(find.textContaining('[7]'), findsOneComponent);
  });

  testComponents('without sources, brackets are just text', (tester) async {
    tester.pumpComponent(const MarkdownView('Step [1] then [2].'));
    expect(find.textContaining('[1]'), findsOneComponent);
  });

  testComponents('a numbered link stays a link', (tester) async {
    tester.pumpComponent(
      const MarkdownView('See [1](https://example.com).', sources: sources),
    );
    expect(find.text('1'), findsOneComponent);
    expect(find.text('dart.dev'), findsNothing);
  });

  testComponents('a source URL that is not web is never a link', (
    tester,
  ) async {
    tester.pumpComponent(
      const MarkdownView(
        'Careful [1].',
        sources: <ChatSourceDto>[
          ChatSourceDto(label: 'evil', url: 'javascript:alert(1)'),
        ],
      ),
    );
    expect(find.tag('a'), findsNothing);
  });

  testComponents('the list under an answer counts and numbers them', (
    tester,
  ) async {
    tester.pumpComponent(const SourcesList(sources));
    expect(
      find.text(t.desktop.desktopSourcesCount(count: 2)),
      findsOneComponent,
    );
    expect(find.tag('li'), findsNComponents(2));
    expect(find.text('Dart overview'), findsOneComponent);
  });
}
