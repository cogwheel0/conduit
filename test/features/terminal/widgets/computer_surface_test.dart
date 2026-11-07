import 'package:conduit/features/terminal/widgets/computer_surface.dart';
import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

import 'computer_test_platform.dart';

class _PointerController extends PlatformViewController {
  final events = <PointerEvent>[];
  @override
  int get viewId => 1;
  @override
  Future<void> dispatchPointerEvent(PointerEvent event) async =>
      events.add(event);
  @override
  Future<void> dispose() async {}
  @override
  Future<void> clearFocus() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late InAppWebViewPlatform? previous;
  setUp(() {
    rootBundle.evict('assets/computer/viewer.js');
    previous = InAppWebViewPlatform.instance;
    InAppWebViewPlatform.instance = ComputerTestPlatform();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          'flutter/assets',
          (_) async => const StringCodec().encodeMessage('// synthetic viewer'),
        );
  });
  tearDown(() {
    if (previous != null) InAppWebViewPlatform.instance = previous;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });

  testWidgets(
    'remote swipes stay in the viewer instead of opening the sidebar',
    (tester) async {
      final pointer = _PointerController();
      InAppWebViewPlatform.instance = ComputerTestPlatform(
        pointerController: pointer,
      );
      var sidebarDrags = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => sidebarDrags++,
            child: Center(
              child: SizedBox(
                width: 300,
                height: 300,
                child: ComputerSurfaceView(
                  connection: ComputerConnection(
                    surface: ComputerSurface.browser,
                    streamUri: Uri.parse(
                      'ws://computer.example/browser/stream',
                    ),
                  ),
                  controller: ComputerSurfaceController(),
                  onState: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(InAppWebView), const Offset(100, 30));
      expect(sidebarDrags, 0);
      expect(pointer.events.whereType<PointerMoveEvent>(), isNotEmpty);
      await tester.dragFrom(const Offset(20, 20), const Offset(100, 0));
      expect(sidebarDrags, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('retiring viewer cannot dispose or detach its replacement', (
    tester,
  ) async {
    final controller = ComputerSurfaceController();
    final oldWeb = ComputerTestWebController();
    final newWeb = ComputerTestWebController();
    Widget harness({required bool old}) => Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: [
          if (old)
            SizedBox(
              key: const ValueKey('old slot'),
              height: 150,
              child: ComputerSurfaceView(
                key: const ValueKey('old'),
                connection: ComputerConnection(
                  surface: ComputerSurface.desktop,
                  streamUri: Uri.parse('ws://computer.example/desktop/stream'),
                ),
                controller: controller,
                onState: (_) {},
              ),
            ),
          SizedBox(
            key: const ValueKey('new slot'),
            height: 150,
            child: ComputerSurfaceView(
              key: const ValueKey('new'),
              connection: ComputerConnection(
                surface: ComputerSurface.browser,
                streamUri: Uri.parse('ws://computer.example/browser/stream'),
              ),
              controller: controller,
              onState: (_) {},
            ),
          ),
        ],
      ),
    );
    await tester.pumpWidget(harness(old: true));
    await tester.pumpAndSettle();
    final views = tester
        .widgetList<InAppWebView>(find.byType(InAppWebView))
        .toList();
    views[0].platform.params.onWebViewCreated!(oldWeb);
    views[1].platform.params.onWebViewCreated!(newWeb);
    await tester.pumpWidget(harness(old: false));
    await controller.control(true);
    expect(oldWeb.scripts, contains('window.computer?.dispose()'));
    expect(newWeb.scripts, ['window.computer?.control(true)']);
    expect(newWeb.handlers, contains('computer'));
    await tester.pumpWidget(const SizedBox());
  });
}
