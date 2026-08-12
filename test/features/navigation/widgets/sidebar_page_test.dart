import 'dart:ui' show Tristate;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:checks/checks.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/core/sync/sync_engine.dart';
import 'package:conduit/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit/features/navigation/widgets/sidebar_page.dart';
import 'package:conduit/features/navigation/widgets/sidebar_tab_registry.dart';
import 'package:conduit/features/navigation/widgets/sidebar_user_pill.dart';
import 'package:conduit/features/hermes/models/hermes_job.dart';
import 'package:conduit/features/hermes/widgets/hermes_sessions_tab.dart';
import 'package:conduit/features/terminal/models/terminal_models.dart';
import 'package:conduit/features/terminal/providers/terminal_providers.dart';
import 'package:conduit/features/terminal/widgets/terminal_tab.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sidebar_page_test_support.dart';

void main() {
  testWidgets('native glass profile avatar uses one compact native button', (
    tester,
  ) async {
    var presses = 0;
    const profileButtonKey = ValueKey<String>('sidebar-profile-button');

    await tester.pumpWidget(
      CupertinoApp(
        home: Center(
          child: buildSidebarProfileButton(
            supportsNativeGlass: true,
            onPressed: () => presses++,
            fallbackStyle: AdaptiveButtonStyle.glass,
            child: const SizedBox.square(dimension: 36),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(CupertinoButton), findsNothing);
    expect(find.byType(CNButton), findsOneWidget);
    expect(find.byType(AdaptiveButton), findsNothing);
    expect(tester.getSize(find.byKey(profileButtonKey)), const Size(44, 44));
    await tester.tap(find.byKey(profileButtonKey));
    expect(presses, 1);

    await tester.pumpWidget(
      CupertinoApp(
        home: Center(
          child: buildSidebarProfileButton(
            supportsNativeGlass: false,
            onPressed: () {},
            fallbackStyle: AdaptiveButtonStyle.plain,
            child: const SizedBox.square(dimension: 36),
          ),
        ),
      ),
    );

    expect(find.byType(AdaptiveButton), findsOneWidget);
  });

  test('native profile glass reuses cached avatar bytes', () {
    final bytes = Uint8List.fromList(const [1, 2, 3]);
    final target =
        buildSidebarProfileButton(
              supportsNativeGlass: true,
              onPressed: () {},
              fallbackStyle: AdaptiveButtonStyle.glass,
              nativeAvatarBytes: bytes,
              child: const SizedBox.square(dimension: 36),
            )
            as SizedBox;
    final button = target.child! as CNButton;
    final placeholderTarget =
        buildSidebarProfileButton(
              supportsNativeGlass: true,
              onPressed: () {},
              fallbackStyle: AdaptiveButtonStyle.glass,
              child: const SizedBox.square(dimension: 36),
            )
            as SizedBox;
    final placeholderButton = placeholderTarget.child! as CNButton;

    expect(identical(button.imageAsset?.imageData, bytes), isTrue);
    expect(button.imageAsset?.assetPath, isEmpty);
    expect(button.imageAsset?.size, 28);
    expect(button.config.minHeight, TouchTarget.minimum);
    expect(button.config.width, TouchTarget.minimum);
    expect(button.config.style, CNButtonStyle.glass);
    expect(button.key, isNot(placeholderButton.key));
  });

  test('Hermes profile host fallback comes from localizations', () {
    check(
      AppLocalizationsEn().hermesSelfHostedAgentLabel,
    ).equals('Self-hosted agent');
  });

  test('accountless native fallback targets generic settings', () {
    expect(
      sidebarProfileFallbackRouteName(
        directPrimary: true,
        hasOpenWebUiUser: false,
      ),
      RouteNames.profile,
    );
    expect(
      sidebarProfileFallbackRouteName(
        directPrimary: true,
        hasOpenWebUiUser: true,
      ),
      RouteNames.profile,
    );
  });

  testWidgets(
    'renders without TabBarView and shows chats as active by default',
    (tester) async {
      final controllers = SidebarTestSidebarHarnessControllers();

      await tester.pumpWidget(
        sidebarTestBuildHarness(controllers: controllers),
      );

      expect(find.byType(TabBarView), findsNothing);

      final chatsLayer = tester.widget<Opacity>(
        sidebarTestLayerOpacityFinder(SidebarTestSidebarTabLayer.chats),
      );
      final terminalLayer = tester.widget<Opacity>(
        sidebarTestLayerOpacityFinder(SidebarTestSidebarTabLayer.terminal),
      );

      expect(chatsLayer.opacity, 1);
      expect(terminalLayer.opacity, 0);
    },
  );

  testWidgets('shows determinate sync progress above every sidebar tab', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        syncStatus: const SyncStatus(
          phase: SyncPhase.running,
          stage: SyncStage.chats,
          completedItems: 3,
          totalItems: 8,
        ),
      ),
    );

    final progress = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey<String>('sidebar-sync-progress')),
    );
    check(progress.value).isNotNull().equals(3 / 8);
    check(progress.semanticsLabel).equals('Syncing chats');
    check(progress.semanticsValue).equals('38%');

    await tester.tap(sidebarTestBottomNavTabLabel('Notes'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('sidebar-sync-progress')),
      findsOneWidget,
    );
  });

  testWidgets('hides sidebar sync progress while idle', (tester) async {
    final controllers = SidebarTestSidebarHarnessControllers();

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        syncStatus: const SyncStatus(),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('sidebar-sync-progress')),
      findsNothing,
    );
  });

  testWidgets('retained API after logout hides OpenWebUI-only tabs', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();

    await tester.pumpWidget(
      sidebarTestBuildHarness(controllers: controllers, isAuthenticated: false),
    );
    await tester.pump();

    expect(sidebarTestBottomNavTabLabel('Notes'), findsNothing);
    expect(sidebarTestBottomNavTabLabel('Terminal'), findsNothing);
    expect(sidebarTestBottomNavTabLabel('Channels'), findsNothing);
  });

  testWidgets(
    'tapping terminal syncs provider state and activates the terminal layer',
    (tester) async {
      final controllers = SidebarTestSidebarHarnessControllers();

      await tester.pumpWidget(
        sidebarTestBuildHarness(controllers: controllers),
      );

      await tester.tap(sidebarTestBottomNavTabLabel('Terminal'));
      await tester.pump();

      final terminalLayer = tester.widget<Opacity>(
        sidebarTestLayerOpacityFinder(SidebarTestSidebarTabLayer.terminal),
      );

      expect(terminalLayer.opacity, 1);
      expect(controllers.activeTabNotifier.currentValue, SidebarTabId.terminal);
    },
  );

  testWidgets('tab definitions own terminal panel transitions', (tester) async {
    final controllers = SidebarTestSidebarHarnessControllers();
    final terminalServers = [sidebarTestDefaultTerminalServers().first];

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        terminalServers: terminalServers,
      ),
    );
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SidebarPage)),
    );

    await tester.tap(sidebarTestBottomNavTabLabel('Terminal'));
    await tester.pump();
    check(
      container.read(terminalSidebarPanelProvider),
    ).equals(TerminalSidebarPanel.files);

    await tester.tap(sidebarTestBottomNavTabLabel('Notes'));
    await tester.pump();
    check(
      container.read(terminalSidebarPanelProvider),
    ).equals(TerminalSidebarPanel.console);
  });

  testWidgets(
    'persisted Notes identity restores notes when notes are enabled',
    (tester) async {
      final controllers = SidebarTestSidebarHarnessControllers(
        initialTab: SidebarTabId.notes,
      );

      await tester.pumpWidget(
        sidebarTestBuildHarness(controllers: controllers),
      );

      final notesLayer = tester.widget<Opacity>(
        sidebarTestLayerOpacityFinder(SidebarTestSidebarTabLayer.notes),
      );
      final chatsLayer = tester.widget<Opacity>(
        sidebarTestLayerOpacityFinder(SidebarTestSidebarTabLayer.chats),
      );

      expect(notesLayer.opacity, 1);
      expect(chatsLayer.opacity, 0);
    },
  );

  testWidgets('reselecting a legacy tab persists its stable identity', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers(legacyIndex: 1);

    await tester.pumpWidget(sidebarTestBuildHarness(controllers: controllers));

    final notesLayer = tester.widget<Opacity>(
      sidebarTestLayerOpacityFinder(SidebarTestSidebarTabLayer.notes),
    );
    check(notesLayer.opacity).equals(1);

    await tester.tap(sidebarTestBottomNavTabLabel('Notes'));
    await tester.pump();

    check(
      controllers.activeTabNotifier.currentValue,
    ).equals(SidebarTabId.notes);
    check(controllers.activeTabNotifier.pendingLegacyIndex()).isNull();
  });

  testWidgets(
    'unavailable persisted tab falls back without changing its identity',
    (tester) async {
      final controllers = SidebarTestSidebarHarnessControllers(
        notesEnabled: false,
        initialTab: SidebarTabId.notes,
      );

      await tester.pumpWidget(
        sidebarTestBuildHarness(controllers: controllers),
      );

      final chatsLayer = tester.widget<Opacity>(
        sidebarTestLayerOpacityFinder(SidebarTestSidebarTabLayer.chats),
      );

      expect(chatsLayer.opacity, 1);
      expect(sidebarTestBottomNavTabLabel('Notes'), findsNothing);
      expect(controllers.activeTabNotifier.currentValue, SidebarTabId.notes);
    },
  );

  testWidgets('active optional tab restores when its feature returns', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers(
      initialTab: SidebarTabId.notes,
    );

    await tester.pumpWidget(sidebarTestBuildHarness(controllers: controllers));

    controllers.notesNotifier.setEnabled(false);
    await tester.pump();

    final chatsLayer = tester.widget<Opacity>(
      sidebarTestLayerOpacityFinder(SidebarTestSidebarTabLayer.chats),
    );

    expect(chatsLayer.opacity, 1);
    expect(controllers.activeTabNotifier.currentValue, SidebarTabId.notes);
    expect(sidebarTestBottomNavTabLabel('Notes'), findsNothing);

    controllers.notesNotifier.setEnabled(true);
    await tester.pump();

    final notesLayer = tester.widget<Opacity>(
      sidebarTestLayerOpacityFinder(SidebarTestSidebarTabLayer.notes),
    );
    expect(notesLayer.opacity, 1);
  });

  testWidgets('inactive layers are excluded from focus and semantics', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();

    await tester.pumpWidget(sidebarTestBuildHarness(controllers: controllers));

    final activeFocus = tester.widget<ExcludeFocus>(
      find
          .descendant(
            of: sidebarTestLayerRootFinder(SidebarTestSidebarTabLayer.chats),
            matching: find.byType(ExcludeFocus),
          )
          .first,
    );
    final inactiveFocus = tester.widget<ExcludeFocus>(
      find
          .descendant(
            of: sidebarTestLayerRootFinder(SidebarTestSidebarTabLayer.terminal),
            matching: find.byType(ExcludeFocus),
          )
          .first,
    );
    final activeSemantics = tester.widget<ExcludeSemantics>(
      find
          .descendant(
            of: sidebarTestLayerRootFinder(SidebarTestSidebarTabLayer.chats),
            matching: find.byType(ExcludeSemantics),
          )
          .first,
    );
    final inactiveSemantics = tester.widget<ExcludeSemantics>(
      find
          .descendant(
            of: sidebarTestLayerRootFinder(SidebarTestSidebarTabLayer.terminal),
            matching: find.byType(ExcludeSemantics),
          )
          .first,
    );

    expect(activeFocus.excluding, isFalse);
    expect(inactiveFocus.excluding, isTrue);
    expect(activeSemantics.excluding, isFalse);
    expect(inactiveSemantics.excluding, isTrue);
  });

  testWidgets('renders adaptive bottom tab bar instead of TabBar', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();
    await tester.pumpWidget(sidebarTestBuildHarness(controllers: controllers));

    expect(find.byType(TabBar), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
    final navigationBar = tester.widget<NavigationBar>(
      find.byType(NavigationBar),
    );
    expect(navigationBar.height, 56);
    expect(
      navigationBar.labelBehavior,
      NavigationDestinationLabelBehavior.alwaysShow,
    );
    expect(sidebarTestBottomNavTabLabel('Chats'), findsOneWidget);
    expect(sidebarTestBottomNavTabLabel('Terminal'), findsOneWidget);
    expect(sidebarTestBottomNavTabLabel('Notes'), findsOneWidget);
    expect(sidebarTestBottomNavTabLabel('Channels'), findsOneWidget);
  });

  testWidgets('reselecting a tab uses a static scroll under reduced motion', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();
    final timestamp = DateTime(2026, 1, 1);
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        disableAnimations: true,
        conversations: List<Conversation>.generate(
          30,
          (index) => Conversation(
            id: 'reduced-motion-$index',
            title: 'Conversation $index',
            createdAt: timestamp,
            updatedAt: timestamp,
            messages: const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final chatsScroll = find.byKey(
      const PageStorageKey<String>('chats_drawer_scroll'),
    );
    final controller = tester.widget<CustomScrollView>(chatsScroll).controller!;
    await tester.drag(chatsScroll, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));

    await tester.tap(sidebarTestBottomNavTabLabel('Chats'));
    await tester.pump();

    expect(controller.offset, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('persistent tablet uses bottom navigation with all five tabs', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        hermesEnabled: true,
        persistentTabletSidebar: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('sidebar-tablet-navigation')),
      findsNothing,
    );
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(
      tester.getSize(find.byType(NavigationBar)).width,
      tester
          .getSize(find.byKey(const ValueKey<String>('sidebar-page-surface')))
          .width,
    );
    for (final label in ['Chats', 'Hermes', 'Notes', 'Terminal', 'Channels']) {
      expect(sidebarTestBottomNavTabLabel(label), findsOneWidget);
    }

    await tester.tap(sidebarTestBottomNavTabLabel('Notes'));
    await tester.pumpAndSettle();

    expect(controllers.activeTabNotifier.currentValue, SidebarTabId.notes);
    expect(
      find.descendant(
        of: sidebarTestLayerRootFinder(SidebarTestSidebarTabLayer.notes),
        matching: find.byWidgetPredicate(
          (widget) => widget is ExcludeSemantics && !widget.excluding,
        ),
      ),
      findsOneWidget,
    );

    await tester.tap(sidebarTestBottomNavTabLabel('Channels'));
    await tester.pumpAndSettle();

    expect(controllers.activeTabNotifier.currentValue, SidebarTabId.channels);
    expect(
      find.descendant(
        of: sidebarTestLayerRootFinder(SidebarTestSidebarTabLayer.channels),
        matching: find.byWidgetPredicate(
          (widget) => widget is ExcludeSemantics && !widget.excluding,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('persistent iOS 26 sidebar requests a full-width native bar', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);

    final controllers = SidebarTestSidebarHarnessControllers();
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        hermesEnabled: true,
        persistentTabletSidebar: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(CNTabBar), findsNothing);
    final tabBar = tester.widget<CupertinoTabBar>(find.byType(CupertinoTabBar));
    expect(tabBar.items, hasLength(5));
    expect(tabBar.items[1].icon, isA<ImageIcon>());
    expect((tabBar.items[1].icon as ImageIcon).image, kHermesTabIcon);
    expect(
      tester.getSize(find.byType(CupertinoTabBar)).width,
      tester.getSize(find.byType(SidebarPage)).width,
    );
  });

  testWidgets('iOS 26 native overlay keeps the Hermes logo and tab labels', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);

    final controllers = SidebarTestSidebarHarnessControllers();
    await tester.pumpWidget(
      sidebarTestBuildHarness(controllers: controllers, hermesEnabled: true),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final tabBar = tester.widget<CNTabBar>(find.byType(CNTabBar));
    expect(tabBar.items, hasLength(5));
    expect(tabBar.iconSize, isNull);
    expect(tabBar.items.map((item) => item.label), [
      'Chats',
      'Hermes',
      'Notes',
      'Terminal',
      'Channels',
    ]);
    expect(tabBar.items[1].icon, isNull);
    expect(tabBar.items[1].imageAsset?.size, 26);
    expect(tabBar.items[0].icon?.size, kCupertinoNativeControlSymbolExtent);
    expect(tabBar.items[2].icon?.size, kCupertinoNativeControlSymbolExtent);
    expect(tabBar.items[4].icon?.size, kCupertinoNativeControlSymbolExtent);
    expect(
      tabBar.items[1].imageAsset?.assetPath,
      'assets/icons/hermes_agent_tab.svg',
    );
  });

  test('native Hermes artwork fills its requested tab icon canvas', () async {
    final svg = await rootBundle.loadString(
      'assets/icons/hermes_agent_tab.svg',
    );

    expect(svg, contains('viewBox="0 0 252 256"'));
  });

  testWidgets('persistent tablet navigation remains usable at 2x text', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        hermesEnabled: true,
        persistentTabletSidebar: true,
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('sidebar-tablet-navigation')),
      findsNothing,
    );
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.tap(sidebarTestBottomNavTabLabel('Notes'));
    await tester.pumpAndSettle();
    expect(controllers.activeTabNotifier.currentValue, SidebarTabId.notes);
  });

  testWidgets('Hermes bottom tab follows dark navigation icon colors', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        hermesEnabled: true,
        theme: AppTheme.dark(TweakcnThemes.t3Chat),
      ),
    );
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(SidebarPage));
    final conduitTheme = context.conduitTheme;
    Finder hermesImage() => find.byWidgetPredicate(
      (widget) => widget is Image && widget.image == kHermesTabIcon,
    );
    Finder hermesImageIcon() =>
        find.ancestor(of: hermesImage(), matching: find.byType(ImageIcon));

    expect(
      tester.widget<Image>(hermesImage()).color,
      conduitTheme.textSecondary,
    );
    expect(
      tester.widget<ImageIcon>(hermesImageIcon()).size,
      kHermesTabIconSize,
    );

    await tester.tap(sidebarTestBottomNavTabLabel('Hermes'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Image>(hermesImage()).color,
      conduitTheme.buttonPrimary,
    );
  });

  testWidgets('hides bottom navigation when Hermes is the only sidebar tab', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        hermesOnly: true,
        hermesEnabled: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(HermesSessionsTab), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets(
    'Hermes-only mode keeps its sole tab while enabled state is settling',
    (tester) async {
      final controllers = SidebarTestSidebarHarnessControllers();
      await tester.pumpWidget(
        sidebarTestBuildHarness(
          controllers: controllers,
          hermesOnly: true,
          hermesEnabled: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(HermesSessionsTab), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Hermes sidebar uses one scheduled-agents launcher tile', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        hermesOnly: true,
        hermesEnabled: true,
        hermesJobs: const [
          HermesJob(
            id: 'daily-summary',
            name: 'Daily summary',
            prompt: 'Summarize updates',
            schedule: '0 9 * * *',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('hermes-scheduled-agents-tile')),
      findsOneWidget,
    );
    expect(find.text('1 active · 1 schedule'), findsOneWidget);
    expect(find.text('Daily summary'), findsNothing);
    expect(find.text('0 9 * * *'), findsNothing);
  });

  testWidgets('hides terminal tab when no terminal servers are available', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        terminalServers: const <TerminalServerInfo>[],
      ),
    );
    await tester.pumpAndSettle();

    expect(sidebarTestBottomNavTabLabel('Terminal'), findsNothing);
    expect(find.byType(TerminalTab), findsNothing);
  });

  testWidgets('keeps terminal tab visible when terminal discovery fails', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        terminalServersError: Exception('terminal discovery failed'),
      ),
    );
    await tester.pumpAndSettle();

    expect(sidebarTestBottomNavTabLabel('Terminal'), findsOneWidget);
    expect(find.byType(TerminalTab), findsOneWidget);
  });

  testWidgets('channel helpers align when terminal tab is hidden', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers(
      initialTab: SidebarTabId.channels,
    );
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        terminalServers: const <TerminalServerInfo>[],
      ),
    );
    await tester.pumpAndSettle();

    expect(sidebarTestBottomNavTabLabel('Terminal'), findsNothing);
    expect(sidebarTestBottomNavTabLabel('Channels'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);

    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();

    final context = tester.element(find.byType(SidebarPage));
    final l10n = AppLocalizations.of(context)!;
    expect(find.text(l10n.searchChannels), findsOneWidget);
    expect(find.text(l10n.searchFiles), findsNothing);
  });

  testWidgets('adaptive bottom bar tapping switches active tab', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();
    await tester.pumpWidget(sidebarTestBuildHarness(controllers: controllers));

    await tester.tap(sidebarTestBottomNavTabLabel('Channels'));
    await tester.pumpAndSettle();

    final channelsLayer = tester.widget<Opacity>(
      sidebarTestLayerOpacityFinder(SidebarTestSidebarTabLayer.channels),
    );
    expect(channelsLayer.opacity, 1);

    final chatsLayer = tester.widget<Opacity>(
      sidebarTestLayerOpacityFinder(SidebarTestSidebarTabLayer.chats),
    );
    expect(chatsLayer.opacity, 0);
  });

  testWidgets('adaptive bottom bar provides tab semantics', (tester) async {
    final controllers = SidebarTestSidebarHarnessControllers();
    await tester.pumpWidget(sidebarTestBuildHarness(controllers: controllers));

    final barScope = find.byType(NavigationBar);

    final chatsSemantics = tester.getSemantics(
      find.descendant(of: barScope, matching: find.text('Chats')).first,
    );
    expect(
      chatsSemantics.getSemanticsData().flagsCollection.isSelected,
      Tristate.isTrue,
    );

    final channelsSemantics = tester.getSemantics(
      find.descendant(of: barScope, matching: find.text('Channels')).first,
    );
    expect(
      channelsSemantics.getSemanticsData().flagsCollection.isSelected,
      Tristate.isFalse,
    );
  });
}
