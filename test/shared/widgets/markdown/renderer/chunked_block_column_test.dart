import 'package:checks/checks.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/markdown_compile_service.dart';
import 'package:conduit/shared/widgets/markdown/markdown_render_gate.dart';
import 'package:conduit/shared/widgets/markdown/renderer/chunked_block_column.dart';
import 'package:conduit/shared/widgets/markdown/renderer/conduit_markdown_widget.dart';
import 'package:conduit/shared/widgets/markdown/streaming_markdown_widget.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

String _manyParagraphs(int paragraphCount) {
  final buffer = StringBuffer();
  for (var index = 0; index < paragraphCount; index += 1) {
    buffer.writeln('Paragraph $index with some **bold** and `code` text.');
    buffer.writeln();
  }
  return buffer.toString();
}

Widget _harness(Widget child) {
  return ProviderScope(
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(width: 400, child: child),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('large settled documents inflate blocks across frames', (
    tester,
  ) async {
    final prepared = prepareMarkdownContent(
      _manyParagraphs(600),
      streaming: false,
    );
    final document = compilePreparedMarkdownSync(prepared);
    check(
      document.blocks.length,
    ).isGreaterThan(128); // over the chunk threshold

    await tester.pumpWidget(
      _harness(ConduitMarkdownWidget(compiledDocument: document)),
    );

    final chunkedFinder = find.byType(ChunkedBlockColumn);
    check(tester.any(chunkedFinder)).isTrue();

    // First frame reveals only the initial chunk.
    final initiallyVisible = find.textContaining(
      'Paragraph 0 ',
      findRichText: true,
    );
    check(tester.any(initiallyVisible)).isTrue();
    check(
      tester.any(find.textContaining('Paragraph 599', findRichText: true)),
    ).isFalse();

    // Subsequent frames stream in the rest; settle bounds the reveal loop.
    await tester.pumpAndSettle();
    check(
      tester.any(find.textContaining('Paragraph 599', findRichText: true)),
    ).isTrue();
  });

  testWidgets('small documents keep the single-frame column', (tester) async {
    final prepared = prepareMarkdownContent(
      _manyParagraphs(10),
      streaming: false,
    );
    final document = compilePreparedMarkdownSync(prepared);

    await tester.pumpWidget(
      _harness(ConduitMarkdownWidget(compiledDocument: document)),
    );

    check(tester.any(find.byType(ChunkedBlockColumn))).isFalse();
    check(
      tester.any(find.textContaining('Paragraph 9 ', findRichText: true)),
    ).isTrue();
  });

  testWidgets(
    'settled chat bodies chunk the display-part column',
    (tester) async {
      // The chat path splits a document into ONE display part per root block,
      // so per-part documents never cross ConduitMarkdownWidget's own block
      // threshold — the parts column itself must chunk (the 5.4s freeze).
      await tester.pumpWidget(
        _harness(
          StreamingMarkdownWidget(
            content: _manyParagraphs(600),
            isStreaming: false,
          ),
        ),
      );

      check(tester.any(find.byType(ChunkedBlockColumn))).isTrue();
      check(
        tester.any(find.textContaining('Paragraph 0 ', findRichText: true)),
      ).isTrue();
      check(
        tester.any(find.textContaining('Paragraph 599', findRichText: true)),
      ).isFalse();

      await tester.pumpAndSettle();
      check(
        tester.any(find.textContaining('Paragraph 599', findRichText: true)),
      ).isTrue();
    },
  );

  test('render gate tracks incomplete regions and notifies on edges', () {
    final gate = MarkdownRenderGate();
    var notifications = 0;
    gate.addListener(() => notifications += 1);

    check(gate.isComplete).isTrue();
    gate.markRegionIncomplete();
    check(gate.isComplete).isFalse();
    check(notifications).equals(1);

    // A second incomplete region does not re-notify (already incomplete).
    gate.markRegionIncomplete();
    check(notifications).equals(1);

    gate.markRegionComplete();
    check(gate.isComplete).isFalse();
    gate.markRegionComplete();
    check(gate.isComplete).isTrue();
    check(notifications).equals(2);
  });
}
