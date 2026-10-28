import 'dart:ui' show Tristate;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/adaptive_dropdown_field.dart';
import 'package:checks/checks.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit/features/navigation/widgets/sidebar_page.dart';
import 'package:conduit/features/navigation/widgets/chats_drawer.dart';
import 'package:conduit/features/notes/widgets/notes_list_tab.dart';
import 'package:conduit/features/channels/widgets/channel_list_tab.dart';
import 'package:conduit/features/navigation/widgets/sidebar_user_pill.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit/features/hermes/widgets/hermes_sessions_tab.dart';
import 'package:conduit/features/terminal/models/terminal_models.dart';
import 'package:conduit/features/terminal/providers/terminal_providers.dart';
import 'package:conduit/features/terminal/widgets/terminal_tab.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sidebar_page_test_support.dart';

void main() {
  test('Mac windows do not reserve the iPad window-control inset', () {
    expect(
      resolveSidebarWindowedLeadingInset(
        usesNativeIOS26Chrome: true,
        isWindowed: true,
        isIOSAppOnMac: true,
      ),
      0,
    );
    expect(
      resolveSidebarWindowedLeadingInset(
        usesNativeIOS26Chrome: true,
        isWindowed: true,
        isIOSAppOnMac: false,
      ),
      62,
    );
  });

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
    final target = buildSidebarProfileButton(
      supportsNativeGlass: true,
      onPressed: () {},
      fallbackStyle: AdaptiveButtonStyle.glass,
      nativeAvatarBytes: bytes,
      child: const SizedBox.square(dimension: 36),
    ) as SizedBox;
    final button = target.child! as CNButton;
    final placeholderTarget = buildSidebarProfileButton(
      supportsNativeGlass: true,
      onPressed: () {},
      fallbackStyle: AdaptiveButtonStyle.glass,
      child: const SizedBox.square(dimension: 36),
    ) as SizedBox;
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
    check(AppLocalizationsEn().hermesSelfHostedAgentLabel)
        .equals('Self-hosted agent');
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

  testWidgets('sidebar mounts only chat history', (tester) async {
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
      ),
    );
    expect(find.byType(TabBarView), findsNothing);
    expect(find.byType(ChatsDrawer), findsOneWidget);
    expect(find.byType(TerminalTab), findsNothing);
    expect(find.byType(NotesListTab), findsNothing);
    expect(find.byType(ChannelListTab), findsNothing);
  });

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

    await sidebarTestSelectDestination(tester, 'Notes');
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

    expect(sidebarTestDestinationLabel('Notes'), findsNothing);
    expect(sidebarTestDestinationLabel('Terminal'), findsNothing);
    expect(sidebarTestDestinationLabel('Channels'), findsNothing);
  });

  testWidgets(
    'terminal destination opens the main page and syncs provider state',
    (tester) async {
      final controllers = SidebarTestSidebarHarnessControllers();

      await tester.pumpWidget(
        sidebarTestBuildHarness(controllers: controllers),
      );

      await sidebarTestSelectDestination(tester, 'Terminal');
      await tester.pump();

      expect(NavigationService.currentRoute, Routes.terminal);
      expect(find.byType(TerminalTab), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SidebarPage),
          matching: find.byType(TerminalTab),
        ),
        findsNothing,
      );
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

    await sidebarTestSelectDestination(tester, 'Terminal');
    await tester.pump();
    check(container.read(terminalSidebarPanelProvider))
        .equals(TerminalSidebarPanel.files);

    await sidebarTestSelectDestination(tester, 'Notes');
    await tester.pump();
    check(container.read(terminalSidebarPanelProvider))
        .equals(TerminalSidebarPanel.console);
  });

  testWidgets('persisted destination never replaces sidebar chat history', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers(
      initialTab: SidebarTabId.notes,
    );
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        initialLocation: Routes.chat,
      ),
    );
    expect(find.byType(ChatsDrawer), findsOneWidget);
    expect(find.byType(NotesListTab), findsNothing);
    expect(controllers.activeTabNotifier.currentValue, SidebarTabId.notes);
  });

  testWidgets('selecting a legacy destination persists its stable identity', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers(legacyIndex: 1);
    await tester.pumpWidget(sidebarTestBuildHarness(controllers: controllers));
    await sidebarTestSelectDestination(tester, 'Notes');
    expect(NavigationService.currentRoute, Routes.notes);
    expect(controllers.activeTabNotifier.currentValue, SidebarTabId.notes);
    expect(controllers.activeTabNotifier.pendingLegacyIndex(), isNull);
  });

  testWidgets(
    'unavailable persisted destination keeps chat history available',
    (tester) async {
      final controllers = SidebarTestSidebarHarnessControllers(
        notesEnabled: false,
        initialTab: SidebarTabId.notes,
      );
      await tester.pumpWidget(
        sidebarTestBuildHarness(controllers: controllers),
      );
      expect(find.byType(ChatsDrawer), findsOneWidget);
      expect(sidebarTestDestinationLabel('Notes'), findsNothing);
      expect(controllers.activeTabNotifier.currentValue, SidebarTabId.notes);
    },
  );

  testWidgets('optional destination visibility follows feature availability', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers(
      initialTab: SidebarTabId.notes,
    );
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        initialLocation: Routes.chat,
      ),
    );
    controllers.notesNotifier.setEnabled(false);
    await tester.pump();
    expect(sidebarTestDestinationLabel('Notes'), findsNothing);
    expect(find.byType(ChatsDrawer), findsOneWidget);
    controllers.notesNotifier.setEnabled(true);
    await tester.pump();
    expect(sidebarTestDestinationLabel('Notes'), findsOneWidget);
    expect(find.byType(ChatsDrawer), findsOneWidget);
  });

  testWidgets('shows branded vertical navigation above the retained lists', (
    tester,
  ) async {
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Conduit'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    final navigation = find.byKey(
      const ValueKey<String>('sidebar-destinations'),
    );
    expect(
      tester.getBottomLeft(navigation).dy,
      lessThanOrEqualTo(
        tester
            .getTopLeft(
              find.byKey(const ValueKey<String>('sidebar-chat-history')),
            )
            .dy,
      ),
    );
    for (final label in ['Chats', 'Notes', 'Terminal', 'Channels']) {
      expect(sidebarTestDestinationLabel(label), findsOneWidget);
    }
  });

  testWidgets('tablet shows destinations and a backend picker', (tester) async {
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
    expect(find.byType(NavigationBar), findsNothing);
    for (final label in ['Chats', 'Notes', 'Terminal', 'Channels']) {
      expect(sidebarTestDestinationLabel(label), findsOneWidget);
    }

    await sidebarTestSelectDestination(tester, 'Notes');
    await tester.pumpAndSettle();

    expect(controllers.activeTabNotifier.currentValue, SidebarTabId.notes);
    expect(NavigationService.currentRoute, Routes.notes);

    await sidebarTestSelectDestination(tester, 'Channels');
    await tester.pumpAndSettle();

    expect(controllers.activeTabNotifier.currentValue, SidebarTabId.channels);
    expect(NavigationService.currentRoute, Routes.channels);
  });

  testWidgets(
    'iOS 26 keeps destinations in the pane without a native tab overlay',
    (tester) async {
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
      PlatformUiCapabilities.debugNativeIOS26Override = true;
      addTearDown(PlatformUiCapabilities.resetDebugOverrides);
      await tester.pumpWidget(
        sidebarTestBuildHarness(
          controllers: SidebarTestSidebarHarnessControllers(),
          hermesEnabled: true,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(CNTabBar), findsNothing);
      expect(find.byType(CupertinoTabBar), findsNothing);
      for (final label in ['Chats', 'Notes', 'Terminal', 'Channels']) {
        expect(sidebarTestDestinationLabel(label), findsOneWidget);
      }
      expect(
        tester
            .widget<AdaptiveSingleChoiceTrigger<SidebarTabId>>(
              find.byType(AdaptiveSingleChoiceTrigger<SidebarTabId>),
            )
            .options
            .map((option) => option.label),
        ['Open WebUI', 'Hermes'],
      );
      final picker = find.byKey(
        const ValueKey<String>('sidebar-backend-selector'),
      );
      expect(
        find.descendant(of: picker, matching: find.text('Open WebUI')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: picker, matching: find.text('Hermes')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: picker,
          matching: find.byType(AdaptiveGlassBackdrop),
        ),
        findsOneWidget,
      );
    },
  );

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
    expect(find.byType(NavigationBar), findsNothing);
    await sidebarTestSelectDestination(tester, 'Notes');
    await tester.pumpAndSettle();
    expect(controllers.activeTabNotifier.currentValue, SidebarTabId.notes);
  });

  testWidgets(
    'backend selection switches history without replacing the main pane',
    (tester) async {
      await tester.pumpWidget(
        sidebarTestBuildHarness(
          controllers: SidebarTestSidebarHarnessControllers(),
          hermesEnabled: true,
          theme: AppTheme.dark(TweakcnThemes.t3Chat),
        ),
      );
      await tester.pumpAndSettle();
      await sidebarTestSelectDestination(tester, 'Notes');
      expect(NavigationService.currentRoute, Routes.notes);
      await sidebarTestSelectDestination(tester, 'Hermes');
      expect(NavigationService.currentRoute, Routes.notes);
      expect(find.text('Open WebUI'), findsNothing);
      expect(find.text('Hermes'), findsOneWidget);
      expect(find.byType(HermesSessionsTab).hitTestable(), findsOneWidget);
      expect(find.byType(ChatsDrawer).hitTestable(), findsNothing);
      await sidebarTestSelectDestination(tester, 'Open WebUI');
      expect(NavigationService.currentRoute, Routes.notes);
      expect(find.byType(ChatsDrawer).hitTestable(), findsOneWidget);
    },
  );

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

    expect(sidebarTestDestinationLabel('Terminal'), findsNothing);
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

    expect(sidebarTestDestinationLabel('Terminal'), findsOneWidget);
    expect(find.byType(TerminalTab), findsNothing);
  });

  testWidgets(
    'sidebar search stays scoped to chats when another destination is selected',
    (tester) async {
      final controllers = SidebarTestSidebarHarnessControllers(
        initialTab: SidebarTabId.channels,
      );
      await tester.pumpWidget(
        sidebarTestBuildHarness(
          controllers: controllers,
          initialLocation: Routes.chat,
          terminalServers: const <TerminalServerInfo>[],
        ),
      );
      await tester.pumpAndSettle();

      expect(sidebarTestDestinationLabel('Terminal'), findsNothing);
      expect(sidebarTestDestinationLabel('Channels'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.search));
      await tester.pump();

      final context = tester.element(find.byType(SidebarPage));
      final l10n = AppLocalizations.of(context)!;
      expect(find.text(l10n.searchConversations), findsOneWidget);
      expect(find.text(l10n.searchFiles), findsNothing);
    },
  );

  testWidgets('channel destination opens the main page', (tester) async {
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
      ),
    );
    await sidebarTestSelectDestination(tester, 'Channels');
    expect(NavigationService.currentRoute, Routes.channels);
    expect(find.byType(ChannelListTab), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SidebarPage),
        matching: find.byType(ChannelListTab),
      ),
      findsNothing,
    );
  });

  testWidgets('destinations expose selection semantics', (tester) async {
    final controllers = SidebarTestSidebarHarnessControllers();
    await tester.pumpWidget(sidebarTestBuildHarness(controllers: controllers));

    final barScope = find.byKey(const ValueKey<String>('sidebar-destinations'));

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
