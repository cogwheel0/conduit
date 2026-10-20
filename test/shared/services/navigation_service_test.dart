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
}
