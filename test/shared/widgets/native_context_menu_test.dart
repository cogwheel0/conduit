import 'package:conduit/core/services/ios_native_dropdown_bridge.dart';

import 'dart:async';
import 'dart:ui' as ui;

import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _text = 'Amber tiles stay in these same lines. ';
final _longText = List.filled(60, _text).join();
const _viewportKey = Key('message-viewport');
const _captureKey = Key('viewport-capture');
final _focusBarrier = find.byWidgetPredicate(
  (widget) => widget is ModalBarrier && widget.color == const Color(0x33000000),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final text in [_text, _longText]) {
    testWidgets(
      'native menu captures clean preview without reflow: ${text == _text ? 'regular' : 'taller than viewport'}',
      (tester) async {
        final fixture = _MenuFixture();
        addTearDown(fixture.dispose);
        final controller = ScrollController();
        addTearDown(controller.dispose);
        var copies = 0;
        await tester.pumpWidget(
          _harness(controller, () => copies++, text: text),
        );
        await tester.pumpAndSettle();
        if (text == _longText) controller.jumpTo(300);
        await tester.pump();
        final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
        List<Rect> lines() => paragraph
            .getBoxesForSelection(
              TextSelection(baseOffset: 0, extentOffset: text.length),
            )
            .map((box) => box.toRect())
            .toList();
        final original = lines();
        final viewport = tester.getRect(find.byKey(_viewportKey));
        final bubble = tester.getRect(find.byType(NativeContextMenu));
        if (text == _longText) {
          expect(bubble.top, lessThan(viewport.top));
          expect(bubble.bottom, greaterThan(viewport.bottom));
        }
        final visible = bubble.intersect(viewport);
        final sample = Offset(bubble.left + 1, visible.center.dy);
        final originalPixel = await _viewportPixel(tester, sample);
        final scrollOffset = controller.offset;
        final gesture = await tester.startGesture(visible.center);
        await tester.pump();
        final args = await _waitForMenu(tester, fixture);
        final request = args[1]! as PlatformDropdownRequest;
        final rect = request.sourceRect!;
        expect(rect.height, lessThanOrEqualTo(240));
        expect(request.options.single.sfSymbol, 'doc.on.doc');
        final png = args[2]! as Uint8List;
        expect(png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
        final header = ByteData.sublistView(png);
        expect(header.getUint32(20), lessThanOrEqualTo(240 * 3));
        final selectedPixel = await tester.runAsync(() async {
          final codec = await ui.instantiateImageCodec(png);
          final frame = await codec.getNextFrame();
          try {
            final ratio = frame.image.width / rect.width;
            return await _pixel(
              frame.image,
              (sample - Offset(rect.x, rect.y)) * ratio,
            );
          } finally {
            frame.image.dispose();
            codec.dispose();
          }
        });
        expect(selectedPixel, originalPixel);
        expect(_focusBarrier, findsOneWidget);
        expect(tester.getRect(find.byType(RawImage)), visible);
        expect(fixture.haptics, ['HapticFeedbackType.heavyImpact']);
        expect(lines(), original);
        expect(tester.getRect(find.byType(NativeContextMenu)), bubble);
        fixture.selection.complete('0');
        await tester.pumpAndSettle();
        expect(copies, 1);
        expect(_focusBarrier, findsNothing);
        expect(await _viewportPixel(tester, sample), originalPixel);
        expect(lines(), original);
        expect(controller.offset, scrollOffset);
        await gesture.up();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testWidgets('a long preview excludes the floating composer', (tester) async {
    final fixture = _MenuFixture();
    addTearDown(fixture.dispose);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(controller, () {}, obscuredBottom: 80));
    await tester.pumpAndSettle();
    controller.jumpTo(300);
    await tester.pump();
    final viewport = tester.getRect(find.byKey(_viewportKey));
    final gesture = await tester.startGesture(
      viewport.topLeft + const Offset(100, 80),
    );
    final args = await _waitForMenu(tester, fixture);
    final source = (args[1]! as PlatformDropdownRequest).sourceRect!;
    expect(source.y + source.height, lessThanOrEqualTo(viewport.bottom - 80));
    expect(tester.getRect(find.byType(RawImage)).bottom, viewport.bottom - 80);
    fixture.selection.complete(null);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final panelHeight in [52.0, 180.0]) {
    testWidgets('preview excludes the measured voice panel at $panelHeight', (
      tester,
    ) async {
      final fixture = _MenuFixture();
      addTearDown(fixture.dispose);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _harness(
          controller,
          () {},
          obscuredBottom: 20,
          voicePanelHeight: panelHeight,
          bottomOverlay: GlobalKey(),
        ),
      );
      await tester.pumpAndSettle();
      controller.jumpTo(300);
      await tester.pump();
      final viewport = tester.getRect(find.byKey(_viewportKey));
      final gesture = await tester.startGesture(
        viewport.topLeft + const Offset(80, 20),
      );
      final args = await _waitForMenu(tester, fixture);
      final source = (args[1]! as PlatformDropdownRequest).sourceRect!;
      expect(source.y + source.height, viewport.bottom - 20 - panelHeight);
      fixture.selection.complete(null);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('initialization coalesces in flight but rechecks a later host', (
    tester,
  ) async {
    final fixture = _MenuFixture();
    addTearDown(fixture.dispose);
    final bridge = IosNativeDropdownBridge.instance;
    final first = bridge.initializeContextMenu();
    final second = bridge.initializeContextMenu();
    expect(identical(first, second), isTrue);
    expect(await first, isTrue);
    expect(fixture.initializations, 1);
    expect(await bridge.initializeContextMenu(), isTrue);
    expect(fixture.initializations, 2);
  });

  testWidgets('menu presentation and dismissal leave source pixels unchanged', (
    tester,
  ) async {
    final fixture = _MenuFixture();
    addTearDown(fixture.dispose);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(controller, () {}, text: _text));
    await tester.pumpAndSettle();
    final bubble = tester.getRect(find.byType(NativeContextMenu));
    final sample = Offset(bubble.left + 1, bubble.center.dy);
    final original = await _viewportPixel(tester, sample);
    final gesture = await tester.startGesture(bubble.center);
    await _waitForMenu(tester, fixture);
    expect(await _viewportPixel(tester, sample), original);
    expect(_focusBarrier, findsOneWidget);
    fixture.selection.complete(null);
    await tester.pumpAndSettle();
    expect(_focusBarrier, findsNothing);
    expect(await _viewportPixel(tester, sample), original);
    await gesture.up();
  });

  testWidgets('a quick tap and a scroll keep their normal behavior', (
    tester,
  ) async {
    final fixture = _MenuFixture();
    addTearDown(fixture.dispose);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var copies = 0;
    await tester.pumpWidget(_harness(controller, () => copies++));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(find.byKey(_viewportKey)));
    await tester.pump();
    expect(fixture.prepared.isCompleted, isFalse);
    await tester.drag(find.byKey(_viewportKey), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
    expect(copies, 0);
    expect(fixture.haptics, isEmpty);
    expect(fixture.cancellations, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'a disposed message dismisses its menu and ignores a late selection',
    (tester) async {
      final fixture = _MenuFixture();
      addTearDown(fixture.dispose);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      var copies = 0;
      await tester.pumpWidget(_harness(controller, () => copies++));
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(_viewportKey)),
      );
      await tester.pump();
      final request = await _waitForMenu(tester, fixture);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.selection.complete('0');
      await tester.pumpAndSettle();
      expect(
        fixture.cancellations.any((args) => args[0] == request[0]),
        isTrue,
      );
      expect(copies, 0);
      await gesture.up();
    },
  );

  testWidgets('an unavailable native interaction retains the existing menu', (
    tester,
  ) async {
    final fixture = _MenuFixture(available: false);
    addTearDown(fixture.dispose);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(controller, () {}));
    await tester.pumpAndSettle();
    expect(find.text('Fallback menu'), findsOneWidget);
    expect(fixture.prepared.isCompleted, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('native presentation failure activates the existing fallback', (tester) async {
    final fixture = _MenuFixture(failPresentation: true);
    addTearDown(fixture.dispose);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(controller, () {}, text: _text));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(tester.getCenter(find.byType(NativeContextMenu)));
    await _waitForMenu(tester, fixture);
    await tester.pumpAndSettle();
    expect(find.text('Fallback menu'), findsOneWidget);
    expect(_focusBarrier, findsNothing);
    await gesture.up();
  });

  testWidgets('message actions are available to accessibility', (tester) async {
    final fixture = _MenuFixture();
    addTearDown(fixture.dispose);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final semantics = tester.ensureSemantics();

    try {
      var copies = 0;
      await tester.pumpWidget(_harness(controller, () => copies++));
      await tester.pumpAndSettle();
      final node = tester.getSemantics(find.byType(NativeContextMenu));
      final id = node.getSemanticsData().customSemanticsActionIds!.single;
      node.owner!.performAction(node.id, SemanticsAction.customAction, id);
      await tester.pump();
      expect(copies, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    } finally {
      semantics.dispose();
    }
  });
}

Future<List<Object?>> _waitForMenu(
  WidgetTester tester,
  _MenuFixture fixture,
) async {
  await tester.pump(const Duration(milliseconds: 600));
  final elapsed = Stopwatch()..start();
  while (!fixture.prepared.isCompleted &&
      elapsed.elapsed < const Duration(seconds: 5)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump(const Duration(milliseconds: 1));
  }
  expect(fixture.prepared.isCompleted, isTrue);
  return fixture.prepared.future;
}

Future<Color> _viewportPixel(WidgetTester tester, Offset position) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      return await _pixel(image, boundary.globalToLocal(position));
    } finally {
      image.dispose();
    }
  }))!;
}

Future<Color> _pixel(ui.Image image, Offset position) async {
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final offset = (position.dy.floor() * image.width + position.dx.floor()) * 4;
  return Color.fromARGB(
    bytes.getUint8(offset + 3),
    bytes.getUint8(offset),
    bytes.getUint8(offset + 1),
    bytes.getUint8(offset + 2),
  );
}

Widget _harness(
  ScrollController controller,
  VoidCallback onCopy, {
  String? text,
  double obscuredBottom = 0,
  GlobalKey? bottomOverlay,
  double voicePanelHeight = 0,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: RepaintBoundary(
        key: _captureKey,
        child: SizedBox(
          key: _viewportKey,
          width: 260,
          height: 240,
          child: Stack(
            children: [
              Positioned.fill(
                child: NativeContextMenuViewport(
                  padding: EdgeInsets.only(bottom: obscuredBottom),
                  bottomOverlay: bottomOverlay,
                  child: ListView(
                    controller: controller,
                    children: [
                      NativeContextMenu(
                        actions: [
                          AdaptiveContextMenuAction(
                            title: 'Copy',
                            iosSymbol: 'doc.on.doc',
                            onPressed: onCopy,
                          ),
                        ],
                        fallbackBuilder: (_) => const Text('Fallback menu'),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          color: Colors.blue,
                          child: Text(
                            text ?? _longText,
                            style: const TextStyle(fontSize: 18),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (obscuredBottom + voicePanelHeight > 0)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: obscuredBottom + voicePanelHeight,
                  child: ColoredBox(key: bottomOverlay, color: Colors.grey),
                ),
            ],
          ),
        ),
      ),
    ),
  ),
);

class _MenuFixture {
  final prepared = Completer<List<Object?>>();
  final selection = Completer<String?>();
  final cancellations = <List<Object?>>[];
  final haptics = <Object?>[];
  int initializations = 0;
  final _messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final _channels = <BasicMessageChannel<Object?>>[];

  _MenuFixture({bool available = true, bool failPresentation = false}) {
    _messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments);
      return null;
    });
    void handle(String name, Future<Object?> Function(Object?) callback) {
      final channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.conduit.NativeDropdownHostApi.$name',
        NativeDropdownHostApi.pigeonChannelCodec,
      );
      _channels.add(channel);
      _messenger.setMockDecodedMessageHandler<Object?>(channel, callback);
    }

    handle('initializeContextMenu', (_) async {
      initializations++;
      return [available];
    });
    handle('showContextMenu', (message) async {
      if (!prepared.isCompleted) prepared.complete(message! as List<Object?>);
      if (failPresentation) return ['PRESENTATION_FAILED', 'Synthetic host detached', null];
      return [await selection.future];
    });
    handle('cancelContextMenu', (message) async {
      cancellations.add(message! as List<Object?>);
      return [null];
    });
  }

  void dispose() {
    _messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    if (!selection.isCompleted) selection.complete(null);
    for (final channel in _channels) {
      _messenger.setMockDecodedMessageHandler<Object?>(channel, null);
    }
  }
}
