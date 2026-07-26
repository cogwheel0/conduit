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
    'pin target remains stable after the newest row exceeds the viewport',
    (tester) async {
      final controller = ItemScrollController();
      final positions = ItemPositionsListener.create();
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
                  itemPositionsListener: positions,
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

      // Once the assistant outgrows the synthetic spacer, reverse layout
      // growth must not push the pinned user row above the viewport.
      assistantHeight.value = 8000;
      await tester.pump();
      await tester.pumpAndSettle();

      expect(pinnedTop(), closeTo(_topInset, 1));
      expect(
        debugShouldExposeScrollToLatestForTesting(
          hasScrollableContent: debugHasScrollablePositionedContentForTesting(
            positions: positions.itemPositions.value,
            itemCount: 10,
            viewportExtent: _viewportHeight,
          ),
          pinAutoFollowing: true,
          userDetached: false,
          isAtLatest: debugIsAtLatestPositionForTesting(
            positions: positions.itemPositions.value,
            viewportExtent: _viewportHeight,
          ),
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('first pinned turn starts settled while measurements arrive', (
    tester,
  ) async {
    final controller = ItemScrollController();
    final pinnedUserExtent = ValueNotifier<double>(0);
    final assistantHeight = ValueNotifier<double>(20);
    final positionSettled = ValueNotifier<bool>(false);
    addTearDown(pinnedUserExtent.dispose);
    addTearDown(assistantHeight.dispose);
    addTearDown(positionSettled.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: _viewportHeight,
          child: ListenableBuilder(
            listenable: Listenable.merge([
              pinnedUserExtent,
              assistantHeight,
              positionSettled,
            ]),
            builder: (context, _) {
              final transcript = ScrollablePositionedList.builder(
                reverse: true,
                itemScrollController: controller,
                initialScrollIndex: 1,
                initialAlignment: 1 - (_topInset / _viewportHeight),
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
              );
              final isSettling = !positionSettled.value;
              return Opacity(
                key: const ValueKey('settling-transcript-visibility'),
                opacity: isSettling ? 0 : 1,
                child: isSettling
                    ? ExcludeSemantics(
                        key: const ValueKey(
                          'settling-transcript-semantics-guard',
                        ),
                        child: IgnorePointer(
                          key: const ValueKey(
                            'settling-transcript-interaction-guard',
                          ),
                          child: transcript,
                        ),
                      )
                    : transcript,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final finder = find.byKey(const ValueKey('settling-pinned-user-row'));
    expect(finder, findsOneWidget);
    expect(
      tester
          .widget<Opacity>(
            find.byKey(const ValueKey('settling-transcript-visibility')),
          )
          .opacity,
      0,
    );
    expect(
      tester
          .widget<IgnorePointer>(
            find.byKey(const ValueKey('settling-transcript-interaction-guard')),
          )
          .ignoring,
      isTrue,
    );
    expect(
      tester
          .widget<ExcludeSemantics>(
            find.byKey(const ValueKey('settling-transcript-semantics-guard')),
          )
          .excluding,
      isTrue,
    );

    // Measurements arrive while hidden. The page performs one item jump and
    // reveals only the already-settled transcript on the following frame.
    pinnedUserExtent.value = 40;
    await tester.pump();
    controller.jumpTo(index: 1, alignment: 1 - (_topInset / _viewportHeight));
    positionSettled.value = true;
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(finder).dy, closeTo(_topInset, 1));
    expect(
      tester
          .widget<Opacity>(
            find.byKey(const ValueKey('settling-transcript-visibility')),
          )
          .opacity,
      1,
    );
    expect(
      find.byKey(const ValueKey('settling-transcript-interaction-guard')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('settling-transcript-semantics-guard')),
      findsNothing,
    );

    assistantHeight.value = 120;

    var minimumPinnedTop = double.infinity;
    var frames = 0;
    while (tester.binding.hasScheduledFrame && frames < 240) {
      frames++;
      await tester.pump(const Duration(milliseconds: 16));
      final pinnedTop = tester.getTopLeft(finder).dy;
      if (pinnedTop < minimumPinnedTop) minimumPinnedTop = pinnedTop;
    }

    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(minimumPinnedTop, greaterThanOrEqualTo(_topInset - 2));
    expect(tester.getTopLeft(finder).dy, closeTo(_topInset, 1));
  });
}
