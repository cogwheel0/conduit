import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/color_tokens.dart';
import 'package:conduit/shared/widgets/markdown/renderer/markdown_style.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/renderer/conduit_markdown_widget.dart';
import 'package:conduit/shared/widgets/markdown/renderer/markdown_table.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Widget harness(String content, {double scale = 1}) => ProviderScope(
    child: MaterialApp(
      theme: AppTheme.dark(TweakcnThemes.t3Chat),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(
            size: const Size(320, 800),
            textScaler: TextScaler.linear(scale),
          ),
          child: SingleChildScrollView(
            child: SizedBox(
              width: 320,
              child: ConduitMarkdownWidget(data: content),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('callouts show one title and preserve rich body text', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        '> [!NOTE]\n> Keep **important** text and `config.set` readable.',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Note', findRichText: true), findsOneWidget);
    expect(
      find.textContaining('important', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('config.set'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('table wraps and column resizing survives a stream update', (
    tester,
  ) async {
    const table =
        '| Format | Description |\n| --- | --- |\n| Code | A useful explanation with enough words to wrap onto several lines |';
    await tester.pumpWidget(harness(table));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownTableView), findsOneWidget);
    final before = tester.getSize(find.byType(Table)).width;
    final handle = find.byIcon(Icons.drag_indicator);
    await tester.drag(handle, const Offset(60, 0));
    await tester.pumpAndSettle();
    final resized = tester.getSize(find.byType(Table)).width;
    expect(resized, greaterThan(before));
    await tester.pumpWidget(harness('$table\n| Settings | Another row |'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(Table)).width, resized);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inline code scales once with the reading text', (tester) async {
    await tester.pumpWidget(harness('Use `config.set` here.'));
    await tester.pumpAndSettle();
    final normal = tester.getRect(find.text('config.set'));
    await tester.pumpWidget(harness('Use `config.set` here.', scale: 2));
    await tester.pumpAndSettle();
    final large = tester.getRect(find.text('config.set'));
    expect(large.width, closeTo(normal.width * 2, 1));
    expect(large.height, closeTo(normal.height * 2, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'emphasis uses distinct colors while links keep their link color',
    (tester) async {
      await tester.pumpWidget(
        harness(
          'Plain **bold** *italic* and [**linked**](https://example.com).',
        ),
      );
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(ConduitMarkdownWidget));
      final style = ConduitMarkdownStyle.fromTheme(context);
      final paragraph = tester
          .widgetList<RichText>(find.byType(RichText))
          .firstWhere((text) => text.text.toPlainText().contains('Plain bold'));
      TextSpan? spanFor(InlineSpan span, String text) {
        if (span is! TextSpan) return null;
        if (span.text == text) return span;
        for (final child in span.children ?? <InlineSpan>[]) {
          final found = spanFor(child, text);
          if (found != null) return found;
        }
        return null;
      }

      expect(spanFor(paragraph.text, 'bold')?.style?.color, style.strongColor);
      expect(
        spanFor(paragraph.text, 'italic')?.style?.color,
        style.emphasisColor,
      );
      expect(spanFor(paragraph.text, 'linked')?.style?.color, style.linkColor);
      expect(style.strongColor, isNot(style.body.color));
      expect(style.emphasisColor, isNot(style.body.color));
    },
  );

  testWidgets('plain quotes keep rich text in the quote reading style', (
    tester,
  ) async {
    await tester.pumpWidget(harness('> A **useful** quote.'));
    await tester.pumpAndSettle();
    final paragraph = tester
        .widgetList<RichText>(find.byType(RichText))
        .firstWhere((text) => text.text.toPlainText().contains('useful'));
    expect(paragraph.text.style?.fontStyle, FontStyle.italic);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rendered syntax colors stay readable as palettes change', (
    tester,
  ) async {
    const source = 'const label = "sample"; // A comment';
    for (final palette in TweakcnThemes.all) {
      for (final brightness in Brightness.values) {
        late Color background;
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: brightness == Brightness.dark
                  ? AppTheme.dark(palette)
                  : AppTheme.light(palette),
              localizationsDelegates: conduitLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Builder(
                  builder: (context) {
                    background = ConduitMarkdownStyle.fromTheme(context)
                        .codeBlockBackground;
                    return const SingleChildScrollView(
                      child: ConduitMarkdownWidget(data: '```js\n$source\n```'),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final rendered = tester
            .widgetList<RichText>(find.byType(RichText))
            .firstWhere((text) => text.text.toPlainText().trim() == source);
        void checkSpan(InlineSpan span, Color inherited) {
          final color = span.style?.color ?? inherited;
          if (span is TextSpan && (span.text?.trim().isNotEmpty ?? false)) {
            expect(
              contrastRatio(color, span.style?.backgroundColor ?? background),
              greaterThanOrEqualTo(4.5),
              reason: '${palette.id} $brightness ${span.text}',
            );
          }
          if (span is TextSpan) {
            for (final child in span.children ?? <InlineSpan>[]) {
              checkSpan(child, color);
            }
          }
        }

        checkSpan(rendered.text, rendered.text.style!.color!);
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('large text and long identifiers fit narrow chat content', (
    tester,
  ) async {
    const longPath =
        '/example/project/with/a/very/long/unbroken/identifier/settings.json';
    await tester.pumpWidget(
      harness(
        '## Clear heading\n\nUse `$longPath`.\n\n```json\n{"enabled": true}\n```\n\n| Format | Description |\n| --- | --- |\n| Code | A longer explanation that must wrap |\n\n> [!WARNING]\n> Keep the explanation readable.',
        scale: 2,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final copy = find.byTooltip('Copy');
    expect(copy, findsOneWidget);
    final size = tester.getSize(copy);
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  });
}
