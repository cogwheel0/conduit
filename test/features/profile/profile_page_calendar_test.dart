import 'package:conduit/features/profile/views/profile_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  Future<int Function()> pumpProfile(
    WidgetTester tester, {
    required bool visible,
  }) async {
    var opened = 0;
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const ProfilePage()),
        GoRoute(
          path: Routes.calendar,
          name: RouteNames.calendar,
          builder: (_, _) {
            opened++;
            return const SizedBox.shrink();
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider2.overrideWithValue(null),
          currentUserProvider.overrideWith((ref) async => null),
          isAuthLoadingProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          appSettingsProvider.overrideWithValue(const AppSettings()),
          calendarAvailableProvider.overrideWithValue(visible),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return () => opened;
  }

  final entry = find.byKey(const Key('calendar-entry'));

  testWidgets('Profile lists Calendar and the tile opens the agenda', (
    tester,
  ) async {
    final opened = await pumpProfile(tester, visible: true);
    await tester.scrollUntilVisible(entry, 300);

    expect(find.text('Calendar'), findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(opened(), 1);
  });

  testWidgets('Profile hides Calendar when the entry is not visible', (
    tester,
  ) async {
    await pumpProfile(tester, visible: false);
    await tester.scrollUntilVisible(find.text('Direct Connections'), 300);

    expect(entry, findsNothing);
  });
}
