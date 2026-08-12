import 'dart:async';

import 'package:conduit/features/direct_connections/controllers/direct_connection_editor_draft.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/services/openwebui_direct_connection_store.dart';
import 'package:conduit/features/direct_connections/views/direct_connection_editor_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'direct_connections_ui_test_support.dart';

void main() {
  testWidgets('server editor reuses the form with a synced-source label', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final snapshot =
        OpenWebUiDirectConnectionsCodec(
          serverId: 'server',
          accountId: 'account',
        ).decode({
          'ui': {
            'directConnections': {
              'OPENAI_API_BASE_URLS': ['https://server.example/v1'],
              'OPENAI_API_KEYS': ['server-key'],
              'OPENAI_API_CONFIGS': {
                '0': {'auth_type': 'bearer'},
              },
            },
          },
        });
    final record = snapshot.records.single;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          openWebUiDirectConnectionsProvider.overrideWith(
            () => DirectTestStaticOpenWebUiConnections(snapshot),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionEditorPage(
            mode: DirectConnectionEditorMode.edit(
              profileId: record.profile.id,
              source: DirectConnectionEditorSource.openWebUi,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Open WebUI'), findsOneWidget);
    expect(
      find.text('Changes are saved to your Open WebUI account.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('direct-connection-name-field')),
      findsNothing,
    );
    expect(find.text('Ollama'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('direct-base-url-field')),
      findsOneWidget,
    );
  });

  testWidgets('local editor builds its authentication dropdown on iOS', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          directConnectionProfilesProvider.overrideWith(
            () => DirectTestStaticDirectProfiles(const []),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DirectConnectionEditorPage(
            mode: DirectConnectionEditorMode.create(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.fling(
      find.byType(Scrollable).first,
      const Offset(0, -1000),
      1000,
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(
        const ValueKey<String>(
          'direct-authentication-selector-openai-compatible',
        ),
      ),
      findsOneWidget,
    );
  });

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
          localizationsDelegates: AppLocalizations.localizationsDelegates,
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
          localizationsDelegates: AppLocalizations.localizationsDelegates,
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
          localizationsDelegates: AppLocalizations.localizationsDelegates,
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
