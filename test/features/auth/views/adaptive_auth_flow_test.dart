import 'dart:ui' as ui;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:checks/checks.dart';
import 'package:conduit/core/models/backend_config.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/features/auth/views/authentication_page.dart';
import 'package:conduit/features/auth/views/backend_chooser_page.dart';
import 'package:conduit/features/auth/views/server_connection_page.dart';
import 'package:conduit/features/auth/widgets/adaptive_auth_scaffold.dart';
import 'package:conduit/features/direct_connections/views/direct_connection_editor_page.dart';
import 'package:conduit/features/direct_connections/views/direct_connections_page.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/views/hermes_settings_page.dart';
import 'package:conduit/features/profile/widgets/adaptive_segmented_selector.dart';
import 'package:conduit/features/profile/widgets/settings_page_scaffold.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const server = ServerConfig(
    id: 'server-1',
    name: 'Open WebUI',
    url: 'https://open-webui.example',
    isActive: true,
  );

  testWidgets(
    'post-logout sign-in flow can return from server setup to backend chooser',
    (tester) async {
      final harness = _AuthHarness(server: server);
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        harness.build(initialLocation: Routes.authentication),
      );
      await tester.pumpAndSettle();

      check(
        harness.router.routeInformationProvider.value.uri.path,
      ).equals(Routes.authentication);
      check(harness.router.canPop()).isFalse();

      await tester.tap(
        find.byKey(const ValueKey<String>('authentication-back-button')),
      );
      await tester.pumpAndSettle();

      check(
        harness.router.routeInformationProvider.value.uri.path,
      ).equals(Routes.serverConnection);
      check(harness.router.canPop()).isFalse();
      expect(
        find.byKey(const ValueKey<String>('server-connection-back-button')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('server-connection-back-button')),
      );
      await tester.pumpAndSettle();

      check(
        harness.router.routeInformationProvider.value.uri.path,
      ).equals(Routes.backendChooser);
      expect(find.byType(BackendChooserPage), findsOneWidget);
      await harness.unmount(tester);
    },
  );

  for (final platform in <TargetPlatform>[
    TargetPlatform.iOS,
    TargetPlatform.android,
  ]) {
    testWidgets('sign-in uses the adaptive auth selector on ${platform.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final harness = _AuthHarness(
        server: server,
        platform: platform,
        backendConfig: const BackendConfig(enableLdap: true),
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        harness.build(initialLocation: Routes.authentication),
      );
      await tester.pumpAndSettle();

      final selectorFinder = find.byKey(
        const ValueKey<String>('authentication-mode-selector'),
      );
      expect(selectorFinder, findsOneWidget);
      final selector = tester.widget<AdaptiveSegmentedSelector<AuthMode>>(
        selectorFinder,
      );
      check(selector.showIcons).isFalse();
      for (final field in tester.widgetList<AccessibleFormField>(
        find.byType(AccessibleFormField),
      )) {
        check(field.prefixIcon).isNull();
      }
      expect(find.byIcon(Icons.hub), findsNothing);
      expect(find.byIcon(Icons.hub_outlined), findsNothing);
      expect(
        find.image(const AssetImage('assets/icons/icon.png')),
        findsNothing,
      );

      final renderedField = tester.widget<AdaptiveTextFormField>(
        find.byType(AdaptiveTextFormField).first,
      );
      check(renderedField.cupertinoDecoration).isNotNull();
      check(renderedField.cupertinoDecoration!.border).isNull();

      if (platform == TargetPlatform.iOS) {
        expect(
          find.byType(CupertinoSlidingSegmentedControl<AuthMode>),
          findsOneWidget,
        );
      } else {
        expect(find.byType(SegmentedButton<AuthMode>), findsOneWidget);
      }

      selector.onChanged(AuthMode.token);
      await tester.pump();

      expect(find.byKey(const ValueKey('api_key_form')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await harness.unmount(tester);
    });

    testWidgets(
      'adaptive selector handles a missing value on ${platform.name}',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: AdaptiveSegmentedSelector<int>(
                value: 3,
                showIcons: false,
                onChanged: (_) {},
                options: const [
                  (
                    value: 1,
                    label: 'One',
                    cupertinoIcon: CupertinoIcons.circle,
                    materialIcon: Icons.circle_outlined,
                    enabled: true,
                  ),
                  (
                    value: 2,
                    label: 'Two',
                    cupertinoIcon: CupertinoIcons.circle,
                    materialIcon: Icons.circle_outlined,
                    enabled: true,
                  ),
                ],
              ),
            ),
          ),
        );

        if (platform == TargetPlatform.iOS) {
          final selector = tester.widget<CupertinoSlidingSegmentedControl<int>>(
            find.byType(CupertinoSlidingSegmentedControl<int>),
          );
          check(selector.groupValue).isNull();
        } else {
          final selector = tester.widget<SegmentedButton<int>>(
            find.byType(SegmentedButton<int>),
          );
          check(selector.selected).isEmpty();
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('server advanced disclosure respects reduced motion', (
    tester,
  ) async {
    final harness = _AuthHarness(server: server, disableAnimations: true);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(initialLocation: Routes.serverConnection),
    );
    await tester.pumpAndSettle();

    final toggle = find.byKey(
      const ValueKey<String>('advanced-settings-toggle'),
    );
    final rotation = tester.widget<AnimatedRotation>(
      find.descendant(of: toggle, matching: find.byType(AnimatedRotation)),
    );

    check(rotation.duration).equals(Duration.zero);
    expect(find.byType(AnimatedCrossFade), findsNothing);

    final urlField = tester.widget<AccessibleFormField>(
      find.byKey(const ValueKey<String>('server-url-field')),
    );
    check(urlField.prefixIcon).isNull();
    final renderedUrlField = tester.widget<AdaptiveTextFormField>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('server-url-field')),
        matching: find.byType(AdaptiveTextFormField),
      ),
    );
    check(renderedUrlField.cupertinoDecoration).isNotNull();
    check(renderedUrlField.cupertinoDecoration!.border).isNull();

    final adaptiveToggle = tester.widget<AdaptiveButton>(toggle);
    check(adaptiveToggle.padding).equals(EdgeInsets.zero);
    check(adaptiveToggle.child).isA<Padding>();
    check(
      (adaptiveToggle.child! as Padding).padding,
    ).equals(const EdgeInsets.symmetric(horizontal: Spacing.md));

    expect(find.byIcon(Icons.hub), findsNothing);
    expect(find.byIcon(Icons.hub_outlined), findsNothing);
    expect(find.image(const AssetImage('assets/icons/icon.png')), findsNothing);

    await tester.tap(toggle);
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('custom-header-name-field')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('custom-header-value-field')),
      findsOneWidget,
    );
    for (final field in tester.widgetList<AccessibleFormField>(
      find.byType(AccessibleFormField),
    )) {
      check(field.prefixIcon).isNull();
    }
    for (final field in tester.widgetList<AdaptiveTextFormField>(
      find.byType(AdaptiveTextFormField),
    )) {
      check(field.prefixIcon).isNull();
      check(field.cupertinoDecoration).isNotNull();
      check(field.cupertinoDecoration!.border).isNull();
    }
    final addHeaderFinder = find.byKey(
      const ValueKey<String>('add-custom-header-button'),
    );
    expect(addHeaderFinder, findsOneWidget);
    final addHeaderButton = tester.widget<ConduitButton>(addHeaderFinder);
    check(addHeaderButton.text).equals('Add header');
    check(addHeaderButton.icon).isNull();
    check(addHeaderButton.useNativeLabel).isTrue();
    check(addHeaderButton.onPressed).isNull();

    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('custom-header-name-field')),
        matching: find.byType(EditableText),
      ),
      'X-Test-Header',
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('custom-header-value-field')),
        matching: find.byType(EditableText),
      ),
      'test-value',
    );
    await tester.pump();
    check(tester.widget<ConduitButton>(addHeaderFinder).onPressed).isNotNull();

    await harness.unmount(tester);
  });

  testWidgets('backend chooser uses local provider marks and clear copy', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final harness = _AuthHarness(server: server, platform: TargetPlatform.iOS);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(initialLocation: Routes.backendChooser),
    );
    await tester.pumpAndSettle();

    expect(find.text('Choose how to connect'), findsOneWidget);
    expect(find.text('Open WebUI'), findsOneWidget);
    expect(find.text('Connect directly'), findsOneWidget);
    expect(find.text('Hermes Agent'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.link), findsOneWidget);
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

    semantics.dispose();
    await harness.unmount(tester);
  });

  testWidgets(
    'Hermes onboarding has explicit back navigation and adaptive fields',
    (tester) async {
      _usePhoneViewport(tester);
      await _initializeBackendOnboardingStorage();
      addTearDown(PreferencesStore.debugReset);
      final harness = _BackendOnboardingHarness();
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        harness.build(initialLocation: Routes.backendChooser),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Hermes Agent'));
      await tester.pumpAndSettle();

      check(
        harness.router.routeInformationProvider.value.uri.path,
      ).equals(Routes.hermesSettings);
      check(harness.router.canPop()).isFalse();
      expect(find.byType(AdaptiveAuthScaffold), findsOneWidget);
      expect(find.byType(SettingsPageScaffold), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('hermes-onboarding-back-button')),
        findsOneWidget,
      );
      expect(find.byType(AccessibleFormField), findsNWidgets(3));
      expect(find.byType(ConduitInput), findsNothing);
      for (final field in tester.widgetList<AdaptiveTextFormField>(
        find.byType(AdaptiveTextFormField),
      )) {
        check(field.cupertinoDecoration).isNotNull();
        check(field.cupertinoDecoration!.border).isNull();
      }

      final container = ProviderScope.containerOf(
        tester.element(find.byType(HermesSettingsPage)),
      );
      check(container.read(hermesConfigProvider).enabled).isFalse();

      await tester.tap(
        find.byKey(const ValueKey<String>('hermes-onboarding-back-button')),
      );
      await tester.pumpAndSettle();

      check(
        harness.router.routeInformationProvider.value.uri.path,
      ).equals(Routes.backendChooser);
      expect(find.byType(BackendChooserPage), findsOneWidget);
      check(container.read(hermesConfigProvider).enabled).isFalse();
      await harness.unmount(tester);
    },
  );

  testWidgets(
    'Direct onboarding has explicit back navigation and a sticky action',
    (tester) async {
      _usePhoneViewport(tester);
      await _initializeBackendOnboardingStorage();
      addTearDown(PreferencesStore.debugReset);
      final harness = _BackendOnboardingHarness();
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
      expect(find.byType(AdaptiveAuthScaffold), findsOneWidget);
      expect(find.byType(SettingsPageScaffold), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('direct-onboarding-back-button')),
        findsOneWidget,
      );
      final startButton = tester.widget<ConduitButton>(
        find.byKey(const ValueKey<String>('finish-direct-onboarding-button')),
      );
      check(startButton.onPressed).isNull();

      await tester.tap(
        find.byKey(const ValueKey<String>('direct-onboarding-back-button')),
      );
      await tester.pumpAndSettle();

      check(
        harness.router.routeInformationProvider.value.uri.path,
      ).equals(Routes.backendChooser);
      expect(find.byType(BackendChooserPage), findsOneWidget);
      await harness.unmount(tester);
    },
  );

  testWidgets('Direct onboarding editor uses adaptive fields and navigation', (
    tester,
  ) async {
    _usePhoneViewport(tester);
    await _initializeBackendOnboardingStorage();
    addTearDown(PreferencesStore.debugReset);
    final harness = _BackendOnboardingHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(
        initialLocation: '${Routes.directConnections}/new?onboarding=true',
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(find.byType(AdaptiveAuthScaffold), findsOneWidget);
    expect(find.byType(SettingsPageScaffold), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('direct-editor-back-button')),
      findsOneWidget,
    );
    expect(find.byType(AccessibleFormField), findsNWidgets(6));
    expect(find.byType(ConduitInput), findsNothing);
    check(
      tester
          .widget<AnimatedCrossFade>(find.byType(AnimatedCrossFade))
          .crossFadeState,
    ).equals(CrossFadeState.showFirst);
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
    await tester.scrollUntilVisible(
      advancedToggle,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(advancedToggle);
    await tester.pumpAndSettle();

    check(
      tester
          .widget<AnimatedCrossFade>(find.byType(AnimatedCrossFade))
          .crossFadeState,
    ).equals(CrossFadeState.showSecond);
    final addHeaderFinder = find.byKey(
      const ValueKey<String>('add-direct-custom-header-button'),
    );
    check(tester.widget<ConduitButton>(addHeaderFinder).onPressed).isNull();
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
    check(tester.widget<ConduitButton>(addHeaderFinder).onPressed).isNotNull();
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
    check(tester.widget<ConduitButton>(addHeaderFinder).onPressed).isNotNull();

    await tester.tap(
      find.byKey(const ValueKey<String>('direct-editor-save-button')),
    );
    await tester.pump();

    expect(find.text('X.Test+Header'), findsOneWidget);
    expect(find.text('test-value'), findsOneWidget);
    expect(
      find.text('Enter an API key or choose no authentication.'),
      findsOneWidget,
    );
    final apiKeyField = tester.widget<AdaptiveTextFormField>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('direct-api-key-field')),
        matching: find.byType(AdaptiveTextFormField),
      ),
    );
    check(apiKeyField.cupertinoDecoration!.border).isNotNull();

    await tester.tap(
      find.byKey(const ValueKey<String>('direct-editor-back-button')),
    );
    await tester.pumpAndSettle();

    final route = harness.router.routeInformationProvider.value.uri;
    check(route.path).equals(Routes.directConnections);
    check(route.queryParameters['onboarding']).equals('true');
    await harness.unmount(tester);
  });

  testWidgets('sign-in displays a sanitized Open WebUI address', (
    tester,
  ) async {
    const serverWithSecrets = ServerConfig(
      id: 'server-with-secrets',
      name: 'Open WebUI',
      url:
          'https://user:password@example.com:8443/openwebui?token=secret#private',
      isActive: true,
    );
    final harness = _AuthHarness(server: serverWithSecrets);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(initialLocation: Routes.authentication),
    );
    await tester.pumpAndSettle();

    expect(find.text('https://example.com:8443/openwebui'), findsOneWidget);
    expect(find.text(serverWithSecrets.url), findsNothing);
    expect(find.textContaining('user:'), findsNothing);
    expect(find.textContaining('token='), findsNothing);
    expect(find.textContaining('#private'), findsNothing);

    await harness.unmount(tester);
  });

  testWidgets('sign-in hides unsupported saved server addresses', (
    tester,
  ) async {
    const unsupportedServer = ServerConfig(
      id: 'unsupported-server',
      name: 'Legacy server',
      url: 'ftp://user:password@example.com/private?token=secret',
      isActive: true,
    );
    final harness = _AuthHarness(server: unsupportedServer);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(initialLocation: Routes.authentication),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Server address unavailable'), findsOneWidget);
    expect(find.textContaining('ftp://'), findsNothing);
    expect(find.textContaining('user:'), findsNothing);
    expect(find.textContaining('token='), findsNothing);

    await harness.unmount(tester);
  });
}

class _AuthHarness {
  _AuthHarness({
    required this.server,
    this.platform = TargetPlatform.android,
    this.backendConfig = const BackendConfig(),
    this.disableAnimations = false,
  }) {
    when(() => storage.getSavedCredentials()).thenAnswer((_) async => null);
    when(() => storage.getAuthToken()).thenAnswer((_) async => '');
    when(() => storage.hasCredentials()).thenAnswer((_) async => false);
    when(() => storage.saveLocalUser(null)).thenAnswer((_) async {});
    when(() => storage.saveLocalUserAvatar(null)).thenAnswer((_) async {});
    when(() => storage.getReviewerMode()).thenAnswer((_) async => false);
  }

  final ServerConfig server;
  final TargetPlatform platform;
  final BackendConfig backendConfig;
  final bool disableAnimations;
  final _MockOptimizedStorageService storage = _MockOptimizedStorageService();
  final ErrorWidgetBuilder _previousErrorWidgetBuilder = ErrorWidget.builder;
  final void Function(FlutterErrorDetails)? _previousFlutterOnError =
      FlutterError.onError;

  late GoRouter router;
  bool _disposed = false;

  Widget build({required String initialLocation}) {
    router = GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: Routes.authentication,
          name: RouteNames.authentication,
          builder: (_, _) => AuthenticationPage(
            serverConfig: server,
            backendConfig: backendConfig,
          ),
        ),
        GoRoute(
          path: Routes.serverConnection,
          name: RouteNames.serverConnection,
          builder: (_, _) => const ServerConnectionPage(),
        ),
        GoRoute(
          path: Routes.backendChooser,
          name: RouteNames.backendChooser,
          builder: (_, _) => const BackendChooserPage(),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        activeServerProvider.overrideWith((_) async => server),
      ],
      child: MaterialApp.router(
        theme: ThemeData(platform: platform),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: disableAnimations),
          child: child!,
        ),
        routerConfig: router,
      ),
    );
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    dispose();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    router.dispose();
    ErrorWidget.builder = _previousErrorWidgetBuilder;
    FlutterError.onError = _previousFlutterOnError;
  }
}

class _MockOptimizedStorageService extends Mock
    implements OptimizedStorageService {}

Future<void> _initializeBackendOnboardingStorage() async {
  SharedPreferences.setMockInitialValues({});
  PreferencesStore.debugReset();
  PreferencesStore.debugOverride(await SharedPreferences.getInstance());
  FlutterSecureStorage.setMockInitialValues({});
}

void _usePhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(375, 812);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _BackendOnboardingHarness {
  _BackendOnboardingHarness() {
    router = GoRouter(
      routes: [
        GoRoute(
          path: Routes.backendChooser,
          name: RouteNames.backendChooser,
          builder: (_, _) => const BackendChooserPage(),
        ),
        GoRoute(
          path: Routes.hermesSettings,
          name: RouteNames.hermesSettings,
          builder: (_, state) =>
              HermesSettingsPage(isOnboarding: state.extra == true),
        ),
        GoRoute(
          path: Routes.directConnections,
          name: RouteNames.directConnections,
          builder: (_, state) => DirectConnectionsPage(
            isOnboarding: state.uri.queryParameters['onboarding'] == 'true',
          ),
        ),
        GoRoute(
          path: Routes.directConnectionEditor,
          name: RouteNames.directConnectionEditor,
          builder: (_, state) => DirectConnectionEditorPage(
            profileId: state.pathParameters['id']!,
            isOnboarding: state.uri.queryParameters['onboarding'] == 'true',
          ),
        ),
      ],
    );
  }

  late final GoRouter router;
  bool _disposed = false;

  Widget build({required String initialLocation}) {
    router.go(initialLocation);
    return ProviderScope(
      overrides: [
        secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
      ],
      child: MaterialApp.router(
        theme: ThemeData(platform: TargetPlatform.iOS),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    );
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    dispose();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    router.dispose();
  }
}
