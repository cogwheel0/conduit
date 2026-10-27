import 'package:conduit/features/navigation/widgets/sidebar_destination_page.dart';
import 'package:conduit/features/navigation/widgets/sidebar_page.dart';
import 'package:conduit/features/navigation/widgets/responsive_drawer_layout.dart';
import 'package:conduit/features/navigation/widgets/chats_drawer.dart';
import 'package:conduit/features/notes/widgets/notes_list_tab.dart';
import 'package:conduit/features/channels/widgets/channel_list_tab.dart';
import 'package:conduit/features/terminal/widgets/terminal_tab.dart';
import 'package:conduit/shared/widgets/sidebar_layout_contract.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/note.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'sidebar_page_test_support.dart';

Widget _chat() => Builder(
  builder: (context) => Scaffold(
    body: TextButton(
      key: const ValueKey<String>('destination-menu-button'),
      onPressed: () => SidebarDrawerControllerScope.maybeOf(context)!.open(),
      child: const Text('Chat content'),
    ),
  ),
);

void main() {
  testWidgets('iOS destination search stays inside the navigation bar', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
    PlatformUiCapabilities.debugNativeIOS26Override = false;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        initialLocation: Routes.notes,
        theme: ThemeData(platform: TargetPlatform.iOS),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ConduitGlassSearchField), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('destination-search-button')),
    );
    await tester.pumpAndSettle();
    final search = find.descendant(
      of: find.byType(SidebarDestinationPage),
      matching: find.byType(ConduitGlassSearchField),
    );
    expect(
      tester.getCenter(search).dy,
      closeTo(
        tester
            .getCenter(
              find.byKey(const ValueKey<String>('destination-menu-button')),
            )
            .dy,
        1,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('destinations close the sidebar and render in the main pane', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final date = DateTime(2026, 1, 1);
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        shellChat: _chat(),
        folders: const [Folder(id: 'paper', name: 'Paper projects')],
        conversations: [
          Conversation(
            id: 'lantern',
            title: 'Paper lantern',
            createdAt: date,
            updatedAt: date,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    for (final label in ['Notes', 'Terminal', 'Channels', 'Chats']) {
      await tester.tap(
        find.byKey(const ValueKey<String>('destination-menu-button')),
      );
      await tester.pumpAndSettle();
      final sidebar = find.byType(SidebarPage);
      expect(
        find.descendant(of: sidebar, matching: find.text('Paper projects')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sidebar, matching: find.text('Paper lantern')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sidebar, matching: find.byType(ChatsDrawer)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sidebar, matching: find.byType(NotesListTab)),
        findsNothing,
      );
      expect(
        find.descendant(of: sidebar, matching: find.byType(TerminalTab)),
        findsNothing,
      );
      expect(
        find.descendant(of: sidebar, matching: find.byType(ChannelListTab)),
        findsNothing,
      );
      await tester.tap(sidebarTestDestinationLabel(label));
      await tester.pumpAndSettle();
      expect(
        tester
            .state<ResponsiveDrawerLayoutState>(
              find.byType(ResponsiveDrawerLayout),
            )
            .isOpen,
        isFalse,
      );
      if (label == 'Chats') {
        expect(find.text('Chat content').hitTestable(), findsOneWidget);
        expect(find.byType(SidebarDestinationPage), findsNothing);
      } else {
        expect(find.byType(SidebarDestinationPage), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(SidebarDestinationPage),
            matching: find.text(label),
          ),
          findsWidgets,
        );
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('main destination search is independent of chat history search', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final date = DateTime(2026, 1, 1);
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        shellChat: _chat(),
        initialLocation: Routes.notes,
        conversations: [
          Conversation(
            id: 'lantern',
            title: 'Paper lantern',
            createdAt: date,
            updatedAt: date,
          ),
        ],
        notes: const [
          Note(
            id: 'supplies',
            title: 'Workshop supplies',
            data: NoteData(content: NoteContent(md: '')),
            createdAt: 1767225600000000000,
            updatedAt: 1767225600000000000,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ConduitGlassSearchField), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('destination-search-button')),
    );
    await tester.pumpAndSettle();
    final mainSearch = find.descendant(
      of: find.byType(SidebarDestinationPage),
      matching: find.byType(TextField),
    );
    await tester.enterText(mainSearch, 'unmatched');
    await tester.pumpAndSettle();
    expect(find.text('Workshop supplies'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('destination-menu-button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Paper lantern'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('sidebar-search-button')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(SidebarPage),
        matching: find.byType(TextField),
      ),
      'Paper',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(mainSearch).controller!.text, 'unmatched');
    await tester.tapAt(const Offset(380, 420));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(mainSearch).controller!.text, 'unmatched');
    await tester.tap(
      find.byKey(const ValueKey<String>('destination-search-button')),
    );
    await tester.pumpAndSettle();
    expect(mainSearch, findsNothing);
    expect(find.text('Workshop supplies'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
