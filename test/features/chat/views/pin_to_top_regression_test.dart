import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

const double _viewportHeight = 600;
const double _topInset = 60;
const double _composerHeight = 80;

void main() {
  testWidgets('reversed positioned list keeps index zero as the newest row', (
    tester,
  ) async {
    final controller = ItemScrollController();
    final positions = ItemPositionsListener.create();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: _viewportHeight,
          child: ScrollablePositionedList.builder(
            reverse: true,
            itemScrollController: controller,
            itemPositionsListener: positions,
            itemCount: 60,
            itemBuilder: (context, positionedIndex) {
              final chronologicalIndex = 59 - positionedIndex;
              return SizedBox(
                key: ValueKey('message-$chronologicalIndex'),
                height: positionedIndex == 0 ? 140 : 44,
                child: Text('$chronologicalIndex'),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('message-59')), findsOneWidget);
    expect(
      positions.itemPositions.value.any((position) => position.index == 0),
      isTrue,
    );
    final latestPosition = positions.itemPositions.value.singleWhere(
      (position) => position.index == 0,
    );
    expect(latestPosition.itemLeadingEdge, closeTo(0, 0.002));

    controller.jumpTo(index: 1, alignment: 0.2);
    await tester.pumpAndSettle();
    final detachedPosition = positions.itemPositions.value.singleWhere(
      (position) => position.index == 0,
    );
    expect(detachedPosition.itemLeadingEdge, lessThan(0));
    expect(
      debugIsAtLatestPositionForTesting(
        positions: positions.itemPositions.value,
        viewportExtent: _viewportHeight,
      ),
      isFalse,
    );

    controller.jumpTo(index: 59);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('message-0')), findsOneWidget);
  });

  testWidgets(
    'pin target remains addressable while newest-row spacer contracts',
    (tester) async {
      final controller = ItemScrollController();
      final assistantHeight = ValueNotifier<double>(20);
      addTearDown(assistantHeight.dispose);

      Widget buildHarness() {
        return MaterialApp(
          home: SizedBox(
            height: _viewportHeight,
            child: ValueListenableBuilder<double>(
              valueListenable: assistantHeight,
              builder: (context, liveHeight, _) {
                return ScrollablePositionedList.builder(
                  reverse: true,
                  itemScrollController: controller,
                  itemCount: 10,
                  itemBuilder: (context, positionedIndex) {
                    if (positionedIndex == 0) {
                      return debugBuildNewestTimelineItemForTesting(
                        row: SizedBox(
                          key: const ValueKey('assistant-row'),
                          height: liveHeight,
                        ),
                        spacerKey: const ValueKey('composer-spacer'),
                        bottomPadding: _composerHeight,
                        pinActive: true,
                        availableExtent: _viewportHeight - _topInset,
                        pinnedUserExtent: 40,
                      );
                    }
                    if (positionedIndex == 1) {
                      return const SizedBox(
                        key: ValueKey('pinned-user-row'),
                        height: 40,
                      );
                    }
                    return const SizedBox(height: 100);
                  },
                );
              },
            ),
          ),
        );
      }

      await tester.pumpWidget(buildHarness());
      await tester.pumpAndSettle();
      controller.jumpTo(index: 1, alignment: 1 - (_topInset / _viewportHeight));
      await tester.pumpAndSettle();

      double pinnedTop() =>
          tester.getTopLeft(find.byKey(const ValueKey('pinned-user-row'))).dy;
      expect(pinnedTop(), closeTo(_topInset, 1));

      assistantHeight.value = 260;
      await tester.pump();
      await tester.pumpAndSettle();

      expect(pinnedTop(), closeTo(_topInset, 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pin animation never overshoots while initial spacer measurement settles',
    (tester) async {
      final controller = ItemScrollController();
      final pinnedUserExtent = ValueNotifier<double>(0);
      final assistantHeight = ValueNotifier<double>(20);
      addTearDown(pinnedUserExtent.dispose);
      addTearDown(assistantHeight.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            height: _viewportHeight,
            child: ListenableBuilder(
              listenable: Listenable.merge([pinnedUserExtent, assistantHeight]),
              builder: (context, _) => ScrollablePositionedList.builder(
                reverse: true,
                itemScrollController: controller,
                itemCount: 10,
                itemBuilder: (context, positionedIndex) {
                  if (positionedIndex == 0) {
                    return debugBuildNewestTimelineItemForTesting(
                      row: SizedBox(height: assistantHeight.value),
                      spacerKey: const ValueKey('settling-composer-spacer'),
                      bottomPadding: _composerHeight,
                      pinActive: true,
                      availableExtent: _viewportHeight - _topInset,
                      pinnedUserExtent: pinnedUserExtent.value,
                    );
                  }
                  if (positionedIndex == 1) {
                    return const SizedBox(
                      key: ValueKey('settling-pinned-user-row'),
                      height: 40,
                    );
                  }
                  return const SizedBox(height: 100);
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // The page waits for both measured rows, rebuilds the stable minimum
      // extent, and only then starts the one pin animation.
      pinnedUserExtent.value = 40;
      await tester.pump();

      final animation = controller.scrollTo(
        index: 1,
        alignment: 1 - (_topInset / _viewportHeight),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      await tester.pump(const Duration(milliseconds: 16));
      assistantHeight.value = 120;

      var minimumPinnedTop = double.infinity;
      var sampledPinnedRow = false;
      for (var frame = 0; frame < 16; frame += 1) {
        await tester.pump(const Duration(milliseconds: 16));
        final finder = find.byKey(const ValueKey('settling-pinned-user-row'));
        if (finder.evaluate().isNotEmpty) {
          sampledPinnedRow = true;
          final pinnedTop = tester.getTopLeft(finder).dy;
          if (pinnedTop < minimumPinnedTop) minimumPinnedTop = pinnedTop;
        }
      }
      await animation;
      await tester.pumpAndSettle();

      expect(sampledPinnedRow, isTrue);
      expect(minimumPinnedTop, greaterThanOrEqualTo(_topInset - 2));
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('settling-pinned-user-row')))
            .dy,
        closeTo(_topInset, 1),
      );
    },
  );
}
