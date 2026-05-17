import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/chat/widgets/assistant_detail_header.dart';
import 'package:conduit/features/chat/widgets/streaming_status_widget.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildHarness(
    List<ChatStatusUpdate> updates, {
    bool isStreaming = true,
  }) {
    return MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      home: Scaffold(
        body: Center(
          child: StreamingStatusWidget(
            updates: updates,
            isStreaming: isStreaming,
          ),
        ),
      ),
    );
  }

  testWidgets('bottom sheet reuses header styling and renders a shared rail', (
    tester,
  ) async {
    const completedDescription =
        'Generating a long search query that should wrap in the bottom sheet '
        'instead of being trimmed away';
    const currentDescription =
        'Searching the web for multiple sources and keeping the full status '
        'visible in the bottom sheet';
    final updates = [
      const ChatStatusUpdate(description: completedDescription, done: true),
      const ChatStatusUpdate(description: currentDescription, done: false),
    ];

    await tester.pumpWidget(buildHarness(updates));
    await tester.tap(find.text(currentDescription));
    await tester.pumpAndSettle();

    expect(find.byType(AssistantDetailHeader), findsNWidgets(3));
    expect(
      find.byKey(const ValueKey<String>('status-timeline-rail-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('status-timeline-rail-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('status-timeline-mask-top-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('status-timeline-mask-bottom-1')),
      findsOneWidget,
    );

    expect(
      tester
          .getSize(find.byKey(const ValueKey<String>('status-timeline-rail-0')))
          .height,
      greaterThan(0),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey<String>('status-timeline-rail-1')))
          .height,
      greaterThan(0),
    );

    final expectedRailColor = AppTheme.light(
      TweakcnThemes.t3Chat,
    ).extension<ConduitThemeExtension>()!.textSecondary.withValues(alpha: 0.6);
    final rail = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('status-timeline-rail-0')),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(rail.color, expectedRailColor);

    final historyText = tester.widget<Text>(find.text(completedDescription));
    expect(historyText.overflow, isNull);
    expect(historyText.maxLines, isNull);

    final bottomSheetTitle = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.data == currentDescription &&
            widget.style?.fontWeight == FontWeight.w600,
      ),
    );
    expect(bottomSheetTitle.overflow, isNull);
    expect(bottomSheetTitle.maxLines, isNull);
  });

  testWidgets('hides incomplete status rows once streaming has finished', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildHarness(const [
        ChatStatusUpdate(description: 'Searching...', done: false),
      ], isStreaming: false),
    );

    expect(find.text('Searching...'), findsNothing);
    expect(find.byType(StreamingStatusWidget), findsOneWidget);
  });

  testWidgets('keeps completed status rows visible after streaming finishes', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildHarness(const [
        ChatStatusUpdate(description: 'Search complete', done: true),
        ChatStatusUpdate(description: 'Searching...', done: false),
      ], isStreaming: false),
    );

    expect(find.text('Search complete'), findsOneWidget);
    expect(find.text('Searching...'), findsNothing);
  });

  testWidgets(
    'keeps status rows with unspecified done visible after streaming finishes',
    (tester) async {
      await tester.pumpWidget(
        buildHarness(const [
          ChatStatusUpdate(description: 'Generating image...'),
        ], isStreaming: false),
      );

      expect(find.text('Generating image...'), findsOneWidget);
    },
  );
}
