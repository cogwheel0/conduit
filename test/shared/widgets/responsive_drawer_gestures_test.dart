import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/shared/widgets/markdown/streaming_markdown_widget.dart';
import 'package:conduit/features/navigation/widgets/responsive_drawer_layout.dart';
import 'package:conduit/shared/widgets/horizontal_gesture_ownership.dart';

import 'responsive_drawer_layout_test_support.dart';

void main() {
  testWidgets('drag settle open emits no sidebar haptic', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    final calls = await drawerTestRecordPlatformCalls(() async {
      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestMobileSize,
          layoutKey: layoutKey,
        ),
      );

      await tester.dragFrom(const Offset(10, 200), const Offset(260, 0));
      await tester.pumpAndSettle();
    });

    expect(layoutKey.currentState!.isOpen, isTrue);
    expect(drawerTestSettleHapticCalls(calls), isEmpty);
  });

  testWidgets('non-scrollable content retains the wide drawer drag region', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      drawerTestBuildHarness(size: drawerTestMobileSize, layoutKey: layoutKey),
    );

    await tester.dragFrom(const Offset(190, 200), const Offset(180, 0));
    await tester.pumpAndSettle();

    expect(layoutKey.currentState!.isOpen, isTrue);
  });

  testWidgets('full-width drawer drag opens from the right half of content', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestMobileSize,
        layoutKey: layoutKey,
        edgeFraction: 1,
      ),
    );

    await tester.dragFrom(const Offset(300, 200), const Offset(80, 0));
    await tester.pumpAndSettle();

    expect(layoutKey.currentState!.isOpen, isTrue);
  });

  testWidgets('explicit gesture owner keeps ordinary full-width drags', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestMobileSize,
        layoutKey: layoutKey,
        edgeFraction: 1,
        child: const HorizontalGestureExclusion(
          child: ColoredBox(color: Colors.orange, child: SizedBox.expand()),
        ),
      ),
    );

    await tester.dragFrom(const Offset(300, 200), const Offset(80, 0));
    await tester.pumpAndSettle();

    expect(layoutKey.currentState!.isOpen, isFalse);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets(
      'completed markdown allows an immediate full-width drawer drag on ${platform.name}',
      (tester) async {
        await drawerTestWithTargetPlatform(platform, () async {
          final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

          await tester.pumpWidget(
            drawerTestBuildHarness(
              size: drawerTestMobileSize,
              layoutKey: layoutKey,
              edgeFraction: 1,
              child: const ProviderScope(
                child: Material(
                  child: Padding(
                    padding: EdgeInsets.only(top: 180),
                    child: StreamingMarkdownWidget(
                      content:
                          'Completed assistant text still leaves a quick '
                          'rightward swipe available to the navigation drawer.',
                      isStreaming: false,
                      debugTreatAsWidgetTest: true,
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final selectionArea = find.byType(SelectionArea);
          expect(selectionArea, findsOneWidget);
          final selectionRect = tester.getRect(selectionArea);
          final dragStart = Offset(300, selectionRect.center.dy);
          expect(selectionRect.contains(dragStart), isTrue);

          await tester.dragFrom(dragStart, const Offset(80, 0));
          await tester.pumpAndSettle();

          expect(layoutKey.currentState!.isOpen, isTrue);
        });
      },
    );
  }

  testWidgets('true screen edge retains drawer priority over exclusions', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestMobileSize,
        layoutKey: layoutKey,
        edgeFraction: 1,
        child: const HorizontalGestureExclusion(
          child: ColoredBox(color: Colors.orange, child: SizedBox.expand()),
        ),
      ),
    );

    await tester.dragFrom(const Offset(10, 200), const Offset(160, 0));
    await tester.pumpAndSettle();

    expect(layoutKey.currentState!.isOpen, isTrue);
  });

  testWidgets('full-width drawer recognizer is inert for an ordinary tap', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();
    var openStartCount = 0;

    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestMobileSize,
        layoutKey: layoutKey,
        edgeFraction: 1,
        onOpenStart: () => openStartCount++,
      ),
    );

    await tester.tapAt(const Offset(300, 200));
    await tester.pumpAndSettle();

    expect(openStartCount, 0);
    expect(layoutKey.currentState!.isOpen, isFalse);
  });

  testWidgets('a single physical move preserves the accepted drawer delta', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestMobileSize,
        layoutKey: layoutKey,
        edgeFraction: 1,
      ),
    );

    await tester.dragFrom(
      const Offset(300, 200),
      const Offset(80, 0),
      touchSlopX: 0,
      touchSlopY: 0,
    );
    await tester.pumpAndSettle();

    expect(layoutKey.currentState!.isOpen, isTrue);
  });

  testWidgets('non-opening drag directions leave full-width drawer inert', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();
    var openStartCount = 0;

    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestMobileSize,
        layoutKey: layoutKey,
        edgeFraction: 1,
        onOpenStart: () => openStartCount++,
      ),
    );

    await tester.dragFrom(const Offset(300, 200), const Offset(30, 140));
    await tester.pumpAndSettle();

    expect(layoutKey.currentState!.isOpen, isFalse);
    expect(openStartCount, 0);

    await tester.dragFrom(const Offset(300, 200), const Offset(-100, 0));
    await tester.pumpAndSettle();

    expect(layoutKey.currentState!.isOpen, isFalse);
    expect(openStartCount, 0);
  });

  testWidgets(
    'right-half horizontal scroll drag wins over full-width drawer drag',
    (tester) async {
      final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();
      final scrollController = ScrollController();

      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestMobileSize,
          layoutKey: layoutKey,
          edgeFraction: 1,
          child: drawerTestBuildHorizontalScrollableContent(
            controller: scrollController,
          ),
        ),
      );
      await tester.pump();

      await tester.dragFrom(const Offset(300, 200), const Offset(80, 0));
      await tester.pumpAndSettle();

      expect(scrollController.offset, 0);
      expect(layoutKey.currentState!.isOpen, isFalse);

      await tester.dragFrom(const Offset(300, 200), const Offset(-160, 0));
      await tester.pumpAndSettle();

      expect(scrollController.offset, greaterThan(0));
      expect(layoutKey.currentState!.isOpen, isFalse);
    },
  );

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets(
      'SelectionArea long-press drag wins over the drawer on ${platform.name}',
      (tester) async {
        await drawerTestWithTargetPlatform(platform, () async {
          final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();
          SelectedContent? selectedContent;

          await tester.pumpWidget(
            drawerTestBuildHarness(
              size: drawerTestMobileSize,
              layoutKey: layoutKey,
              edgeFraction: 1,
              child: Material(
                child: HorizontalGestureExclusion(
                  child: SelectionArea(
                    onSelectionChanged: (content) => selectedContent = content,
                    contextMenuBuilder: (_, _) => const SizedBox.shrink(),
                    magnifierConfiguration: TextMagnifierConfiguration.disabled,
                    child: const PrioritizedHorizontalGesture(
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Padding(
                          padding: EdgeInsets.only(top: 180),
                          child: Text(
                            key: ValueKey('selectable-copy'),
                            'Selection gestures keep direct control of this text '
                            'instead of opening the navigation drawer.',
                            softWrap: false,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          final textRect = tester.getRect(
            find.byKey(const ValueKey('selectable-copy')),
          );
          await drawerTestLongPressDrag(
            tester,
            Offset(300, textRect.center.dy),
            const Offset(70, 0),
          );

          expect(selectedContent?.plainText, isNotEmpty);
          expect(layoutKey.currentState!.isOpen, isFalse);
        });
      },
    );
  }

  testWidgets(
    'text-field long-press selection wins over full-width drawer drag',
    (tester) async {
      await drawerTestWithTargetPlatform(TargetPlatform.iOS, () async {
        final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();
        final textController = TextEditingController(
          text:
              'Editable text keeps cursor and selection gestures in the field',
        );
        addTearDown(textController.dispose);

        await tester.pumpWidget(
          drawerTestBuildHarness(
            size: drawerTestMobileSize,
            layoutKey: layoutKey,
            edgeFraction: 1,
            child: Material(
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 180),
                  child: TextField(
                    key: const ValueKey('editable-copy'),
                    controller: textController,
                    maxLines: 1,
                    contextMenuBuilder: (_, _) => const SizedBox.shrink(),
                    magnifierConfiguration: TextMagnifierConfiguration.disabled,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final fieldRect = tester.getRect(
          find.byKey(const ValueKey('editable-copy')),
        );
        await tester.dragFrom(
          Offset(300, fieldRect.center.dy),
          const Offset(70, 0),
        );
        await tester.pumpAndSettle();

        expect(layoutKey.currentState!.isOpen, isFalse);

        await drawerTestLongPressDrag(
          tester,
          Offset(300, fieldRect.center.dy),
          const Offset(70, 0),
        );

        expect(textController.selection.isCollapsed, isFalse);
        expect(layoutKey.currentState!.isOpen, isFalse);
      });
    },
  );

  testWidgets(
    'eager descendant gesture owner wins over full-width drawer drag',
    (tester) async {
      final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestMobileSize,
          layoutKey: layoutKey,
          edgeFraction: 1,
          child: HorizontalGestureExclusion(
            child: PrioritizedHorizontalGesture(
              child: drawerTestBuildEagerGestureOwner(),
            ),
          ),
        ),
      );

      await tester.dragFrom(const Offset(300, 200), const Offset(80, 0));
      await tester.pumpAndSettle();

      expect(layoutKey.currentState!.isOpen, isFalse);
    },
  );

  testWidgets(
    'horizontal scrollable away from the leading edge wins the edge drag',
    (tester) async {
      final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();
      final scrollController = ScrollController(initialScrollOffset: 120);

      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestMobileSize,
          layoutKey: layoutKey,
          child: drawerTestBuildHorizontalScrollableContent(
            controller: scrollController,
            key: const ValueKey('horizontal-scrollable'),
          ),
        ),
      );
      await tester.pump();

      await tester.dragFrom(const Offset(10, 200), const Offset(180, 0));
      await tester.pumpAndSettle();

      expect(layoutKey.currentState!.isOpen, isFalse);
      expect(scrollController.offset, lessThan(120));
    },
  );

  testWidgets(
    'horizontal scrollable at the leading edge wins drags away from the screen edge',
    (tester) async {
      final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();
      final scrollController = ScrollController();

      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestMobileSize,
          layoutKey: layoutKey,
          edgeFraction: 1,
          child: drawerTestBuildHorizontalScrollableContent(
            controller: scrollController,
          ),
        ),
      );
      await tester.pump();

      await tester.dragFrom(const Offset(21, 200), const Offset(-180, 0));
      await tester.pumpAndSettle();

      expect(layoutKey.currentState!.isOpen, isFalse);
      expect(scrollController.offset, greaterThan(0));
    },
  );

  testWidgets('wide markdown table keeps center-origin horizontal drags', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestMobileSize,
        layoutKey: layoutKey,
        child: const ProviderScope(
          child: Material(
            child: StreamingMarkdownWidget(
              content: drawerTestWideMarkdownTable,
              isStreaming: false,
              debugTreatAsWidgetTest: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = find.byType(DataTable);
    expect(table, findsOneWidget);
    final horizontalScrollable = find.ancestor(
      of: table,
      matching: find.byType(Scrollable),
    );
    expect(horizontalScrollable, findsOneWidget);
    final scrollableState = tester.state<ScrollableState>(horizontalScrollable);
    expect(scrollableState.position.maxScrollExtent, greaterThan(0));

    final tableRect = tester.getRect(table);
    await tester.dragFrom(
      Offset(190, tableRect.center.dy),
      const Offset(180, 0),
    );
    await tester.pumpAndSettle();

    expect(layoutKey.currentState!.isOpen, isFalse);

    final initialScrollOffset = scrollableState.position.pixels;
    await tester.dragFrom(
      Offset(190, tableRect.center.dy),
      const Offset(-180, 0),
    );
    await tester.pumpAndSettle();

    expect(scrollableState.position.pixels, greaterThan(initialScrollOffset));
    expect(layoutKey.currentState!.isOpen, isFalse);
  });

  testWidgets('wide markdown table keeps fresh drags from body-cell padding', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      drawerTestBuildHarness(
        size: drawerTestMobileSize,
        layoutKey: layoutKey,
        child: const ProviderScope(
          child: Material(
            child: StreamingMarkdownWidget(
              content: drawerTestWideMarkdownTable,
              isStreaming: false,
              debugTreatAsWidgetTest: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = find.byType(DataTable);
    expect(table, findsOneWidget);
    final horizontalScrollable = find.ancestor(
      of: table,
      matching: find.byType(Scrollable),
    );
    expect(horizontalScrollable, findsOneWidget);
    final scrollableState = tester.state<ScrollableState>(horizontalScrollable);
    expect(scrollableState.position.maxScrollExtent, greaterThan(0));

    // With one header and one body row, DataTable's vertical center is still
    // in the header's opaque InkWell. Exercise the non-interactive padding at
    // the bottom of a body cell instead, matching a fresh drag on table chrome.
    final tableRect = tester.getRect(table);
    final bodyCellPaddingPoint = Offset(190, tableRect.bottom - 8);
    expect(tableRect.contains(bodyCellPaddingPoint), isTrue);

    final textRects = find
        .descendant(of: table, matching: find.byType(Text))
        .evaluate()
        .map((element) {
          final renderBox = element.renderObject! as RenderBox;
          return renderBox.localToGlobal(Offset.zero) & renderBox.size;
        });
    expect(
      textRects.any((rect) => rect.contains(bodyCellPaddingPoint)),
      isFalse,
    );

    await tester.dragFrom(bodyCellPaddingPoint, const Offset(-180, 0));
    await tester.pumpAndSettle();

    final scrolledOffset = scrollableState.position.pixels;
    expect(scrolledOffset, greaterThan(0));
    expect(layoutKey.currentState!.isOpen, isFalse);

    await tester.dragFrom(bodyCellPaddingPoint, const Offset(180, 0));
    await tester.pumpAndSettle();

    expect(scrollableState.position.pixels, lessThan(scrolledOffset));
    expect(layoutKey.currentState!.isOpen, isFalse);
  });

  testWidgets(
    'horizontal scrollable at the leading edge can still open the drawer',
    (tester) async {
      final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();
      final scrollController = ScrollController();

      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestMobileSize,
          layoutKey: layoutKey,
          edgeFraction: 1,
          child: drawerTestBuildHorizontalScrollableContent(
            controller: scrollController,
          ),
        ),
      );
      await tester.pump();

      await tester.dragFrom(const Offset(10, 200), const Offset(260, 0));
      await tester.pumpAndSettle();

      expect(layoutKey.currentState!.isOpen, isTrue);
    },
  );
}
