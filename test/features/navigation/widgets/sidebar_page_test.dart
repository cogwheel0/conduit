import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:checks/checks.dart';
import 'package:conduit/core/database/chat_database_repository.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/providers/app_startup_providers.dart';
import 'package:conduit/core/providers/backend_mode_providers.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/channel.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/folder.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/note.dart';
import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/core/sync/sync_engine.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/channels/widgets/channel_list_tab.dart';
import 'package:conduit/features/channels/providers/channel_providers.dart';
import 'package:conduit/features/navigation/providers/conversation_selection_provider.dart';
import 'package:conduit/features/navigation/providers/sidebar_providers.dart';
import 'package:conduit/features/navigation/widgets/chats_drawer.dart';
import 'package:conduit/features/navigation/widgets/drawer_section_notifiers.dart';
import 'package:conduit/features/navigation/widgets/sidebar_page.dart';
import 'package:conduit/features/navigation/widgets/sidebar_user_pill.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/models/hermes_job.dart';
import 'package:conduit/features/hermes/widgets/hermes_sessions_tab.dart';
import 'package:conduit/features/notes/widgets/notes_list_tab.dart';
import 'package:conduit/features/notes/providers/notes_providers.dart';
import 'package:conduit/features/terminal/models/terminal_models.dart';
import 'package:conduit/features/terminal/providers/terminal_providers.dart';
import 'package:conduit/features/terminal/widgets/terminal_tab.dart';
import 'package:conduit/features/tools/providers/tools_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/user_avatar.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/openwebui_storage_test_overrides.dart';

/// Label within [NavigationBar] built by adaptive_platform_ui from
/// [AdaptiveBottomNavigationBar.items].
Finder _sidebarBottomNavTabLabel(String label) =>
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

void main() {
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
      final controllers = _SidebarHarnessControllers();

      await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));

      expect(find.byType(TabBarView), findsNothing);

      final chatsLayer = tester.widget<Opacity>(
        _layerOpacityFinder(_SidebarTabLayer.chats),
      );
      final terminalLayer = tester.widget<Opacity>(
        _layerOpacityFinder(_SidebarTabLayer.terminal),
      );

      expect(chatsLayer.opacity, 1);
      expect(terminalLayer.opacity, 0);
    },
  );

  testWidgets('shows determinate sync progress above every sidebar tab', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();

    await tester.pumpWidget(
      _buildSidebarHarness(
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

    await tester.tap(_sidebarBottomNavTabLabel('Notes'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('sidebar-sync-progress')),
      findsOneWidget,
    );
  });

  testWidgets('hides sidebar sync progress while idle', (tester) async {
    final controllers = _SidebarHarnessControllers();

    await tester.pumpWidget(
      _buildSidebarHarness(
        controllers: controllers,
        syncStatus: const SyncStatus(),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('sidebar-sync-progress')),
      findsNothing,
    );
  });

  testWidgets(
    'tapping terminal syncs provider state and activates the terminal layer',
    (tester) async {
      final controllers = _SidebarHarnessControllers();

      await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));

      await tester.tap(_sidebarBottomNavTabLabel('Terminal'));
      await tester.pump();

      final terminalLayer = tester.widget<Opacity>(
        _layerOpacityFinder(_SidebarTabLayer.terminal),
      );

      expect(terminalLayer.opacity, 1);
      expect(controllers.activeTabNotifier.currentValue, 2);
    },
  );

  testWidgets(
    'persisted initial index 1 restores notes when notes are enabled',
    (tester) async {
      final controllers = _SidebarHarnessControllers(initialIndex: 1);

      await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));

      final notesLayer = tester.widget<Opacity>(
        _layerOpacityFinder(_SidebarTabLayer.notes),
      );
      final chatsLayer = tester.widget<Opacity>(
        _layerOpacityFinder(_SidebarTabLayer.chats),
      );

      expect(notesLayer.opacity, 1);
      expect(chatsLayer.opacity, 0);
    },
  );

  testWidgets(
    'persisted initial index syncs to the clamped value when notes are disabled',
    (tester) async {
      final controllers = _SidebarHarnessControllers(
        notesEnabled: false,
        initialIndex: 3,
      );

      await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));

      final channelsLayer = tester.widget<Opacity>(
        _layerOpacityFinder(_SidebarTabLayer.channels),
      );

      expect(channelsLayer.opacity, 1);
      expect(_sidebarBottomNavTabLabel('Notes'), findsNothing);
      expect(controllers.activeTabNotifier.currentValue, 2);
    },
  );

  testWidgets('disabling notes re-clamps controller and provider to channels', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers(initialIndex: 3);

    await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));

    controllers.notesNotifier.setEnabled(false);
    await tester.pump();

    final channelsLayer = tester.widget<Opacity>(
      _layerOpacityFinder(_SidebarTabLayer.channels),
    );

    expect(channelsLayer.opacity, 1);
    expect(controllers.activeTabNotifier.currentValue, 2);
    expect(_sidebarBottomNavTabLabel('Notes'), findsNothing);
  });

  testWidgets('inactive layers are excluded from focus and semantics', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();

    await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));

    final activeFocus = tester.widget<ExcludeFocus>(
      find
          .descendant(
            of: _layerRootFinder(_SidebarTabLayer.chats),
            matching: find.byType(ExcludeFocus),
          )
          .first,
    );
    final inactiveFocus = tester.widget<ExcludeFocus>(
      find
          .descendant(
            of: _layerRootFinder(_SidebarTabLayer.terminal),
            matching: find.byType(ExcludeFocus),
          )
          .first,
    );
    final activeSemantics = tester.widget<ExcludeSemantics>(
      find
          .descendant(
            of: _layerRootFinder(_SidebarTabLayer.chats),
            matching: find.byType(ExcludeSemantics),
          )
          .first,
    );
    final inactiveSemantics = tester.widget<ExcludeSemantics>(
      find
          .descendant(
            of: _layerRootFinder(_SidebarTabLayer.terminal),
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
    final controllers = _SidebarHarnessControllers();
    await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));

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
    expect(_sidebarBottomNavTabLabel('Chats'), findsOneWidget);
    expect(_sidebarBottomNavTabLabel('Terminal'), findsOneWidget);
    expect(_sidebarBottomNavTabLabel('Notes'), findsOneWidget);
    expect(_sidebarBottomNavTabLabel('Channels'), findsOneWidget);
  });

  testWidgets('Hermes bottom tab follows dark navigation icon colors', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();
    await tester.pumpWidget(
      _buildSidebarHarness(
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

    expect(
      tester.widget<Image>(hermesImage()).color,
      conduitTheme.textSecondary,
    );

    await tester.tap(_sidebarBottomNavTabLabel('Hermes'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Image>(hermesImage()).color,
      conduitTheme.buttonPrimary,
    );
  });

  testWidgets('hides bottom navigation when Hermes is the only sidebar tab', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();
    await tester.pumpWidget(
      _buildSidebarHarness(
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
      final controllers = _SidebarHarnessControllers();
      await tester.pumpWidget(
        _buildSidebarHarness(
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
    final controllers = _SidebarHarnessControllers();
    await tester.pumpWidget(
      _buildSidebarHarness(
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
    final controllers = _SidebarHarnessControllers();
    await tester.pumpWidget(
      _buildSidebarHarness(
        controllers: controllers,
        terminalServers: const <TerminalServerInfo>[],
      ),
    );
    await tester.pumpAndSettle();

    expect(_sidebarBottomNavTabLabel('Terminal'), findsNothing);
    expect(find.byType(TerminalTab), findsNothing);
  });

  testWidgets('keeps terminal tab visible when terminal discovery fails', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();
    await tester.pumpWidget(
      _buildSidebarHarness(
        controllers: controllers,
        terminalServersError: Exception('terminal discovery failed'),
      ),
    );
    await tester.pumpAndSettle();

    expect(_sidebarBottomNavTabLabel('Terminal'), findsOneWidget);
    expect(find.byType(TerminalTab), findsOneWidget);
  });

  testWidgets('channel helpers align when terminal tab is hidden', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers(initialIndex: 2);
    await tester.pumpWidget(
      _buildSidebarHarness(
        controllers: controllers,
        terminalServers: const <TerminalServerInfo>[],
      ),
    );
    await tester.pumpAndSettle();

    expect(_sidebarBottomNavTabLabel('Terminal'), findsNothing);
    expect(_sidebarBottomNavTabLabel('Channels'), findsOneWidget);
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
    final controllers = _SidebarHarnessControllers();
    await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));

    await tester.tap(_sidebarBottomNavTabLabel('Channels'));
    await tester.pumpAndSettle();

    final channelsLayer = tester.widget<Opacity>(
      _layerOpacityFinder(_SidebarTabLayer.channels),
    );
    expect(channelsLayer.opacity, 1);

    final chatsLayer = tester.widget<Opacity>(
      _layerOpacityFinder(_SidebarTabLayer.chats),
    );
    expect(chatsLayer.opacity, 0);
  });

  testWidgets('adaptive bottom bar provides tab semantics', (tester) async {
    final controllers = _SidebarHarnessControllers();
    await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));

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

  testWidgets('empty chats tab shows a refresh action below the message', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();
    final pendingRefresh = controllers.keepChatRefreshPending();

    await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(SidebarPage));
    final l10n = AppLocalizations.of(context)!;
    final refreshLabel = MaterialLocalizations.of(
      context,
    ).refreshIndicatorSemanticLabel;

    final refreshAction = _checkEmptyStateRefreshButtonBelow(
      tester,
      layer: _SidebarTabLayer.chats,
      message: l10n.noConversationsYet,
      refreshLabel: refreshLabel,
    );
    await tester.tap(refreshAction);
    await tester.tap(refreshAction);
    await tester.pump();

    check(controllers.chatRefreshCalls).equals(1);
    pendingRefresh.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('collapsed paginated chat sections do not consume hidden pages', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();
    final pagination = _TestConversationPagination(remainingPages: 3);
    final timestamp = DateTime(2026, 1, 1);

    await tester.pumpWidget(
      _buildSidebarHarness(
        controllers: controllers,
        conversations: [
          Conversation(
            id: 'recent-1',
            title: 'Hidden recent',
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
          Conversation(
            id: 'archived-1',
            title: 'Hidden archived',
            createdAt: timestamp,
            updatedAt: timestamp,
            archived: true,
          ),
        ],
        pagination: pagination,
        showRecent: false,
        showArchived: false,
      ),
    );
    await tester.pumpAndSettle();

    check(pagination.loadMoreCalls).equals(0);
    expect(find.text('Hidden recent'), findsNothing);
    expect(find.text('Hidden archived'), findsNothing);
  });

  testWidgets(
    'load more reaches a regular chat after 200 collapsed folder rows',
    (tester) async {
      final controllers = _SidebarHarnessControllers();
      final pagination = _TestConversationPagination(remainingPages: 1);
      final timestamp = DateTime(2026, 1, 1);
      final firstPage = List<Conversation>.generate(
        200,
        (index) => Conversation(
          id: 'foldered-$index',
          title: 'Collapsed folder chat $index',
          createdAt: timestamp,
          updatedAt: timestamp,
          folderId: 'collapsed-folder',
        ),
      );

      await tester.pumpWidget(
        _buildSidebarHarness(
          controllers: controllers,
          conversations: firstPage,
          pagination: pagination,
          folders: const [
            Folder(
              id: 'collapsed-folder',
              name: 'Collapsed Folder',
              isExpanded: false,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      check(pagination.loadMoreCalls).equals(0);
      expect(find.text('Collapsed folder chat 0'), findsNothing);

      final context = tester.element(find.byType(SidebarPage));
      final loadMoreLabel = AppLocalizations.of(context)!.workspaceLoadMore;
      final loadMoreButton = find.byKey(
        const ValueKey<String>('chats-load-more'),
      );
      expect(loadMoreButton, findsOneWidget);
      final loadMoreSemantics = find.bySemanticsLabel(loadMoreLabel);
      final hasEnabledLoadMoreButton =
          Iterable<int>.generate(loadMoreSemantics.evaluate().length).any((
            index,
          ) {
            final semantics = tester
                .getSemantics(loadMoreSemantics.at(index))
                .getSemanticsData();
            return semantics.label == loadMoreLabel &&
                semantics.flagsCollection.isButton &&
                semantics.flagsCollection.isEnabled == Tristate.isTrue;
          });
      check(hasEnabledLoadMoreButton).isTrue();

      await tester.tap(loadMoreButton);
      await tester.pumpAndSettle();

      check(pagination.loadMoreCalls).equals(1);
      expect(find.text('Paged 1'), findsOneWidget);
    },
  );

  testWidgets('visible end of expanded recent chats requests the next page', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();
    final pagination = _TestConversationPagination(remainingPages: 1);
    final timestamp = DateTime(2026, 1, 1);

    await tester.pumpWidget(
      _buildSidebarHarness(
        controllers: controllers,
        conversations: [
          Conversation(
            id: 'recent-1',
            title: 'Visible recent',
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        ],
        pagination: pagination,
        showRecent: true,
        showArchived: false,
      ),
    );
    await tester.pumpAndSettle();

    check(pagination.loadMoreCalls).equals(1);
    expect(find.text('Visible recent'), findsOneWidget);
    expect(find.text('Paged 1'), findsOneWidget);
  });

  testWidgets(
    'pagination reload keeps previous rows visible instead of replacing the '
    'drawer with a spinner',
    (tester) async {
      final controllers = _SidebarHarnessControllers();
      final reloadGate = Completer<void>();
      final pagination = _TestConversationPagination(
        remainingPages: 1,
        reloadGate: reloadGate,
      );
      final timestamp = DateTime(2026, 1, 1);

      await tester.pumpWidget(
        _buildSidebarHarness(
          controllers: controllers,
          conversations: [
            Conversation(
              id: 'recent-1',
              title: 'Visible recent',
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          ],
          pagination: pagination,
          showRecent: true,
          showArchived: false,
        ),
      );
      // The visible end of the short list auto-requests the next page, which
      // now parks the provider in a reload (loading-with-previous) state.
      await tester.pump();
      await tester.pump();
      check(pagination.loadMoreCalls).equals(1);

      // While the reload is in flight the previous rows must stay on screen;
      // the drawer must not tear itself down into a centered spinner.
      expect(find.text('Visible recent'), findsOneWidget);

      reloadGate.complete();
      await tester.pumpAndSettle();

      expect(find.text('Visible recent'), findsOneWidget);
      expect(find.text('Paged 1'), findsOneWidget);
    },
  );

  testWidgets('pinned-only visibility does not consume regular pages', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();
    final pagination = _TestConversationPagination(remainingPages: 1);
    final timestamp = DateTime(2026, 1, 1);

    await tester.pumpWidget(
      _buildSidebarHarness(
        controllers: controllers,
        conversations: [
          Conversation(
            id: 'pinned-1',
            title: 'Visible pinned',
            createdAt: timestamp,
            updatedAt: timestamp,
            pinned: true,
          ),
        ],
        pagination: pagination,
        showPinned: true,
        showRecent: false,
        showArchived: false,
      ),
    );
    await tester.pumpAndSettle();

    check(pagination.loadMoreCalls).equals(0);
    expect(find.text('Visible pinned'), findsOneWidget);
  });

  testWidgets('archived section exposes exact count and pages independently', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();
    final archivedPagination = _TestArchivedConversationPagination(
      totalCount: 450,
      pageSize: 2,
    );

    await tester.pumpWidget(
      _buildSidebarHarness(
        controllers: controllers,
        archivedPagination: archivedPagination,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Archived'), findsOneWidget);
    expect(find.text('450'), findsOneWidget);
    expect(find.text('Archived page 0'), findsNothing);
    check(archivedPagination.loadedCount).equals(0);

    await tester.tap(find.text('Archived'));
    await tester.pumpAndSettle();

    check(archivedPagination.loadedCount).equals(2);
    expect(find.text('Archived page 0'), findsOneWidget);
    final archivedLoadMore = find.byKey(
      const ValueKey<String>('chats-archived-load-more'),
    );
    expect(archivedLoadMore, findsOneWidget);
    final context = tester.element(find.byType(SidebarPage));
    final l10n = AppLocalizations.of(context)!;
    final archivedLoadMoreLabel = '${l10n.workspaceLoadMore}: ${l10n.archived}';
    final archivedLoadMoreSemantics = find.bySemanticsLabel(
      archivedLoadMoreLabel,
    );
    final hasEnabledArchivedLoadMore =
        Iterable<int>.generate(archivedLoadMoreSemantics.evaluate().length).any(
          (index) {
            final semantics = tester
                .getSemantics(archivedLoadMoreSemantics.at(index))
                .getSemanticsData();
            return semantics.label == archivedLoadMoreLabel &&
                semantics.flagsCollection.isButton &&
                semantics.flagsCollection.isEnabled == Tristate.isTrue;
          },
        );
    check(hasEnabledArchivedLoadMore).isTrue();

    await tester.tap(archivedLoadMore);
    await tester.pumpAndSettle();

    check(archivedPagination.loadMoreCalls).equals(1);
    check(archivedPagination.loadedCount).equals(4);

    await tester.tap(find.text('Archived'));
    await tester.pumpAndSettle();

    check(archivedPagination.loadedCount).equals(0);
    expect(find.text('Archived page 0'), findsNothing);
    expect(find.text('450'), findsOneWidget);
  });

  testWidgets('empty notes tab shows a refresh action below the message', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers(initialIndex: 1);
    final pendingRefresh = controllers.keepNoteRefreshPending();

    await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(SidebarPage));
    final l10n = AppLocalizations.of(context)!;
    final refreshLabel = MaterialLocalizations.of(
      context,
    ).refreshIndicatorSemanticLabel;

    final refreshAction = _checkEmptyStateRefreshButtonBelow(
      tester,
      layer: _SidebarTabLayer.notes,
      message: l10n.noNotesYet,
      refreshLabel: refreshLabel,
    );
    await tester.tap(refreshAction);
    await tester.tap(refreshAction);
    await tester.pump();

    check(controllers.noteRefreshCalls).equals(1);
    pendingRefresh.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('channel layer state survives notes toggle', (tester) async {
    final controllers = _SidebarHarnessControllers(initialIndex: 3);

    await tester.pumpWidget(_buildSidebarHarness(controllers: controllers));

    final initialChannelState = tester.state(find.byType(ChannelListTab));

    controllers.notesNotifier.setEnabled(false);
    await tester.pumpAndSettle();

    final channelStateWithoutNotes = tester.state(find.byType(ChannelListTab));

    controllers.notesNotifier.setEnabled(true);
    await tester.pumpAndSettle();

    final channelStateWithNotesAgain = tester.state(
      find.byType(ChannelListTab),
    );

    expect(channelStateWithoutNotes, same(initialChannelState));
    expect(channelStateWithNotesAgain, same(initialChannelState));
  });

  testWidgets('profile app bar leading stays visible across sidebar tabs', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();
    const user = User(
      id: 'user-1',
      username: 'ava',
      email: 'ava@example.com',
      name: 'Ava',
      role: 'user',
    );

    await tester.pumpWidget(
      _buildSidebarHarness(controllers: controllers, currentUser: user),
    );

    expect(find.byType(SidebarProfileAppBarLeading), findsOneWidget);

    await tester.tap(_sidebarBottomNavTabLabel('Terminal'));
    await tester.pumpAndSettle();

    expect(find.byType(SidebarProfileAppBarLeading), findsOneWidget);

    await tester.tap(_sidebarBottomNavTabLabel('Notes'));
    await tester.pumpAndSettle();

    expect(find.byType(SidebarProfileAppBarLeading), findsOneWidget);

    await tester.tap(_sidebarBottomNavTabLabel('Channels'));
    await tester.pumpAndSettle();

    expect(find.byType(SidebarProfileAppBarLeading), findsOneWidget);
  });

  testWidgets('Hermes-only profile entry renders without an OpenWebUI user', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider2.overrideWithValue(null),
          currentUserProvider.overrideWith((ref) async => null),
          apiServiceProvider.overrideWithValue(null),
          hermesOnlyModeProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SidebarProfileAppBarLeading()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('sidebar-profile-button')),
      findsOneWidget,
    );
    expect(find.byType(UserAvatar), findsOneWidget);
  });

  testWidgets('accountless direct profile click opens generic settings', (
    tester,
  ) async {
    var nativePresentationCalls = 0;
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) =>
              const Scaffold(body: SidebarProfileAppBarLeading()),
        ),
        GoRoute(
          path: Routes.profile,
          name: RouteNames.profile,
          builder: (_, _) => const Scaffold(body: Text('Settings destination')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider2.overrideWithValue(null),
          currentUserProvider.overrideWith((ref) async => null),
          apiServiceProvider.overrideWithValue(null),
          hermesOnlyModeProvider.overrideWithValue(false),
          preferredBackendProvider.overrideWith(
            _DirectPreferredBackendController.new,
          ),
          sidebarNativeProfilePresenterProvider.overrideWithValue((_) async {
            nativePresentationCalls++;
            return false;
          }),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('sidebar-profile-button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Settings destination'), findsOneWidget);
    expect(nativePresentationCalls, 1);
  });

  testWidgets('sidebar material app bar uses the compact toolbar height', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();
    const user = User(
      id: 'user-1',
      username: 'ava',
      email: 'ava@example.com',
      name: 'Ava',
      role: 'user',
    );

    await tester.pumpWidget(
      _buildSidebarHarness(controllers: controllers, currentUser: user),
    );

    final appBar = tester.widget<AppBar>(find.byType(AppBar));

    expect(appBar.toolbarHeight, kTextTabBarHeight);
  });

  testWidgets('closing expanded search clears the active filter', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();
    final timestamp = DateTime(2026, 1, 1);
    const user = User(
      id: 'user-1',
      username: 'ava',
      name: 'Ava',
      email: 'ava@example.com',
      role: 'user',
    );

    await tester.pumpWidget(
      _buildSidebarHarness(
        controllers: controllers,
        currentUser: user,
        conversations: [
          Conversation(
            id: 'alpha-chat',
            title: 'Alpha Chat',
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
          Conversation(
            id: 'beta-chat',
            title: 'Beta Chat',
            createdAt: timestamp,
            updatedAt: timestamp.add(const Duration(minutes: 1)),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alpha Chat'), findsOneWidget);
    expect(find.text('Beta Chat'), findsOneWidget);

    ProviderScope.containerOf(
      tester.element(find.byType(SidebarPage)),
    ).read(sidebarHeaderSearchExpandedProvider.notifier).setExpanded(true);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('Alpha Chat'), findsNothing);
    expect(find.text('Beta Chat'), findsNothing);

    await tester.tap(find.byType(ConduitAdaptiveAppBarIconButton));
    await tester.pumpAndSettle();

    expect(find.text('Alpha Chat'), findsOneWidget);
    expect(find.text('Beta Chat'), findsOneWidget);
  });

  testWidgets('nested folders render stacked under their parent', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();
    final timestamp = DateTime(2026, 1, 1);
    final nestedConversation = Conversation(
      id: 'nested-chat',
      title: 'Nested Chat',
      createdAt: timestamp,
      updatedAt: timestamp,
      folderId: 'child-folder',
      messages: const [],
    );
    final nestedConversationId = conversationScopedId(nestedConversation);

    await tester.pumpWidget(
      _buildSidebarHarness(
        controllers: controllers,
        folders: [
          const Folder(
            id: 'parent-folder',
            name: 'Parent Folder',
            isExpanded: true,
          ),
          const Folder(
            id: 'child-folder',
            name: 'Child Folder',
            parentId: 'parent-folder',
            isExpanded: true,
          ),
        ],
        conversations: [nestedConversation],
      ),
    );
    await tester.pumpAndSettle();

    final parentFinder = find.text('Parent Folder');
    final childFinder = find.text('Child Folder');
    final chatFinder = find.text('Nested Chat');

    expect(parentFinder, findsOneWidget);
    expect(childFinder, findsOneWidget);
    expect(chatFinder, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('tree-guides-folder-child-folder')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey<String>('tree-guides-chat-$nestedConversationId')),
      findsOneWidget,
    );

    final parentOffset = tester.getTopLeft(
      find.byKey(const ValueKey<String>('folder-open-parent-folder')),
    );
    final childOffset = tester.getTopLeft(
      find.byKey(const ValueKey<String>('folder-open-child-folder')),
    );
    final chatOffset = tester.getTopLeft(
      find.byKey(ValueKey<String>('drawer-chat-$nestedConversationId')),
    );

    expect(childOffset.dx, greaterThan(parentOffset.dx));
    expect(chatOffset.dx, greaterThanOrEqualTo(childOffset.dx));
  });

  testWidgets('folder rows no longer show inline new chat buttons', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();

    await tester.pumpWidget(
      _buildSidebarHarness(
        controllers: controllers,
        folders: const [
          Folder(id: 'parent-folder', name: 'Parent Folder', isExpanded: true),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Icon &&
            (widget.icon == CupertinoIcons.plus_circle ||
                widget.icon == Icons.add_circle_outline_rounded),
      ),
      findsNothing,
    );
  });

  testWidgets('chat tab new chat clears stale folder target', (tester) async {
    final controllers = _SidebarHarnessControllers();

    await tester.pumpWidget(
      _buildSidebarHarness(
        controllers: controllers,
        settings: const AppSettings(temporaryChatByDefault: true),
        folders: const [
          Folder(id: 'parent-folder', name: 'Parent Folder', isExpanded: false),
        ],
      ),
    );
    await tester.pumpAndSettle();

    NavigationService.router.go('/folder/parent-folder');
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SidebarPage)),
      listen: false,
    );
    container.read(pendingFolderIdProvider.notifier).set('parent-folder');
    container.read(temporaryChatEnabledProvider.notifier).set(false);

    await tester.tap(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.add),
      ),
    );
    await tester.pumpAndSettle();

    expect(NavigationService.currentRoute, '/chat');
    expect(container.read(pendingFolderIdProvider), isNull);
    expect(container.read(temporaryChatEnabledProvider), isTrue);
  });

  testWidgets('tapping a folder row opens the folder route', (tester) async {
    final controllers = _SidebarHarnessControllers();

    await tester.pumpWidget(
      _buildSidebarHarness(
        controllers: controllers,
        folders: const [
          Folder(id: 'parent-folder', name: 'Parent Folder', isExpanded: false),
          Folder(
            id: 'child-folder',
            name: 'Child Folder',
            parentId: 'parent-folder',
            isExpanded: false,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Child Folder'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('folder-open-parent-folder')),
    );
    await tester.pumpAndSettle();

    expect(NavigationService.currentRoute, '/folder/parent-folder');
    expect(find.text('Child Folder'), findsNothing);
  });

  testWidgets('tapping a folder arrow only expands inline contents', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();

    await tester.pumpWidget(
      _buildSidebarHarness(
        controllers: controllers,
        folders: const [
          Folder(id: 'parent-folder', name: 'Parent Folder', isExpanded: false),
          Folder(
            id: 'child-folder',
            name: 'Child Folder',
            parentId: 'parent-folder',
            isExpanded: false,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Child Folder'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('folder-expand-parent-folder')),
    );
    await tester.pumpAndSettle();

    expect(NavigationService.currentRoute, '/chat');
    expect(find.text('Child Folder'), findsOneWidget);
  });

  testWidgets('folders with missing parents fall back to the root level', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();
    final timestamp = DateTime(2026, 1, 1);

    await tester.pumpWidget(
      _buildSidebarHarness(
        controllers: controllers,
        folders: [
          const Folder(
            id: 'root-folder',
            name: 'Root Folder',
            isExpanded: true,
          ),
          const Folder(
            id: 'orphan-folder',
            name: 'Orphan Folder',
            parentId: 'missing-folder',
            isExpanded: true,
          ),
        ],
        conversations: [
          Conversation(
            id: 'orphan-chat',
            title: 'Orphan Chat',
            createdAt: timestamp,
            updatedAt: timestamp,
            folderId: 'orphan-folder',
            messages: const [],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final rootOffset = tester.getTopLeft(find.text('Root Folder'));
    final orphanOffset = tester.getTopLeft(find.text('Orphan Folder'));

    expect(orphanOffset.dx, closeTo(rootOffset.dx, 0.1));
  });

  testWidgets('opening an on-device chat loads its full direct history', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();
    final timestamp = DateTime(2026, 1, 1);
    final summary = withChatStorageProvenance(
      Conversation(
        id: 'direct-local:drawer-test',
        title: 'On-device chat',
        createdAt: timestamp,
        updatedAt: timestamp,
      ),
      ChatStorageKind.directLocal,
    );
    final full = withChatStorageProvenance(
      summary.copyWith(
        messages: [
          ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: 'Loaded from the direct database',
            timestamp: timestamp,
          ),
        ],
      ),
      ChatStorageKind.directLocal,
    );

    await tester.pumpWidget(
      _buildSidebarHarness(
        controllers: controllers,
        conversations: [summary],
        loadedConversations: {conversationScopedId(summary): full},
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SidebarPage)),
      listen: false,
    );
    container.read(selectedFilterIdsProvider.notifier).set(const ['filter-a']);
    await tester.tap(
      find.byKey(
        ValueKey<String>('drawer-chat-${conversationScopedId(summary)}'),
      ),
    );
    await tester.pumpAndSettle();

    final active = container.read(activeConversationProvider);
    expect(active?.messages, hasLength(1));
    expect(active?.messages.single.content, 'Loaded from the direct database');
    expect(chatStorageKindOf(active), ChatStorageKind.directLocal);
    expect(container.read(selectedFilterIdsProvider), isEmpty);

    // The provenance-aware message watch now correctly subscribes to the
    // direct-local Drift database. Dispose it inside the test and give Drift's
    // zero-delay stream cleanup a frame before the binding checks timers.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'server chat tapped during bootstrap opens when storage becomes ready',
    (tester) async {
      final controllers = _SidebarHarnessControllers();
      final timestamp = DateTime(2026, 1, 1);
      final previous = withChatStorageProvenance(
        Conversation(
          id: 'previous-chat',
          title: 'Previously committed chat',
          createdAt: timestamp,
          updatedAt: timestamp,
        ),
        ChatStorageKind.directLocal,
      );
      final summary = withChatStorageProvenance(
        Conversation(
          id: 'server-bootstrap-chat',
          title: 'Newly synchronized chat',
          createdAt: timestamp,
          updatedAt: timestamp,
        ),
        ChatStorageKind.openWebUi,
      );
      final full = withChatStorageProvenance(
        summary.copyWith(
          messages: [
            ChatMessage(
              id: 'assistant-1',
              role: 'assistant',
              content: 'Loaded after storage certification',
              timestamp: timestamp,
            ),
          ],
        ),
        ChatStorageKind.openWebUi,
      );
      final scopedId = conversationScopedId(summary);

      await tester.pumpWidget(
        _buildSidebarHarness(
          controllers: controllers,
          conversations: [summary],
          isAuthenticated: true,
          openWebUiServerId: 'test-server',
          openWebUiStorageOpen: false,
          activeConversation: previous,
          loadedConversations: {scopedId: full},
        ),
      );
      await tester.pumpAndSettle();

      final row = find.byKey(ValueKey<String>('drawer-chat-$scopedId'));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SidebarPage)),
        listen: false,
      );
      await tester.tap(row);
      await tester.pump();

      expect(container.read(activeConversationProvider)?.id, previous.id);
      expect(container.read(conversationSelectionProvider).isLoading, isTrue);
      expect(
        find.descendant(
          of: row,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );

      container.read(openWebUiDatabaseAccessProvider.notifier).open();
      await tester.pumpAndSettle();

      expect(container.read(activeConversationProvider)?.id, full.id);
      expect(
        container.read(activeConversationProvider)?.messages.single.content,
        'Loaded after storage certification',
      );
      expect(container.read(conversationSelectionProvider).isLoading, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets(
    'account switch while a server chat loads cannot republish its body',
    (tester) async {
      final controllers = _SidebarHarnessControllers();
      final timestamp = DateTime(2026, 1, 1);
      final summary = withChatStorageProvenance(
        Conversation(
          id: 'server-drawer-test',
          title: 'Server chat',
          createdAt: timestamp,
          updatedAt: timestamp,
        ),
        ChatStorageKind.openWebUi,
      );
      final full = summary.copyWith(
        messages: [
          ChatMessage(
            id: 'private-assistant',
            role: 'assistant',
            content: 'Account A private body',
            timestamp: timestamp,
          ),
        ],
      );
      final previous = withChatStorageProvenance(
        Conversation(
          id: 'previous-chat',
          title: 'Previously committed chat',
          createdAt: timestamp,
          updatedAt: timestamp,
        ),
        ChatStorageKind.directLocal,
      );
      final loadGate = Completer<Conversation>();

      await tester.pumpWidget(
        _buildSidebarHarness(
          controllers: controllers,
          conversations: [summary],
          isAuthenticated: true,
          openWebUiServerId: 'test-server',
          activeConversation: previous,
          pendingLoadedConversations: {
            conversationScopedId(summary): loadGate.future,
          },
        ),
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(SidebarPage)),
        listen: false,
      );
      await tester.tap(
        find.byKey(
          ValueKey<String>('drawer-chat-${conversationScopedId(summary)}'),
        ),
      );
      await tester.pump();

      container.read(_sidebarAuthTokenProvider.notifier).set('account-b-token');
      loadGate.complete(full);
      await tester.pumpAndSettle();

      expect(container.read(activeConversationProvider)?.id, previous.id);
    },
  );

  testWidgets('colliding chat ids render and select as distinct rows', (
    tester,
  ) async {
    final controllers = _SidebarHarnessControllers();
    final timestamp = DateTime(2026, 1, 1);
    final server = withChatStorageProvenance(
      Conversation(
        id: 'shared-id',
        title: 'Server copy',
        createdAt: timestamp,
        updatedAt: timestamp,
      ),
      ChatStorageKind.openWebUi,
    );
    final direct = withChatStorageProvenance(
      Conversation(
        id: 'shared-id',
        title: 'Device copy',
        createdAt: timestamp,
        updatedAt: timestamp.add(const Duration(seconds: 1)),
      ),
      ChatStorageKind.directLocal,
    );

    await tester.pumpWidget(
      _buildSidebarHarness(
        controllers: controllers,
        conversations: [direct, server],
        isAuthenticated: true,
        openWebUiServerId: 'test-server',
        loadedConversations: {
          conversationScopedId(server): server,
          conversationScopedId(direct): direct,
        },
      ),
    );
    await tester.pumpAndSettle();

    final serverTile = find.byKey(
      ValueKey<String>('drawer-chat-${conversationScopedId(server)}'),
    );
    final directTile = find.byKey(
      ValueKey<String>('drawer-chat-${conversationScopedId(direct)}'),
    );
    expect(serverTile, findsOneWidget);
    expect(directTile, findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SidebarPage)),
      listen: false,
    );
    container.read(activeChatIdsProvider.notifier).setActive('shared-id');
    await tester.pump();

    expect(
      find.descendant(
        of: serverTile,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: directTile,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: directTile,
        matching: find.byKey(
          const ValueKey<String>('conversation-unread-indicator'),
        ),
      ),
      findsOneWidget,
    );
    container.read(activeChatIdsProvider.notifier).setInactive('shared-id');
    await tester.pump();

    await tester.tap(directTile);
    await tester.pumpAndSettle();
    expect(
      chatStorageKindOf(container.read(activeConversationProvider)),
      ChatStorageKind.directLocal,
    );

    final serverOwnership = captureOpenWebUiConversationRead(container);
    expect(serverOwnership, isNotNull);
    expect(
      openWebUiConversationReadIsCurrent(container, serverOwnership!),
      isTrue,
    );
    await tester.tap(serverTile);
    await tester.pumpAndSettle();
    expect(
      chatStorageKindOf(container.read(activeConversationProvider)),
      ChatStorageKind.openWebUi,
    );

    // Disposing the live Drift message watch schedules a zero-delay stream
    // query cleanup. Unmount explicitly so the test binding can drain it.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

enum _SidebarTabLayer { chats, terminal, notes, channels }

Finder _layerRootFinder(_SidebarTabLayer layer) =>
    find.byKey(ValueKey<String>('sidebar-tab-layer-${layer.name}'));

Finder _layerOpacityFinder(_SidebarTabLayer layer) {
  final childType = switch (layer) {
    _SidebarTabLayer.chats => ChatsDrawer,
    _SidebarTabLayer.terminal => TerminalTab,
    _SidebarTabLayer.notes => NotesListTab,
    _SidebarTabLayer.channels => ChannelListTab,
  };

  return find.descendant(
    of: _layerRootFinder(layer),
    matching: find.byWidgetPredicate(
      (widget) => widget is Opacity && widget.child.runtimeType == childType,
    ),
  );
}

Finder _checkEmptyStateRefreshButtonBelow(
  WidgetTester tester, {
  required _SidebarTabLayer layer,
  required String message,
  required String refreshLabel,
}) {
  final layerRoot = _layerRootFinder(layer);
  final messageFinder = find.descendant(
    of: layerRoot,
    matching: find.text(message),
  );
  final refreshTextFinder = find.descendant(
    of: layerRoot,
    matching: find.text(refreshLabel),
  );
  final refreshSemanticsFinder = find.descendant(
    of: layerRoot,
    matching: find.bySemanticsLabel(refreshLabel),
  );

  check(messageFinder.evaluate()).length.equals(1);
  check(refreshTextFinder.evaluate()).length.equals(1);
  final refreshSemanticsCount = refreshSemanticsFinder.evaluate().length;
  check(refreshSemanticsCount > 0).isTrue();
  final hasEnabledButtonSemantics =
      Iterable<int>.generate(refreshSemanticsCount).any((index) {
        final semantics = tester
            .getSemantics(refreshSemanticsFinder.at(index))
            .getSemanticsData();
        return semantics.label == refreshLabel &&
            semantics.flagsCollection.isButton &&
            semantics.flagsCollection.isEnabled == Tristate.isTrue;
      });
  check(hasEnabledButtonSemantics).isTrue();

  final messageBottom = tester.getBottomLeft(messageFinder).dy;
  final refreshTop = tester.getTopLeft(refreshTextFinder).dy;
  check(refreshTop > messageBottom).isTrue();

  return refreshTextFinder;
}

Widget _buildSidebarHarness({
  required _SidebarHarnessControllers controllers,
  User? currentUser,
  List<Conversation> conversations = const [],
  _TestConversationPagination? pagination,
  _TestArchivedConversationPagination? archivedPagination,
  bool showPinned = true,
  bool showRecent = true,
  bool showArchived = false,
  List<Folder> folders = const [],
  List<TerminalServerInfo>? terminalServers,
  Object? terminalServersError,
  AppSettings settings = const AppSettings(),
  bool hermesOnly = false,
  bool hermesEnabled = false,
  List<HermesJob> hermesJobs = const [],
  Map<String, Conversation> loadedConversations = const {},
  Map<String, Future<Conversation>> pendingLoadedConversations = const {},
  bool isAuthenticated = false,
  String? openWebUiServerId,
  bool openWebUiStorageOpen = true,
  Conversation? activeConversation,
  ThemeData? theme,
  SyncStatus? syncStatus,
}) {
  final availableTerminalServers = terminalServers ?? _defaultTerminalServers();
  final router = GoRouter(
    initialLocation: '/chat',
    routes: [
      GoRoute(
        path: '/chat',
        name: RouteNames.chat,
        builder: (context, state) => const Scaffold(body: SidebarPage()),
      ),
      GoRoute(
        path: '/folder/:id',
        name: RouteNames.folder,
        builder: (context, state) => const Scaffold(body: SidebarPage()),
      ),
      GoRoute(
        path: '/notes/:id',
        name: RouteNames.noteEditor,
        builder: (context, state) => const Scaffold(body: SidebarPage()),
      ),
      GoRoute(
        path: '/channel/:id',
        name: RouteNames.channel,
        builder: (context, state) => const Scaffold(body: SidebarPage()),
      ),
    ],
  );
  NavigationService.attachRouter(router);

  return ProviderScope(
    overrides: [
      ...openWebUiStorageOpenOverrides(open: openWebUiStorageOpen),
      if (syncStatus != null)
        syncEngineProvider.overrideWith(() => _FixedSyncEngine(syncStatus)),
      // The sidebar harness owns its in-memory OpenWebUI database explicitly;
      // unrelated auth bootstrap must not close that test seam underneath it.
      openWebUiAccountStorageIsolationProvider.overrideWith(
        _NoopOpenWebUiAccountStorageIsolation.new,
      ),
      // ignore: scoped_providers_should_specify_dependencies
      appSettingsProvider.overrideWithValue(settings),
      // ignore: scoped_providers_should_specify_dependencies
      apiServiceProvider.overrideWithValue(_SidebarApiService()),
      // The production auth provider is deliberately incomplete in this
      // narrow harness; keep its account-generation boundary deterministic.
      // ignore: scoped_providers_should_specify_dependencies
      openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
      // ignore: scoped_providers_should_specify_dependencies
      isAuthenticatedProvider2.overrideWithValue(isAuthenticated),
      if (isAuthenticated)
        // ignore: scoped_providers_should_specify_dependencies
        authTokenProvider3.overrideWith(
          (ref) => ref.watch(_sidebarAuthTokenProvider),
        ),
      if (openWebUiServerId != null)
        openWebUiCertifiedDatabaseServerProvider.overrideWith(
          () => _SeededCertifiedDatabaseServer(openWebUiServerId),
        ),
      // ignore: scoped_providers_should_specify_dependencies
      currentUserProvider2.overrideWithValue(currentUser),
      // ignore: scoped_providers_should_specify_dependencies
      currentUserProvider.overrideWith((ref) async => currentUser),
      if (activeConversation != null)
        activeConversationProvider.overrideWith(
          () => _SeededActiveConversation(activeConversation),
        ),
      // ignore: scoped_providers_should_specify_dependencies
      conversationsProvider.overrideWith(
        () => _TestConversations(
          conversations,
          onRefresh: controllers.recordChatRefresh,
          pagination: pagination,
          archivedPagination: archivedPagination,
        ),
      ),
      for (final entry in loadedConversations.entries)
        loadConversationProvider(
          entry.key,
        ).overrideWith((ref) async => entry.value),
      for (final entry in pendingLoadedConversations.entries)
        loadConversationProvider(entry.key).overrideWith((ref) => entry.value),
      // ignore: scoped_providers_should_specify_dependencies
      modelsProvider.overrideWith(_TestModels.new),
      // ignore: scoped_providers_should_specify_dependencies
      foldersProvider.overrideWith(() => _TestFolders(folders)),
      // ignore: scoped_providers_should_specify_dependencies
      notesListProvider.overrideWith(
        () => _TestNotesList(onRefresh: controllers.recordNoteRefresh),
      ),
      // ignore: scoped_providers_should_specify_dependencies
      channelsListProvider.overrideWith(_TestChannelsList.new),
      // ignore: scoped_providers_should_specify_dependencies
      optimizedStorageServiceProvider.overrideWithValue(
        _FakeOptimizedStorageService(),
      ),
      // ignore: scoped_providers_should_specify_dependencies
      showPinnedProvider.overrideWith(
        () => _TestShowPinnedNotifier(showPinned),
      ),
      // ignore: scoped_providers_should_specify_dependencies
      showFoldersProvider.overrideWith(_TestShowFoldersNotifier.new),
      // ignore: scoped_providers_should_specify_dependencies
      showRecentProvider.overrideWith(
        () => _TestShowRecentNotifier(showRecent),
      ),
      showArchivedProvider.overrideWith(
        () => _TestShowArchivedNotifier(showArchived),
      ),
      // ignore: scoped_providers_should_specify_dependencies
      reviewerModeProvider.overrideWithValue(false),
      hermesOnlyModeProvider.overrideWithValue(hermesOnly),
      hermesEnabledProvider.overrideWithValue(hermesEnabled),
      hermesApiServiceProvider.overrideWithValue(null),
      terminalServiceProvider.overrideWithValue(null),
      hermesJobsProvider.overrideWith(
        () => _TestHermesJobsController(hermesJobs),
      ),
      // ignore: scoped_providers_should_specify_dependencies
      notesFeatureEnabledProvider.overrideWith(() => controllers.notesNotifier),
      // ignore: scoped_providers_should_specify_dependencies
      sidebarActiveTabProvider.overrideWith(
        () => controllers.activeTabNotifier,
      ),
      // ignore: scoped_providers_should_specify_dependencies
      terminalAvailableServersProvider.overrideWith((ref) async {
        final error = terminalServersError;
        if (error != null) {
          throw error;
        }
        return availableTerminalServers;
      }),
    ],
    child: MaterialApp.router(
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
}

final class _SidebarApiService extends Mock implements ApiService {}

final class _FixedSyncEngine extends SyncEngine {
  _FixedSyncEngine(this.initial);

  final SyncStatus initial;

  @override
  SyncStatus build() => initial;
}

final class _NoopOpenWebUiAccountStorageIsolation
    extends OpenWebUiAccountStorageIsolation {
  @override
  void build() {}
}

final _sidebarAuthTokenProvider = NotifierProvider<_SidebarAuthToken, String?>(
  _SidebarAuthToken.new,
);

final class _SidebarAuthToken extends Notifier<String?> {
  @override
  String? build() => 'test-token';

  void set(String? token) => state = token;
}

final class _SeededCertifiedDatabaseServer
    extends OpenWebUiCertifiedDatabaseServerNotifier {
  _SeededCertifiedDatabaseServer(this.serverId);

  final String serverId;

  @override
  String? build() => serverId;
}

final class _SeededActiveConversation extends ActiveConversationNotifier {
  _SeededActiveConversation(this.conversation);

  final Conversation conversation;

  @override
  Conversation? build() => conversation;
}

List<TerminalServerInfo> _defaultTerminalServers() {
  return <TerminalServerInfo>[
    TerminalServerInfo(
      kind: TerminalServerKind.system,
      selectionId: 'test-terminal',
      systemServerId: 'test-terminal',
      baseUrl: Uri.parse('https://example.com/api/v1/terminals/test-terminal'),
      name: 'Test Terminal',
    ),
    TerminalServerInfo(
      kind: TerminalServerKind.system,
      selectionId: 'test-terminal-2',
      systemServerId: 'test-terminal-2',
      baseUrl: Uri.parse(
        'https://example.com/api/v1/terminals/test-terminal-2',
      ),
      name: 'Test Terminal 2',
    ),
  ];
}

final class _DirectPreferredBackendController
    extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.direct;
}

class _TestHermesJobsController extends HermesJobsController {
  _TestHermesJobsController(this.jobs);

  final List<HermesJob> jobs;

  @override
  Future<List<HermesJob>> build() async => jobs;
}

class _SidebarHarnessControllers {
  _SidebarHarnessControllers({bool notesEnabled = true, int initialIndex = 0})
    : notesNotifier = _TestNotesFeatureEnabledNotifier(notesEnabled),
      activeTabNotifier = _TestSidebarActiveTab(initialIndex);

  final _TestNotesFeatureEnabledNotifier notesNotifier;
  final _TestSidebarActiveTab activeTabNotifier;
  int chatRefreshCalls = 0;
  int noteRefreshCalls = 0;
  Completer<void>? _pendingChatRefresh;
  Completer<void>? _pendingNoteRefresh;

  Completer<void> keepChatRefreshPending() {
    return _pendingChatRefresh = Completer<void>();
  }

  Completer<void> keepNoteRefreshPending() {
    return _pendingNoteRefresh = Completer<void>();
  }

  Future<void> recordChatRefresh() {
    chatRefreshCalls++;
    return _pendingChatRefresh?.future ?? Future<void>.value();
  }

  Future<void> recordNoteRefresh() {
    noteRefreshCalls++;
    return _pendingNoteRefresh?.future ?? Future<void>.value();
  }
}

class _TestNotesFeatureEnabledNotifier extends NotesFeatureEnabledNotifier {
  _TestNotesFeatureEnabledNotifier(this.initialValue);

  final bool initialValue;

  @override
  bool build() => initialValue;

  @override
  void setEnabled(bool enabled) {
    state = enabled;
  }
}

class _TestSidebarActiveTab extends SidebarActiveTab {
  _TestSidebarActiveTab(this.initialValue);

  final int initialValue;

  @override
  int build() => initialValue;

  @override
  void set(int index) {
    state = index.clamp(0, 3);
  }

  // ignore: avoid_public_notifier_properties
  int get currentValue => state;
}

/// Dependency bumped by gated pagination, mirroring the production notifier's
/// private page tick: bumping it re-runs [_TestConversations.build], which
/// Riverpod reports as a loading-with-previous-value reload until it resolves.
final _testConversationReloadTickProvider =
    NotifierProvider<_TestConversationReloadTick, int>(
      _TestConversationReloadTick.new,
    );

class _TestConversationReloadTick extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

class _TestConversations extends Conversations {
  _TestConversations(
    this.conversations, {
    this.onRefresh,
    this.pagination,
    this.archivedPagination,
  });

  final List<Conversation> conversations;
  final Future<void> Function()? onRefresh;
  final _TestConversationPagination? pagination;
  final _TestArchivedConversationPagination? archivedPagination;
  final List<Conversation> _gateLoadedPages = <Conversation>[];

  @override
  Future<List<Conversation>> build() async {
    final reloadGate = pagination?.reloadGate;
    if (reloadGate != null) {
      final tick = ref.watch(_testConversationReloadTickProvider);
      if (tick > 0) {
        await reloadGate.future;
        final nextConversation = pagination!.takeNextConversation();
        if (nextConversation != null) {
          _gateLoadedPages.add(nextConversation);
        }
      }
      return [...conversations, ..._gateLoadedPages];
    }
    return conversations;
  }

  @override
  Future<void> refresh({
    bool includeFolders = false,
    bool forceFresh = false,
  }) async {
    await onRefresh?.call();
  }

  @override
  bool hasMoreRegularChats() {
    return pagination?.hasMore ?? super.hasMoreRegularChats();
  }

  @override
  bool isLoadingMoreRegularChats() => false;

  @override
  Future<void> loadMore() async {
    final pagination = this.pagination;
    if (pagination == null) {
      return super.loadMore();
    }
    pagination.loadMoreCalls++;
    if (pagination.reloadGate != null) {
      // Mirror the production notifier: pagination bumps a tick dependency,
      // which re-runs build and reports a loading-with-previous-value reload
      // until the widened window emits after the gate completes.
      ref.read(_testConversationReloadTickProvider.notifier).bump();
      await Future<void>.delayed(Duration.zero);
      return;
    }
    final nextConversation = pagination.takeNextConversation();
    if (nextConversation == null) return;
    state = AsyncData<List<Conversation>>([
      ...state.value ?? conversations,
      nextConversation,
    ]);
  }

  @override
  int archivedChatCount() {
    return archivedPagination?.totalCount ?? super.archivedChatCount();
  }

  @override
  bool archivedChatsVisible() {
    return archivedPagination?.visible ?? super.archivedChatsVisible();
  }

  @override
  bool hasMoreArchivedChats() {
    final pagination = archivedPagination;
    return pagination == null
        ? super.hasMoreArchivedChats()
        : pagination.loadedCount < pagination.totalCount;
  }

  @override
  bool isLoadingMoreArchivedChats() => false;

  @override
  Future<void> setArchivedChatsVisible(bool visible) async {
    final pagination = archivedPagination;
    if (pagination == null) {
      return super.setArchivedChatsVisible(visible);
    }
    pagination.setVisible(visible);
    _publishArchivedPage(pagination);
  }

  @override
  Future<void> loadMoreArchived() async {
    final pagination = archivedPagination;
    if (pagination == null) {
      return super.loadMoreArchived();
    }
    pagination.loadMore();
    _publishArchivedPage(pagination);
  }

  void _publishArchivedPage(_TestArchivedConversationPagination pagination) {
    final active = (state.asData?.value ?? conversations)
        .where((conversation) => !conversation.archived)
        .toList(growable: false);
    state = AsyncData<List<Conversation>>([
      ...active,
      ...pagination.loadedConversations,
    ]);
  }
}

class _TestConversationPagination {
  _TestConversationPagination({required this.remainingPages, this.reloadGate});

  int remainingPages;
  int loadMoreCalls = 0;
  int pagesConsumed = 0;

  /// When set, `loadMore` first publishes a reload (loading-with-previous)
  /// state and holds it until the gate completes, exposing the intermediate
  /// provider state the production tick-based pagination goes through.
  final Completer<void>? reloadGate;

  bool get hasMore => remainingPages > 0;

  Conversation? takeNextConversation() {
    if (!hasMore) return null;
    remainingPages--;
    pagesConsumed++;
    final timestamp = DateTime(
      2026,
      1,
      1,
    ).add(Duration(minutes: pagesConsumed));
    return Conversation(
      id: 'paged-$pagesConsumed',
      title: 'Paged $pagesConsumed',
      createdAt: timestamp,
      updatedAt: timestamp,
    );
  }
}

class _TestArchivedConversationPagination {
  _TestArchivedConversationPagination({
    required this.totalCount,
    required this.pageSize,
  });

  final int totalCount;
  final int pageSize;
  bool visible = false;
  int loadedCount = 0;
  int loadMoreCalls = 0;

  void setVisible(bool value) {
    visible = value;
    loadedCount = value ? pageSize.clamp(0, totalCount).toInt() : 0;
  }

  void loadMore() {
    if (!visible || loadedCount >= totalCount) return;
    loadMoreCalls++;
    loadedCount = (loadedCount + pageSize).clamp(0, totalCount).toInt();
  }

  List<Conversation> get loadedConversations {
    final timestamp = DateTime(2026, 1, 1);
    return List<Conversation>.generate(
      loadedCount,
      (index) => Conversation(
        id: 'archived-page-$index',
        title: 'Archived page $index',
        createdAt: timestamp,
        updatedAt: timestamp.add(Duration(minutes: index)),
        archived: true,
      ),
    );
  }
}

class _TestModels extends Models {
  @override
  Future<List<Model>> build() async => const [];
}

class _TestFolders extends Folders {
  _TestFolders(this.folders);

  final List<Folder> folders;

  @override
  Future<List<Folder>> build() async => folders;
}

class _TestNotesList extends NotesList {
  _TestNotesList({this.onRefresh});

  final Future<void> Function()? onRefresh;

  @override
  Future<List<Note>> build() async => const [];

  @override
  Future<void> refresh() async {
    await onRefresh?.call();
  }
}

class _TestChannelsList extends ChannelsList {
  @override
  Future<List<Channel>> build() async => const [];
}

class _FakeOptimizedStorageService extends Fake
    implements OptimizedStorageService {
  @override
  Future<void> saveLocalDefaultModel(Model? model) async {}
}

class _TestShowPinnedNotifier extends ShowPinnedNotifier {
  _TestShowPinnedNotifier(this.initialValue);

  final bool initialValue;

  @override
  bool build() => initialValue;
}

class _TestShowFoldersNotifier extends ShowFoldersNotifier {
  @override
  bool build() => true;
}

class _TestShowRecentNotifier extends ShowRecentNotifier {
  _TestShowRecentNotifier(this.initialValue);

  final bool initialValue;

  @override
  bool build() => initialValue;
}

class _TestShowArchivedNotifier extends ShowArchivedNotifier {
  _TestShowArchivedNotifier(this.initialValue);

  final bool initialValue;

  @override
  bool build() => initialValue;
}
