import 'dart:async';

import 'package:conduit/features/navigation/providers/sidebar_providers.dart';
import 'package:conduit/features/navigation/widgets/sidebar_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show chatMessagesProvider;
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit/features/navigation/providers/conversation_selection_provider.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:go_router/go_router.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit/features/navigation/widgets/drawer_shell_page.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sidebar_page_test_support.dart';

void main() {
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  testWidgets('Mac shell exposes the complete desktop shortcut set', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSAppOnMacOverride = true;

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: AppKeyboardShortcuts(child: Focus(child: Text('Content'))),
        ),
      ),
    );

    final bindings = tester
        .widget<CallbackShortcuts>(find.byType(CallbackShortcuts))
        .bindings;
    expect(
      bindings.keys,
      containsAll(<ShortcutActivator>[
        const SingleActivator(
          LogicalKeyboardKey.keyN,
          meta: true,
          includeRepeats: false,
        ),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true),
        const SingleActivator(LogicalKeyboardKey.digit1, meta: true),
        const SingleActivator(LogicalKeyboardKey.digit2, meta: true),
        const SingleActivator(LogicalKeyboardKey.digit3, meta: true),
        const SingleActivator(LogicalKeyboardKey.digit4, meta: true),
        const SingleActivator(LogicalKeyboardKey.digit5, meta: true),
        const SingleActivator(LogicalKeyboardKey.comma, meta: true),
      ]),
    );
    expect(
      bindings.keys.where(
        (activator) =>
            activator.triggers?.contains(LogicalKeyboardKey.escape) ?? false,
      ),
      hasLength(1),
    );
  });

  testWidgets('Command-N accepts an initial press but ignores repeats', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSAppOnMacOverride = true;

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: AppKeyboardShortcuts(child: Focus(child: Text('Content'))),
        ),
      ),
    );

    final bindings = tester
        .widget<CallbackShortcuts>(find.byType(CallbackShortcuts))
        .bindings;
    final commandN = bindings.keys.whereType<SingleActivator>().singleWhere(
      (activator) => activator.trigger == LogicalKeyboardKey.keyN,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    expect(
      commandN.accepts(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyN,
          logicalKey: LogicalKeyboardKey.keyN,
          timeStamp: Duration.zero,
        ),
        HardwareKeyboard.instance,
      ),
      true,
    );
    expect(
      commandN.accepts(
        const KeyRepeatEvent(
          physicalKey: PhysicalKeyboardKey.keyN,
          logicalKey: LogicalKeyboardKey.keyN,
          timeStamp: Duration.zero,
        ),
        HardwareKeyboard.instance,
      ),
      false,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  });

  testWidgets('Command-K focuses search and Escape closes it', (tester) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSAppOnMacOverride = true;

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: AppKeyboardShortcuts(
            child: Consumer(builder: _searchShortcutTestChild),
          ),
        ),
      ),
    );
    final context = tester.element(find.text('Content'));
    final container = ProviderScope.containerOf(context);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();

    expect(container.read(sidebarHeaderSearchExpandedProvider), true);
    expect(container.read(sidebarSearchFieldFocusNodeProvider).hasFocus, true);

    container.read(sidebarSearchFieldControllerProvider).text = 'query';
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(container.read(sidebarHeaderSearchExpandedProvider), false);
    expect(container.read(sidebarSearchFieldControllerProvider).text, isEmpty);
  });

  for (final sliding in [false, true]) {
    testWidgets(
      'number shortcuts respect the sidebar layout (sliding: $sliding)',
      (tester) async {
        PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
        PlatformUiCapabilities.debugIOSAppOnMacOverride = true;
        final activeTab = SidebarTestTestSidebarActiveTab(SidebarTabId.chats);

        final router = GoRouter(
          initialLocation: Routes.chat,
          routes: [
            for (final path in [Routes.chat, Routes.notes])
              GoRoute(
                path: path,
                builder: (context, state) => const AppKeyboardShortcuts(
                  child: Focus(autofocus: true, child: Text('Content')),
                ),
              ),
          ],
        );
        NavigationService.attachRouter(router);
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appSettingsProvider.overrideWithValue(
                AppSettings(slidingSidebarEnabled: sliding),
              ),
              sidebarNavigationSnapshotProvider.overrideWithValue(
                SidebarNavigationSnapshot(
                  tabs: const [SidebarTabId.chats, SidebarTabId.notes],
                  selectedTab: SidebarTabId.chats,
                ),
              ),
              sidebarActiveTabProvider.overrideWith(() => activeTab),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );

        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();

        expect(activeTab.currentValue, SidebarTabId.notes);
        expect(
          router.routeInformationProvider.value.uri.path,
          sliding ? Routes.notes : Routes.chat,
        );
      },
    );
  }

  testWidgets('Command-N uses the backend selected in the sidebar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSAppOnMacOverride = true;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
    PlatformUiCapabilities.debugNativeIOS26Override = false;
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        hermesEnabled: true,
        shellChat: const Scaffold(
          body: Focus(autofocus: true, child: Text('Chat content')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SidebarPage)),
      listen: false,
    );
    container
        .read(sidebarHistoryTabProvider.notifier)
        .select(SidebarTabId.hermes);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    final model = container.read(selectedModelProvider);
    expect(model, isNotNull);
    expect(isHermesModel(model!), isTrue);
  });

  for (final available in [false, true]) {
    for (final shortcut in [false, true]) {
      testWidgets(
        'Open WebUI New Chat overrides a Hermes default (shortcut: $shortcut, available: $available)',
        (tester) async {
          tester.view.physicalSize = const Size(1024, 768);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
          PlatformUiCapabilities.debugIOSAppOnMacOverride = true;
          PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
          PlatformUiCapabilities.debugNativeIOS26Override = false;
          final hermes = hermesSyntheticModel();
          const serverModel = Model(id: 'demo-model', name: 'Demo model');
          await tester.pumpWidget(
            sidebarTestBuildHarness(
              controllers: SidebarTestSidebarHarnessControllers(),
              hermesEnabled: true,
              settings: AppSettings(defaultModel: hermes.id),
              models: [hermes, if (available) serverModel],
              loadServerDefaultModel: () async => serverModel.id,
              shellChat: const Scaffold(
                body: Focus(autofocus: true, child: Text('Chat content')),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final container = ProviderScope.containerOf(
            tester.element(find.byType(SidebarPage)),
            listen: false,
          );
          container.read(selectedModelProvider.notifier).set(hermes);
          container.read(pendingFolderIdProvider.notifier).set('demo-folder');
          if (shortcut) {
            await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
            await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          } else {
            await tester.tap(
              find.byKey(const ValueKey<String>('sidebar-create-button')),
            );
          }
          await tester.pumpAndSettle();
          expect(
            container.read(selectedModelProvider)?.id,
            available ? serverModel.id : hermes.id,
          );
          expect(
            container.read(pendingFolderIdProvider),
            available ? null : 'demo-folder',
          );
          expect(container.read(appSettingsProvider).defaultModel, hermes.id);
        },
      );
    }
  }

  for (final (appDefault, cachedDefault, serverDefault, expected, calls) in [
    (null, null, 'server-b', 'server-b', 1),
    (null, null, 'Server B', 'server-b', 1),
    ('server-a', null, 'server-b', 'server-a', 0),
    (kHermesDefaultModelId, null, 'server-b', 'server-b', 1),
    (null, null, kHermesDefaultModelId, 'server-a', 1),
    // With no default chosen the server is asked again, cache or not.
    (null, 'server-b', 'server-a', 'server-a', 1),
    ('missing-model', 'server-b', 'server-a', 'server-b', 0),
    (null, kHermesDefaultModelId, 'server-b', 'server-b', 1),
    (null, null, null, 'server-a', 1),
  ]) {
    testWidgets(
      'Open WebUI creation resolves defaults: $appDefault / $cachedDefault / $serverDefault',
      (tester) async {
        tester.view.physicalSize = const Size(1024, 768);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var requests = 0;
        await tester.pumpWidget(
          sidebarTestBuildHarness(
            controllers: SidebarTestSidebarHarnessControllers(),
            hermesEnabled: true,
            settings: AppSettings(defaultModel: appDefault),
            cachedDefaultModel: cachedDefault == null
                ? null
                : Model(id: cachedDefault, name: 'Cached model'),
            models: [
              hermesSyntheticModel(),
              const Model(id: 'server-a', name: 'Server A'),
              const Model(id: 'server-b', name: 'Server B'),
            ],
            loadServerDefaultModel: () async {
              requests++;
              return serverDefault;
            },
            shellChat: const Scaffold(body: Text('Chat content')),
          ),
        );
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byType(SidebarPage)),
          listen: false,
        );
        await tester.tap(
          find.byKey(const ValueKey<String>('sidebar-create-button')),
        );
        await tester.pumpAndSettle();
        expect(container.read(selectedModelProvider)?.id, expected);
        expect(requests, calls);
      },
    );
  }

  testWidgets('Open WebUI creation keeps a Direct-primary install on Direct', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final direct = DirectModelRegistry().replaceProfileModels(
      DirectConnectionProfile(
        id: 'direct-profile',
        name: 'Direct',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://api.example/v1',
        apiKey: 'key',
      ),
      [DirectRemoteModel(id: 'direct-model')],
    ).single;
    var requests = 0;
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        hermesEnabled: true,
        directPreferred: true,
        models: [
          hermesSyntheticModel(),
          const Model(id: 'server-a', name: 'Server A'),
          direct,
        ],
        loadServerDefaultModel: () async {
          requests++;
          return 'server-a';
        },
        shellChat: const Scaffold(body: Text('Chat content')),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SidebarPage)),
      listen: false,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('sidebar-create-button')),
    );
    await tester.pumpAndSettle();
    expect(container.read(selectedModelProvider), same(direct));
    expect(requests, 0);
  });

  testWidgets('Open WebUI creation says when models failed to load', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        modelsError: StateError('offline'),
        shellChat: const Scaffold(body: Text('Chat content')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('sidebar-create-button')),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(SidebarPage)))!;
    expect(find.text(l10n.failedToLoadModels), findsOneWidget);
    expect(find.text(l10n.noModelsAvailable), findsNothing);
  });

  testWidgets('a failed default retains an eligible selected model', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const selected = Model(id: 'server-b', name: 'Server B');
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        models: const [
          Model(id: 'server-a', name: 'Server A'),
          selected,
        ],
        shellChat: const Scaffold(body: Text('Chat content')),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SidebarPage)),
      listen: false,
    );
    container.read(selectedModelProvider.notifier).set(selected);
    container.read(pendingFolderIdProvider.notifier).set('demo-folder');
    await tester.tap(
      find.byKey(const ValueKey<String>('sidebar-create-button')),
    );
    await tester.pumpAndSettle();
    expect(container.read(selectedModelProvider)?.id, selected.id);
    expect(container.read(pendingFolderIdProvider), isNull);
  });

  testWidgets('selecting a conversation cancels a delayed creation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final result = Completer<String?>();
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        models: const [Model(id: 'server-model', name: 'Server model')],
        loadServerDefaultModel: () => result.future,
        shellChat: const Scaffold(body: Text('Chat content')),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SidebarPage)),
      listen: false,
    );
    container.read(pendingFolderIdProvider.notifier).set('demo-folder');
    await tester.tap(
      find.byKey(const ValueKey<String>('sidebar-create-button')),
    );
    await tester.pump();
    final selection = container
        .read(conversationSelectionProvider.notifier)
        .select(
          Conversation(
            id: 'other-chat',
            title: 'Other chat',
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
        );
    result.complete('server-model');
    await tester.pumpAndSettle();
    await selection;
    expect(container.read(pendingFolderIdProvider), 'demo-folder');
    expect(container.read(selectedModelProvider), isNull);
  });

  for (final (hermes, delayedModels) in [
    (false, false),
    (false, true),
    (true, false),
  ]) {
    testWidgets(
      'New Chat supersedes an earlier selection (Hermes: $hermes, delayed models: $delayedModels)',
      (tester) async {
        tester.view.physicalSize = const Size(1024, 768);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final summary = withChatStorageProvenance(
          Conversation(
            id: 'pending-chat',
            title: 'Pending chat',
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
          ChatStorageKind.directLocal,
        );
        final loaded = Completer<Conversation>();
        final models = Completer<List<Model>>();
        const serverModel = Model(id: 'server-model', name: 'Server model');
        await tester.pumpWidget(
          sidebarTestBuildHarness(
            controllers: SidebarTestSidebarHarnessControllers(),
            hermesEnabled: true,
            settings: const AppSettings(defaultModel: 'server-model'),
            models: const [serverModel],
            pendingModels: delayedModels ? models.future : null,
            pendingLoadedConversations: {
              conversationScopedId(summary): loaded.future,
            },
            shellChat: const Scaffold(body: Text('Chat content')),
          ),
        );
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byType(SidebarPage)),
          listen: false,
        );
        if (hermes) {
          container
              .read(sidebarHistoryTabProvider.notifier)
              .select(SidebarTabId.hermes);
          await tester.pumpAndSettle();
        }
        final selection = container
            .read(conversationSelectionProvider.notifier)
            .select(summary);
        await tester.pump();
        expect(container.read(conversationSelectionProvider).isLoading, true);
        await tester.tap(
          find.byKey(const ValueKey<String>('sidebar-create-button')),
        );
        await tester.pumpAndSettle();
        loaded.complete(summary);
        await tester.pumpAndSettle();
        expect(container.read(activeConversationProvider), isNull);
        if (delayedModels) {
          models.complete([serverModel]);
          await tester.pumpAndSettle();
        }
        expect(
          (await selection).disposition,
          ConversationSelectionDisposition.canceled,
        );
        expect(container.read(activeConversationProvider), isNull);
        expect(container.read(conversationSelectionProvider).isLoading, false);
      },
    );
  }

  for (final manual in [false, true]) {
    testWidgets('pending creation respects manual model selection: $manual', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final result = Completer<List<Model>>();
      const preferred = Model(id: 'preferred', name: 'Preferred model');
      const other = Model(id: 'other', name: 'Other model');
      await tester.pumpWidget(
        sidebarTestBuildHarness(
          controllers: SidebarTestSidebarHarnessControllers(),
          settings: const AppSettings(defaultModel: 'preferred'),
          pendingModels: result.future,
          shellChat: const Scaffold(body: Text('Chat content')),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SidebarPage)),
        listen: false,
      );
      container.read(pendingFolderIdProvider.notifier).set('demo-folder');
      await tester.tap(
        find.byKey(const ValueKey<String>('sidebar-create-button')),
      );
      await tester.pump();
      container.read(isManualModelSelectionProvider.notifier).set(manual);
      container.read(selectedModelProvider.notifier).set(other);
      result.complete([preferred, other]);
      await tester.pumpAndSettle();
      expect(
        container.read(selectedModelProvider)?.id,
        manual ? other.id : preferred.id,
      );
      expect(
        container.read(pendingFolderIdProvider),
        manual ? 'demo-folder' : null,
      );
    });
  }

  testWidgets('a delayed server default cannot create after navigation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final result = Completer<String?>();
    final hermes = hermesSyntheticModel();
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        hermesEnabled: true,
        models: [
          hermes,
          const Model(id: 'server-model', name: 'Server model'),
        ],
        loadServerDefaultModel: () => result.future,
        shellChat: const Scaffold(body: Text('Chat content')),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SidebarPage)),
      listen: false,
    );
    container.read(selectedModelProvider.notifier).set(hermes);
    container.read(pendingFolderIdProvider.notifier).set('demo-folder');
    await tester.tap(
      find.byKey(const ValueKey<String>('sidebar-create-button')),
    );
    await tester.pump();
    NavigationService.router.go(Routes.notes);
    await tester.pumpAndSettle();
    result.complete('server-model');
    await tester.pumpAndSettle();
    expect(NavigationService.currentRoute, Routes.notes);
    expect(container.read(selectedModelProvider)?.id, hermes.id);
    expect(container.read(pendingFolderIdProvider), 'demo-folder');
  });

  testWidgets('a delayed server default cannot clear a newer message', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final result = Completer<String?>();
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        models: const [Model(id: 'server-model', name: 'Server model')],
        loadServerDefaultModel: () => result.future,
        apiServerConfig: const ServerConfig(
          id: 'demo-server',
          name: 'Demo server',
          url: 'https://demo.example.test',
        ),
        shellChat: const Scaffold(body: Text('Chat content')),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SidebarPage)),
      listen: false,
    );
    // The chat page keeps the transcript alive while it is shown.
    container.listen(chatMessagesProvider, (_, _) {});
    container.read(pendingFolderIdProvider.notifier).set('demo-folder');
    await tester.tap(
      find.byKey(const ValueKey<String>('sidebar-create-button')),
    );
    await tester.pump();
    container
        .read(chatMessagesProvider.notifier)
        .addMessage(
          ChatMessage(
            id: 'demo-sent',
            role: 'user',
            content: 'Example question',
            timestamp: DateTime.utc(2026),
          ),
        );
    result.complete('server-model');
    await tester.pumpAndSettle();
    expect(container.read(pendingFolderIdProvider), 'demo-folder');
    expect([
      for (final message in container.read(chatMessagesProvider)) message.id,
    ], ['demo-sent']);
  });

  testWidgets('accountless New Chat keeps the generic creation path', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        hasApiService: false,
        isAuthenticated: false,
        shellChat: const Scaffold(body: Text('Chat content')),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SidebarPage)),
      listen: false,
    );
    container.read(pendingFolderIdProvider.notifier).set('demo-folder');
    await tester.tap(
      find.byKey(const ValueKey<String>('sidebar-create-button')),
    );
    await tester.pumpAndSettle();
    expect(container.read(pendingFolderIdProvider), isNull);
  });

  for (final direct in [false, true]) {
    testWidgets('Hermes route selects its history (direct: $direct)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      PlatformUiCapabilities.debugIOSAppOnMacOverride = true;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
      PlatformUiCapabilities.debugNativeIOS26Override = false;
      await tester.pumpWidget(
        sidebarTestBuildHarness(
          controllers: SidebarTestSidebarHarnessControllers(),
          hermesEnabled: true,
          initialLocation: direct ? Routes.hermesSessions : Routes.chat,
          shellChat: const Scaffold(
            body: Focus(autofocus: true, child: Text('Chat content')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (!direct) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pumpAndSettle();
      }
      expect(NavigationService.currentRoute, Routes.hermesSessions);
      await tester.tap(
        find.byKey(const ValueKey<String>('sidebar-create-button')),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SidebarPage)),
        listen: false,
      );
      final model = container.read(selectedModelProvider);
      expect(model, isNotNull);
      expect(isHermesModel(model!), isTrue);
    });
  }

  testWidgets('iPad and iPhone get the shortcuts as the Mac app does', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSAppOnMacOverride = false;

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: AppKeyboardShortcuts(
            child: Consumer(builder: _searchShortcutTestChild),
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.text('Content')),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();

    expect(container.read(sidebarHeaderSearchExpandedProvider), true);
  });

  testWidgets('Command-K still works after Escape leaves a field', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    final field = FocusNode();
    addTearDown(field.dispose);

    // The route's focus scope sits above the shortcuts, as the shell's own
    // page does in the app.
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: AppKeyboardShortcuts(
            child: Material(
              child: Consumer(
                builder: (context, ref, _) => Column(
                  children: [
                    TextField(focusNode: field),
                    Focus(
                      focusNode: ref.watch(sidebarSearchFieldFocusNodeProvider),
                      child: const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(TextField)),
    );
    await tester.showKeyboard(find.byType(TextField));
    expect(field.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(field.hasFocus, isFalse);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(container.read(sidebarHeaderSearchExpandedProvider), isTrue);
  });

  for (final kind in ['dialog', 'sheet']) {
    testWidgets('Escape closes a dismissible $kind inside the shell first', (
      tester,
    ) async {
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: AppKeyboardShortcuts(
              // The shell's routes live in a navigator under the shortcuts.
              child: Navigator(
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(
                    body: Consumer(builder: _searchShortcutTestChild),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final context = tester.element(find.text('Content'));
      final container = ProviderScope.containerOf(context);
      container
          .read(sidebarHeaderSearchExpandedProvider.notifier)
          .setExpanded(true);
      await tester.pump();
      if (kind == 'dialog') {
        unawaited(
          showDialog<void>(
            context: context,
            useRootNavigator: false,
            builder: (_) => const AlertDialog(content: Text('Synthetic')),
          ),
        );
      } else {
        unawaited(
          showModalBottomSheet<void>(
            context: context,
            builder: (_) => const Text('Synthetic'),
          ),
        );
      }
      await tester.pumpAndSettle();
      expect(find.text('Synthetic'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Synthetic'), findsNothing);
      // Search behind it is left as it was.
      expect(container.read(sidebarHeaderSearchExpandedProvider), isTrue);

      // With nothing in front, Escape is the shell's again.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(container.read(sidebarHeaderSearchExpandedProvider), isFalse);
    });
  }

  testWidgets('Escape closes search while message text has focus', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    final reply = FocusNode();
    addTearDown(reply.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: AppKeyboardShortcuts(
            child: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: Column(
                    children: [
                      const Consumer(builder: _searchShortcutTestChild),
                      // As a settled assistant reply is wrapped: its
                      // DismissIntent action only passes the key on.
                      SelectionArea(
                        focusNode: reply,
                        child: const Text('Synthetic reply'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.text('Content')),
    );
    container
        .read(sidebarHeaderSearchExpandedProvider.notifier)
        .setExpanded(true);
    reply.requestFocus();
    await tester.pump();
    expect(reply.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(container.read(sidebarHeaderSearchExpandedProvider), isFalse);

    // With search closed, the next Escape leaves the text.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(reply.hasFocus, isFalse);
  });

  testWidgets('Escape hides a selection menu before it closes search', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    final reply = FocusNode();
    addTearDown(reply.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: AppKeyboardShortcuts(
            child: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: Column(
                    children: [
                      const Consumer(builder: _searchShortcutTestChild),
                      // As a settled reply's selection shows its menu.
                      SelectionArea(
                        focusNode: reply,
                        contextMenuBuilder: (context, region) =>
                            AdaptiveTextSelectionMenu(
                              selectionRect: Rect.fromCenter(
                                center: region.contextMenuAnchors.primaryAnchor,
                                width: 1,
                                height: 1,
                              ),
                              anchors: region.contextMenuAnchors,
                              buttonItems: region.contextMenuButtonItems,
                              onDismiss: () => region.hideToolbar(false),
                            ),
                        child: const Text('Synthetic reply'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.text('Content')),
    );
    container
        .read(sidebarHeaderSearchExpandedProvider.notifier)
        .setExpanded(true);
    reply.requestFocus();
    await tester.pump();
    tester
        .state<SelectableRegionState>(find.byType(SelectableRegion))
        .selectAll(SelectionChangedCause.toolbar);
    await tester.pumpAndSettle();
    final menu = find.byType(AdaptiveTextSelectionMenu);
    expect(menu, findsOneWidget);
    expect(AdaptiveTextSelectionMenu.isShowing, isTrue);

    // The first Escape hides the menu and leaves search open.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(menu, findsNothing);
    expect(AdaptiveTextSelectionMenu.isShowing, isFalse);
    expect(container.read(sidebarHeaderSearchExpandedProvider), isTrue);

    // With no menu showing, the next one closes search.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(container.read(sidebarHeaderSearchExpandedProvider), isFalse);
  });

  testWidgets('Escape closes an open menu before search', (tester) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    final menu = MenuController();
    final anchor = FocusNode();
    addTearDown(anchor.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: AppKeyboardShortcuts(
            child: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: Column(
                    children: [
                      const Consumer(builder: _searchShortcutTestChild),
                      MenuAnchor(
                        controller: menu,
                        menuChildren: [
                          MenuItemButton(
                            onPressed: () {},
                            child: const Text('Synthetic action'),
                          ),
                        ],
                        child: TextButton(
                          focusNode: anchor,
                          onPressed: () {},
                          child: const Text('More'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.text('Content')),
    );
    container
        .read(sidebarHeaderSearchExpandedProvider.notifier)
        .setExpanded(true);
    anchor.requestFocus();
    menu.open();
    await tester.pumpAndSettle();
    expect(find.text('Synthetic action'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(menu.isOpen, isFalse);
    expect(container.read(sidebarHeaderSearchExpandedProvider), isTrue);
  });

  testWidgets('a dialog that Escape cannot dismiss keeps the layers behind '
      'it', (tester) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: AppKeyboardShortcuts(
            child: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => const Scaffold(
                  body: Consumer(builder: _searchShortcutTestChild),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final context = tester.element(find.text('Content'));
    final container = ProviderScope.containerOf(context);
    container
        .read(sidebarHeaderSearchExpandedProvider.notifier)
        .setExpanded(true);
    await tester.pump();
    unawaited(
      showDialog<void>(
        context: context,
        useRootNavigator: false,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(content: Text('Synthetic')),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Synthetic'), findsOneWidget);
    expect(container.read(sidebarHeaderSearchExpandedProvider), isTrue);
  });

  testWidgets('Android does not install the shortcuts', (tester) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: AppKeyboardShortcuts(child: Text('Content'))),
      ),
    );

    expect(find.byType(CallbackShortcuts), findsNothing);
  });

  testWidgets('a field keeps its editing keys, and Escape while an input '
      'method composes', (tester) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: AppKeyboardShortcuts(
            child: Material(
              child: TextField(controller: controller, focusNode: focusNode),
            ),
          ),
        ),
      ),
    );
    final bindings = tester
        .widget<CallbackShortcuts>(find.byType(CallbackShortcuts))
        .bindings;
    // Nothing the shell binds is a text editing key: Command with a letter
    // that edits text (select all, copy, cut, paste, undo), or a key
    // without Command other than Escape.
    for (final activator in bindings.keys) {
      final triggers = activator.triggers ?? const <LogicalKeyboardKey>[];
      expect(triggers, isNot(contains(LogicalKeyboardKey.keyA)));
      expect(triggers, isNot(contains(LogicalKeyboardKey.keyC)));
      expect(triggers, isNot(contains(LogicalKeyboardKey.keyV)));
      expect(triggers, isNot(contains(LogicalKeyboardKey.keyX)));
      expect(triggers, isNot(contains(LogicalKeyboardKey.keyZ)));
      if (activator is SingleActivator) expect(activator.meta, isTrue);
    }

    await tester.showKeyboard(find.byType(TextField));
    // Kana still being composed by an input method.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'かな',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    // Once the text is committed, Escape leaves the field.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'かな',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(focusNode.hasFocus, isFalse);
  });
}

Widget _searchShortcutTestChild(
  BuildContext context,
  WidgetRef ref,
  Widget? child,
) => Column(
  children: [
    const Focus(autofocus: true, child: Text('Content')),
    Focus(
      focusNode: ref.watch(sidebarSearchFieldFocusNodeProvider),
      child: const SizedBox.shrink(),
    ),
  ],
);
