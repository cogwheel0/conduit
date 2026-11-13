import 'dart:async';

import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'direct_connections_ui_test_support.dart';
import '../../support/test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);

  testWidgets('onboarding does not save an unreachable direct provider', (
    tester,
  ) async {
    final controller = DirectTestOnboardingDirectProfiles(
      const DirectConnectionProbe(
        reachable: false,
        message: 'Provider unavailable',
      ),
    );
    final router = directTestOnboardingRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          directConnectionProfilesProvider.overrideWith(() => controller),
        ],
        child: MaterialApp.router(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await directTestSubmitOnboarding(tester);

    expect(controller.probeCalls, 1);
    expect(controller.upsertCalls, 0);
    expect(router.routeInformationProvider.value.uri.path, '/editor/new');
    expect(find.text('Provider unavailable'), findsOneWidget);
  });

  testWidgets('onboarding saves a reachable provider before the overview', (
    tester,
  ) async {
    final controller = DirectTestOnboardingDirectProfiles(
      const DirectConnectionProbe(reachable: true),
    );
    final router = directTestOnboardingRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          directConnectionProfilesProvider.overrideWith(() => controller),
        ],
        child: MaterialApp.router(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await directTestSubmitOnboarding(tester);

    expect(controller.probeCalls, 1);
    expect(controller.upsertCalls, 1);
    expect(controller.lastUpsert?.apiKey, 'test-secret');
    expect(router.routeInformationProvider.value.uri.path, '/overview');
    expect(find.text('Connection overview'), findsOneWidget);
  });

  testWidgets('onboarding locks the form and saves the tested draft', (
    tester,
  ) async {
    final probeCompleter = Completer<DirectConnectionProbe>();
    final controller = DirectTestOnboardingDirectProfiles(
      const DirectConnectionProbe(reachable: true),
      probeCompleter: probeCompleter,
    );
    final router = directTestOnboardingRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          directConnectionProfilesProvider.overrideWith(() => controller),
        ],
        child: MaterialApp.router(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('direct-api-key-field')),
      'test-secret',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('direct-editor-save-button')),
    );
    await tester.pump();

    expect(controller.probeCalls, 1);
    final probedDraft = controller.lastProbe!;
    expect(
      tester
          .widget<AbsorbPointer>(
            find.byKey(
              const ValueKey<String>('direct-editor-form-interaction-lock'),
            ),
          )
          .absorbing,
      isTrue,
    );
    probeCompleter.complete(const DirectConnectionProbe(reachable: true));
    await tester.pumpAndSettle();

    expect(controller.upsertCalls, 1);
    expect(controller.lastUpsert, same(probedDraft));
  });
}
