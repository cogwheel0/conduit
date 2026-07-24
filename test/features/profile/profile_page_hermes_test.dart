import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/providers/backend_mode_providers.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/profile/views/profile_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
          localizationsDelegates: AppLocalizations.localizationsDelegates,
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
    expect(find.text('Hermes Agent'), findsOneWidget);
    expect(find.byKey(const Key('hermes-settings-logo')), findsOneWidget);
    expect(find.byKey(const Key('settings-category-account')), findsNothing);
    expect(find.byKey(const Key('settings-category-app')), findsNothing);
    expect(find.byKey(const Key('settings-category-ai')), findsNothing);

    await tester.scrollUntilVisible(find.text('Direct Connections'), 300);
    expect(find.byKey(const Key('settings-category-server')), findsNothing);
    expect(find.text('Direct Connections'), findsOneWidget);
    expect(
      find.text('Connect to OpenAI-compatible APIs and Ollama'),
      findsOneWidget,
    );
    expect(find.text('Connect to Open WebUI'), findsOneWidget);

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
          localizationsDelegates: AppLocalizations.localizationsDelegates,
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
