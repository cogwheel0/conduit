import 'package:conduit/features/profile/views/profile_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpProfile(
    WidgetTester tester, {
    required bool advanced,
    required PersonalConnectionsAccess access,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider2.overrideWithValue(null),
          currentUserProvider.overrideWith((ref) async => null),
          isAuthLoadingProvider2.overrideWithValue(false),
          apiServiceProvider.overrideWithValue(null),
          appSettingsProvider.overrideWithValue(
            AppSettings(advancedFeaturesEnabled: advanced),
          ),
          personalConnectionsAccessProvider.overrideWithValue(access),
        ],
        child: const MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ProfilePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const allowed = PersonalConnectionsAccess.allowed();
  final entry = find.byKey(const Key('personal-connections-entry'));

  testWidgets('Profile lists Personal connections with Advanced and access', (
    tester,
  ) async {
    await pumpProfile(tester, advanced: true, access: allowed);
    await tester.scrollUntilVisible(entry, 300);

    expect(entry, findsOneWidget);
    expect(find.text('Personal connections'), findsOneWidget);
  });

  testWidgets('Profile hides Personal connections while Advanced is off', (
    tester,
  ) async {
    await pumpProfile(tester, advanced: false, access: allowed);
    await tester.scrollUntilVisible(find.text('Direct Connections'), 300);

    expect(entry, findsNothing);
  });

  testWidgets('Profile hides Personal connections without server access', (
    tester,
  ) async {
    await pumpProfile(
      tester,
      advanced: true,
      access: const PersonalConnectionsAccess.blocked(
        PersonalConnectionsBlock.serverDisabled,
      ),
    );
    await tester.scrollUntilVisible(find.text('Direct Connections'), 300);

    expect(entry, findsNothing);
  });
}
