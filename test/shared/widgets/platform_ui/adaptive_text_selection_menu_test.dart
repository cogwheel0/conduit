import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Covers fallback hosts, native action transport, and presentation ownership.
void main() {
  const channel = MethodChannel('app.cogwheel.conduit/text_selection_menu');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late List<MethodCall> calls;
  late List<Completer<int?>> replies;
  var copied = 0;
  var selected = 0;
  var dismissed = 0;

  setUp(() {
    calls = [];
    replies = [];
    copied = selected = dismissed = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      if (call.method != 'show') return Future<Object?>.value();
      final reply = Completer<int?>();
      replies.add(reply);
      return reply.future;
    });
  });
  tearDown(
    () =>
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  Future<void> host(
    WidgetTester tester, {
    bool supported = true,
    double y = 100,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData.fromView(tester.view)
              .copyWith(supportsShowingSystemContextMenu: supported),
          child: Scaffold(
            body: AdaptiveTextSelectionMenu(
              selectionRect: Rect.fromLTWH(20, y, 160, 24),
              anchors: TextSelectionToolbarAnchors(
                primaryAnchor: Offset(100, y),
              ),
              buttonItems: [
                ContextMenuButtonItem(
                  type: ContextMenuButtonType.copy,
                  onPressed: () => copied++,
                ),
                ContextMenuButtonItem(
                  type: ContextMenuButtonType.selectAll,
                  onPressed: () => selected++,
                ),
              ],
              onDismiss: () => dismissed++,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('Android retains the Flutter toolbar', (tester) async {
    await host(tester);
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
    expect(calls, isEmpty);
    await tester.tap(find.text('Copy'));
    expect(copied, 1);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('unsupported iOS retains the Flutter toolbar', (tester) async {
    await host(tester, supported: false);
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
    expect(calls, isEmpty);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets(
    'sends labels and full-view logical geometry without selected text',
    (tester) async {
      await host(tester);
      final args = calls.single.arguments as Map;
      expect(calls.single.method, 'show');
      expect(args['labels'], ['Copy', 'Select All']);
      expect(args['rect'], [20.0, 100.0, 160.0, 24.0]);
      expect(
        args['viewWidth'],
        tester.view.physicalSize.width / tester.view.devicePixelRatio,
      );
      expect(
        args['viewHeight'],
        tester.view.physicalSize.height / tester.view.devicePixelRatio,
      );
      expect(args.containsKey('text'), isFalse);
      expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
      replies.single.complete(1);
      await tester.pump();
      expect(selected, 1);
      expect(copied, 0);
    },
    variant: const TargetPlatformVariant({TargetPlatform.iOS}),
  );

  for (final missing in [true, false]) {
    testWidgets(
      'unavailable native host restores the Flutter toolbar ($missing)',
      (tester) async {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          call,
        ) async {
          if (missing) throw MissingPluginException();
          throw PlatformException(code: 'unavailable');
        });
        await host(tester);
        await tester.pump();
        expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
        await tester.tap(find.text('Copy'));
        expect(copied, 1);
      },
      variant: const TargetPlatformVariant({TargetPlatform.iOS}),
    );
  }

  testWidgets('system dismissal hides the toolbar without invoking an action', (
    tester,
  ) async {
    await host(tester);
    replies.single.complete(null);
    await tester.pump();
    expect(dismissed, 1);
    expect(copied + selected, 0);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('late replies cannot act on a removed selection', (tester) async {
    await host(tester);
    final session = (calls.single.arguments as Map)['session'];
    await tester.pumpWidget(const SizedBox());
    replies.single.complete(0);
    await tester.pump();
    expect(copied, 0);
    expect(dismissed, 0);
    expect(calls.last.method, 'hide');
    expect((calls.last.arguments as Map)['session'], session);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets(
    'replaced selections ignore old callbacks and keep their own action',
    (tester) async {
      await host(tester);
      await host(tester, y: 180);
      expect(replies, hasLength(2));
      replies.first.complete(0);
      await tester.pump();
      expect(copied + dismissed, 0);
      replies.last.complete(1);
      await tester.pump();
      expect(selected, 1);
    },
    variant: const TargetPlatformVariant({TargetPlatform.iOS}),
  );
}
