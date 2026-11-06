import 'package:checks/checks.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets(
    'native-sheet Open WebUI connect makes the auth flow the router location',
    (tester) async {
      // The app router redirects a newly authenticated session to chat only
      // when an auth route is the current location. A push over /chat keeps
      // /chat as that location, which strands sign-in on the auth pages.
      final router = GoRouter(
        initialLocation: Routes.chat,
        routes: [
          GoRoute(
            path: Routes.chat,
            builder: (context, state) => const SizedBox(),
          ),
          GoRoute(
            path: Routes.serverConnection,
            name: RouteNames.serverConnection,
            builder: (context, state) => const SizedBox(),
          ),
        ],
      );
      addTearDown(router.dispose);
      NavigationService.attachRouter(router);
      await tester.pumpWidget(
        WidgetsApp.router(routerConfig: router, color: const Color(0xFF000000)),
      );

      NavigationService.openOpenWebUIConnectFromNativeSheet();
      await tester.pumpAndSettle();

      final configuration = router.routerDelegate.currentConfiguration;
      check(configuration.uri.path).equals(Routes.serverConnection);
      check(configuration.extra).isA<NativeSheetNavigationOrigin>();
    },
  );

  testWidgets('back returns through the main-pane pages visited before', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: Routes.chat,
      routes: [
        for (final path in [
          Routes.chat,
          Routes.notes,
          Routes.noteEditor,
          Routes.channels,
          Routes.profile,
        ])
          GoRoute(path: path, builder: (context, state) => const SizedBox()),
      ],
    );
    addTearDown(router.dispose);
    NavigationService.attachRouter(router);
    await tester.pumpWidget(
      WidgetsApp.router(routerConfig: router, color: const Color(0xFF000000)),
    );
    Future<void> visit(String location) async {
      router.go(location);
      await tester.pumpAndSettle();
    }

    Future<String?> back() async {
      NavigationService.returnToPreviousPage(fallback: Routes.chat);
      await tester.pumpAndSettle();
      return NavigationService.currentRoute;
    }

    await visit(Routes.notes);
    await visit('/notes/demo');
    await visit(Routes.profile);
    await visit(Routes.channels);
    // Settings and other screens outside the main pane are passed over.
    check(await back()).equals('/notes/demo');
    check(await back()).equals(Routes.notes);
    check(await back()).equals(Routes.chat);
    check(await back()).equals(Routes.chat);

    // Returning to a page drops the pages after it, so back cannot cycle.
    await visit(Routes.notes);
    await visit('/notes/demo');
    await visit(Routes.notes);
    check(await back()).equals(Routes.chat);
  });
}
