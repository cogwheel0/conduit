import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/shared/widgets/markdown/streaming_markdown_widget.dart';
import 'package:conduit/shared/widgets/responsive_drawer_layout.dart';

const _mobileSize = Size(390, 844);
const _tabletSize = Size(1024, 1366);
const _vibrateChannel = MethodChannel('vibrate');
const _wideMarkdownTable = '''
| Provider | Management experience | Deployment options | Access control |
| --- | --- | --- | --- |
| Example Identity Provider | Polished administrative interface | Docker Compose, Helm, and Kubernetes | OAuth, OIDC, SAML, and role-based access control |
''';

class _RecordedPlatformCall {
  const _RecordedPlatformCall(this.method, this.arguments);

  final String method;
  final Object? arguments;

  @override
  String toString() => '_RecordedPlatformCall($method, $arguments)';
}

Future<List<_RecordedPlatformCall>> _recordPlatformCalls(
  Future<void> Function() action,
) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <_RecordedPlatformCall>[];

  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    calls.add(_RecordedPlatformCall(call.method, call.arguments));
    return null;
  });
  messenger.setMockMethodCallHandler(_vibrateChannel, (call) async {
    calls.add(_RecordedPlatformCall('vibrate:${call.method}', call.arguments));
    return null;
  });

  try {
    await action();
  } finally {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(_vibrateChannel, null);
  }

  return calls;
}

Future<void> _recordPlatformCallsDuring(
  Future<void> Function(List<_RecordedPlatformCall> calls) action,
) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <_RecordedPlatformCall>[];

  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    calls.add(_RecordedPlatformCall(call.method, call.arguments));
    return null;
  });
  messenger.setMockMethodCallHandler(_vibrateChannel, (call) async {
    calls.add(_RecordedPlatformCall('vibrate:${call.method}', call.arguments));
    return null;
  });

  try {
    await action(calls);
  } finally {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(_vibrateChannel, null);
  }
}

Iterable<_RecordedPlatformCall> _settleHapticCalls(
  List<_RecordedPlatformCall> calls,
) => calls.where(
  (call) =>
      (call.method == 'HapticFeedback.vibrate' &&
          call.arguments == 'HapticFeedbackType.mediumImpact') ||
      call.method == 'vibrate:medium',
);

Widget _buildHarness({
  required Size size,
  GlobalKey<ResponsiveDrawerLayoutState>? layoutKey,
  Widget? child,
  Widget? drawer,
  double edgeFraction = 0.5,
  VoidCallback? onOpenStart,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: ResponsiveDrawerLayout(
        key: layoutKey,
        edgeFraction: edgeFraction,
        onOpenStart: onOpenStart,
        drawer:
            drawer ??
            const ColoredBox(
              key: ValueKey('drawer'),
              color: Colors.blue,
              child: SizedBox.expand(),
            ),
        child:
            child ??
            const ColoredBox(
              key: ValueKey('content'),
              color: Colors.orange,
              child: SizedBox.expand(),
            ),
      ),
    ),
  );
}

Widget _buildEagerGestureOwner() {
  return RawGestureDetector(
    behavior: HitTestBehavior.opaque,
    gestures: <Type, GestureRecognizerFactory>{
      EagerGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
            EagerGestureRecognizer.new,
            (_) {},
          ),
    },
    child: const ColoredBox(
      key: ValueKey('eager-gesture-owner'),
      color: Colors.orange,
      child: SizedBox.expand(),
    ),
  );
}

Future<void> _longPressDrag(
  WidgetTester tester,
  Offset start,
  Offset delta,
) async {
  final gesture = await tester.startGesture(start);
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
  await gesture.moveBy(delta);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _withTargetPlatform(
  TargetPlatform platform,
  Future<void> Function() action,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await action();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Widget _buildHorizontalScrollableContent({
  ScrollController? controller,
  Key? key,
}) {
  return ColoredBox(
    color: Colors.orange,
    child: SingleChildScrollView(
      key: key,
      controller: controller,
      scrollDirection: Axis.horizontal,
      child: const SizedBox(
        width: 1200,
        height: 844,
        child: ColoredBox(color: Colors.deepOrange),
      ),
    ),
  );
}

Future<void> _openDrawer(
  WidgetTester tester,
  GlobalKey<ResponsiveDrawerLayoutState> layoutKey,
) async {
  layoutKey.currentState!.open();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('drag settle open emits no sidebar haptic', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    final calls = await _recordPlatformCalls(() async {
      await tester.pumpWidget(
        _buildHarness(size: _mobileSize, layoutKey: layoutKey),
      );

      await tester.dragFrom(const Offset(10, 200), const Offset(260, 0));
      await tester.pumpAndSettle();
    });

    expect(layoutKey.currentState!.isOpen, isTrue);
    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets('non-scrollable content retains the wide drawer drag region', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      _buildHarness(size: _mobileSize, layoutKey: layoutKey),
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
      _buildHarness(size: _mobileSize, layoutKey: layoutKey, edgeFraction: 1),
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
      _buildHarness(
        size: _mobileSize,
        layoutKey: layoutKey,
        edgeFraction: 1,
        child: const DrawerOpenGestureExclusion(
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
        await _withTargetPlatform(platform, () async {
          final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

          await tester.pumpWidget(
            _buildHarness(
              size: _mobileSize,
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
      _buildHarness(
        size: _mobileSize,
        layoutKey: layoutKey,
        edgeFraction: 1,
        child: const DrawerOpenGestureExclusion(
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
      _buildHarness(
        size: _mobileSize,
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
      _buildHarness(size: _mobileSize, layoutKey: layoutKey, edgeFraction: 1),
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
      _buildHarness(
        size: _mobileSize,
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
        _buildHarness(
          size: _mobileSize,
          layoutKey: layoutKey,
          edgeFraction: 1,
          child: _buildHorizontalScrollableContent(
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
        await _withTargetPlatform(platform, () async {
          final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();
          SelectedContent? selectedContent;

          await tester.pumpWidget(
            _buildHarness(
              size: _mobileSize,
              layoutKey: layoutKey,
              edgeFraction: 1,
              child: Material(
                child: DrawerOpenGestureExclusion(
                  child: SelectionArea(
                    onSelectionChanged: (content) => selectedContent = content,
                    contextMenuBuilder: (_, _) => const SizedBox.shrink(),
                    magnifierConfiguration: TextMagnifierConfiguration.disabled,
                    child: const DrawerOpenGesturePriority(
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
          await _longPressDrag(
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
      await _withTargetPlatform(TargetPlatform.iOS, () async {
        final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();
        final textController = TextEditingController(
          text:
              'Editable text keeps cursor and selection gestures in the field',
        );
        addTearDown(textController.dispose);

        await tester.pumpWidget(
          _buildHarness(
            size: _mobileSize,
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

        await _longPressDrag(
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
        _buildHarness(
          size: _mobileSize,
          layoutKey: layoutKey,
          edgeFraction: 1,
          child: DrawerOpenGestureExclusion(
            child: DrawerOpenGesturePriority(child: _buildEagerGestureOwner()),
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
        _buildHarness(
          size: _mobileSize,
          layoutKey: layoutKey,
          child: _buildHorizontalScrollableContent(
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
        _buildHarness(
          size: _mobileSize,
          layoutKey: layoutKey,
          edgeFraction: 1,
          child: _buildHorizontalScrollableContent(
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
      _buildHarness(
        size: _mobileSize,
        layoutKey: layoutKey,
        child: const ProviderScope(
          child: Material(
            child: StreamingMarkdownWidget(
              content: _wideMarkdownTable,
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
      _buildHarness(
        size: _mobileSize,
        layoutKey: layoutKey,
        child: const ProviderScope(
          child: Material(
            child: StreamingMarkdownWidget(
              content: _wideMarkdownTable,
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
        _buildHarness(
          size: _mobileSize,
          layoutKey: layoutKey,
          edgeFraction: 1,
          child: _buildHorizontalScrollableContent(
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

  testWidgets('horizontal drag closes an open mobile drawer without haptic', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      _buildHarness(size: _mobileSize, layoutKey: layoutKey),
    );
    await _openDrawer(tester, layoutKey);
    expect(layoutKey.currentState!.isOpen, isTrue);

    final calls = await _recordPlatformCalls(() async {
      await tester.drag(
        find.byKey(const ValueKey('drawer')),
        const Offset(-400, 0),
      );
      await tester.pumpAndSettle();
    });

    expect(layoutKey.currentState!.isOpen, isFalse);
    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets('initial mount fires zero haptics', (tester) async {
    final calls = await _recordPlatformCalls(() async {
      await tester.pumpWidget(_buildHarness(size: _mobileSize));
      await tester.pumpAndSettle();
    });

    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets('rebuild and resize at a settled endpoint fire zero haptics', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      _buildHarness(size: _mobileSize, layoutKey: layoutKey),
    );
    await _openDrawer(tester, layoutKey);

    final calls = await _recordPlatformCalls(() async {
      await tester.pumpWidget(
        _buildHarness(size: _mobileSize, layoutKey: layoutKey),
      );
      await tester.pump();

      await tester.pumpWidget(
        _buildHarness(size: _tabletSize, layoutKey: layoutKey),
      );
      await tester.pump();

      await tester.pumpWidget(
        _buildHarness(size: _mobileSize, layoutKey: layoutKey),
      );
      await tester.pump();
    });

    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets('programmatic open settles without haptic', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    final calls = await _recordPlatformCalls(() async {
      await tester.pumpWidget(
        _buildHarness(size: _mobileSize, layoutKey: layoutKey),
      );

      layoutKey.currentState!.open();
      await tester.pumpAndSettle();
    });

    expect(layoutKey.currentState!.isOpen, isTrue);
    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets('programmatic close settles without haptic', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      _buildHarness(size: _mobileSize, layoutKey: layoutKey),
    );
    await _openDrawer(tester, layoutKey);
    expect(layoutKey.currentState!.isOpen, isTrue);

    final calls = await _recordPlatformCalls(() async {
      layoutKey.currentState!.close();
      await tester.pumpAndSettle();
    });

    expect(layoutKey.currentState!.isOpen, isFalse);
    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets('open when already open fires zero haptics', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      _buildHarness(size: _mobileSize, layoutKey: layoutKey),
    );
    await _openDrawer(tester, layoutKey);
    expect(layoutKey.currentState!.isOpen, isTrue);

    final calls = await _recordPlatformCalls(() async {
      layoutKey.currentState!.open();
      await tester.pumpAndSettle();
    });

    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets('close when already closed fires zero haptics', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    await tester.pumpWidget(
      _buildHarness(size: _mobileSize, layoutKey: layoutKey),
    );

    final calls = await _recordPlatformCalls(() async {
      layoutKey.currentState!.close();
      await tester.pumpAndSettle();
    });

    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets('same endpoint repeat settle emits no haptic', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    final calls = await _recordPlatformCalls(() async {
      await tester.pumpWidget(
        _buildHarness(size: _mobileSize, layoutKey: layoutKey),
      );

      layoutKey.currentState!.open();
      await tester.pumpAndSettle();

      await tester.drag(
        find.byKey(const ValueKey('drawer')),
        const Offset(-80, 0),
      );
      await tester.pumpAndSettle();
    });

    expect(layoutKey.currentState!.isOpen, isTrue);
    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets(
    'drag leaving an endpoint before release settles without haptic',
    (tester) async {
      final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

      await _recordPlatformCallsDuring((calls) async {
        await tester.pumpWidget(
          _buildHarness(size: _mobileSize, layoutKey: layoutKey),
        );

        final gesture = await tester.startGesture(const Offset(10, 200));
        await gesture.moveBy(const Offset(360, 0));
        await tester.pump();
        await gesture.moveBy(const Offset(-200, 0));
        await tester.pump();

        await gesture.up();
        await tester.pump();

        expect(layoutKey.currentState!.isOpen, isFalse);
        expect(_settleHapticCalls(calls), isEmpty);

        await tester.pumpAndSettle();

        expect(layoutKey.currentState!.isOpen, isTrue);
        expect(_settleHapticCalls(calls), isEmpty);
      });
    },
  );

  testWidgets('drag cancel resets state so next open settles without haptic', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    final calls = await _recordPlatformCalls(() async {
      await tester.pumpWidget(
        _buildHarness(size: _mobileSize, layoutKey: layoutKey),
      );

      final gesture = await tester.startGesture(const Offset(10, 200));
      await gesture.moveBy(const Offset(160, 0));
      await tester.pump();
      await gesture.cancel();
      await tester.pump();

      layoutKey.currentState!.open();
      await tester.pumpAndSettle();
    });

    expect(layoutKey.currentState!.isOpen, isTrue);
    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets('interrupted reversed settle emits no abandoned haptic', (
    tester,
  ) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    final calls = await _recordPlatformCalls(() async {
      await tester.pumpWidget(
        _buildHarness(size: _mobileSize, layoutKey: layoutKey),
      );

      layoutKey.currentState!.open();
      await tester.pump(const Duration(milliseconds: 16));

      layoutKey.currentState!.close();
      await tester.pumpAndSettle();
    });

    expect(layoutKey.currentState!.isOpen, isFalse);
    expect(_settleHapticCalls(calls), isEmpty);
  });

  testWidgets('tablet layout emits zero mobile settle haptics', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();

    final calls = await _recordPlatformCalls(() async {
      await tester.pumpWidget(
        _buildHarness(size: _tabletSize, layoutKey: layoutKey),
      );

      layoutKey.currentState!.close();
      await tester.pumpAndSettle();

      layoutKey.currentState!.open();
      await tester.pumpAndSettle();
    });

    expect(_settleHapticCalls(calls), isEmpty);
  });
}
