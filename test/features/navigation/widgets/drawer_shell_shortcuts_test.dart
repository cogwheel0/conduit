import 'dart:async';

import 'package:conduit/features/navigation/providers/sidebar_providers.dart';
import 'package:conduit/features/navigation/widgets/sidebar_page.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit/features/navigation/providers/conversation_selection_provider.dart';
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
          home: MacDesktopShortcuts(child: Focus(child: Text('Content'))),
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
        const SingleActivator(LogicalKeyboardKey.escape),
      ]),
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
          home: MacDesktopShortcuts(child: Focus(child: Text('Content'))),
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
          home: MacDesktopShortcuts(
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
                builder: (context, state) => const MacDesktopShortcuts(
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
    (null, 'server-b', 'server-a', 'server-b', 0),
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

  testWidgets('non-Mac iOS does not install desktop shortcuts', (tester) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSAppOnMacOverride = false;

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: MacDesktopShortcuts(child: Text('Content'))),
      ),
    );

    expect(find.byType(CallbackShortcuts), findsNothing);
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
