import 'dart:async';

import 'package:conduit/core/database/chat_database_repository.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/folder.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/navigation/providers/conversation_selection_provider.dart';
import 'package:conduit/features/navigation/widgets/chats_drawer.dart';
import 'package:conduit/features/navigation/widgets/conversation_tile.dart';
import 'package:conduit/features/navigation/widgets/folder_tree_guides.dart';
import 'package:conduit/features/navigation/widgets/sidebar_page.dart';
import 'package:conduit/features/tools/providers/tools_providers.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sidebar_page_test_support.dart';

void main() {
  testWidgets('nested folders render stacked under their parent', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();
    final timestamp = DateTime(2026, 1, 1);
    final nestedConversation = Conversation(
      id: 'nested-chat',
      title: 'Nested Chat',
      createdAt: timestamp,
      updatedAt: timestamp,
      lastReadAt: timestamp,
      folderId: 'child-folder',
      messages: const [],
    );
    final nestedConversationId = conversationScopedId(nestedConversation);

    await tester.pumpWidget(
      sidebarTestBuildHarness(
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
    final nestedHierarchy = tester.widget<FolderTreeHierarchyNode>(
      find.byKey(const ValueKey<String>('tree-guides-folder-child-folder')),
    );
    expect(nestedHierarchy.child, isA<ConduitContextMenu>());
    final nestedConversationHierarchy = tester.widget<FolderTreeHierarchyNode>(
      find.byKey(ValueKey<String>('tree-guides-chat-$nestedConversationId')),
    );
    expect(nestedConversationHierarchy.child, isA<ConduitContextMenu>());

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
    expect(chatOffset.dx, greaterThan(childOffset.dx));

    final parentIconLeft = tester
        .getRect(
          find.byKey(const ValueKey<String>('folder-icon-parent-folder')),
        )
        .left;
    final childIconLeft = tester
        .getRect(find.byKey(const ValueKey<String>('folder-icon-child-folder')))
        .left;
    final nestedChatTitleLeft = tester.getRect(chatFinder).left;
    expect(
      childIconLeft - parentIconLeft,
      2 * FolderTreeHierarchyNode.segmentWidth,
    );
    expect(
      nestedChatTitleLeft - parentIconLeft,
      3 * FolderTreeHierarchyNode.segmentWidth,
    );
  });

  testWidgets('folder rows no longer show inline new chat buttons', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();

    await tester.pumpWidget(
      sidebarTestBuildHarness(
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
    final controllers = SidebarTestSidebarHarnessControllers();

    await tester.pumpWidget(
      sidebarTestBuildHarness(
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
    final controllers = SidebarTestSidebarHarnessControllers();

    await tester.pumpWidget(
      sidebarTestBuildHarness(
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

  testWidgets('folder rows match chat tile surfaces and active styling', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        folders: const [
          Folder(id: 'parent-folder', name: 'Parent Folder', isExpanded: false),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final surfaceFinder = find.byKey(
      const ValueKey<String>('folder-surface-parent-folder'),
    );
    final theme = tester.element(surfaceFinder).conduitTheme;

    expect(
      tester.widget<Container>(surfaceFinder).margin,
      kConversationTileMargin,
    );
    expect(
      find.byKey(const ValueKey<String>('folder-active-tint-parent-folder')),
      findsNothing,
    );
    expect(
      tester.widget<Text>(find.text('Parent Folder')).style?.color,
      theme.textSecondary,
    );
    expect(
      tester.widget<Text>(find.text('Parent Folder')).style?.fontWeight,
      FontWeight.w400,
    );

    NavigationService.router.go('/folder/parent-folder');
    await tester.pumpAndSettle();

    final tint = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey<String>('folder-active-tint-parent-folder')),
    );
    final tintDecoration = tint.decoration as BoxDecoration;
    expect(tintDecoration.border, isNull);
    expect(
      tintDecoration.color,
      conduitConversationTileDecoration(theme, selected: true).color,
    );
    expect(
      tintDecoration.borderRadius,
      BorderRadius.circular(AppBorderRadius.card),
    );
    expect(
      tester.widget<Text>(find.text('Parent Folder')).style?.color,
      theme.textPrimary,
    );
    expect(
      tester.widget<Text>(find.text('Parent Folder')).style?.fontWeight,
      FontWeight.w600,
    );
  });

  testWidgets('folder rows paint pressed feedback and clear it on release', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        folders: const [
          Folder(id: 'parent-folder', name: 'Parent Folder', isExpanded: false),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey<String>('folder-open-parent-folder'));
    final gesture = await tester.startGesture(tester.getCenter(row));
    await tester.pump();

    final pressedFinder = find.byKey(
      const ValueKey<String>('folder-pressed-tint-parent-folder'),
    );
    final pressed = tester.widget<DecoratedBox>(pressedFinder);
    final theme = tester.element(row).conduitTheme;
    expect(
      (pressed.decoration as BoxDecoration).color,
      conduitConversationTileDecoration(
        theme,
        selected: false,
        pressed: true,
      ).color,
    );

    await gesture.up();
    await tester.pump();
    expect(pressedFinder, findsNothing);
  });

  testWidgets('active top-level chat tint aligns with root folder gutters', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();
    final timestamp = DateTime(2026, 1, 1);
    final conversation = Conversation(
      id: 'active-chat',
      title: 'Active Chat',
      createdAt: timestamp,
      updatedAt: timestamp,
      messages: const [],
    );

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        conversations: [conversation],
        activeConversation: conversation,
        folders: const [
          Folder(id: 'parent-folder', name: 'Parent Folder', isExpanded: false),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final chatRect = tester.getRect(
      find.byKey(
        ValueKey<String>('drawer-chat-${conversationScopedId(conversation)}'),
      ),
    );
    final folderRect = tester.getRect(
      find.byKey(const ValueKey<String>('folder-surface-parent-folder')),
    );
    final sectionLeadingLeft = tester
        .getRect(find.byKey(const ValueKey<String>('folders-section-leading')))
        .left;
    final folderIconLeft = tester
        .getRect(
          find.byKey(const ValueKey<String>('folder-icon-parent-folder')),
        )
        .left;

    expect(chatRect.left, 0);
    expect(chatRect.left, folderRect.left);
    expect(chatRect.right, folderRect.right);
    expect(tester.getTopLeft(find.text('Active Chat')).dx, Spacing.md);
    expect(tester.getTopLeft(find.text('Active Chat')).dx, sectionLeadingLeft);
    expect(folderIconLeft, sectionLeadingLeft);

    NavigationService.router.go('/folder/parent-folder');
    await tester.pumpAndSettle();

    final chatTintRect = tester.getRect(
      find.byKey(const ValueKey<String>('conversation-tile-active-tint')),
    );
    final folderTintRect = tester.getRect(
      find.byKey(const ValueKey<String>('folder-active-tint-parent-folder')),
    );
    final drawerRect = tester.getRect(find.byType(ChatsDrawer));
    final leftTintInset = chatTintRect.left - drawerRect.left;
    final rightTintInset = drawerRect.right - chatTintRect.right;
    final titleLeft = tester.getTopLeft(find.text('Active Chat')).dx;
    expect(titleLeft - chatTintRect.left, Spacing.sm);
    expect(chatTintRect.left, Spacing.sm);
    expect(rightTintInset, leftTintInset);
    expect(chatTintRect.left, folderTintRect.left);
    expect(chatTintRect.right, folderTintRect.right);
  });

  testWidgets('tapping a folder arrow only expands inline contents', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();

    await tester.pumpWidget(
      sidebarTestBuildHarness(
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

    expect(
      tester.getSize(
        find.byKey(const ValueKey<String>('folder-expand-parent-folder')),
      ),
      const Size.square(TouchTarget.minimum),
    );
    expect(
      tester.getSize(find.byTooltip(AppLocalizationsEn().newFolder)),
      const Size.square(TouchTarget.minimum),
    );

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
    final controllers = SidebarTestSidebarHarnessControllers();
    final timestamp = DateTime(2026, 1, 1);

    await tester.pumpWidget(
      sidebarTestBuildHarness(
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
    final controllers = SidebarTestSidebarHarnessControllers();
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
      sidebarTestBuildHarness(
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
      final controllers = SidebarTestSidebarHarnessControllers();
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
        sidebarTestBuildHarness(
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
      final controllers = SidebarTestSidebarHarnessControllers();
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
        sidebarTestBuildHarness(
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

      container
          .read(sidebarTestAuthTokenProvider.notifier)
          .set('account-b-token');
      loadGate.complete(full);
      await tester.pumpAndSettle();

      expect(container.read(activeConversationProvider)?.id, previous.id);
    },
  );

  testWidgets('colliding chat ids render and select as distinct rows', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();
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
      sidebarTestBuildHarness(
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
