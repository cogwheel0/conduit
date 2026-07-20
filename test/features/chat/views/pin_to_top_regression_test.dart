// Regression harness for the prompt-to-top anchor.
//
// Reproduces ChatPage's send-time anchoring flow with the same primitives: a
// CustomScrollView, a SuperSliverList holding history + the live turn, and the
// dynamically reserved end space folded into the list's composer-spacer item.
// It uses the real resolveChatPinStickTargetForTesting /
// resolveChatAnchoredEndSpaceExtent logic and a 220ms animateTo like
// _animatePinnedMessageToTop.
//
// It also mirrors the ScrollNotification predicates from ChatPage's
// NotificationListener to detect whether purely programmatic scrolling
// (jumpTo/animateTo/scroll corrections) would trip the "user gesture"
// cancellation path.

import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

const double kViewportHeight = 600;
const double kTopPadding = 60;
const double kHistoryRowHeight = 100;
const double kComposerSpacer = 80;

class PinHarness extends StatefulWidget {
  const PinHarness({super.key, required this.state});
  final PinHarnessState state;

  @override
  State<PinHarness> createState() => _PinHarnessWidgetState();
}

class PinHarnessState {
  final scrollController = ScrollController();
  final listController = ListController();
  final userRowKey = GlobalKey();

  int historyCount = 8;
  bool sent = false;
  double assistantHeight = 20;
  double userRowHeight = 40;

  bool isAutoFollowing = true;
  bool isPositionSettled = false;
  bool isUserInteracting = false;
  double endSpaceExtent = 0;

  // Records why/when the ChatPage predicates would have canceled auto-follow.
  final cancelEvents = <String>[];

  _PinHarnessWidgetState? _widgetState;

  int get anchorIndex => historyCount; // user row index after history
  int get managedItemCount =>
      historyCount + (sent ? 2 : 0) + 1; // + composer spacer

  void rebuild() => _widgetState?._rebuild();

  void dispose() {
    scrollController.dispose();
    listController.dispose();
  }
}

class _PinHarnessWidgetState extends State<PinHarness> {
  PinHarnessState get s => widget.state;

  void _rebuild() => setState(() {});

  @override
  void initState() {
    super.initState();
    s._widgetState = this;
  }

  void _syncStickTarget() {
    if (s.sent) {
      s.listController.stickTarget = resolveChatPinStickTargetForTesting(
        anchorIndex: s.anchorIndex,
        anchorAlignment: kTopPadding / kViewportHeight,
        isAutoFollowing: s.isAutoFollowing,
        isUserInteracting: s.isUserInteracting,
        isPositionSettled: s.isPositionSettled,
        anchoredEndSpaceExtent: s.endSpaceExtent,
      );
    } else {
      s.listController.stickTarget = const StickTarget.bottom();
    }
  }

  @override
  Widget build(BuildContext context) {
    _syncStickTarget();
    final itemCount = s.managedItemCount;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // Mirror of ChatPage's predicates (chat_page.dart ~2305-2353).
        final isTouchDragStart =
            notification is ScrollStartNotification &&
            notification.dragDetails != null;
        final isUserScrollUpdate =
            notification is ScrollUpdateNotification &&
            (notification.dragDetails != null || s.isUserInteracting);
        final isUserDirectionalScroll =
            notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle;
        final isUserScrollIdle =
            notification is UserScrollNotification &&
            notification.direction == ScrollDirection.idle;
        if (isTouchDragStart || isUserScrollUpdate || isUserDirectionalScroll) {
          if (!s.isUserInteracting) {
            if (s.isAutoFollowing && s.sent) {
              s.cancelEvents.add(
                'cancel-by-${notification.runtimeType} '
                'dragDetails=${notification is ScrollStartNotification
                    ? notification.dragDetails
                    : notification is ScrollUpdateNotification
                    ? notification.dragDetails
                    : null} '
                'direction=${notification is UserScrollNotification ? notification.direction : null}',
              );
              s.isAutoFollowing = false;
            }
          }
          s.isUserInteracting = true;
        }
        if (notification is ScrollEndNotification || isUserScrollIdle) {
          s.isUserInteracting = false;
        }
        _syncStickTarget();
        return false;
      },
      child: CustomScrollView(
        controller: s.scrollController,
        physics: const SuperRangeMaintainingScrollPhysics(
          parent: ClampingScrollPhysics(),
        ),
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: kTopPadding)),
          SuperSliverList(
            listController: s.listController,
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                if (index == itemCount - 1) {
                  final endSpace = s.sent
                      ? resolveChatAnchoredEndSpaceExtent(
                          availableExtent: kViewportHeight - kTopPadding,
                          contentExtentFromAnchor:
                              s.userRowHeight +
                              s.assistantHeight +
                              kComposerSpacer,
                        )
                      : 0.0;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    s.endSpaceExtent = endSpace;
                    _syncStickTarget();
                  });
                  // The reserved space is intentionally an item in the managed
                  // list, not a separate trailing sliver. This makes the
                  // package's sliver-local target reachability math see it.
                  return SizedBox(
                    key: const ValueKey('composer-spacer'),
                    height: kComposerSpacer + endSpace,
                  );
                }
                if (s.sent && index == s.anchorIndex) {
                  return KeyedSubtree(
                    key: s.userRowKey,
                    child: SizedBox(height: s.userRowHeight),
                  );
                }
                if (s.sent && index == s.anchorIndex + 1) {
                  return SizedBox(
                    key: const ValueKey('assistant-row'),
                    height: s.assistantHeight,
                  );
                }
                return SizedBox(
                  key: ValueKey('history-$index'),
                  height: kHistoryRowHeight,
                );
              },
              childCount: itemCount,
              findChildIndexCallback: (key) {
                if (key == const ValueKey('composer-spacer')) {
                  return itemCount - 1;
                }
                if (key == const ValueKey('assistant-row')) {
                  return s.sent ? s.anchorIndex + 1 : null;
                }
                if (key is ValueKey<String> &&
                    key.value.startsWith('history-')) {
                  return int.parse(key.value.substring('history-'.length));
                }
                return null; // GlobalKey user row: same as ChatPage
              },
            ),
          ),
        ],
      ),
    );
  }
}

double userRowTop(WidgetTester tester, PinHarnessState s) {
  final ctx = s.userRowKey.currentContext!;
  final box = ctx.findRenderObject()! as RenderBox;
  return box.localToGlobal(Offset.zero).dy;
}

Future<void> pumpHarness(WidgetTester tester, PinHarnessState s) async {
  tester.view.physicalSize = const Size(400, kViewportHeight);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: PinHarness(state: s)),
    ),
  );
  // Settle at bottom like an ongoing conversation.
  s.scrollController.jumpTo(s.scrollController.position.maxScrollExtent);
  await tester.pump();
}

/// Mirrors _activatePinToTopAnchor + _scrollToUserMessage +
/// _animatePinnedMessageToTop (chat_page.dart:768-793, 1924-2014).
Future<void> simulateSend(WidgetTester tester, PinHarnessState s) async {
  s.sent = true;
  s.isAutoFollowing = true;
  s.isPositionSettled = false;
  s.endSpaceExtent = kViewportHeight - kTopPadding;
  s.rebuild();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final ctx = s.userRowKey.currentContext;
    if (ctx == null || !s.isAutoFollowing) {
      debugPrint('post-frame: ctx=$ctx autoFollow=${s.isAutoFollowing}');
      return;
    }
    final box = ctx.findRenderObject()! as RenderBox;
    final targetTop = box.localToGlobal(Offset.zero).dy;
    final current = s.scrollController.offset;
    final maxScroll = s.scrollController.position.maxScrollExtent;
    final target = (current + targetTop - kTopPadding)
        .clamp(0.0, maxScroll)
        .toDouble();
    debugPrint(
      'post-frame: targetTop=$targetTop current=$current '
      'max=$maxScroll target=$target',
    );
    if ((target - current).abs() < 1.0) {
      s.isPositionSettled = true;
      return;
    }
    s.scrollController
        .animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() {
          debugPrint(
            'animateTo completed at offset=${s.scrollController.offset} '
            'activity=${s.scrollController.position.activity}',
          );
          if (s.isAutoFollowing) s.isPositionSettled = true;
        });
  });
  await tester.pump(); // frame with the new rows; post-frame starts animation
}

void main() {
  testWidgets('B1/B5: send pins the prompt to the top and it stays pinned '
      'while streaming grows the response', (tester) async {
    final s = PinHarnessState();
    addTearDown(s.dispose);
    await pumpHarness(tester, s);

    await simulateSend(tester, s);
    for (var f = 0; f < 6; f++) {
      await tester.pump(const Duration(milliseconds: 50));
      debugPrint(
        'anim frame $f: offset=${s.scrollController.offset} '
        'isScrolling=${s.scrollController.position.isScrollingNotifier.value}',
      );
    }
    await tester.pump();

    final topAfterAnimation = userRowTop(tester, s);
    debugPrint('cancelEvents after send/animation: ${s.cancelEvents}');
    debugPrint(
      'user row top after animation: $topAfterAnimation '
      '(expected ~$kTopPadding)',
    );
    debugPrint(
      'offset=${s.scrollController.offset} '
      'max=${s.scrollController.position.maxScrollExtent} '
      'endSpace=${s.endSpaceExtent}',
    );

    // Now stream: grow the assistant row in chunks, one frame apart,
    // exactly like live extents changing mid-conversation.
    for (var i = 0; i < 8; i++) {
      s.assistantHeight += 30;
      s.rebuild();
      await tester.pump(const Duration(milliseconds: 50));
      debugPrint(
        'chunk $i: userRowTop=${userRowTop(tester, s)} '
        'offset=${s.scrollController.offset} '
        'endSpace=${s.endSpaceExtent} '
        'max=${s.scrollController.position.maxScrollExtent}',
      );
    }
    await tester.pumpAndSettle();

    final topAfterStreaming = userRowTop(tester, s);
    debugPrint(
      'final userRowTop=$topAfterStreaming '
      'cancelEvents=${s.cancelEvents}',
    );

    expect(
      topAfterAnimation,
      closeTo(kTopPadding, 1.0),
      reason: 'the send animation itself works: prompt pinned at topInset',
    );
    expect(
      topAfterStreaming,
      closeTo(kTopPadding, 1.0),
      reason:
          'keeping the reserved end space inside SuperSliverList makes '
          'the item target reachable, so streaming growth must preserve the '
          'prompt-to-top anchor',
    );
    expect(
      tester.takeException(),
      isNull,
      reason: 'extent updates must not schedule builds during layout',
    );
  });

  testWidgets('B: streaming chunks arriving DURING the 220ms animation', (
    tester,
  ) async {
    final s = PinHarnessState();
    addTearDown(s.dispose);
    await pumpHarness(tester, s);

    await simulateSend(tester, s);
    // Interleave chunks with animation frames.
    for (var i = 0; i < 4; i++) {
      s.assistantHeight += 25;
      s.rebuild();
      await tester.pump(const Duration(milliseconds: 50));
      debugPrint(
        'mid-anim chunk $i: userRowTop=${userRowTop(tester, s)} '
        'offset=${s.scrollController.offset}',
      );
    }
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    final top = userRowTop(tester, s);
    debugPrint(
      'after mid-animation streaming: userRowTop=$top '
      'cancelEvents=${s.cancelEvents}',
    );
    expect(top, closeTo(kTopPadding, 1.0));
  });
}
