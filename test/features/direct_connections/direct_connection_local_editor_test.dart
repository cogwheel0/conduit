import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/views/direct_connections_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'direct_connections_ui_test_support.dart';

void main() {
  testWidgets(
    'opening an editor preserves the native sheet transition origin',
    (tester) async {
      Object? editorExtra;
      final router = GoRouter(
        initialLocation: Routes.directConnections,
        routes: [
          GoRoute(
            path: Routes.directConnections,
            name: RouteNames.directConnections,
            builder: (_, _) => const DirectConnectionsPage(),
          ),
          GoRoute(
            path: Routes.directConnectionEditor,
            name: RouteNames.directConnectionEditor,
            builder: (_, state) {
              editorExtra = state.extra;
              return const Scaffold(body: Text('Connection editor'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            directConnectionProfilesProvider.overrideWith(
              () => DirectTestStaticDirectProfiles(const []),
            ),
            directHistoryPolicyProvider.overrideWith(
              DirectTestStaticHistoryPolicy.new,
            ),
          ],
          child: MaterialApp.router(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('No Direct Connections Yet'));
      await tester.pumpAndSettle();

      expect(editorExtra, isA<NativeSheetNavigationOrigin>());
      expect(find.text('Connection editor'), findsOneWidget);
    },
  );
}
