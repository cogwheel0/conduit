import 'dart:ui' as ui;

import 'package:checks/checks.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/features/auth/views/backend_chooser_page.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/shared/widgets/utility_components.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/views/hermes_settings_page.dart';
import 'package:conduit/features/profile/widgets/adaptive_segmented_selector.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/adaptive_auth_harness.dart';

const _testServer = ServerConfig(
  id: 'server-1',
  name: 'Open WebUI',
  url: 'https://open-webui.example',
  isActive: true,
);

void main() {
  testWidgets('backend chooser uses local provider marks and clear copy', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final harness = AdaptiveAuthHarness(
        server: _testServer,
        platform: TargetPlatform.iOS,
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        harness.build(initialLocation: Routes.backendChooser),
      );
      await tester.pumpAndSettle();

      expect(find.text('Choose how to connect'), findsOneWidget);
      expect(find.text('Open WebUI'), findsOneWidget);
      expect(find.text('Connect directly'), findsOneWidget);
      expect(find.text('Apple On-Device'), findsOneWidget);
      expect(find.text('Apple Private Cloud Compute'), findsOneWidget);
      expect(find.text('Hermes Agent'), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.link), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.device_phone_portrait), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.cloud_fill), findsOneWidget);
      expect(find.byIcon(Icons.hub), findsNothing);
      expect(find.byType(Image), findsNWidgets(2));
      expect(
        find.image(const AssetImage('assets/icons/open_webui.png')),
        findsOneWidget,
      );
      expect(
        find.image(const AssetImage('assets/icons/hermes_agent.png')),
        findsOneWidget,
      );
      final openWebUiSemantics = tester.getSemantics(
        find.bySemanticsLabel(
          'Open WebUI. Sign in to your server for synced chats, notes, and more.',
        ),
      );
      expect(
        openWebUiSemantics.getSemanticsData().hasAction(ui.SemanticsAction.tap),
        isTrue,
      );

      await harness.unmount(tester);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('backend chooser reflows and scrolls with accessibility text', (
    tester,
  ) async {
    usePhoneViewport(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 3.2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final harness = AdaptiveAuthHarness(
      server: _testServer,
      platform: TargetPlatform.iOS,
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(initialLocation: Routes.backendChooser),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final hermes = find.text('Hermes Agent');
    await tester.ensureVisible(hermes);
    await tester.pumpAndSettle();
    expect(hermes, findsOneWidget);
    expect(tester.takeException(), isNull);

    await harness.unmount(tester);
  });

  testWidgets(
    'Hermes onboarding has explicit back navigation and adaptive fields',
    (tester) async {
      usePhoneViewport(tester);
      await initializeBackendOnboardingStorage();
      addTearDown(PreferencesStore.debugReset);
      final harness = BackendOnboardingHarness();
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        harness.build(initialLocation: Routes.backendChooser),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Hermes Agent'));
      await tester.pumpAndSettle();

      check(harness.router.routeInformationProvider.value.uri.path)
          .equals(Routes.hermesSettings);
      check(harness.router.canPop()).isFalse();
      expect(find.byType(UtilityPageScaffold), findsOneWidget);
      expect(
        tester
            .widget<UtilityPageScaffold>(find.byType(UtilityPageScaffold))
            .maxWidth,
        480,
      );
      expect(
        find.byKey(const ValueKey<String>('hermes-onboarding-back-button')),
        findsOneWidget,
      );
      expect(find.byType(AccessibleFormField), findsNWidgets(2));
      expect(find.byType(ConduitInput), findsNothing);
      for (final field in tester.widgetList<AdaptiveTextFormField>(
        find.byType(AdaptiveTextFormField),
      )) {
        check(field.cupertinoDecoration).isNotNull();
        check(field.cupertinoDecoration!.border).isNull();
      }
      await tester.tap(
        find.byKey(const ValueKey<String>('hermes-memory-key-disclosure')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AccessibleFormField), findsNWidgets(3));

      await tester.tap(find.text('Desktop Gateway'));
      await tester.pumpAndSettle();
      final accessHeaders = find.byKey(
        const ValueKey<String>('hermes-access-headers-disclosure'),
      );
      expect(accessHeaders, findsOneWidget);
      check(tester.widget<UtilityDisclosureSection>(accessHeaders).expanded)
          .isFalse();
      await tester.tap(accessHeaders);
      await tester.pumpAndSettle();
      check(tester.widget<UtilityDisclosureSection>(accessHeaders).expanded)
          .isTrue();
      expect(find.text('Header name'), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(HermesSettingsPage)),
      );
      check(container.read(hermesConfigProvider).enabled).isFalse();

      await tester.tap(
        find.byKey(const ValueKey<String>('hermes-onboarding-back-button')),
      );
      await tester.pumpAndSettle();

      check(harness.router.routeInformationProvider.value.uri.path)
          .equals(Routes.backendChooser);
      expect(find.byType(BackendChooserPage), findsOneWidget);
      check(container.read(hermesConfigProvider).enabled).isFalse();
      await harness.unmount(tester);
    },
  );

  testWidgets(
    'Direct onboarding opens the overview and returns to the chooser',
    (tester) async {
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => PlatformUiCapabilities.debugPlatformOverride = null);
      usePhoneViewport(tester);
      await initializeBackendOnboardingStorage();
      addTearDown(PreferencesStore.debugReset);
      final harness = BackendOnboardingHarness();
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        harness.build(initialLocation: Routes.backendChooser),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Connect directly'));
      await tester.pumpAndSettle();

      final route = harness.router.routeInformationProvider.value.uri;
      check(route.path).equals(Routes.directConnections);
      check(route.queryParameters['onboarding']).equals('true');
      check(harness.router.canPop()).isFalse();
      expect(find.byType(UtilityPageScaffold), findsOneWidget);
      expect(
        tester
            .widget<UtilityPageScaffold>(find.byType(UtilityPageScaffold))
            .maxWidth,
        480,
      );
      expect(
        find.byKey(const ValueKey<String>('direct-onboarding-back-button')),
        findsOneWidget,
      );
      expect(find.text('No direct connections yet'), findsOneWidget);
      expect(find.text('Direct Connections'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('finish-direct-onboarding-button')),
        findsOneWidget,
      );
      final navigationBarBottom = tester
          .getBottomLeft(find.byType(ConduitAdaptiveCupertinoNavigationBar))
          .dy;
      final emptyTitleTop = tester
          .getTopLeft(find.text('No direct connections yet'))
          .dy;
      check(emptyTitleTop - navigationBarBottom).isLessOrEqual(Spacing.xxxl);

      await tester.tap(
        find.byKey(const ValueKey<String>('direct-onboarding-back-button')),
      );
      await tester.pumpAndSettle();

      check(harness.router.routeInformationProvider.value.uri.path)
          .equals(Routes.backendChooser);
      expect(find.byType(BackendChooserPage), findsOneWidget);
      await harness.unmount(tester);
    },
  );

  testWidgets(
    'Direct onboarding opens retained profiles instead of forcing a new one',
    (tester) async {
      usePhoneViewport(tester);
      await initializeBackendOnboardingStorage();
      addTearDown(PreferencesStore.debugReset);
      FlutterSecureStorage.setMockInitialValues({
        'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
          DirectConnectionProfile(
            id: 'retained-direct',
            name: 'Retained Direct',
            adapterKey: kOpenAiCompatibleAdapterKey,
            baseUrl: 'https://direct.example/v1',
            apiKey: 'secret-key',
          ),
        ]).encode(),
      });
      final harness = BackendOnboardingHarness();
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        harness.build(initialLocation: Routes.backendChooser),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Connect directly'));
      await tester.pumpAndSettle();

      final route = harness.router.routeInformationProvider.value.uri;
      check(route.path).equals(Routes.directConnections);
      check(route.queryParameters['onboarding']).equals('true');
      expect(find.text('Retained Direct'), findsOneWidget);
      expect(find.text('Connect a provider'), findsNothing);
      await harness.unmount(tester);
    },
  );

  testWidgets('Direct onboarding editor uses adaptive fields and navigation', (
    tester,
  ) async {
    usePhoneViewport(tester);
    await initializeBackendOnboardingStorage();
    addTearDown(PreferencesStore.debugReset);
    final harness = BackendOnboardingHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(
        initialLocation: '${Routes.directConnections}/new?onboarding=true',
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(find.byType(UtilityPageScaffold), findsOneWidget);
    expect(
      tester
          .widget<UtilityPageScaffold>(find.byType(UtilityPageScaffold))
          .maxWidth,
      480,
    );
    expect(
      find.byKey(const ValueKey<String>('direct-editor-back-button')),
      findsOneWidget,
    );
    expect(find.byType(AccessibleFormField), findsNWidgets(3));
    expect(find.byType(ConduitInput), findsNothing);
    expect(find.text('For OpenAI-compatible APIs.'), findsNothing);
    expect(find.text('Connect with an OpenRouter API key.'), findsNothing);
    expect(find.text('Connect to Ollama Cloud with an API key.'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('direct-api-version-field')),
      findsNothing,
    );
    for (final selector in tester.widgetList<AdaptiveSegmentedSelector<Object>>(
      find.byType(AdaptiveSegmentedSelector),
    )) {
      check(selector.showIcons).isFalse();
    }
    for (final field in tester.widgetList<AdaptiveTextFormField>(
      find.byType(AdaptiveTextFormField),
    )) {
      check(field.cupertinoDecoration).isNotNull();
      check(field.cupertinoDecoration!.border).isNull();
    }

    final advancedToggle = find.byKey(
      const ValueKey<String>('direct-advanced-settings-toggle'),
    );
    await tester.ensureVisible(advancedToggle);
    await tester.pumpAndSettle();
    await tester.tap(advancedToggle);
    await tester.pumpAndSettle();

    expect(find.byType(AccessibleFormField), findsNWidgets(5));
    expect(
      find.byKey(const ValueKey<String>('direct-api-version-field')),
      findsOneWidget,
    );
    final addHeaderFinder = find.byKey(
      const ValueKey<String>('add-direct-custom-header-button'),
    );
    check(tester.widget<UtilityRow>(addHeaderFinder).onTap).isNull();
    await tester.enterText(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('direct-custom-header-name-field'),
        ),
        matching: find.byType(EditableText),
      ),
      'X.Test+Header',
    );
    await tester.pump();
    check(tester.widget<UtilityRow>(addHeaderFinder).onTap).isNotNull();
    await tester.enterText(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('direct-custom-header-value-field'),
        ),
        matching: find.byType(EditableText),
      ),
      'test-value',
    );
    await tester.pump();
    check(tester.widget<UtilityRow>(addHeaderFinder).onTap).isNotNull();

    expect(find.text('X.Test+Header'), findsOneWidget);
    expect(find.text('test-value'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('utility-route-back-button')),
    );
    await tester.pumpAndSettle();
    check(
      tester
          .widget<ConduitButton>(
            find.byKey(const ValueKey<String>('direct-editor-save-button')),
          )
          .onPressed,
    ).isNull();
    final apiKeyField = tester.widget<AdaptiveTextFormField>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('direct-api-key-field')),
        matching: find.byType(AdaptiveTextFormField),
      ),
    );
    check(apiKeyField.cupertinoDecoration).isNotNull();

    await tester.tap(
      find.byKey(const ValueKey<String>('direct-editor-back-button')),
    );
    await tester.pumpAndSettle();

    final route = harness.router.routeInformationProvider.value.uri;
    check(route.path).equals(Routes.directConnections);
    check(route.queryParameters['onboarding']).equals('true');
    await harness.unmount(tester);
  });
}
