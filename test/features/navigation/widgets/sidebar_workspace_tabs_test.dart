import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/providers/backend_mode_providers.dart';
import 'package:conduit/core/models/channel.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/note.dart';
import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/channels/widgets/channel_list_tab.dart';
import 'package:conduit/features/navigation/providers/sidebar_providers.dart';
import 'package:conduit/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit/features/navigation/widgets/conversation_tile.dart';
import 'package:conduit/features/navigation/widgets/sidebar_page.dart';
import 'package:conduit/features/navigation/widgets/sidebar_user_pill.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/user_avatar.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'sidebar_page_test_support.dart';

void main() {
  testWidgets('empty notes tab shows a create action below the message', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers(
      initialTab: SidebarTabId.notes,
    );
    await tester.pumpWidget(sidebarTestBuildHarness(controllers: controllers));
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(SidebarPage));
    final l10n = AppLocalizations.of(context)!;
    expect(find.text(l10n.noNotesYet), findsOneWidget);
    expect(find.text(l10n.createNote), findsOneWidget);
  });

  testWidgets('notes and channels use flat chat-style sidebar rows', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers(
      initialTab: SidebarTabId.notes,
    );
    final timestamp = DateTime(2026, 1, 1);
    final conversation = Conversation(
      id: 'flat-chat',
      title: 'Flat Chat',
      createdAt: timestamp,
      updatedAt: timestamp,
      messages: const [],
    );
    const note = Note(
      id: 'flat-note',
      title: 'Flat Note',
      data: NoteData(content: NoteContent(md: '')),
      createdAt: 1767225600000000000,
      updatedAt: 1767225600000000000,
    );
    const channel = Channel(
      id: 'flat-channel',
      name: 'Flat Channel',
      description: '',
    );

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        conversations: [conversation],
        notes: const [note],
        channels: const [channel],
      ),
    );
    await tester.pumpAndSettle();

    final noteRow = find.byKey(
      const ValueKey<String>('note-sidebar-row-flat-note'),
    );
    expect(noteRow, findsOneWidget);
    expect(
      find.descendant(of: noteRow, matching: find.byType(DecoratedBox)),
      findsNothing,
    );
    final noteMenu = tester.widget<ConduitContextMenu>(
      find.ancestor(of: noteRow, matching: find.byType(ConduitContextMenu)),
    );
    expect(noteMenu.previewBuilder, isNotNull);
    final noteRect = tester.getRect(noteRow);
    final noteTitle = tester.widget<Text>(
      find.descendant(of: noteRow, matching: find.text('Flat Note')),
    );

    await tester.tap(sidebarTestBottomNavTabLabel('Chats'));
    await tester.pumpAndSettle();
    final chatRect = tester.getRect(
      find.byKey(
        ValueKey<String>('drawer-chat-${conversationScopedId(conversation)}'),
      ),
    );
    final chatTitle = tester.widget<Text>(find.text('Flat Chat'));
    expect(noteRect.left, chatRect.left);
    expect(noteRect.right, chatRect.right);
    expect(noteRect.height, chatRect.height);
    expect(noteTitle.style?.fontSize, AppTypography.sidebarTitleStyle.fontSize);
    expect(noteTitle.style?.fontSize, chatTitle.style?.fontSize);

    await tester.tap(sidebarTestBottomNavTabLabel('Channels'));
    await tester.pumpAndSettle();
    final channelRow = find.byKey(
      const ValueKey<String>('channel-sidebar-row-flat-channel'),
    );
    expect(channelRow, findsOneWidget);
    expect(
      find.descendant(of: channelRow, matching: find.byType(DecoratedBox)),
      findsNothing,
    );
    final channelMenu = tester.widget<ConduitContextMenu>(
      find.ancestor(of: channelRow, matching: find.byType(ConduitContextMenu)),
    );
    expect(channelMenu.previewBuilder, isNotNull);
    final channelRect = tester.getRect(channelRow);
    final channelTitle = tester.widget<Text>(
      find.descendant(of: channelRow, matching: find.text('Flat Channel')),
    );
    expect(channelRect.left, chatRect.left);
    expect(channelRect.right, chatRect.right);
    expect(channelRect.height, chatRect.height);
    expect(
      channelTitle.style?.fontSize,
      AppTypography.sidebarTitleStyle.fontSize,
    );
    expect(channelTitle.style?.fontSize, chatTitle.style?.fontSize);
  });

  testWidgets('channel semantics include the unread message count', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers(
      initialTab: SidebarTabId.channels,
    );
    const channel = Channel(
      id: 'unread-channel',
      name: 'Unread Channel',
      description: 'Channel preview',
      unreadCount: 3,
    );

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: controllers,
        channels: const [channel],
      ),
    );
    await tester.pumpAndSettle();

    final channelRow = find.byKey(
      const ValueKey<String>('channel-sidebar-row-unread-channel'),
    );
    expect(
      tester.getSemantics(channelRow).label,
      contains('3 unread messages'),
    );
  });

  testWidgets('note rows show last-edited metadata instead of descriptions', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers(
      initialTab: SidebarTabId.notes,
    );
    const note = Note(
      id: 'hierarchy-note',
      title: 'Project brief',
      data: NoteData(
        content: NoteContent(md: 'Supporting description for the note'),
      ),
      createdAt: 1767225600000000000,
      updatedAt: 1767225600000000000,
    );

    await tester.pumpWidget(
      sidebarTestBuildHarness(controllers: controllers, notes: const [note]),
    );
    await tester.pumpAndSettle();

    final row = find.byKey(
      const ValueKey<String>('note-sidebar-row-hierarchy-note'),
    );
    final title = tester.widget<Text>(
      find.descendant(of: row, matching: find.text('Project brief')),
    );
    final tileContent = tester.widget<SidebarListTileContent>(
      find.descendant(of: row, matching: find.byType(SidebarListTileContent)),
    );
    final lastEditedFinder = find.descendant(
      of: row,
      matching: find.byKey(
        const ValueKey<String>('note-sidebar-last-edited-hierarchy-note'),
      ),
    );
    final lastEdited = tester.widget<Text>(lastEditedFinder);
    final theme = tester.element(row).conduitTheme;

    expect(title.style?.fontWeight, FontWeight.w400);
    expect(tileContent.titleFontWeight, FontWeight.w400);
    expect(title.style?.color, theme.textSecondary);
    expect(lastEdited.data, 'Jan 1');
    expect(lastEdited.style?.fontSize, AppTypography.bodySmallStyle.fontSize);
    expect(lastEdited.style?.fontSize, lessThan(title.style!.fontSize!));
    expect(
      lastEdited.style?.color,
      theme.textSecondary.withValues(alpha: Alpha.secondary),
    );
    expect(
      tester.getCenter(lastEditedFinder).dx,
      greaterThan(
        tester
            .getCenter(
              find.descendant(of: row, matching: find.text('Project brief')),
            )
            .dx,
      ),
    );
    expect(
      find.descendant(
        of: row,
        matching: find.text('Supporting description for the note'),
      ),
      findsNothing,
    );
  });

  testWidgets('channel layer state survives notes toggle', (tester) async {
    final controllers = SidebarTestSidebarHarnessControllers(
      initialTab: SidebarTabId.channels,
    );

    await tester.pumpWidget(sidebarTestBuildHarness(controllers: controllers));

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
    final controllers = SidebarTestSidebarHarnessControllers();
    const user = User(
      id: 'user-1',
      username: 'ava',
      email: 'ava@example.com',
      name: 'Ava',
      role: 'user',
    );

    await tester.pumpWidget(
      sidebarTestBuildHarness(controllers: controllers, currentUser: user),
    );

    expect(find.byType(SidebarProfileAppBarLeading), findsOneWidget);

    await tester.tap(sidebarTestBottomNavTabLabel('Terminal'));
    await tester.pumpAndSettle();

    expect(find.byType(SidebarProfileAppBarLeading), findsOneWidget);

    await tester.tap(sidebarTestBottomNavTabLabel('Notes'));
    await tester.pumpAndSettle();

    expect(find.byType(SidebarProfileAppBarLeading), findsOneWidget);

    await tester.tap(sidebarTestBottomNavTabLabel('Channels'));
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
          localizationsDelegates: conduitLocalizationsDelegates,
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
            SidebarTestDirectPreferredBackendController.new,
          ),
          sidebarNativeProfilePresenterProvider.overrideWithValue((_) async {
            nativePresentationCalls++;
            return false;
          }),
        ],
        child: MaterialApp.router(
          localizationsDelegates: conduitLocalizationsDelegates,
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
    final controllers = SidebarTestSidebarHarnessControllers();
    const user = User(
      id: 'user-1',
      username: 'ava',
      email: 'ava@example.com',
      name: 'Ava',
      role: 'user',
    );

    await tester.pumpWidget(
      sidebarTestBuildHarness(controllers: controllers, currentUser: user),
    );

    final appBar = tester.widget<AppBar>(find.byType(AppBar));

    expect(appBar.toolbarHeight, kTextTabBarHeight);
  });

  testWidgets('closing expanded search clears the active filter', (
    tester,
  ) async {
    final controllers = SidebarTestSidebarHarnessControllers();
    final timestamp = DateTime(2026, 1, 1);
    const user = User(
      id: 'user-1',
      username: 'ava',
      name: 'Ava',
      email: 'ava@example.com',
      role: 'user',
    );

    await tester.pumpWidget(
      sidebarTestBuildHarness(
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

    ProviderScope.containerOf(tester.element(find.byType(SidebarPage)))
        .read(sidebarHeaderSearchExpandedProvider.notifier)
        .setExpanded(true);
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
}
