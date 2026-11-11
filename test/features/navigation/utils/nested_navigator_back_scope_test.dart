import 'package:conduit/features/navigation/utils/chat_list_back.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late List<bool> reports;
  late int guardedBacks;

  /// What the app last told Android about handling back.
  bool? appHandlesBack() => reports.isEmpty ? null : reports.last;

  Future<GoRouter> mount(WidgetTester tester, {bool android = true}) async {
    debugChatBackIsAndroidOverride = android;
    addTearDown(() => debugChatBackIsAndroidOverride = null);
    // The app reports back handling to Android only once it is running.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    reports = <bool>[];
    guardedBacks = 0;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
        reports.add(call.arguments as bool);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final router = GoRouter(
      initialLocation: '/guarded',
      routes: [
        ShellRoute(
          builder: (context, state, child) =>
              NestedNavigatorBackScope(child: child),
          routes: [
            GoRoute(
              path: '/guarded',
              builder: (context, state) => PopScope(
                canPop: false,
                onPopInvokedWithResult: (didPop, _) => guardedBacks++,
                child: const Text('Guarded'),
              ),
            ),
            GoRoute(
              path: '/plain',
              builder: (context, state) => const Text('Plain'),
            ),
          ],
        ),
        GoRoute(
          path: '/over',
          builder: (context, state) => const Text('Over the shell'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('Android hands back to a nested page that handles it', (
    tester,
  ) async {
    final router = await mount(tester);
    expect(appHandlesBack(), isTrue);

    // A root route coming and going makes the root navigator report again,
    // from its own top route: the shell.
    router.push('/over');
    await tester.pumpAndSettle();
    router.pop();
    await tester.pumpAndSettle();
    expect(appHandlesBack(), isTrue);

    // Back reaches the nested page, and the shell stays.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(guardedBacks, 1);
    expect(find.text('Guarded'), findsOneWidget);
  });

  testWidgets('a nested page that leaves back alone lets Android take it', (
    tester,
  ) async {
    final router = await mount(tester);

    router.go('/plain');
    await tester.pumpAndSettle();
    expect(appHandlesBack(), isFalse);

    router.go('/guarded');
    await tester.pumpAndSettle();
    expect(appHandlesBack(), isTrue);
  });

  testWidgets('other platforms keep the shell as it was', (tester) async {
    await mount(tester, android: false);

    // Nothing holds the shell route over the guarded page: no guard between
    // the scope and the nested navigator blocks back.
    final holds = find.descendant(
      of: find.byType(NestedNavigatorBackScope),
      matching: find.byWidgetPredicate(
        (widget) => widget is PopScope && !widget.canPop,
      ),
    );
    expect(
      find.ancestor(of: find.byType(Navigator).last, matching: holds),
      findsNothing,
    );
  });
}
