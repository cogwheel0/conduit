import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/profile/views/profile_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _homeAgent = HermesConnectionProfile(
  id: 'hermes-home',
  name: 'Home agent',
  documentTrustPrincipalId: 'p-home',
  baseUrl: 'http://10.0.0.5:8642',
);

void main() {
  testWidgets('Hermes-only profile exposes only app-local settings', (
    tester,
  ) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider2.overrideWithValue(null),
          currentUserProvider.overrideWith((ref) async => null),
          isAuthLoadingProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          hermesOnlyModeProvider.overrideWithValue(true),
        ],
        child: const MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ProfilePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Personalization'), findsNothing);
    expect(find.text('Notifications'), findsNothing);
    expect(find.text('No email'), findsNothing);

    expect(find.text('Audio'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
    expect(find.byKey(const Key('settings-account-group')), findsNothing);
    expect(find.byKey(const Key('settings-category-account')), findsNothing);
    expect(find.byKey(const Key('settings-category-app')), findsNothing);
    expect(find.byKey(const Key('settings-category-ai')), findsNothing);
    expect(find.byKey(const Key('settings-category-server')), findsNothing);
    // Connections -- Open WebUI's included -- are reached through Accounts.
    expect(find.text('Connect to Open WebUI'), findsNothing);
    expect(find.text('Add account'), findsOneWidget);

    await tester.fling(find.byType(ListView), const Offset(0, -1000), 2000);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-category-support')), findsNothing);
    expect(find.text('About'), findsOneWidget);
    expect(find.byKey(const Key('settings-donations')), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Buy Me a Coffee'),
        matching: find.byKey(const Key('settings-donations')),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settings-sign-out')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    ErrorWidget.builder = originalErrorWidgetBuilder;
    FlutterError.onError = originalFlutterErrorOnError;
  });

  testWidgets('the card names the Hermes connection in use', (tester) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider2.overrideWithValue(null),
          currentUserProvider.overrideWith((ref) async => null),
          isAuthLoadingProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          hermesOnlyModeProvider.overrideWithValue(true),
          hermesEnabledProvider.overrideWithValue(true),
          hermesConnectionsProvider.overrideWithValue(const [_homeAgent]),
          hermesActiveConnectionIdProvider.overrideWithValue(_homeAgent.id),
        ],
        child: const MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ProfilePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final card = find.byKey(const Key('settings-accounts'));
    expect(card, findsOneWidget);
    // The connection is who Settings is for; Hermes is where.
    expect(
      find.descendant(of: card, matching: find.text('Home agent')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('Hermes Agent')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.byKey(const Key('hermes-settings-logo')),
      ),
      findsOneWidget,
    );
    // Hermes replies and scheduled tasks notify without an Open WebUI
    // account, so their settings and push are reachable.
    expect(find.byKey(const Key('settings-notifications')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    ErrorWidget.builder = originalErrorWidgetBuilder;
    FlutterError.onError = originalFlutterErrorOnError;
  });

  testWidgets('direct-only profile exposes Personalization for defaults', (
    tester,
  ) async {
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider2.overrideWithValue(null),
          currentUserProvider.overrideWith((ref) async => null),
          isAuthLoadingProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          hermesOnlyModeProvider.overrideWithValue(false),
          preferredBackendProvider.overrideWith(
            () => _DirectPreferredBackendController(),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ProfilePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Personalization'), 300);
    expect(find.text('Personalization'), findsOneWidget);
    expect(find.text('Notifications'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    ErrorWidget.builder = originalErrorWidgetBuilder;
    FlutterError.onError = originalFlutterErrorOnError;
  });
}

class _DirectPreferredBackendController extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.direct;
}
