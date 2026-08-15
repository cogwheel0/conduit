import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:checks/checks.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/folder.dart';
import 'package:conduit/features/navigation/widgets/sidebar_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sidebar_page_test_support.dart';

void main() {
  testWidgets('empty chats tab shows a refresh action below the message', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();
    final pendingRefresh = controllers.keepChatRefreshPending();

    await tester.pumpWidget(sidebarTestBuildHarness(controllers: controllers));
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(SidebarPage));
    final l10n = AppLocalizations.of(context)!;
    final refreshLabel = MaterialLocalizations.of(context)
        .refreshIndicatorSemanticLabel;

    final refreshAction = sidebarTestCheckEmptyStateRefreshButtonBelow(
      tester,
      layer: SidebarTestSidebarTabLayer.chats,
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

  testWidgets(
    'chat pull-to-refresh reserves a gutter above conversation rows',
    (tester) async {
      final controllers = SidebarTestSidebarHarnessControllers();
      final pendingRefresh = controllers.keepChatRefreshPending();
      final timestamp = DateTime(2026, 1, 1);
      final conversation = Conversation(
        id: 'refresh-layout-chat',
        title: 'Refresh layout',
        createdAt: timestamp,
        updatedAt: timestamp,
      );

      await tester.pumpWidget(
        sidebarTestBuildHarness(
          controllers: controllers,
          conversations: [conversation],
        ),
      );
      await tester.pumpAndSettle();

      final tile = find.byKey(
        ValueKey<String>('drawer-chat-${conversationScopedId(conversation)}'),
      );
      final refreshSlot = find.byKey(
        const ValueKey<String>('chats-refresh-slot'),
      );
      final idleSlotHeight = tester.getSize(refreshSlot).height;
      final refreshControl = tester.widget<RefreshIndicator>(
        find.descendant(
          of: sidebarTestLayerRootFinder(SidebarTestSidebarTabLayer.chats),
          matching: find.byType(RefreshIndicator),
        ),
      );
      check(refreshControl.onStatusChange).isNotNull();
      refreshControl.onStatusChange!(RefreshIndicatorStatus.refresh);
      final refreshing = refreshControl.onRefresh();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      check(controllers.chatRefreshCalls).equals(1);
      final progress = find.byKey(
        const ValueKey<String>('chats-refresh-progress'),
      );
      check(progress.evaluate()).length.equals(1);
      expect(
        find.descendant(
          of: progress,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      check(tester.getBottomLeft(progress).dy <= tester.getTopLeft(tile).dy)
          .isTrue();
      check(tester.getSize(refreshSlot).height > idleSlotHeight).isTrue();

      pendingRefresh.complete();
      await refreshing;
      refreshControl.onStatusChange!(RefreshIndicatorStatus.done);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      check(progress.evaluate()).isEmpty();
      check(tester.getSize(refreshSlot).height).equals(idleSlotHeight);
    },
  );

  testWidgets('chat pull-to-refresh uses Cupertino progress on iOS', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();
    final timestamp = DateTime(2026, 1, 1);

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        conversations: [
          Conversation(
            id: 'cupertino-refresh-chat',
            title: 'Cupertino refresh',
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        ],
        theme: ThemeData(platform: TargetPlatform.iOS),
      ),
    );
    await tester.pumpAndSettle();

    final refreshControl = tester.widget<RefreshIndicator>(
      find.byType(RefreshIndicator),
    );
    refreshControl.onStatusChange!(RefreshIndicatorStatus.refresh);
    await tester.pump();

    final progress = find.byKey(
      const ValueKey<String>('chats-refresh-progress'),
    );
    expect(
      find.descendant(
        of: progress,
        matching: find.byType(CupertinoActivityIndicator),
      ),
      findsOneWidget,
    );
  });

  testWidgets('collapsed paginated chat sections do not consume hidden pages', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();
    final pagination = SidebarTestTestConversationPagination(remainingPages: 3);
    final timestamp = DateTime(2026, 1, 1);

    await tester.pumpWidget(
      sidebarTestBuildHarness(
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
      final controllers = SidebarTestSidebarHarnessControllers();
      final pagination = SidebarTestTestConversationPagination(
        remainingPages: 1,
      );
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
        sidebarTestBuildHarness(
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
          Iterable<int>.generate(loadMoreSemantics.evaluate().length)
              .any((index) {
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
    final controllers = SidebarTestSidebarHarnessControllers();
    final pagination = SidebarTestTestConversationPagination(remainingPages: 1);
    final timestamp = DateTime(2026, 1, 1);

    await tester.pumpWidget(
      sidebarTestBuildHarness(
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
      final controllers = SidebarTestSidebarHarnessControllers();
      final reloadGate = Completer<void>();
      final pagination = SidebarTestTestConversationPagination(
        remainingPages: 1,
        reloadGate: reloadGate,
      );
      final timestamp = DateTime(2026, 1, 1);

      await tester.pumpWidget(
        sidebarTestBuildHarness(
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
    final controllers = SidebarTestSidebarHarnessControllers();
    final pagination = SidebarTestTestConversationPagination(remainingPages: 1);
    final timestamp = DateTime(2026, 1, 1);

    await tester.pumpWidget(
      sidebarTestBuildHarness(
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
    final controllers = SidebarTestSidebarHarnessControllers();
    final archivedPagination = SidebarTestTestArchivedConversationPagination(
      totalCount: 450,
      pageSize: 2,
    );

    await tester.pumpWidget(
      sidebarTestBuildHarness(
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
        Iterable<int>.generate(archivedLoadMoreSemantics.evaluate().length)
            .any((index) {
              final semantics = tester
                  .getSemantics(archivedLoadMoreSemantics.at(index))
                  .getSemanticsData();
              return semantics.label == archivedLoadMoreLabel &&
                  semantics.flagsCollection.isButton &&
                  semantics.flagsCollection.isEnabled == Tristate.isTrue;
            });
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
}
