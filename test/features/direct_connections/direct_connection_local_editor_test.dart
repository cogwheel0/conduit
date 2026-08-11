import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/providers/backend_mode_providers.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/features/direct_connections/controllers/direct_connection_editor_draft.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/views/direct_connection_editor_page.dart';
import 'package:conduit/features/direct_connections/views/direct_connections_page.dart';
import 'package:conduit/features/profile/widgets/adaptive_segmented_selector.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'direct_connections_ui_test_support.dart';

void main() {
  testWidgets('editor restores the OpenAI-family completion API mode', (
    tester,
  ) async {
    final profile = DirectConnectionProfile(
      id: 'lm-studio',
      name: 'LM Studio',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'http://localhost:1234/v1',
      openAiApiMode: DirectOpenAiApiMode.responses,
    );
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        profile,
      ]).encode(),
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DirectConnectionEditorPage(
            mode: DirectConnectionEditorMode.edit(profileId: 'lm-studio'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await directTestExpandAdvancedSettings(tester);

    final selector = tester
        .widget<AdaptiveSegmentedSelector<DirectOpenAiApiMode>>(
          find.byKey(const ValueKey<String>('direct-openai-api-mode-selector')),
        );
    expect(selector.value, DirectOpenAiApiMode.responses);
    expect(find.text('Chat Completions'), findsOneWidget);
    expect(find.text('Responses'), findsOneWidget);
  });

  testWidgets('switching an existing profile to OpenRouter normalizes state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final profile = DirectConnectionProfile(
      id: 'existing-generic',
      name: 'Existing provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://provider.example/v1',
      openAiApiMode: DirectOpenAiApiMode.responses,
    );
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        profile,
      ]).encode(),
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DirectConnectionEditorPage(
            mode: DirectConnectionEditorMode.edit(
              profileId: 'existing-generic',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('OpenRouter'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(
        const ValueKey<String>('direct-openai-api-mode-selector'),
        skipOffstage: false,
      ),
      findsNothing,
    );
    final authenticationSelector = tester
        .widget<DropdownButtonFormField<DirectAuthenticationMode>>(
          find.byKey(const Key('direct-authentication-selector-openrouter')),
        );
    expect(
      authenticationSelector.initialValue,
      DirectAuthenticationMode.bearer,
    );
    expect(
      tester
          .widget<AccessibleFormField>(
            find.byKey(
              const ValueKey<String>('direct-base-url-field'),
              skipOffstage: false,
            ),
          )
          .controller
          ?.text,
      kOpenRouterApiBaseUrl,
    );
  });

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
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add connection'));
      await tester.pumpAndSettle();

      expect(editorExtra, isA<NativeSheetNavigationOrigin>());
      expect(find.text('Connection editor'), findsOneWidget);
    },
  );

  testWidgets('editor rejects a save from a stale profile snapshot', (
    tester,
  ) async {
    final profile = DirectConnectionProfile(
      id: 'shared-profile',
      name: 'Original provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://provider.example/v1',
      apiKey: 'original-secret',
    );
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        profile,
      ]).encode(),
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DirectConnectionEditorPage(
            mode: DirectConnectionEditorMode.edit(profileId: 'shared-profile'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DirectConnectionEditorPage)),
    );

    await container
        .read(directConnectionProfilesProvider.notifier)
        .upsert(
          profile.copyWith(
            name: 'Concurrent provider',
            apiKey: 'concurrent-secret',
          ),
        );
    await tester.pumpAndSettle();
    final nameField = find.byKey(
      const ValueKey<String>('direct-connection-name-field'),
    );
    await tester.scrollUntilVisible(
      nameField,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(nameField, 'Stale rename');
    await tester.scrollUntilVisible(
      find.text('Save'),
      500,
      scrollable: find.byType(Scrollable).first,
    );

    final save = tester.widget<ConduitButton>(
      find.byWidgetPredicate(
        (widget) => widget is ConduitButton && widget.text == 'Save',
        skipOffstage: false,
      ),
    );
    save.onPressed!();
    await tester.pumpAndSettle();

    expect(
      find.text('This connection changed elsewhere. Reopen it before saving.'),
      findsAtLeastNWidgets(1),
    );
    final saved = container
        .read(directConnectionProfilesProvider)
        .requireValue
        .single;
    expect(saved.name, 'Concurrent provider');
    expect(saved.apiKey, 'concurrent-secret');
  });

  testWidgets('delete confirmation serializes editor operations', (
    tester,
  ) async {
    final profile = DirectConnectionProfile(
      id: 'home',
      name: 'Home provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://provider.example/v1',
      apiKey: 'secret',
    );
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        profile,
      ]).encode(),
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DirectConnectionEditorPage(
            mode: DirectConnectionEditorMode.edit(profileId: 'home'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Delete connection'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Delete connection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Delete connection?'), findsOneWidget);
    final save = tester.widget<ConduitButton>(
      find.byWidgetPredicate(
        (widget) => widget is ConduitButton && widget.text == 'Save',
      ),
    );
    final testConnection = tester.widget<ConduitButton>(
      find.byWidgetPredicate(
        (widget) => widget is ConduitButton && widget.text == 'Test connection',
      ),
    );
    final delete = tester.widget<ConduitButton>(
      find.byWidgetPredicate(
        (widget) =>
            widget is ConduitButton && widget.text == 'Delete connection',
      ),
    );
    expect(save.onPressed, isNull);
    expect(testConnection.onPressed, isNull);
    expect(delete.isLoading, isTrue);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    final restoredDelete = tester.widget<ConduitButton>(
      find.byWidgetPredicate(
        (widget) =>
            widget is ConduitButton && widget.text == 'Delete connection',
      ),
    );
    expect(restoredDelete.isLoading, isFalse);
    expect(restoredDelete.onPressed, isNotNull);
  });

  testWidgets('delete checks profiles added while confirmation is open', (
    tester,
  ) async {
    final profile = DirectConnectionProfile(
      id: 'home',
      name: 'Home provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://provider.example/v1',
      apiKey: 'secret',
    );
    final alternate = DirectConnectionProfile(
      id: 'backup',
      name: 'Backup provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://backup.example/v1',
      apiKey: 'backup-secret',
    );
    final backendController = DirectTestTrackingPreferredBackendController();
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        profile,
      ]).encode(),
    });
    final router = GoRouter(
      initialLocation: '/edit',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const SizedBox.shrink(),
          routes: [
            GoRoute(
              path: 'edit',
              builder: (_, _) => const DirectConnectionEditorPage(
                mode: DirectConnectionEditorMode.edit(profileId: 'home'),
              ),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
          preferredBackendProvider.overrideWith(() => backendController),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DirectConnectionEditorPage)),
    );

    await tester.scrollUntilVisible(
      find.text('Delete connection'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Delete connection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await container
        .read(directConnectionProfilesProvider.notifier)
        .upsert(alternate);
    await tester.pump();
    expect(
      container.read(directConnectionProfilesProvider).requireValue,
      hasLength(2),
    );

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(
      container
          .read(directConnectionProfilesProvider)
          .requireValue
          .map((item) => item.id),
      ['backup'],
    );
    expect(container.read(preferredBackendProvider), PreferredBackend.direct);
    expect(backendController.writes, isEmpty);
  });

  testWidgets('backend preference failure preserves the last direct profile', (
    tester,
  ) async {
    final profile = DirectConnectionProfile(
      id: 'home',
      name: 'Home provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://provider.example/v1',
      apiKey: 'secret',
    );
    FlutterSecureStorage.setMockInitialValues({
      'direct_connection_profiles_v1': DirectConnectionProfilesDocument([
        profile,
      ]).encode(),
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
          preferredBackendProvider.overrideWith(
            DirectTestFailingPreferredBackendController.new,
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DirectConnectionEditorPage(
            mode: DirectConnectionEditorMode.edit(profileId: 'home'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DirectConnectionEditorPage)),
    );

    await tester.scrollUntilVisible(
      find.text('Delete connection'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Delete connection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Could not delete this connection.'), findsOneWidget);
    expect(
      container.read(directConnectionProfilesProvider).requireValue.single.id,
      'home',
    );
    expect(container.read(preferredBackendProvider), PreferredBackend.direct);
    final durable = await const FlutterSecureStorage().read(
      key: 'direct_connection_profiles_v1',
    );
    expect(durable, contains('secret'));
  });

  testWidgets(
    'profile write failure restores a pre-cleared direct preference',
    (tester) async {
      final profile = DirectConnectionProfile(
        id: 'home',
        name: 'Home provider',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://provider.example/v1',
        apiKey: 'secret',
      );
      final backendController = DirectTestTrackingPreferredBackendController();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            secureStorageProvider.overrideWithValue(
              DirectTestRejectingProfileWriteSecureStorage(
                DirectConnectionProfilesDocument([profile]).encode(),
              ),
            ),
            preferredBackendProvider.overrideWith(() => backendController),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const DirectConnectionEditorPage(
              mode: DirectConnectionEditorMode.edit(profileId: 'home'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DirectConnectionEditorPage)),
      );

      await tester.scrollUntilVisible(
        find.text('Delete connection'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Delete connection'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Could not delete this connection.'), findsOneWidget);
      expect(
        container.read(directConnectionProfilesProvider).requireValue.single.id,
        'home',
      );
      expect(container.read(preferredBackendProvider), PreferredBackend.direct);
      expect(backendController.writes, [
        PreferredBackend.unset,
        PreferredBackend.direct,
      ]);
    },
  );
}
