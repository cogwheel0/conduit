import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/models/chat_transcript_window.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/features/chat/widgets/chat_timeline_viewport.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/sidebar_layout_contract.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestTextToSpeechController extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

const _topContentInset = 32.0;

double _transcriptOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find.byKey(const ValueKey<String>('sliver-transcript-visibility')),
    )
    .opacity;

void _useFixedViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 600);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

void _viewportTest(String description, WidgetTesterCallback callback) {
  testWidgets(description, (tester) async {
    _useFixedViewport(tester);
    await callback(tester);
  });
}

ChatTimelineViewportController _controller(WidgetTester tester) {
  final controller = ChatTimelineViewportController();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  return controller;
}

class _TrackedGesture {
  _TrackedGesture(this._gesture);

  final TestGesture _gesture;
  bool _released = false;

  Future<void> moveBy(Offset offset) => _gesture.moveBy(offset);

  Future<void> up() async {
    await _gesture.up();
    _released = true;
  }

  Future<void> cancel() async {
    if (_released) return;
    await _gesture.cancel();
    _released = true;
  }
}

class _MountedRowProbe extends StatefulWidget {
  const _MountedRowProbe({required this.messageId, required this.onMounted});

  final String messageId;
  final ValueChanged<String> onMounted;

  @override
  State<_MountedRowProbe> createState() => _MountedRowProbeState();
}

class _MountedRowProbeState extends State<_MountedRowProbe> {
  @override
  void initState() {
    super.initState();
    widget.onMounted(widget.messageId);
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: 52, child: Text(widget.messageId));
}

class _TransformAvailability extends SingleChildRenderObjectWidget {
  const _TransformAvailability({
    required this.available,
    required super.child,
    super.key,
  });

  final bool available;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTransformAvailability(available);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderTransformAvailability renderObject,
  ) {
    renderObject.available = available;
  }
}

class _RenderTransformAvailability extends RenderProxyBox {
  _RenderTransformAvailability(this._available);

  bool _available;
  int unavailableSizeReads = 0;
  int unavailableTransformReads = 0;

  @override
  bool get hasSize {
    if (!_available) {
      unavailableSizeReads += 1;
      return false;
    }
    return super.hasSize;
  }

  set available(bool value) {
    if (_available == value) return;
    _available = value;
    markNeedsPaint();
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    if (!_available) {
      unavailableTransformReads += 1;
      throw StateError('Ancestor paint transform is not laid out');
    }
    super.applyPaintTransform(child, transform);
  }
}

Future<_TrackedGesture> _startTrackedGesture(
  WidgetTester tester,
  Offset position,
) async {
  final tracked = _TrackedGesture(await tester.startGesture(position));
  addTearDown(() async {
    await tracked.cancel();
  });
  return tracked;
}

/// Shows the platform scrollbar the way a person does, by scrolling the
/// transcript; the app's own position changes leave it hidden. The finger
/// rests before lifting so the release starts no fling.
Future<void> _revealScrollbarByScrolling(WidgetTester tester, double dy) async {
  final gesture = await _startTrackedGesture(
    tester,
    tester.getCenter(find.byType(CustomScrollView)),
  );
  for (var step = 0; step < 4; step++) {
    await gesture.moveBy(Offset(0, dy / 4));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pump(const Duration(milliseconds: 100));
  await gesture.up();
  for (var frame = 0; frame < 3; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Advances bounded zero-duration frames used by initial-position retry tests.
Future<void> _pumpSettleFrames(
  WidgetTester tester, {
  int count = debugChatTimelineInitialPositionMaxAttempts + 2,
}) async {
  for (var frame = 0; frame < count; frame += 1) {
    await tester.pump();
  }
}

Rect _paintedThumb(WidgetTester tester) {
  final paint = tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .firstWhere((widget) => widget.foregroundPainter is ScrollbarPainter);
  final painter = paint.foregroundPainter! as ScrollbarPainter;
  double? top;
  double? bottom;
  for (var y = 0.0; y < 600; y += .25) {
    if (painter.hitTestOnlyThumbInteractive(
      Offset(796, y),
      PointerDeviceKind.mouse,
    )) {
      top ??= y;
      bottom = y;
    }
  }
  if (top == null || bottom == null) {
    throw StateError('Scrollbar thumb not painted');
  }
  return Rect.fromLTRB(792, top, 799, bottom);
}

void main() {
  _viewportTest(
    'animated navigation reaches both ends despite inaccurate estimates',
    (tester) async {
      final controller = _controller(tester);
      final ids = List.generate(10000, (i) => 'synthetic-$i');
      await tester.pumpWidget(
        _viewportHost(
          _viewport(
            controller: controller,
            ids: ids,
            followLatest: false,
            estimateRowExtent: (_) => 100,
            rowBuilder: (_, i) => SizedBox(height: i % 10 == 5 ? 3000 : 60),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final oldest = controller.animateToOldest(
        duration: const Duration(milliseconds: 500),
        curve: Curves.linear,
      );
      await tester.pumpAndSettle();
      expect(await oldest, isTrue);
      expect(controller.visibleMessageIds.first, ids.first);
      final latest = controller.animateToLatest(
        duration: const Duration(milliseconds: 500),
        curve: Curves.linear,
      );
      await tester.pumpAndSettle();
      await latest;
      expect(controller.visibleMessageIds.last, ids.last);
      expect(controller.distanceFromLatest, closeTo(0, 1));
    },
  );

  for (final (animated, estimate) in [
    (false, 100.0),
    (true, 100.0),
    // Estimates five times too tall pick a center too close to the end.
    (false, 300.0),
  ]) {
    _viewportTest(
      'returning to the latest from far away rests a short reply on the '
      'composer (animated: $animated, estimate: $estimate)',
      (tester) async {
        final controller = _controller(tester);
        final ids = List.generate(2000, (i) => 'synthetic-$i');
        await tester.pumpWidget(
          _viewportHost(
            _viewport(
              controller: controller,
              ids: ids,
              followLatest: false,
              // Opening at the oldest message leaves the newest rows
              // unmeasured, so only estimates describe them.
              initialAnchor: const ChatScrollAnchor(
                messageId: 'synthetic-0',
                offsetWithinMessage: 0,
              ),
              estimateRowExtent: (_) => estimate,
              rowBuilder: (_, i) => SizedBox(height: i % 10 == 5 ? 300 : 60),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.visibleMessageIds.first, ids.first);

        if (animated) {
          final latest = controller.animateToLatest(
            duration: const Duration(milliseconds: 300),
            curve: Curves.linear,
          );
          await tester.pumpAndSettle();
          await latest;
        } else {
          controller.jumpToLatest();
          await tester.pumpAndSettle();
        }

        // The newest row ends where the transcript's bottom padding begins,
        // not at the toolbar with empty space beneath it.
        final viewport = tester.getRect(find.byType(CustomScrollView));
        final last = controller.rowRect(ids.last);
        expect(last, isNotNull);
        expect(last!.bottom, closeTo(viewport.bottom - 80, 1));
        expect(controller.distanceFromLatest, closeTo(0, 1));
        // Earlier messages fill the screen above it.
        expect(controller.visibleMessageIds.length, greaterThan(3));
      },
    );
  }

  _viewportTest(
    'seeking the scrollbar to its end rests a short reply on the composer',
    (tester) async {
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
      addTearDown(PlatformUiCapabilities.resetDebugOverrides);
      final controller = _controller(tester);
      final ids = List.generate(500, (i) => 'synthetic-$i');
      await tester.pumpWidget(
        _viewportHost(
          _viewport(
            controller: controller,
            ids: ids,
            followLatest: false,
            initialAnchor: const ChatScrollAnchor(
              messageId: 'synthetic-0',
              offsetWithinMessage: 0,
            ),
            // Tall opening rows give the visible screen about two message
            // units, so the scrollbar's end seeks two rows from the last.
            // Estimates put a full screen below there; only 120 px follow.
            estimateRowExtent: (_) => 300,
            rowBuilder: (_, i) => SizedBox(height: i < 20 ? 300 : 60),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bar = tester
          .widget<Scrollbar>(find.byType(Scrollbar))
          .controller!
          .position;
      bar.jumpTo(bar.maxScrollExtent);
      await tester.pumpAndSettle();

      final viewport = tester.getRect(find.byType(CustomScrollView));
      final last = controller.rowRect(ids.last);
      expect(last, isNotNull);
      expect(last!.bottom, closeTo(viewport.bottom - 80, 1));
    },
  );

  _viewportTest('a mouse thumb drag during a fling holds until release', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    final controller = _controller(tester);
    var ends = 0;
    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: List.generate(500, (i) => 'synthetic-$i'),
          followLatest: false,
          rowHeight: (_) => 100,
          onUserDragEnd: () => ends++,
        ),
        theme: ThemeData(
          scrollbarTheme: const ScrollbarThemeData(
            thumbVisibility: WidgetStatePropertyAll(true),
            thickness: WidgetStatePropertyAll(8),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, 300),
      3000,
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(ends, 0, reason: 'the fling is still running');

    // A mouse does not stop the content's fling the way a touch does, so
    // the thumb's first seek is what stops it.
    final mouse = await tester.startGesture(
      _paintedThumb(tester).center,
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(() async {
      try {
        await mouse.cancel();
      } catch (_) {}
    });
    await tester.pump(const Duration(milliseconds: 50));
    for (var step = 0; step < 3; step++) {
      await mouse.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(ends, 0, reason: 'the thumb is still held');

    await mouse.up();
    await tester.pumpAndSettle();
    expect(ends, 1);
  });

  _viewportTest('a viewport removed mid-drag still ends the drag', (
    tester,
  ) async {
    final controller = _controller(tester);
    var starts = 0;
    var ends = 0;
    var showViewport = true;
    late StateSetter rebuild;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          rebuild = setState;
          return _viewportHost(
            showViewport
                ? _viewport(
                    controller: controller,
                    ids: List.generate(40, (i) => 'synthetic-$i'),
                    followLatest: false,
                    onUserDragStart: () => starts++,
                    onUserDragEnd: () => ends++,
                  )
                : const SizedBox.expand(),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    final gesture = await _startTrackedGesture(
      tester,
      tester.getCenter(find.byType(CustomScrollView)),
    );
    for (var step = 0; step < 3; step++) {
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(starts, 1);

    // The transcript empties while the finger is still down.
    rebuild(() => showViewport = false);
    await tester.pump();
    await tester.pump();
    expect(ends, 1);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(ends, 1);
  });

  _viewportTest('Android track taps page the mapped scrollbar', (tester) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    final controller = _controller(tester);
    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: const ['synthetic-tall'],
          followLatest: false,
          initialAnchor: const ChatScrollAnchor(
            messageId: 'synthetic-tall',
            offsetWithinMessage: 0,
          ),
          rowBuilder: (_, _) => const SizedBox(height: 10000),
        ),
        theme: ThemeData(
          platform: TargetPlatform.android,
          scrollbarTheme: const ScrollbarThemeData(
            thumbVisibility: WidgetStatePropertyAll(true),
            thickness: WidgetStatePropertyAll(8),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    position.jumpTo(1);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_paintedThumb(tester).bottom, lessThan(200));
    await tester.tapAt(const Offset(796, 400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(position.pixels, inExclusiveRange(300, 600));
    await tester.tapAt(const Offset(796, 34), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(position.pixels, lessThan(50));
  });

  _viewportTest('track paging stays physical across mixed message heights', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    final controller = _controller(tester);
    final ids = List.generate(100, (index) => 'synthetic-$index');
    var starts = 0;
    var ends = 0;
    double height(int index) => index.isEven ? 80 : 4000;
    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: ids,
          followLatest: false,
          initialAnchor: ChatScrollAnchor(
            messageId: ids[20],
            offsetWithinMessage: 0,
          ),
          rowBuilder: (_, index) => SizedBox(height: height(index)),
          onUserDragStart: () => starts++,
          onUserDragEnd: () => ends++,
        ),
        theme: ThemeData(
          platform: TargetPlatform.android,
          scrollbarTheme: const ScrollbarThemeData(
            thumbVisibility: WidgetStatePropertyAll(true),
            thickness: WidgetStatePropertyAll(8),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    double contentOffset() {
      final anchor = controller.captureTopVisibleAnchor()!;
      final index = ids.indexOf(anchor.messageId);
      return List.generate(index, height).fold(0.0, (a, b) => a + b) -
          anchor.offsetWithinMessage;
    }

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    position.jumpTo(position.pixels + 1);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    final before = contentOffset();
    await tester.tapAt(const Offset(796, 500));
    var previous = before;
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final current = contentOffset();
      expect(current, greaterThanOrEqualTo(previous - .01));
      previous = current;
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      contentOffset() - before,
      closeTo(position.viewportDimension * .8, 1),
    );
    await tester.tapAt(const Offset(796, 34), kind: PointerDeviceKind.mouse);
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final current = contentOffset();
      expect(current, lessThanOrEqualTo(previous + .01));
      previous = current;
    }
    await tester.pumpAndSettle();
    expect(contentOffset(), closeTo(before, 1));
    expect(starts, 2);
    expect(ends, 2);
    await tester.tapAt(const Offset(796, 500));
    await tester.pump(const Duration(milliseconds: 32));
    await tester.tapAt(const Offset(796, 500));
    await tester.pump(const Duration(milliseconds: 32));
    expect(ends, 2);
    await tester.pumpAndSettle();
    expect(starts, 3);
    expect(ends, 3);
    expect(tester.takeException(), isNull);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    _viewportTest('$platform mouse wheel reaches keyboard-dismiss ancestors', (
      tester,
    ) async {
      PlatformUiCapabilities.debugPlatformOverride = platform;
      addTearDown(PlatformUiCapabilities.resetDebugOverrides);
      final controller = _controller(tester);
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final directions = <ScrollDirection>[];
      await tester.pumpWidget(
        _viewportHost(
          NotificationListener<UserScrollNotification>(
            onNotification: (notification) {
              directions.add(notification.direction);
              if (notification.direction != ScrollDirection.idle) {
                focus.unfocus();
              }
              return false;
            },
            child: Focus(
              focusNode: focus,
              child: _viewport(
                controller: controller,
                ids: List.generate(100, (i) => 'synthetic-$i'),
                followLatest: false,
                rowHeight: (_) => 100,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(ChatTimelineViewport)),
          scrollDelta: const Offset(0, -100),
        ),
      );
      await tester.pumpAndSettle();
      expect(directions, contains(ScrollDirection.forward));
      expect(focus.hasFocus, isFalse);
    });

    _viewportTest('$platform switching chats cancels a held scrollbar', (
      tester,
    ) async {
      PlatformUiCapabilities.debugPlatformOverride = platform;
      addTearDown(PlatformUiCapabilities.resetDebugOverrides);
      final controller = _controller(tester);
      var ends = 0;
      // Like ChatPage, the parent rebuilds when a drag ends, which it may not
      // do while the switch is still building.
      Widget host(int owner) => StatefulBuilder(
        builder: (context, setState) => _viewportHost(
          _viewport(
            controller: controller,
            ownerGeneration: owner,
            ids: List.generate(
              owner == 1 ? 500 : 4,
              (i) => 'synthetic-$owner-$i',
            ),
            followLatest: false,
            rowHeight: (_) => 100,
            onUserDragEnd: () => setState(() => ends++),
          ),
          theme: ThemeData(
            scrollbarTheme: const ScrollbarThemeData(
              thumbVisibility: WidgetStatePropertyAll(true),
              thickness: WidgetStatePropertyAll(8),
            ),
          ),
        ),
      );
      await tester.pumpWidget(host(1));
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      await _revealScrollbarByScrolling(tester, 60);
      ends = 0;
      final gesture = await _startTrackedGesture(
        tester,
        _paintedThumb(tester).center,
      );
      await tester.pump(const Duration(milliseconds: 150));
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 32));
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 32));
      await tester.pumpWidget(host(2));
      await tester.pumpAndSettle();
      final newOffset = position.pixels;
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 32));
      expect(position.pixels, newOffset);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(ends, 1);
      expect(
        controller.visibleMessageIds.every(
          (id) => id.startsWith('synthetic-2-'),
        ),
        isTrue,
      );
    });

    _viewportTest(
      '$platform scrollbar reaches both ends of the complete history',
      (tester) async {
        PlatformUiCapabilities.debugPlatformOverride = platform;
        addTearDown(PlatformUiCapabilities.resetDebugOverrides);
        final controller = _controller(tester);
        final ids = List.generate(500, (index) => 'synthetic-$index');
        await tester.pumpWidget(
          _viewportHost(
            _viewport(
              controller: controller,
              ids: ids,
              followLatest: false,
              estimateRowExtent: (_) => 100,
              rowBuilder: (_, index) =>
                  SizedBox(height: index % 10 == 5 ? 3000 : 60),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final oldest = controller.jumpToOldest();
        await tester.pumpAndSettle();
        expect(await oldest, isTrue);
        final bar = platform == TargetPlatform.iOS
            ? tester
                  .widget<CupertinoScrollbar>(find.byType(CupertinoScrollbar))
                  .controller!
                  .position
            : tester
                  .widget<Scrollbar>(find.byType(Scrollbar))
                  .controller!
                  .position;
        expect(bar.pixels, closeTo(bar.minScrollExtent, .01));
        controller.jumpToLatest();
        await tester.pumpAndSettle();
        expect(bar.pixels, closeTo(bar.maxScrollExtent, .01));
        expect(controller.visibleMessageIds.last, ids.last);
      },
    );

    _viewportTest(
      '$platform thumb moves continuously within one tall message',
      (tester) async {
        PlatformUiCapabilities.debugPlatformOverride = platform;
        addTearDown(PlatformUiCapabilities.resetDebugOverrides);
        final controller = _controller(tester);
        await tester.pumpWidget(
          _viewportHost(
            _viewport(
              controller: controller,
              ids: const ['synthetic-tall'],
              followLatest: false,
              initialAnchor: const ChatScrollAnchor(
                messageId: 'synthetic-tall',
                offsetWithinMessage: 0,
              ),
              rowBuilder: (_, _) => const SizedBox(height: 10000),
            ),
            theme: ThemeData(
              scrollbarTheme: const ScrollbarThemeData(
                thumbVisibility: WidgetStatePropertyAll(true),
                thickness: WidgetStatePropertyAll(8),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final position = tester
            .state<ScrollableState>(find.byType(Scrollable))
            .position;
        await _revealScrollbarByScrolling(tester, -60);
        final thumb = _paintedThumb(tester);
        final gesture = await _startTrackedGesture(tester, thumb.center);
        await tester.pump(const Duration(milliseconds: 150));
        var previous = position.pixels;
        for (var i = 0; i < 8; i++) {
          await gesture.moveBy(const Offset(0, 10));
          await tester.pump(const Duration(milliseconds: 32));
          if (i > 1) expect(position.pixels, greaterThan(previous));
          previous = position.pixels;
        }
        expect(position.pixels, greaterThan(1000));
        await gesture.up();
        await tester.pumpAndSettle();
      },
    );

    _viewportTest(
      '$platform thumb drags through a long history without building intervening rows',
      (tester) async {
        PlatformUiCapabilities.debugPlatformOverride = platform;
        addTearDown(PlatformUiCapabilities.resetDebugOverrides);
        final controller = _controller(tester);
        final ids = List.generate(10000, (index) => 'synthetic-$index');
        var builds = 0;
        var starts = 0;
        var ends = 0;
        await tester.pumpWidget(
          _viewportHost(
            _viewport(
              controller: controller,
              ids: ids,
              followLatest: false,
              initialAnchor: const ChatScrollAnchor(
                messageId: 'synthetic-1000',
                offsetWithinMessage: 0,
              ),
              estimateRowExtent: (_) => 100,
              rowBuilder: (_, index) {
                builds++;
                return SizedBox(height: index % 10 == 5 ? 3000 : 60);
              },
              onUserDragStart: () => starts++,
              onUserDragEnd: () => ends++,
            ),
            theme: ThemeData(
              scrollbarTheme: const ScrollbarThemeData(
                thumbVisibility: WidgetStatePropertyAll(true),
                thickness: WidgetStatePropertyAll(8),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _revealScrollbarByScrolling(tester, -60);
        starts = 0;
        ends = 0;
        final thumb = _paintedThumb(tester);
        final initialBuilds = builds;
        final gesture = await _startTrackedGesture(tester, thumb.center);
        await tester.pump(const Duration(milliseconds: 150));
        for (var i = 0; i < 10; i++) {
          await gesture.moveBy(const Offset(0, 20));
          await tester.pump(const Duration(milliseconds: 32));
        }
        await tester.pump(const Duration(milliseconds: 32));
        expect(_paintedThumb(tester).top - thumb.top, closeTo(200, 24));
        await gesture.up();
        await tester.pumpAndSettle();
        final anchor = controller.captureTopVisibleAnchor()!;
        final index = int.parse(anchor.messageId.split('-').last);
        expect(index, greaterThan(3000));
        expect(index, lessThan(8000));
        expect(builds - initialBuilds, lessThan(350));
        expect(starts, 1);
        expect(ends, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  _viewportTest('scrolling does not re-estimate the remaining history', (
    tester,
  ) async {
    final controller = _controller(tester);
    var estimates = 0;
    final ids = List.generate(10000, (index) => 'synthetic-$index');
    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: ids,
          followLatest: false,
          initialAnchor: const ChatScrollAnchor(
            messageId: 'synthetic-5000',
            offsetWithinMessage: 0,
          ),
          estimateRowExtent: (_) {
            estimates++;
            return 100;
          },
          rowBuilder: (_, index) => SizedBox(height: index.isEven ? 60 : 240),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final estimatesAtRest = estimates;
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    for (var frame = 0; frame < 60; frame++) {
      position.jumpTo(position.pixels - 80);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(estimates - estimatesAtRest, 0);
  });

  for (final direction in [-1, 1]) {
    _viewportTest(
      'scrollbar advances consistently in direction $direction past inaccurate row estimates',
      (tester) async {
        final controller = _controller(tester);
        final ids = List.generate(300, (index) => 'synthetic-$index');
        await tester.pumpWidget(
          _viewportHost(
            _viewport(
              controller: controller,
              ids: ids,
              initialAnchor: const ChatScrollAnchor(
                messageId: 'synthetic-100',
                offsetWithinMessage: 0,
              ),
              followLatest: false,
              estimateRowExtent: (_) => 100,
              rowBuilder: (_, index) => SizedBox(
                height: index % 10 == 5 ? 3000 : 60,
                child: Text('Synthetic row $index'),
              ),
            ),
            theme: ThemeData(
              scrollbarTheme: const ScrollbarThemeData(
                thumbVisibility: WidgetStatePropertyAll(true),
                thickness: WidgetStatePropertyAll(8),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final position = tester
            .state<ScrollableState>(find.byType(Scrollable))
            .position;
        var previous = _paintedThumb(tester).top;
        var reversals = 0;
        var largestReverse = 0.0;
        for (var frame = 0; frame < 180; frame++) {
          position.jumpTo(position.pixels + direction * 80);
          await tester.pump(const Duration(milliseconds: 16));
          final current = _paintedThumb(tester).top;
          if ((current - previous) * direction < -.25) {
            reversals++;
            if ((previous - current).abs() > largestReverse) {
              largestReverse = (previous - current).abs();
            }
          }
          previous = current;
        }
        expect(
          reversals,
          0,
          reason: 'Largest backwards thumb movement: $largestReverse px',
        );
      },
    );
  }

  _viewportTest(
    'platform scrollbars keep message metrics separate from pixel scrolling',
    (tester) async {
      final controller = _controller(tester);
      final ids = List<String>.generate(30, (index) => 'message-$index');
      addTearDown(PlatformUiCapabilities.resetDebugOverrides);

      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(
        _viewportHost(_viewport(controller: controller, ids: ids)),
      );
      await tester.pump();

      final scrollView = tester.widget<CustomScrollView>(
        find.byType(CustomScrollView),
      );
      final materialScrollbar = tester.widget<Scrollbar>(
        find.byType(Scrollbar),
      );
      expect(
        identical(materialScrollbar.controller, scrollView.controller),
        false,
      );
      expect(materialScrollbar.controller!.hasClients, isTrue);

      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      await tester.pumpWidget(
        _viewportHost(_viewport(controller: controller, ids: ids)),
      );
      await tester.pump();

      final cupertinoScrollbar = tester.widget<CupertinoScrollbar>(
        find.byType(CupertinoScrollbar),
      );
      final iosScrollView = tester.widget<CustomScrollView>(
        find.byType(CustomScrollView),
      );
      expect(
        identical(cupertinoScrollbar.controller, iosScrollView.controller),
        false,
      );
      expect(cupertinoScrollbar.controller!.hasClients, isTrue);
    },
  );

  _viewportTest('the scroll indicator shows for the user\'s scrolls only', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(30, (index) => 'message-$index');
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;

    await tester.pumpWidget(
      _viewportHost(_viewport(controller: controller, ids: ids)),
    );
    await tester.pumpAndSettle();
    final indicator = find.byType(CupertinoScrollbar);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;

    // The app's own move (pinning, following a reply) shows nothing. The
    // mapped scrollbar hears of content scrolling after layout, a frame late.
    position.jumpTo(position.pixels - 400);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(indicator, isNot(paints..rrect()));

    // A drag does, and the indicator fades once the scroll is at rest.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(indicator, paints..rrect());
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(indicator, isNot(paints..rrect()));
  });

  _viewportTest('scrollbar track is inset by the toolbar and composer', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(30, (index) => 'message-$index');
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;

    await tester.pumpWidget(
      _viewportHost(_viewport(controller: controller, ids: ids)),
    );
    await tester.pump();

    final scrollbarPadding = MediaQuery.paddingOf(
      tester.element(find.byType(Scrollbar)),
    );
    check(scrollbarPadding.top).equals(_topContentInset);
    check(scrollbarPadding.bottom).equals(80);
    final rowPadding = MediaQuery.paddingOf(
      tester.element(find.byType(CustomScrollView)),
    );
    check(rowPadding.bottom).equals(0);
  });

  _viewportTest('row extent estimates make the content extent exact before '
      'any row has been laid out', (tester) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(60, (index) => 'message-$index');
    // The tall row sits far above both the initial centre and the latest
    // window, so only the estimate can account for it before it is built.
    double heightOf(String id) => id == 'message-30' ? 3000 : 200;
    // Everything above the anchored latest row lives in the reverse sliver,
    // whose extent is the negative minimum scroll offset. The top clearance
    // cancels against the viewport anchor, so the rows alone remain.
    final olderRowsExtent = ids
        .take(ids.length - 1)
        .fold<double>(0, (sum, id) => sum + heightOf(id));
    final built = <String>{};

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: ids,
          followLatest: false,
          initialAnchor: const ChatScrollAnchor(
            messageId: 'message-59',
            offsetWithinMessage: 0,
          ),
          estimateRowExtent: (index) => heightOf(ids[index]),
          rowBuilder: (context, index) {
            final id = ids[index];
            built.add(id);
            return SizedBox(
              height: heightOf(id),
              child: Text(id, key: ValueKey<String>('label-$id')),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    check(built).not((it) => it.contains('message-30'));
    check(-position.minScrollExtent).isCloseTo(olderRowsExtent, 1);
  });

  test('row extent estimate grows with text, scale, and attachments', () {
    double estimate(String text, double width, {double scale = 1}) =>
        estimateChatRowExtent(
          text: text,
          viewportWidth: width,
          textScale: scale,
        );
    final short = estimate('hi', 400);
    final long = estimate('x' * 4000, 400);
    check(long).isGreaterThan(short);
    check(long).isGreaterThan(estimate('x' * 4000, 1200));
    check(estimate('x' * 4000, 400, scale: 2)).isGreaterThan(long);
    check(estimateChatRowExtent(text: '', viewportWidth: 400, imageCount: 1))
        .isGreaterThan(estimateChatRowExtent(text: '', viewportWidth: 400));
    check(estimateChatRowExtent(text: 'hi', viewportWidth: 400, isUser: true))
        .isLessThan(estimateChatRowExtent(text: 'hi', viewportWidth: 400));
  });

  test('row extent memory returns recorded heights and evicts oldest', () {
    final memory = ChatRowExtentMemory.instance;
    addTearDown(memory.debugClear);
    memory.debugClear();
    String key(int i) => ChatRowExtentMemory.keyFor(
      messageId: 'm$i',
      layoutSignature: 10,
      viewportWidth: 400,
      textScale: 1,
    );
    memory.record(key(0), 120);
    check(memory.lookup(key(0))).equals(120);
    check(
      memory.lookup(
        ChatRowExtentMemory.keyFor(
          messageId: 'm0',
          layoutSignature: 11,
          viewportWidth: 400,
          textScale: 1,
        ),
      ),
    ).isNull();
    for (var i = 1; i <= 2000; i += 1) {
      memory.record(key(i), i.toDouble());
    }
    check(memory.debugLength).equals(2000);
    check(memory.lookup(key(0))).isNull();
    check(memory.lookup(key(2000))).equals(2000);
  });

  _viewportTest('measured row heights are reported by source index', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(30, (index) => 'message-$index');
    final reported = <int, double>{};
    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: ids,
          rowHeight: (id) => id == 'message-29' ? 90 : 52,
          onRowExtentMeasured: (index, extent) => reported[index] = extent,
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(reported[29]).equals(90);
    check(reported[28]).equals(52);
  });

  _viewportTest('content extent stays exact once rows have been laid out', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(40, (index) => 'message-$index');
    double heightOf(String id) => id == 'message-20' ? 3000 : 40;
    final exactExtent =
        _topContentInset +
        ids.fold<double>(0, (sum, id) => sum + heightOf(id)) +
        80;
    // Same tree shape for both scales so the viewport state survives and the
    // remembered extents are cleared by the layout-input change, not by a
    // fresh state.
    Widget host(double scale) => _viewportHost(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: _viewport(
            controller: controller,
            ids: ids,
            followLatest: false,
            rowHeight: (id) => heightOf(id) * scale,
            rowRebuildKeys: List<Object?>.filled(ids.length, scale),
          ),
        ),
      ),
    );

    await tester.pumpWidget(host(1));
    await tester.pumpAndSettle();

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    double totalExtent() =>
        position.maxScrollExtent -
        position.minScrollExtent +
        position.viewportDimension;

    // Walk every row through the build window once.
    for (
      var offset = position.maxScrollExtent;
      offset > position.minScrollExtent;
      offset -= 400
    ) {
      position.jumpTo(offset);
      await tester.pump();
    }
    position.jumpTo(position.minScrollExtent);
    await tester.pump();

    // Park the build window inside the tall row, where the built-row average
    // used to inflate the estimate for every unbuilt row.
    position.jumpTo(
      position.minScrollExtent + _topContentInset + 20 * 40 + 1200,
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('label-message-20')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('label-message-0')), findsNothing);
    check(totalExtent()).isCloseTo(exactExtent, 1);

    // A text scale change rewraps rows, so remembered extents are dropped and
    // unbuilt rows are estimated from rows measured under the new scale.
    await tester.pumpWidget(host(2));
    await tester.pump();
    // Walk down from the top through the tall row so rows 0-20 are measured
    // at the new scale, then park inside the tall row. The trailing rows
    // were never rebuilt, so only the median of remeasured rows gives the
    // exact extent; stale scale-1 heights would fall short.
    position.jumpTo(position.minScrollExtent);
    await tester.pump();
    final parkInsideTallRow =
        position.minScrollExtent + _topContentInset + 20 * 80 + 1200;
    for (
      var offset = position.pixels;
      offset < parkInsideTallRow;
      offset += 400
    ) {
      position.jumpTo(offset);
      await tester.pump();
    }
    position.jumpTo(parkInsideTallRow);
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('label-message-20')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('label-message-21')),
      findsNothing,
    );
    // Measure from the tall row's real position: the sliver keeps stale
    // offsets for leading rows it never rebuilt, which is Flutter's own
    // imprecision and not what this estimate covers.
    final tallRowTop =
        tester
            .getTopLeft(find.byKey(const ValueKey<String>('label-message-20')))
            .dy -
        tester.getTopLeft(find.byType(CustomScrollView)).dy;
    final expected =
        position.pixels -
        position.minScrollExtent +
        tallRowTop +
        6000 +
        19 * 80 +
        80;
    check(totalExtent()).isCloseTo(expected, 1);
  });

  test(
    'viewport rejects simultaneous anchor maintenance and latest follow',
    () {
      final controller = ChatTimelineViewportController();
      addTearDown(controller.dispose);

      check(
        () => _viewport(
          controller: controller,
          ids: const <String>[],
          maintainVisibleAnchor: true,
          followLatest: true,
        ),
      ).throws<AssertionError>();
    },
  );

  _viewportTest('older center-sliver pages prepend without moving content', (
    tester,
  ) async {
    final controller = _controller(tester);
    var ids = List<String>.generate(50, (index) => 'message-${index + 50}');
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: ids,
              maintainVisibleAnchor: true,
              followLatest: false,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, 420),
      900,
    );
    await tester.pumpAndSettle();
    check(controller.distanceFromLatest).isGreaterThan(0);
    final anchor = controller.captureTopVisibleAnchor();
    check(anchor).isNotNull();
    final anchorId = anchor!.messageId;
    final before = controller.rowRect(anchorId)!.top;

    rebuild(() {
      ids = [...List<String>.generate(50, (index) => 'message-$index'), ...ids];
    });
    await tester.pump();
    await tester.pump();

    check(controller.rowRect(anchorId)!.top).isCloseTo(before, 1);
  });

  _viewportTest(
    'route transition transform outage preserves the visible anchor',
    (tester) async {
      final controller = _controller(tester);
      var ids = List<String>.generate(50, (index) => 'message-${index + 50}');
      var transformAvailable = true;
      final transformKey = GlobalKey();
      late StateSetter rebuild;

      await tester.pumpWidget(
        _viewportHost(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return _TransformAvailability(
                key: transformKey,
                available: transformAvailable,
                child: _viewport(
                  controller: controller,
                  ids: ids,
                  maintainVisibleAnchor: true,
                  followLatest: false,
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 420),
        900,
      );
      await tester.pumpAndSettle();
      final anchor = controller.captureTopVisibleAnchor();
      check(anchor).isNotNull();
      final anchorId = anchor!.messageId;
      final before = controller.rowRect(anchorId)!.top;

      rebuild(() {
        transformAvailable = false;
        ids = [
          ...List<String>.generate(50, (index) => 'message-$index'),
          ...ids,
        ];
      });
      await tester.pump(const Duration(), EnginePhase.build);
      final transform =
          transformKey.currentContext!.findRenderObject()
              as _RenderTransformAvailability;
      check(transform.unavailableSizeReads).isGreaterThan(0);
      check(transform.unavailableTransformReads).equals(0);
      check(tester.takeException()).isNull();

      // Let the deferred maintenance callbacks observe the unavailable
      // geometry. Recovery must resume them once the transform is valid.
      await tester.pump(const Duration(), EnginePhase.paint);
      check(transform.unavailableTransformReads).equals(0);
      check(tester.takeException()).isNull();

      rebuild(() => transformAvailable = true);
      await tester.pump();
      await tester.pump();

      check(tester.takeException()).isNull();
      check(controller.rowRect(anchorId)!.top).isCloseTo(before, 1);
    },
  );

  _viewportTest('oldest edge reserves the toolbar content inset', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(30, (index) => 'message-$index');

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: ids,
          initialAnchor: const ChatScrollAnchor(
            messageId: 'message-15',
            offsetWithinMessage: 0,
          ),
          followLatest: false,
          rowHeight: (_) => 64,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    scrollable.position.jumpTo(scrollable.position.minScrollExtent);
    await tester.pumpAndSettle();

    final metrics = controller.metrics!;
    check(metrics.pixels).isCloseTo(metrics.minScrollExtent, 1);
    final viewportTop = tester.getTopLeft(find.byType(CustomScrollView)).dy;
    check(controller.rowRect(ids.first)!.top)
        .isCloseTo(viewportTop + _topContentInset, 1);
  });

  _viewportTest('native iOS status-bar tap scrolls to the oldest row', (
    tester,
  ) async {
    final controller = _controller(tester);
    const ids = <String>['oldest-user', 'very-tall-assistant', 'latest-user'];
    var nativeScrollToTopCalls = 0;

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: ids,
          initialAnchor: const ChatScrollAnchor(
            messageId: 'latest-user',
            offsetWithinMessage: 0,
          ),
          followLatest: false,
          rowHeight: (id) => id == 'very-tall-assistant' ? 20000 : 64,
          onNativeScrollToTop: () async {
            nativeScrollToTopCalls += 1;
            await controller.animateToOldest(
              duration: const Duration(milliseconds: 500),
              curve: Curves.linearToEaseOut,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(controller.metrics!.pixels - controller.metrics!.minScrollExtent)
        .isGreaterThan(200);

    tester.simulateStatusBarTap();
    await tester.pumpAndSettle();

    check(nativeScrollToTopCalls).equals(1);
    final viewportTop = tester.getTopLeft(find.byType(CustomScrollView)).dy;
    check(controller.rowRect(ids.first)!.top)
        .isCloseTo(viewportTop + _topContentInset, 1);
  });

  for (final sidebarOpen in [false, true]) {
    _viewportTest(
      'status-bar tap leaves the chat to an open sidebar ($sidebarOpen)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final controller = _controller(tester);
        var nativeScrollToTopCalls = 0;
        await tester.pumpWidget(
          SidebarDrawerControllerScope(
            controller: _StubDrawerController(isOpen: sidebarOpen),
            child: _viewportHost(
              _viewport(
                controller: controller,
                ids: const ['oldest-user', 'latest-user'],
                onNativeScrollToTop: () async => nativeScrollToTopCalls += 1,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        tester.simulateStatusBarTap();
        await tester.pumpAndSettle();

        check(nativeScrollToTopCalls).equals(sidebarOpen ? 0 : 1);
      },
    );
  }

  _viewportTest('pinned prompt clears the toolbar without clipping glass', (
    tester,
  ) async {
    final controller = _controller(tester);

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: const ['history-user', 'history-assistant', 'user', 'assistant'],
          pinnedUserMessageId: 'user',
          pinAutomatic: true,
          followLatest: false,
          rowHeight: (_) => 64,
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(await controller.jumpMessageToTop('user')).isTrue();
    await tester.pump();

    final viewportTop = tester.getTopLeft(find.byType(CustomScrollView)).dy;
    check(controller.rowRect('user')!.top)
        .isCloseTo(viewportTop + _topContentInset, 1);
    check(controller.rowRect('history-assistant')!.bottom)
        .isLessOrEqual(controller.rowRect('user')!.top + 1);
    check(controller.rowRect('history-assistant')!.bottom)
        .isGreaterThan(viewportTop);
    check(
      find
          .byKey(const ValueKey<String>('chat-pinned-turn-top-clearance'))
          .evaluate(),
    ).isEmpty();
    check(
      find
          .byKey(const ValueKey<String>('chat-timeline-content-clip'))
          .evaluate(),
    ).isEmpty();
  });

  _viewportTest(
    'short turn cleanup cannot strand completed content under the toolbar',
    (tester) async {
      final providerContainer = ProviderContainer.test(
        overrides: [
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
          streamingHapticsEnabledProvider.overrideWithValue(false),
        ],
      );
      final controller = _controller(tester);
      const ids = ['history-user', 'history-assistant', 'user', 'assistant'];
      final historyAssistant = ChatMessage(
        id: 'history-assistant',
        role: 'assistant',
        content: 'Previous response content',
        timestamp: DateTime(2026),
        model: 'test-model',
        isStreaming: false,
        metadata: const {'responseDone': true},
      );
      String? pinnedUserMessageId = 'user';
      var pinAutomatic = true;
      late StateSetter rebuild;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: providerContainer,
          child: _viewportHost(
            StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return _viewport(
                  controller: controller,
                  ids: ids,
                  pinnedUserMessageId: pinnedUserMessageId,
                  pinAutomatic: pinAutomatic,
                  followLatest: false,
                  rowBuilder: (context, index) {
                    final id = ids[index];
                    if (id == 'history-assistant') {
                      return AssistantMessageWidget(
                        message: historyAssistant,
                        isStreaming: false,
                        showFollowUps: false,
                        animateOnMount: false,
                        suppressStreamingHaptics: true,
                        onDelete: () {},
                      );
                    }
                    return SizedBox(height: id.endsWith('user') ? 75 : 80);
                  },
                );
              },
            ),
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      check(await controller.jumpMessageToTop('user')).isTrue();
      await tester.pumpAndSettle();

      rebuild(() {
        pinnedUserMessageId = null;
        pinAutomatic = false;
      });
      await tester.pump();
      controller.jumpToLatest();
      await tester.pumpAndSettle();

      final viewportTop = tester.getTopLeft(find.byType(CustomScrollView)).dy;
      final contentRect = tester.getRect(
        find.text('Previous response content'),
      );
      check(contentRect.top)
          .isGreaterOrEqual(viewportTop + _topContentInset - 1);
      check(controller.distanceFromLatest).isLessThan(1);
    },
  );

  _viewportTest(
    'live footer is a separate sliver and cannot resize the assistant row',
    (tester) async {
      final controller = _controller(tester);
      var footerHeight = 28.0;
      var footerVisible = true;
      late StateSetter rebuild;

      await tester.pumpWidget(
        _viewportHost(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return _viewport(
                controller: controller,
                ids: const ['user', 'assistant'],
                followLatest: false,
                pinnedUserMessageId: 'user',
                pinAutomatic: true,
                liveFooter: footerVisible
                    ? SizedBox(
                        key: const ValueKey('live-footer'),
                        height: footerHeight,
                      )
                    : null,
                rowHeight: (id) => id == 'assistant' ? 80 : 52,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      check(await controller.jumpMessageToTop('user')).isTrue();
      await tester.pump();

      final assistantHeight = controller.rowRect('assistant')!.height;
      final promptTop = controller.rowRect('user')!.top;
      check(assistantHeight).isCloseTo(80, 0.1);
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('live-footer')),
          matching: find.byType(SliverToBoxAdapter),
        ),
        findsOneWidget,
      );

      rebuild(() => footerHeight = 60);
      await tester.pump();
      await tester.pump();
      check(controller.rowRect('assistant')!.height)
          .isCloseTo(assistantHeight, 0.1);
      check(controller.rowRect('user')!.top).isCloseTo(promptTop, 1);

      rebuild(() => footerVisible = false);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('live-footer')), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('chat-timeline-live-footer-sliver')),
        findsNothing,
      );
      check(controller.rowRect('assistant')!.height).isCloseTo(80, 0.1);
      check(controller.rowRect('user')!.top).isCloseTo(promptTop, 1);
    },
  );

  _viewportTest(
    'enabling free-scroll maintenance captures before same-frame insertion',
    (tester) async {
      final controller = _controller(tester);
      var ids = List<String>.generate(24, (index) => 'message-$index');
      var maintainVisibleAnchor = false;
      final mountCounts = <String, int>{};
      late StateSetter rebuild;

      await tester.pumpWidget(
        _viewportHost(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return _viewport(
                controller: controller,
                ids: ids,
                maintainVisibleAnchor: maintainVisibleAnchor,
                followLatest: false,
                rowBuilder: (context, index) => _MountedRowProbe(
                  messageId: ids[index],
                  onMounted: (id) => mountCounts.update(
                    id,
                    (count) => count + 1,
                    ifAbsent: () => 1,
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      check(await controller.jumpMessageToTop('message-16')).isTrue();
      await tester.pump();
      final before = controller.rowRect('message-16')!.top;

      rebuild(() {
        maintainVisibleAnchor = true;
        ids = [...ids.take(8), 'inserted-status', ...ids.skip(8)];
      });
      await tester.pump();
      await tester.pump();

      check(controller.rowRect('message-16')!.top).isCloseTo(before, 1);
      check(mountCounts['message-16']).equals(1);
    },
  );

  _viewportTest('timeline mutations rebuild only changed mounted rows', (
    tester,
  ) async {
    final controller = _controller(tester);
    var ids = List<String>.generate(18, (index) => 'message-$index');
    var rowRebuildKeys = List<Object?>.of(ids);
    final buildCounts = <String, int>{};
    late StateSetter rebuild;
    late final ChatTimelineRowBuilder rowBuilder;
    rowBuilder = (context, index) {
      final id = ids[index];
      buildCounts.update(id, (count) => count + 1, ifAbsent: () => 1);
      return SizedBox(height: 52, child: Text(id));
    };

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: ids,
              rowRebuildKeys: rowRebuildKeys,
              rowBuilder: rowBuilder,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final initialCounts = Map<String, int>.of(buildCounts);

    rebuild(() {
      ids = [...ids, 'message-18'];
      rowRebuildKeys = [...rowRebuildKeys, 'message-18'];
    });
    await tester.pumpAndSettle();

    for (final entry in initialCounts.entries) {
      check(buildCounts[entry.key]).equals(entry.value);
    }
    check(buildCounts['message-18']).equals(1);

    final beforeVersionChange = Map<String, int>.of(buildCounts);
    rebuild(() {
      rowRebuildKeys = [...rowRebuildKeys]..[17] = 'message-17-v2';
    });
    await tester.pump();

    check(buildCounts['message-17'])
        .equals(beforeVersionChange['message-17']! + 1);
    for (final id in ids.where((id) => id != 'message-17')) {
      check(buildCounts[id]).equals(beforeVersionChange[id]);
    }
  });

  _viewportTest('row builder changes invalidate cached rows', (tester) async {
    final controller = _controller(tester);
    const ids = ['message-0'];
    late StateSetter rebuild;
    ChatTimelineRowBuilder rowBuilder = (context, index) =>
        const SizedBox(height: 52, child: Text('version-1'));

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: ids,
              rowRebuildKeys: ids,
              rowBuilder: rowBuilder,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    check(find.text('version-1').evaluate()).length.equals(1);
    rebuild(() {
      rowBuilder = (context, index) =>
          const SizedBox(height: 52, child: Text('version-2'));
    });
    await tester.pump();

    check(find.text('version-1').evaluate()).isEmpty();
    check(find.text('version-2').evaluate()).length.equals(1);
  });

  _viewportTest('cached rows update inherited theme values', (tester) async {
    final controller = _controller(tester);
    const ids = ['message-0'];
    Widget rowBuilder(BuildContext context, int index) => SizedBox(
      height: 52,
      child: Text(
        'themed-row',
        style: TextStyle(color: Theme.of(context).colorScheme.primary),
      ),
    );

    Widget host(Color primary) => _viewportHost(
      _viewport(
        controller: controller,
        ids: ids,
        rowRebuildKeys: ids,
        rowBuilder: rowBuilder,
      ),
      theme: ThemeData(colorScheme: ColorScheme.light(primary: primary)),
    );

    await tester.pumpWidget(host(Colors.red));
    await tester.pumpAndSettle();
    check(tester.widget<Text>(find.text('themed-row')).style?.color)
        .equals(Colors.red);

    await tester.pumpWidget(host(Colors.blue));
    await tester.pumpAndSettle();

    check(tester.widget<Text>(find.text('themed-row')).style?.color)
        .equals(Colors.blue);
  });

  _viewportTest('viewport movement does not alter a free-scroll anchor', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(24, (index) => 'message-$index');
    var viewportTop = 0.0;
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Stack(
              children: [
                Positioned(
                  top: viewportTop,
                  left: 0,
                  right: 0,
                  height: 500,
                  child: _viewport(
                    controller: controller,
                    ids: ids,
                    maintainVisibleAnchor: true,
                    followLatest: false,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    check(await controller.jumpMessageToTop('message-16')).isTrue();
    await tester.pump();
    final viewportBefore = tester
        .getTopLeft(find.byType(ChatTimelineViewport))
        .dy;
    final relativeBefore =
        controller.rowRect('message-16')!.top -
        (viewportBefore + _topContentInset);

    rebuild(() => viewportTop = 40);
    await tester.pump();
    await tester.pump();

    final viewportAfter = tester
        .getTopLeft(find.byType(ChatTimelineViewport))
        .dy;
    final relativeAfter =
        controller.rowRect('message-16')!.top -
        (viewportAfter + _topContentInset);
    check(relativeAfter).isCloseTo(relativeBefore, 1);
  });

  _viewportTest('identical viewport metrics notify only once', (tester) async {
    final controller = _controller(tester);
    var callbacks = 0;

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: const ['message'],
          onMetricsChanged: (_) => callbacks += 1,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final settledCallbacks = callbacks;
    check(settledCallbacks).isGreaterThan(0);

    controller.requestLayoutMaintenance();
    await tester.pump();
    await tester.pump();

    check(callbacks).equals(settledCallbacks);
  });

  _viewportTest('growing live tail leaves a detached marker pixel-stable', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(24, (index) => 'message-$index');
    var tailHeight = 400.0;
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: ids,
              maintainVisibleAnchor: true,
              followLatest: false,
              rowHeight: (id) => id == ids.last ? tailHeight : 52,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(await controller.jumpMessageToTop('message-16')).isTrue();
    await tester.pump();
    final before = controller.rowRect('message-16')!.top;
    final viewportTop = tester.getTopLeft(find.byType(ChatTimelineViewport)).dy;
    check(before).isCloseTo(viewportTop + _topContentInset, 1);

    rebuild(() => tailHeight = 900);
    await tester.pump();
    await tester.pump();

    check(controller.rowRect(ids.last)!.height).isCloseTo(900, 1);
    check(controller.rowRect('message-16')!.top).isCloseTo(before, 1);
  });

  _viewportTest('anchor capture prefers the long row intersecting the inset', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(16, (index) => 'message-$index');

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: ids,
          initialAnchor: const ChatScrollAnchor(
            messageId: 'message-8',
            offsetWithinMessage: -600,
          ),
          followLatest: false,
          rowHeight: (id) => id == 'message-8' ? 720 : 52,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final anchor = controller.captureTopVisibleAnchor();
    final anchorChecks = check(anchor).isNotNull();
    anchorChecks
        .has((value) => value.messageId, 'messageId')
        .equals('message-8');
    final offsetChecks = anchorChecks.has(
      (value) => value.offsetWithinMessage,
      'offsetWithinMessage',
    );
    offsetChecks
      ..isGreaterThan(-605)
      ..isLessThan(-590);
  });

  _viewportTest(
    'real streaming assistant subscription leaves detached content stable',
    (tester) async {
      final providerContainer = ProviderContainer.test(
        overrides: [
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
          streamingHapticsEnabledProvider.overrideWithValue(false),
        ],
      );
      final controller = _controller(tester);
      final ids = [
        ...List<String>.generate(20, (index) => 'message-$index'),
        'assistant',
      ];
      var assistantMessage = ChatMessage(
        id: 'assistant',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2026),
        model: 'test-model',
        isStreaming: true,
      );
      late StateSetter rebuild;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: providerContainer,
          child: _viewportHost(
            StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return _viewport(
                  controller: controller,
                  ids: ids,
                  maintainVisibleAnchor: true,
                  followLatest: false,
                  rowBuilder: (context, index) {
                    final id = ids[index];
                    if (id != 'assistant') {
                      return const SizedBox(height: 52);
                    }
                    return AssistantMessageWidget(
                      message: assistantMessage,
                      isStreaming:
                          assistantMessage.metadata?['responseDone'] != true,
                      showFollowUps: false,
                      animateOnMount: false,
                      suppressStreamingHaptics: true,
                      onDelete: () {},
                    );
                  },
                );
              },
            ),
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      check(await controller.jumpMessageToTop('message-12')).isTrue();
      await tester.pump();
      final before = controller.rowRect('message-12')!.top;
      final assistantBefore = controller.rowRect('assistant')!.height;

      final streamedContent = List<String>.generate(
        160,
        (index) => 'Streaming line $index with enough text to wrap.',
      ).join('\n\n');
      providerContainer
          .read(streamingContentProvider.notifier)
          .set(streamedContent);
      await tester.pumpAndSettle();

      check(controller.rowRect('assistant')!.height)
          .isGreaterThan(assistantBefore);
      check(controller.rowRect('message-12')!.top).isCloseTo(before, 1);
      final streamingExtent = controller.rowRect('assistant')!.height;
      final completedContent =
          '$streamedContent\n\n${List<String>.generate(80, (index) => 'Completed line $index adds final rendered content.').join('\n\n')}';

      rebuild(() {
        assistantMessage = assistantMessage.copyWith(
          content: completedContent,
          isStreaming: false,
          metadata: const {'responseDone': true},
        );
      });
      await tester.pumpAndSettle();
      check(controller.rowRect('assistant')!.height)
          .isGreaterThan(streamingExtent);
      check(controller.rowRect('message-12')!.top).isCloseTo(before, 1);
    },
  );

  _viewportTest(
    'expansion and insertion above the visible anchor are corrected',
    (tester) async {
      final controller = _controller(tester);
      var ids = List<String>.generate(30, (index) => 'message-$index');
      var expandedHeight = 52.0;
      late StateSetter rebuild;

      await tester.pumpWidget(
        _viewportHost(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return _viewport(
                controller: controller,
                ids: ids,
                maintainVisibleAnchor: true,
                followLatest: false,
                rowHeight: (id) => id == 'message-8' ? expandedHeight : 52,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      check(await controller.jumpMessageToTop('message-18')).isTrue();
      await tester.pump();
      final before = controller.rowRect('message-18')!.top;

      rebuild(() => expandedHeight = 240);
      await tester.pump();
      await tester.pump();
      check(controller.rowRect('message-18')!.top).isCloseTo(before, 1);

      rebuild(() {
        ids = [...ids.take(12), 'tool-status', ...ids.skip(12)];
      });
      await tester.pump();
      await tester.pump();
      check(controller.rowRect('message-18')!.top).isCloseTo(before, 1);

      rebuild(() {
        ids = ids.where((id) => id != 'message-0').toList(growable: false);
      });
      await tester.pump();
      await tester.pump();
      check(controller.rowRect('message-18')!.top).isCloseTo(before, 1);
    },
  );

  _viewportTest('streamed row growth does not repeat pin maintenance', (
    tester,
  ) async {
    final controller = _controller(tester);
    const ids = ['user', 'tool', 'assistant'];
    final assistantHeight = ValueNotifier<double>(80);
    addTearDown(assistantHeight.dispose);
    var pinEndSpace = -1.0;
    String? pinnedUserMessageId = 'user';
    final reportedPinSpaces = <double>[];
    var metricsReportCount = 0;
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: ids,
              pinnedUserMessageId: pinnedUserMessageId,
              pinAutomatic: true,
              followLatest: false,
              onPinEndSpaceChanged: (value) {
                pinEndSpace = value;
                reportedPinSpaces.add(value);
              },
              onMetricsChanged: (_) => metricsReportCount += 1,
              rowBuilder: (context, index) {
                final id = ids[index];
                if (id == 'assistant') {
                  return ValueListenableBuilder<double>(
                    valueListenable: assistantHeight,
                    builder: (context, height, _) =>
                        SizedBox(height: height, child: Text(id)),
                  );
                }
                return SizedBox(
                  height: id == 'user' ? 64 : 48,
                  child: Text(id),
                );
              },
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(pinEndSpace).isGreaterThan(0);
    check(await controller.jumpMessageToTop('user')).isTrue();
    await tester.pumpAndSettle();
    final promptTop = controller.rowRect('user')!.top;
    final originalSpace = pinEndSpace;
    final initialReportCount = reportedPinSpaces.length;
    final initialMetricsReportCount = metricsReportCount;

    for (final height in <double>[120, 160, 200, 240]) {
      assistantHeight.value = height;
      await tester.pump();
      await tester.pump();
    }

    check(controller.rowRect('user')!.top).isCloseTo(promptTop, 1);
    check(pinEndSpace).equals(originalSpace);
    check(reportedPinSpaces.length).equals(initialReportCount);
    check(metricsReportCount).equals(initialMetricsReportCount);
    check(reportedPinSpaces).every((space) => space.isGreaterOrEqual(0));

    rebuild(() => pinnedUserMessageId = null);
    await tester.pump();
    await tester.pump();
    check(reportedPinSpaces.last).equals(0);
  });

  _viewportTest('pin space exhaustion never moves the prompt', (tester) async {
    final controller = _controller(tester);
    var assistantHeight = 80.0;
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: const ['user', 'assistant'],
              pinnedUserMessageId: 'user',
              pinAutomatic: true,
              followLatest: false,
              rowHeight: (id) => id == 'assistant' ? assistantHeight : 64,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(await controller.jumpMessageToTop('user')).isTrue();
    await tester.pump();
    final promptTop = controller.rowRect('user')!.top;

    for (final height in <double>[240, 480, 720, 960, 1200]) {
      rebuild(() => assistantHeight = height);
      await tester.pump();
      await tester.pump();
      check(controller.rowRect('user')!.top).isCloseTo(promptTop, 1);
    }
    check(controller.hasRealContentOverflow).isTrue();
  });

  _viewportTest(
    'short completion keeps the prompt pinned after automatic follow stops',
    (tester) async {
      final controller = _controller(tester);
      final ids = [
        ...List<String>.generate(12, (index) => 'history-$index'),
        'user',
        'assistant',
      ];
      var pinAutomatic = true;
      var maintainVisibleAnchor = false;
      late StateSetter rebuild;

      await tester.pumpWidget(
        _viewportHost(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return _viewport(
                controller: controller,
                ids: ids,
                pinnedUserMessageId: 'user',
                pinAutomatic: pinAutomatic,
                maintainVisibleAnchor: maintainVisibleAnchor,
                followLatest: false,
                rowHeight: (_) => 52,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      check(await controller.jumpMessageToTop('user')).isTrue();
      await tester.pumpAndSettle();
      final promptTop = controller.rowRect('user')!.top;

      rebuild(() {
        pinAutomatic = false;
        maintainVisibleAnchor = true;
      });
      await tester.pump();
      await tester.pump();

      check(controller.rowRect('user')!.top).isCloseTo(promptTop, 1);
      final spacer = tester.widget<SizedBox>(
        find.byKey(const ValueKey<String>('chat-composer-spacer')),
      );
      check(spacer.height!).isGreaterThan(80);
    },
  );

  _viewportTest(
    'established chat completion preserves the second prompt position',
    (tester) async {
      final controller = _controller(tester);
      var ids = List<String>.generate(12, (index) => 'history-$index');
      String? pinnedUserMessageId;
      var pinAutomatic = false;
      var maintainVisibleAnchor = false;
      var followLatest = true;
      var assistantHeight = 80.0;
      Widget? liveFooter;
      late StateSetter rebuild;

      await tester.pumpWidget(
        _viewportHost(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return _viewport(
                controller: controller,
                ids: ids,
                pinnedUserMessageId: pinnedUserMessageId,
                pinAutomatic: pinAutomatic,
                maintainVisibleAnchor: maintainVisibleAnchor,
                followLatest: followLatest,
                liveFooter: liveFooter,
                rowHeight: (id) => id == 'assistant' ? assistantHeight : 52,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      rebuild(() {
        ids = [...ids, 'user', 'assistant'];
        pinnedUserMessageId = 'user';
        pinAutomatic = true;
        followLatest = false;
        liveFooter = const SizedBox(height: 28);
      });
      await tester.pump();
      check(await controller.jumpMessageToTop('user')).isTrue();
      await tester.pumpAndSettle();

      rebuild(() => assistantHeight = 900);
      await tester.pump();
      await tester.pump();
      final promptTop = controller.rowRect('user')!.top;

      rebuild(() {
        pinnedUserMessageId = null;
        pinAutomatic = false;
        maintainVisibleAnchor = true;
        liveFooter = null;
      });
      await tester.pump();
      await tester.pump();

      check(controller.rowRect('user')!.top).isCloseTo(promptTop, 1);
      check(controller.distanceFromLatest).isGreaterThan(48);
    },
  );

  _viewportTest('missing pin geometry reports one terminal value', (
    tester,
  ) async {
    final controller = _controller(tester);
    final reportedPinSpaces = <double>[];

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: const ['assistant'],
          pinnedUserMessageId: 'missing-user',
          pinAutomatic: true,
          followLatest: false,
          onPinEndSpaceChanged: reportedPinSpaces.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    check(reportedPinSpaces).deepEquals([0]);
    controller.requestLayoutMaintenance();
    await tester.pumpAndSettle();
    check(reportedPinSpaces).deepEquals([0]);
  });

  _viewportTest('populated transcript keeps trailing notice in pin geometry', (
    tester,
  ) async {
    final controller = _controller(tester);
    var noticeHeight = 60.0;
    var pinEndSpace = 0.0;
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: const ['user', 'assistant'],
              pinnedUserMessageId: 'user',
              pinAutomatic: true,
              followLatest: false,
              trailingContent: SizedBox(
                key: const ValueKey('server-warning-slot'),
                height: noticeHeight,
              ),
              onPinEndSpaceChanged: (value) => pinEndSpace = value,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(find.byKey(const ValueKey('server-warning-slot')).evaluate()).length
        .equals(1);
    final originalSpace = pinEndSpace;

    rebuild(() => noticeHeight = 140);
    await tester.pump();
    await tester.pump();

    check(pinEndSpace).isCloseTo(originalSpace - 80, 1);
  });

  _viewportTest('later pin movement is monotonic and has no second settle', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = [
      ...List<String>.generate(18, (index) => 'history-$index'),
      'user',
      'assistant',
    ];

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: ids,
          pinnedUserMessageId: 'user',
          pinAutomatic: true,
          followLatest: false,
          rowHeight: (id) => id == 'assistant' ? 72 : 52,
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(await controller.jumpMessageToTop('history-8')).isTrue();
    await tester.pump();
    final positions = <double>[controller.rowRect('user')!.top];
    final navigation = controller.animateMessageToTop(
      'user',
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    for (var frame = 0; frame < 6; frame += 1) {
      await tester.pump(const Duration(milliseconds: 40));
      positions.add(controller.rowRect('user')!.top);
    }
    await tester.pumpAndSettle();
    await navigation;

    check(positions.last).isLessThan(positions.first - 1);
    for (var index = 1; index < positions.length; index += 1) {
      check(positions[index]).isLessOrEqual(positions[index - 1] + 0.5);
    }
    final settled = controller.rowRect('user')!.top;
    await tester.pump(const Duration(milliseconds: 250));
    check(controller.rowRect('user')!.top).isCloseTo(settled, 1);
  });

  _viewportTest(
    'latest action retires pin support and follows the real footer',
    (tester) async {
      final controller = _controller(tester);
      final ids = [
        ...List<String>.generate(18, (index) => 'history-$index'),
        'user',
        'assistant',
      ];
      String? pinnedUserMessageId = 'user';
      var pinAutomatic = true;
      var followLatest = false;
      var assistantHeight = 80.0;
      late StateSetter rebuild;

      await tester.pumpWidget(
        _viewportHost(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return _viewport(
                controller: controller,
                ids: ids,
                pinnedUserMessageId: pinnedUserMessageId,
                pinAutomatic: pinAutomatic,
                maintainVisibleAnchor: false,
                followLatest: followLatest,
                rowHeight: (id) => id == 'assistant' ? assistantHeight : 52,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      check(await controller.jumpMessageToTop('history-8')).isTrue();
      await tester.pump();

      final navigation = controller.animateMessageToTop(
        'user',
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      await tester.pumpAndSettle();
      check(await navigation).isTrue();

      final viewportTop = tester.getTopLeft(find.byType(CustomScrollView)).dy;
      final settledTop = controller.rowRect('user')!.top;
      check(settledTop).isCloseTo(viewportTop + _topContentInset, 1);
      check(controller.distanceFromMessageTop('user')!).isLessThan(1);

      rebuild(() {
        pinnedUserMessageId = null;
        pinAutomatic = false;
      });
      await tester.pump();
      await tester.pump();
      final spacer = tester.widget<SizedBox>(
        find.byKey(const ValueKey<String>('chat-composer-spacer')),
      );
      check(spacer.height).equals(80);

      final latestNavigation = controller.animateToLatest(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      await tester.pumpAndSettle();
      await latestNavigation;
      check(controller.distanceFromLatest).isLessThan(1);

      rebuild(() {
        followLatest = true;
        assistantHeight = 240;
      });
      await tester.pump();
      await tester.pump();
      check(controller.distanceFromLatest).isLessThan(1);
    },
  );

  _viewportTest('pinned latest distance follows the prompt target', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = <String>[
      'user',
      ...List<String>.generate(8, (index) => 'message-$index'),
    ];

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: ids,
          pinnedUserMessageId: 'user',
          pinAutomatic: true,
          followLatest: false,
          rowHeight: (_) => 64,
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(await controller.jumpMessageToTop('user')).isTrue();
    await tester.pump();
    check(controller.distanceFromMessageTop('user')!).isLessThan(1);

    check(await controller.jumpMessageToTop('message-5')).isTrue();
    await tester.pump();
    check(controller.distanceFromMessageTop('user')!).isGreaterThan(48);
  });

  _viewportTest('deep-history pin staging stays one viewport from latest', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(80, (index) => 'message-$index');

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: ids,
          initialAnchor: const ChatScrollAnchor(
            messageId: 'message-4',
            offsetWithinMessage: 0,
          ),
          followLatest: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    controller.prepositionOneViewportFromLatest();
    await tester.pump();
    await tester.pump();

    // A recenter reports its metrics a frame after it moves; the live
    // distance is current immediately.
    final metrics = controller.metrics!;
    check(
      controller.liveDistanceFromLatest,
    ).isCloseTo(metrics.viewportDimension, 1);
  });

  _viewportTest('pin staging from the oldest message builds a bounded set', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(10000, (index) => 'synthetic-$index');
    var builds = 0;

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: ids,
          followLatest: false,
          estimateRowExtent: (_) => 100,
          rowBuilder: (_, index) {
            builds++;
            return SizedBox(height: index % 10 == 5 ? 300 : 60);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final oldest = controller.jumpToOldest();
    await tester.pumpAndSettle();
    check(await oldest).isTrue();

    builds = 0;
    controller.prepositionOneViewportFromLatest();
    await tester.pumpAndSettle();

    check(builds).isLessThan(200);
    check(
      controller.liveDistanceFromLatest,
    ).isCloseTo(controller.metrics!.viewportDimension, 1);
  });

  _viewportTest('saved intra-row pixel anchor restores exactly', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(20, (index) => 'message-$index');

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: ids,
          initialAnchor: const ChatScrollAnchor(
            messageId: 'message-10',
            offsetWithinMessage: -23,
          ),
          followLatest: false,
          rowHeight: (_) => 96,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final viewportTop = tester.getTopLeft(find.byType(ChatTimelineViewport)).dy;
    check(
      controller.rowRect('message-10')!.top - (viewportTop + _topContentInset),
    ).isCloseTo(-23, 1);
  });

  _viewportTest(
    'saved anchor restores after its empty fallback becomes visible',
    (tester) async {
      final controller = _controller(tester);
      var ids = <String>[];
      late StateSetter rebuild;

      await tester.pumpWidget(
        _viewportHost(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return _viewport(
                controller: controller,
                ids: ids,
                initialAnchor: const ChatScrollAnchor(
                  messageId: 'message-10',
                  offsetWithinMessage: -18,
                ),
                followLatest: false,
                rowHeight: (_) => 96,
              );
            },
          ),
        ),
      );
      await tester.pump();
      check(_transcriptOpacity(tester)).equals(0);

      await _pumpSettleFrames(tester);
      check(_transcriptOpacity(tester)).equals(1);

      rebuild(() {
        ids = List<String>.generate(20, (index) => 'message-$index');
      });
      await tester.pumpAndSettle();

      final viewportTop = tester
          .getTopLeft(find.byType(ChatTimelineViewport))
          .dy;
      check(
        controller.rowRect('message-10')!.top -
            (viewportTop + _topContentInset),
      ).isCloseTo(-18, 1);
      check(_transcriptOpacity(tester)).equals(1);
    },
  );

  _viewportTest(
    'saved anchor eventually reveals a permanently empty transcript',
    (tester) async {
      final controller = _controller(tester);

      await tester.pumpWidget(
        _viewportHost(
          _viewport(
            controller: controller,
            ids: const [],
            initialAnchor: const ChatScrollAnchor(
              messageId: 'missing',
              offsetWithinMessage: 0,
            ),
            followLatest: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      check(_transcriptOpacity(tester)).equals(1);
    },
  );

  _viewportTest(
    'initially empty transcript settles at latest after late load',
    (tester) async {
      final controller = _controller(tester);
      var ids = <String>[];
      late StateSetter rebuild;

      await tester.pumpWidget(
        _viewportHost(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return _viewport(controller: controller, ids: ids);
            },
          ),
        ),
      );
      await _pumpSettleFrames(tester);

      rebuild(() {
        ids = List<String>.generate(30, (index) => 'message-$index');
      });
      await tester.pumpAndSettle();

      check(controller.distanceFromLatest).isCloseTo(0, 1);
    },
  );

  _viewportTest('center-row replacement preserves the visible pixel anchor', (
    tester,
  ) async {
    final controller = _controller(tester);
    var ids = List<String>.generate(20, (index) => 'message-$index');
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: ids,
              initialAnchor: const ChatScrollAnchor(
                messageId: 'message-10',
                offsetWithinMessage: 0,
              ),
              followLatest: false,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = controller.rowRect('message-11')!.top;

    rebuild(() {
      ids = ids.where((id) => id != 'message-10').toList(growable: false);
    });
    await tester.pump();
    await tester.pump();

    check(controller.visibleMessageIds).contains('message-11');
    check(controller.rowRect('message-11')!.top).isCloseTo(before, 1);
  });

  _viewportTest('message navigation seeks rows outside the render cache', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(120, (index) => 'message-$index');

    await tester.pumpWidget(
      _viewportHost(
        _viewport(controller: controller, ids: ids, followLatest: false),
      ),
    );
    await tester.pumpAndSettle();
    check(controller.rowRect('message-2')).isNull();

    final animated = controller.animateMessageToTop(
      'message-2',
      duration: const Duration(milliseconds: 1),
      curve: Curves.linear,
    );
    await tester.pumpAndSettle();
    check(await animated).isTrue();
    final viewportTop = tester.getTopLeft(find.byType(CustomScrollView)).dy;
    check(controller.rowRect('message-2')!.top)
        .isCloseTo(viewportTop + _topContentInset, 1);

    controller.jumpToLatest();
    await tester.pumpAndSettle();
    check(controller.rowRect('message-60')).isNull();
    final jumped = controller.jumpMessageToTop('message-60');
    await tester.pumpAndSettle();
    check(await jumped).isTrue();
    check(controller.rowRect('message-60')!.top)
        .isCloseTo(viewportTop + _topContentInset, 1);
  });

  _viewportTest('failed off-cache navigation restores its entry offset', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(2000, (index) => 'message-$index');

    await tester.pumpWidget(
      _viewportHost(_viewport(controller: controller, ids: ids)),
    );
    await tester.pumpAndSettle();
    final entryOffset = controller.metrics!.pixels;

    final navigation = controller.jumpMessageToTop('message-0');
    await tester.pumpAndSettle();

    check(await navigation).isFalse();
    check(controller.metrics!.pixels).isCloseTo(entryOffset, 1);
  });

  _viewportTest('pointer-down restores an interrupted off-cache seek', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(2000, (index) => 'message-$index');

    await tester.pumpWidget(
      _viewportHost(_viewport(controller: controller, ids: ids)),
    );
    await tester.pumpAndSettle();
    final entryOffset = controller.metrics!.pixels;

    final navigation = controller.jumpMessageToTop('message-0');
    await tester.pump();
    check(controller.isProgrammaticNavigationActive).isTrue();

    final gesture = await _startTrackedGesture(
      tester,
      tester.getCenter(find.byType(CustomScrollView)),
    );
    await tester.pump();

    check(controller.isProgrammaticNavigationActive).isFalse();
    check(controller.metrics!.pixels).isCloseTo(entryOffset, 1);
    await gesture.cancel();
    await tester.pumpAndSettle();
    check(await navigation).isFalse();
  });

  _viewportTest('explicit latest owns one animation and remains attached', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(30, (index) => 'message-$index');

    await tester.pumpWidget(
      _viewportHost(
        _viewport(controller: controller, ids: ids, followLatest: false),
      ),
    );
    await tester.pumpAndSettle();
    check(await controller.jumpMessageToTop('message-12')).isTrue();
    await tester.pump();
    final startingDistance = controller.distanceFromLatest;
    check(startingDistance).isGreaterThan(48);

    final navigation = controller.animateToLatest(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    var navigationDone = false;
    unawaited(navigation.then((_) => navigationDone = true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    check(controller.isProgrammaticNavigationActive).isTrue();
    final firstDistance = controller.distanceFromLatest;
    check(firstDistance).isLessThan(startingDistance);
    final supersedingNavigation = controller.animateToLatest(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    var supersedingNavigationDone = false;
    unawaited(
      supersedingNavigation.then((_) => supersedingNavigationDone = true),
    );
    await tester.pump();
    final supersedingDistances = <double>[controller.distanceFromLatest];
    for (var frame = 0; frame < 6; frame += 1) {
      await tester.pump(const Duration(milliseconds: 40));
      supersedingDistances.add(controller.distanceFromLatest);
    }
    for (var index = 1; index < supersedingDistances.length; index += 1) {
      check(supersedingDistances[index])
          .isLessOrEqual(supersedingDistances[index - 1] + 0.5);
    }
    check(supersedingDistances.first).isLessOrEqual(firstDistance);
    await tester.pumpAndSettle();
    await tester.pump();

    check(navigationDone).isTrue();
    check(supersedingNavigationDone).isTrue();
    check(controller.distanceFromLatest).isCloseTo(0, 1);
    check(controller.isProgrammaticNavigationActive).isFalse();
  });

  _viewportTest(
    'attached streaming growth keeps the live footer fixed in the growth frame',
    (tester) async {
      final controller = _controller(tester);
      var assistantHeight = 900.0;
      late StateSetter rebuild;

      await tester.pumpWidget(
        _viewportHost(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return _viewport(
                controller: controller,
                ids: const ['assistant'],
                followLatest: true,
                liveFooter: const SizedBox(
                  key: ValueKey<String>('live-footer-probe'),
                  height: 28,
                ),
                rowHeight: (_) => assistantHeight,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final footer = find.byKey(const ValueKey<String>('live-footer-probe'));
      final initialTop = tester.getTopLeft(footer).dy;
      for (var chunk = 0; chunk < 4; chunk += 1) {
        rebuild(() => assistantHeight += 48);
        await tester.pump();

        check(tester.getTopLeft(footer).dy).isCloseTo(initialTop, 1);
        check(controller.distanceFromLatest).isCloseTo(0, 1);
      }
    },
  );

  _viewportTest('a real drag cancels programmatic navigation', (tester) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(30, (index) => 'message-$index');
    var pointerDowns = 0;
    var dragStarts = 0;
    var dragEnds = 0;

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: ids,
          followLatest: false,
          onPointerDown: () => pointerDowns += 1,
          onUserDragStart: () => dragStarts += 1,
          onUserDragEnd: () => dragEnds += 1,
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(await controller.jumpMessageToTop('message-12')).isTrue();
    await tester.pump();

    final navigation = controller.animateToLatest(
      duration: const Duration(seconds: 1),
      curve: Curves.linear,
    );
    var navigationDone = false;
    unawaited(navigation.then((_) => navigationDone = true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    check(controller.isProgrammaticNavigationActive).isTrue();

    final gesture = await _startTrackedGesture(
      tester,
      tester.getCenter(find.byType(CustomScrollView)),
    );
    await gesture.moveBy(const Offset(0, -32));
    await tester.pump();
    check(controller.isProgrammaticNavigationActive).isFalse();
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    check(navigationDone).isTrue();
    check(pointerDowns).equals(1);
    check(dragStarts).equals(1);
    check(dragEnds).equals(1);
  });

  _viewportTest('pointer-signal scrolling claims manual ownership', (
    tester,
  ) async {
    final controller = _controller(tester);
    final ids = List<String>.generate(30, (index) => 'message-$index');
    var followLatest = true;
    var dragStarts = 0;
    var dragEnds = 0;
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: ids,
              followLatest: followLatest,
              onUserDragStart: () {
                dragStarts += 1;
                rebuild(() => followLatest = false);
              },
              onUserDragEnd: () => dragEnds += 1,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(CustomScrollView)),
        scrollDelta: const Offset(0, -120),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    check(dragStarts).equals(1);
    check(dragEnds).equals(1);
    check(followLatest).isFalse();
    check(controller.distanceFromLatest).isGreaterThan(48);

    final navigation = controller.animateToLatest(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    await tester.pumpAndSettle();
    await navigation;
    check(dragStarts).equals(1);
  });

  _viewportTest('initial settlement is excluded from paint and interaction', (
    tester,
  ) async {
    final controller = _controller(tester);
    var hidden = true;
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: const ['user', 'assistant'],
              hideUntilSettled: hidden,
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    check(_transcriptOpacity(tester)).equals(0);
    final interaction = find.byKey(
      const ValueKey<String>('sliver-transcript-interaction'),
    );
    check(tester.widget<IgnorePointer>(interaction).ignoring).isTrue();

    rebuild(() => hidden = false);
    await tester.pump();
    check(_transcriptOpacity(tester)).equals(1);
    check(tester.widget<IgnorePointer>(interaction).ignoring).isFalse();
  });

  _viewportTest('composer padding alone is not real transcript overflow', (
    tester,
  ) async {
    final controller = _controller(tester);

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: const ['message'],
          // 32 (top inset) + 540 fits in 600; the 80px composer padding is
          // the only reason the scrollable exceeds the viewport.
          rowHeight: (_) => 540,
        ),
      ),
    );
    await tester.pumpAndSettle();

    check(controller.hasRealContentOverflow).isFalse();
  });

  _viewportTest('content taller than the viewport is real overflow', (
    tester,
  ) async {
    final controller = _controller(tester);

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: const ['message'],
          rowHeight: (_) => 900,
        ),
      ),
    );
    await tester.pumpAndSettle();

    check(controller.hasRealContentOverflow).isTrue();
  });

  _viewportTest(
    'trailing refresh needs a past-threshold drag and fires once per drag',
    (tester) async {
      final controller = _controller(tester);
      var refreshes = 0;

      await tester.pumpWidget(
        _viewportHost(
          _viewport(
            controller: controller,
            ids: const ['message'],
            onTrailingRefresh: () async {
              refreshes += 1;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Leave enough margin that touch slop or pixel rounding cannot turn this
      // into an accidental threshold-boundary test.
      const belowThreshold = debugChatTimelineTrailingRefreshThreshold - 12;
      const aboveThreshold = debugChatTimelineTrailingRefreshThreshold + 24;
      await tester.drag(
        find.byType(CustomScrollView),
        const Offset(0, -belowThreshold),
        touchSlopY: 0,
      );
      await tester.pumpAndSettle();
      check(refreshes).equals(0);

      await tester.drag(
        find.byType(CustomScrollView),
        const Offset(0, -aboveThreshold),
        touchSlopY: 0,
      );
      await tester.pumpAndSettle();
      check(refreshes).equals(1);

      await tester.drag(
        find.byType(CustomScrollView),
        const Offset(0, -aboveThreshold),
        touchSlopY: 0,
      );
      await tester.pumpAndSettle();
      check(refreshes).equals(2);
    },
  );

  _viewportTest('trailing refresh subtracts reversed overscroll', (
    tester,
  ) async {
    final controller = _controller(tester);
    var refreshes = 0;

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: const ['message'],
          onTrailingRefresh: () async {
            refreshes += 1;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await _startTrackedGesture(
      tester,
      tester.getCenter(find.byType(CustomScrollView)),
    );
    const belowThreshold = debugChatTimelineTrailingRefreshThreshold - 12;
    const reversingDrag = debugChatTimelineTrailingRefreshThreshold + 8;
    // The reversal overshoots past zero, so accumulated progress must clamp at
    // zero; the final remaining drag then crosses the threshold with margin.
    const remainingThresholdDrag =
        debugChatTimelineTrailingRefreshThreshold - belowThreshold + 8;
    await gesture.moveBy(const Offset(0, -belowThreshold));
    await tester.pump();
    await gesture.moveBy(const Offset(0, reversingDrag));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -belowThreshold));
    await tester.pump();
    check(refreshes).equals(0);

    await gesture.moveBy(const Offset(0, -remainingThresholdDrag));
    await tester.pump();
    check(refreshes).equals(1);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  _viewportTest('refresh completion cannot re-arm the active drag', (
    tester,
  ) async {
    final controller = _controller(tester);
    var refreshes = 0;
    var completion = Completer<void>();

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: const ['message'],
          onTrailingRefresh: () {
            refreshes += 1;
            return completion.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await _startTrackedGesture(
      tester,
      tester.getCenter(find.byType(CustomScrollView)),
    );
    await gesture.moveBy(
      const Offset(0, -(debugChatTimelineTrailingRefreshThreshold + 88)),
    );
    await tester.pump();
    check(refreshes).equals(1);

    completion.complete();
    await tester.pump();
    await gesture.moveBy(
      const Offset(0, -(debugChatTimelineTrailingRefreshThreshold + 28)),
    );
    await tester.pump();
    check(refreshes).equals(1);
    await gesture.up();
    await tester.pumpAndSettle();

    completion = Completer<void>();
    await tester.drag(
      find.byType(CustomScrollView),
      const Offset(0, -(debugChatTimelineTrailingRefreshThreshold + 24)),
      touchSlopY: 0,
    );
    await tester.pump();
    completion.complete();
    check(refreshes).equals(2);
    await tester.pumpAndSettle();
  });

  _viewportTest('synchronous refresh failures clear and can retry', (
    tester,
  ) async {
    final controller = _controller(tester);
    var refreshes = 0;

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: const ['message'],
          onTrailingRefresh: () {
            refreshes += 1;
            throw StateError('synchronous refresh failure');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (
      var expectedRefreshes = 1;
      expectedRefreshes <= 2;
      expectedRefreshes++
    ) {
      await tester.drag(
        find.byType(CustomScrollView),
        const Offset(0, -(debugChatTimelineTrailingRefreshThreshold + 24)),
        touchSlopY: 0,
      );
      await tester.pumpAndSettle();
      check(refreshes).equals(expectedRefreshes);
      check(tester.takeException()).isNull();
      check(find.byType(CircularProgressIndicator).evaluate()).isEmpty();
    }
  });

  _viewportTest('owner change removes an active trailing refresh indicator', (
    tester,
  ) async {
    final controller = _controller(tester);
    final completion = Completer<void>();
    var ownerGeneration = 1;
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: const ['message'],
              ownerGeneration: ownerGeneration,
              onTrailingRefresh: () => completion.future,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(
      find.byType(CustomScrollView),
      const Offset(0, -(debugChatTimelineTrailingRefreshThreshold + 24)),
      touchSlopY: 0,
    );
    await tester.pump();
    check(find.byType(CircularProgressIndicator).evaluate()).length.equals(1);

    rebuild(() => ownerGeneration = 2);
    await tester.pump();
    check(find.byType(CircularProgressIndicator).evaluate()).isEmpty();

    completion.complete();
    await tester.pumpAndSettle();
    check(find.byType(CircularProgressIndicator).evaluate()).isEmpty();
  });

  _viewportTest('owner generation change cancels stale navigation', (
    tester,
  ) async {
    final controller = _controller(tester);
    var ownerGeneration = 1;
    var ids = List<String>.generate(30, (index) => 'old-$index');
    late StateSetter rebuild;

    await tester.pumpWidget(
      _viewportHost(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _viewport(
              controller: controller,
              ids: ids,
              ownerGeneration: ownerGeneration,
              followLatest: false,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(await controller.jumpMessageToTop('old-12')).isTrue();
    await tester.pump();

    var staleNavigationCompleted = false;
    unawaited(
      controller
          .animateToLatest(
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOutCubic,
          )
          .then((_) => staleNavigationCompleted = true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    check(controller.isProgrammaticNavigationActive).isTrue();

    rebuild(() {
      ownerGeneration = 2;
      ids = List<String>.generate(16, (index) => 'replacement-$index');
    });
    await tester.pump();
    await tester.pumpAndSettle();

    check(staleNavigationCompleted).isTrue();
    check(controller.isProgrammaticNavigationActive).isFalse();
    check(controller.distanceFromLatest).isCloseTo(0, 1);
    check(controller.visibleMessageIds.where((id) => id.startsWith('old-')))
        .isEmpty();
    check(controller.visibleMessageIds).isNotEmpty();
  });

  _viewportTest('controller dispose permanently fences later commands', (
    tester,
  ) async {
    final controller = ChatTimelineViewportController();
    var disposed = false;
    void disposeOnce() {
      if (disposed) return;
      disposed = true;
      controller.dispose();
    }

    addTearDown(disposeOnce);

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: List<String>.generate(20, (index) => 'message-$index'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    check(controller.isAttached).isTrue();

    disposeOnce();
    check(controller.isAttached).isFalse();
    check(await controller.jumpMessageToTop('message-10')).isFalse();

    await tester.pump();
    check(controller.isAttached).isFalse();
    check(await controller.jumpMessageToTop('message-10')).isFalse();
  });

  _viewportTest('duplicate message IDs collapse to their first source index', (
    tester,
  ) async {
    final controller = _controller(tester);
    const ids = ['first', 'duplicate', 'duplicate', 'last'];

    await tester.pumpWidget(
      _viewportHost(
        _viewport(
          controller: controller,
          ids: ids,
          rowBuilder: (context, index) =>
              SizedBox(height: 52, child: Text('source-$index')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    check(find.text('source-0').evaluate().length).equals(1);
    check(find.text('source-1').evaluate().length).equals(1);
    // The later duplicate is intentionally omitted from the rendered timeline.
    check(find.text('source-2').evaluate()).isEmpty();
    check(find.text('source-3').evaluate().length).equals(1);
    check(controller.visibleMessageIds)
        .deepEquals(['first', 'duplicate', 'last']);
  });
}

Widget _viewportHost(
  Widget child, {
  ThemeData? theme,
  Iterable<LocalizationsDelegate<dynamic>>? localizationsDelegates,
  Iterable<Locale> supportedLocales = const <Locale>[Locale('en', 'US')],
}) {
  return MaterialApp(
    theme: theme,
    localizationsDelegates: localizationsDelegates,
    supportedLocales: supportedLocales,
    home: Scaffold(body: SizedBox.expand(child: child)),
  );
}

Widget _viewport({
  required ChatTimelineViewportController controller,
  required List<String> ids,
  int ownerGeneration = 1,
  ChatScrollAnchor? initialAnchor,
  String? pinnedUserMessageId,
  bool pinAutomatic = false,
  bool maintainVisibleAnchor = false,
  // Defaults to the inverse so free-scroll anchor maintenance and automatic
  // latest ownership remain mutually exclusive in tests, as in ChatPage.
  bool? followLatest,
  Widget? liveFooter,
  Widget? trailingContent,
  bool hideUntilSettled = false,
  double Function(String id)? rowHeight,
  double? Function(int index)? estimateRowExtent,
  void Function(int index, double extent)? onRowExtentMeasured,
  ChatTimelineRowBuilder? rowBuilder,
  List<Object?> rowRebuildKeys = const <Object?>[],
  ValueChanged<ChatTimelineViewportMetrics>? onMetricsChanged,
  ValueChanged<double>? onPinEndSpaceChanged,
  Future<void> Function()? onTrailingRefresh,
  Future<void> Function()? onNativeScrollToTop,
  VoidCallback? onPointerDown,
  VoidCallback? onUserDragStart,
  VoidCallback? onUserDragEnd,
}) {
  return ChatTimelineViewport(
    controller: controller,
    ownerGeneration: ownerGeneration,
    messageIds: ids,
    rowRebuildKeys: rowRebuildKeys,
    estimateRowExtent: estimateRowExtent,
    onRowExtentMeasured: onRowExtentMeasured,
    initialAnchor: initialAnchor,
    pinnedUserMessageId: pinnedUserMessageId,
    liveFooter: liveFooter,
    trailingContent: trailingContent,
    topContentInset: _topContentInset,
    bottomPadding: 80,
    horizontalPadding: 16,
    cacheExtent: 600,
    physics: const AlwaysScrollableScrollPhysics(),
    maintainVisibleAnchor: maintainVisibleAnchor,
    followLatest: followLatest ?? !maintainVisibleAnchor,
    pinAutomatic: pinAutomatic,
    hideUntilSettled: hideUntilSettled,
    onPointerDown: onPointerDown ?? () {},
    onUserDragStart: onUserDragStart ?? () {},
    onUserDragEnd: onUserDragEnd ?? () {},
    onMetricsChanged: onMetricsChanged ?? (_) {},
    onPinEndSpaceChanged: onPinEndSpaceChanged ?? (_) {},
    onTrailingRefresh: onTrailingRefresh ?? () async {},
    onNativeScrollToTop: onNativeScrollToTop ?? () async {},
    rowBuilder:
        rowBuilder ??
        (context, index) {
          final id = ids[index];
          return SizedBox(
            height: rowHeight?.call(id) ?? 52,
            child: Text(id, key: ValueKey<String>('label-$id')),
          );
        },
  );
}

class _StubDrawerController implements SidebarDrawerController {
  _StubDrawerController({required this.isOpen});

  @override
  final bool isOpen;

  @override
  void open({double velocity = 0.0}) {}

  @override
  void close({double velocity = 0.0}) {}

  @override
  void toggle() {}
}
