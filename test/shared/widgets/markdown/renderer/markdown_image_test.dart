import 'package:conduit/shared/widgets/markdown/renderer/conduit_markdown_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const imageKey = ValueKey<String>('markdown-image');

  Widget buildHarness(String data) {
    return ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ConduitMarkdownWidget(
              data: data,
              imageBuilder: (_, _, _) =>
                  const SizedBox(key: imageKey, width: 24, height: 24),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renders image line followed by text as a block image', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildHarness(
        '![placeholder](https://example.com/image.png)\nFollow-up text',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(imageKey), findsOneWidget);
    expect(find.text('Follow-up text', findRichText: true), findsOneWidget);
    expect(
      find.textContaining('placeholder', findRichText: true),
      findsNothing,
    );
  });

  testWidgets('renders image line followed by a hard break as a block image', (
    tester,
  ) async {
    for (final content in <String>[
      '![placeholder](https://example.com/image.png)  \nFollow-up text',
      '![placeholder](https://example.com/image.png)\\\nFollow-up text',
    ]) {
      await tester.pumpWidget(buildHarness(content));
      await tester.pumpAndSettle();

      expect(find.byKey(imageKey), findsOneWidget);
      expect(find.text('Follow-up text', findRichText: true), findsOneWidget);
      expect(
        find.textContaining('placeholder', findRichText: true),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });

  testWidgets('keeps sentence-level inline image fallback unchanged', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildHarness('See ![placeholder](https://example.com/image.png) here.'),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(imageKey), findsNothing);
    expect(
      find.textContaining('See placeholder here.', findRichText: true),
      findsOneWidget,
    );
  });
}
