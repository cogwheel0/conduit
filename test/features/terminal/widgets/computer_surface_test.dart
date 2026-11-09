import 'package:conduit/features/terminal/widgets/computer_surface.dart';
import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
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

  testWidgets(
    'viewer keeps proxy cookies outside the WebView cookie store',
    (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ComputerSurfaceView(
            connection: ComputerConnection(
              surface: ComputerSurface.desktop,
              streamUri: Uri.parse(
                'wss://computer.example:9443/nested/desktop/stream',
              ),
              proxyCookies: {
                'CF_Authorization': 'synthetic-proxy',
                'unsafe': '</script><script>bad()</script>',
                'bad;name': 'discard',
                'bad_value': 'discard; path=/other',
              },
            ),
            controller: ComputerSurfaceController(),
            onState: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final params = tester
          .widget<InAppWebView>(find.byType(InAppWebView))
          .platform
          .params;
      expect(
        params.initialData!.baseUrl.toString(),
        'http://127.0.0.1/index.html',
      );
      final document = params.initialData!.data;
      expect(document, isNot(contains('synthetic-proxy')));
      expect(document, isNot(contains('document.cookie')));
      expect(document, isNot(contains('computer.example')));
      expect(document, contains('-webkit-user-select:none'));
      expect(document, contains('-webkit-touch-callout:none'));
      expect(
        params.initialSettings!.incognito,
        defaultTargetPlatform != TargetPlatform.android,
      );
      expect(params.initialSettings!.sharedCookiesEnabled, isFalse);
      expect(params.initialSettings!.javaScriptHandlersOriginAllowList, {
        'http://127.0.0.1',
      });
      expect(document, contains('connect-src ws://127.0.0.1:* data:'));
      final decision = await params.shouldOverrideUrlLoading!(
        ComputerTestWebController(),
        NavigationAction(
          request: URLRequest(
            url: WebUri('https://computer.example:9443/private'),
          ),
          isForMainFrame: true,
        ),
      );
      expect(decision, NavigationActionPolicy.CANCEL);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets('backgrounding before WebView startup remains hidden', (
    tester,
  ) async {
    final controller = ComputerSurfaceController();
    await controller.visibility(false);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ComputerSurfaceView(
          connection: ComputerConnection(
            surface: ComputerSurface.desktop,
            streamUri: Uri.parse('ws://computer.example/desktop/stream'),
          ),
          controller: controller,
          onState: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final params = tester
        .widget<InAppWebView>(find.byType(InAppWebView))
        .platform
        .params;
    final web = ComputerTestWebController();
    params.onWebViewCreated!(web);
    params.onLoadStop!(web, null);
    for (var i = 0; i < 50 && web.scripts.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(web.scripts.single, contains('"visible":false'));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  });

  testWidgets('a held viewport keeps the browser size under the keyboard', (
    tester,
  ) async {
    final controller = ComputerSurfaceController();
    Widget harness({required double height, required bool hold}) =>
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              height: height,
              child: ComputerSurfaceView(
                connection: ComputerConnection(
                  surface: ComputerSurface.browser,
                  streamUri: Uri.parse('ws://computer.example/browser/stream'),
                ),
                controller: controller,
                holdViewport: hold,
                onState: (_) {},
              ),
            ),
          ),
        );
    await tester.pumpWidget(harness(height: 560, hold: false));
    await tester.pumpAndSettle();
    final params = tester
        .widget<InAppWebView>(find.byType(InAppWebView))
        .platform
        .params;
    final web = ComputerTestWebController();
    params.onWebViewCreated!(web);
    params.onLoadStop!(web, null);
    for (var i = 0; i < 50 && web.scripts.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(web.scripts.single, contains('"height":560'));
    Iterable<String> viewports() =>
        web.scripts.where((s) => s.startsWith('window.computer?.viewport'));

    // The keyboard shrinks the view; the remote page keeps its size.
    await tester.pumpWidget(harness(height: 300, hold: true));
    await tester.pump();
    expect(viewports(), isEmpty);
    // Back to the size the page already has: nothing to resend.
    await tester.pumpWidget(harness(height: 560, hold: false));
    await tester.pump();
    expect(viewports(), isEmpty);
    // A real change, such as rotation, still resizes it.
    await tester.pumpWidget(harness(height: 480, hold: false));
    await tester.pump();
    expect(viewports().single, contains('"height":480'));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  });

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
