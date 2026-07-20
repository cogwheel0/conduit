import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/markdown/renderer/block_renderer.dart';
import 'package:conduit/shared/widgets/markdown/renderer/conduit_markdown_widget.dart';
import 'package:conduit/shared/widgets/web_content_embed.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildHarness(
    String data, {
    MarkdownHeavyBlockPolicy heavyBlockPolicy = MarkdownHeavyBlockPolicy.eager,
  }) {
    return ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ConduitMarkdownWidget(
              data: data,
              heavyBlockPolicy: heavyBlockPolicy,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('inline SVG preview waits for eager heavy-block policy', (
    tester,
  ) async {
    const content = '```svg\n<svg><circle cx="5" cy="5" r="4" /></svg>\n```';

    await tester.pumpWidget(
      buildHarness(content, heavyBlockPolicy: MarkdownHeavyBlockPolicy.defer),
    );
    await tester.pumpAndSettle();
    expect(find.byType(WebContentEmbed), findsNothing);
    expect(find.textContaining('<svg>', findRichText: true), findsOneWidget);

    await tester.pumpWidget(buildHarness(content));
    await tester.pumpAndSettle();
    expect(find.byType(WebContentEmbed), findsNothing);
    expect(find.text('Load SVG preview'), findsOneWidget);

    await tester.tap(find.text('Load SVG preview'));
    await tester.pumpAndSettle();
    expect(find.byType(WebContentEmbed), findsOneWidget);
  });

  testWidgets('changed inline SVG requires a new explicit activation', (
    tester,
  ) async {
    const first = '```svg\n<svg><circle r="4" /></svg>\n```';
    const second = '```svg\n<svg><rect width="8" height="8" /></svg>\n```';

    await tester.pumpWidget(buildHarness(first));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Load SVG preview'));
    await tester.pumpAndSettle();
    expect(find.byType(WebContentEmbed), findsOneWidget);

    await tester.pumpWidget(buildHarness(second));
    await tester.pumpAndSettle();
    expect(find.byType(WebContentEmbed), findsNothing);
    expect(find.text('Load SVG preview'), findsOneWidget);
  });

  testWidgets('large JSON code blocks stay collapsed until expanded', (
    tester,
  ) async {
    final lines = <String>['{'];
    for (var index = 0; index < 68; index++) {
      lines.add('  "key$index": $index,');
    }
    lines.add('  "tail": true');
    lines.add('}');

    final content = ['```json', ...lines, '```'].join('\n');

    await tester.pumpWidget(buildHarness(content));
    await tester.pumpAndSettle();

    expect(find.textContaining('Show '), findsOneWidget);
    expect(find.textContaining('"key0"', findRichText: true), findsOneWidget);
    expect(find.textContaining('"key60"', findRichText: true), findsNothing);

    await tester.tap(find.textContaining('Show '));
    await tester.pumpAndSettle();

    expect(find.text('Show less'), findsOneWidget);
    expect(find.textContaining('"key60"', findRichText: true), findsOneWidget);
  });

  testWidgets('highlighted code text respects system text scaling', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2.5)),
            child: const Scaffold(
              body: SingleChildScrollView(
                child: ConduitMarkdownWidget(
                  data: '```dart\nfinal x = 1;\n```',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scaledCodeRichText = tester
        .widgetList<RichText>(find.byType(RichText))
        .where((widget) => widget.text.toPlainText().contains('final x = 1;'));

    expect(scaledCodeRichText, isNotEmpty);
    expect(scaledCodeRichText.first.textScaler.scale(10), 25);
  });
}
