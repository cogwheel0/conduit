import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sidebar_page_test_support.dart';

void main() {
  final markAsUnread = AppLocalizationsEn().markAsUnread;
  final readAt = DateTime(2026, 1, 1, 12);

  Conversation chat(String id, {DateTime? lastReadAt}) => Conversation(
    id: id,
    title: 'Chat $id',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1, 10),
    lastReadAt: lastReadAt,
    messages: const [],
  );

  List<String> menuLabels(WidgetTester tester, Conversation conversation) {
    final tile = find.byKey(
      ValueKey<String>('drawer-chat-${conversationScopedId(conversation)}'),
    );
    final menu = tester.widget<ConduitContextMenu>(
      find.ancestor(of: tile, matching: find.byType(ConduitContextMenu)).first,
    );
    return [for (final action in menu.actions) action.label];
  }

  testWidgets('only a read Open WebUI chat that is not open offers it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final read = chat('read', lastReadAt: readAt);
    final unread = chat('unread', lastReadAt: DateTime(2026, 1, 1, 9));
    final open = chat('open', lastReadAt: readAt);
    final onDevice = withChatStorageProvenance(
      chat('on-device', lastReadAt: readAt),
      ChatStorageKind.directLocal,
    );

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        conversations: [read, unread, open, onDevice],
        activeConversation: open,
      ),
    );
    await tester.pumpAndSettle();

    expect(menuLabels(tester, read), contains(markAsUnread));
    expect(menuLabels(tester, unread), isNot(contains(markAsUnread)));
    expect(menuLabels(tester, open), isNot(contains(markAsUnread)));
    expect(menuLabels(tester, onDevice), isNot(contains(markAsUnread)));
  });

  testWidgets('a LibreChat chat offers neither it nor a server title', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final generateTitle = AppLocalizationsEn().generateTitle;
    final read = chat('read', lastReadAt: readAt);
    // Open WebUI is signed in, but this chat is not one it holds: either
    // action would send its id to Open WebUI.
    final libreChat = withChatStorageProvenance(
      chat('librechat', lastReadAt: readAt),
      ChatStorageKind.libreChat,
    );

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        conversations: [read, libreChat],
        // Its menu asks whether the app is online, which the rig's API
        // cannot answer.
        extraOverrides: [isOnlineProvider.overrideWithValue(true)],
      ),
    );
    await tester.pumpAndSettle();

    expect(menuLabels(tester, read), contains(markAsUnread));
    expect(menuLabels(tester, read), contains(generateTitle));
    expect(menuLabels(tester, libreChat), isNot(contains(markAsUnread)));
    expect(menuLabels(tester, libreChat), isNot(contains(generateTitle)));
  });
}
