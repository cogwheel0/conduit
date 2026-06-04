import 'package:conduit/shared/widgets/markdown/renderer/conduit_markdown_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildHarness(String data) {
    return ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ConduitMarkdownWidget(data: data),
          ),
        ),
      ),
    );
  }

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
