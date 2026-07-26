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
                final endSpace = resolveChatAnchoredEndSpaceExtent(
                  availableExtent: _viewportHeight - _topInset,
                  contentExtentFromAnchor: 40 + liveHeight + _composerHeight,
                );
                return ScrollablePositionedList.builder(
                  reverse: true,
                  itemScrollController: controller,
                  itemCount: 10,
                  itemBuilder: (context, positionedIndex) {
                    if (positionedIndex == 0) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            key: const ValueKey('assistant-row'),
                            height: liveHeight,
                          ),
                          SizedBox(
                            key: const ValueKey('composer-spacer'),
                            height: _composerHeight + endSpace,
                          ),
                        ],
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
      controller.jumpTo(index: 1, alignment: 1 - (_topInset / _viewportHeight));
      await tester.pumpAndSettle();

      expect(pinnedTop(), closeTo(_topInset, 1));
      expect(tester.takeException(), isNull);
    },
  );
}
