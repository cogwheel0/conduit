import 'package:conduit/features/navigation/widgets/conversation_tile.dart';
import 'package:conduit/features/navigation/widgets/sidebar_section_header.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import 'sidebar_page_test_support.dart';

Conversation _chat(String id, DateTime updatedAt, {bool pinned = false}) =>
    Conversation(
      id: id,
      title: id,
      createdAt: updatedAt,
      updatedAt: updatedAt,
      lastReadAt: updatedAt,
      pinned: pinned,
      messages: const [],
    );

void main() {
  final l10n = AppLocalizationsEn();

  testWidgets('groups chats under date headers and leaves out empty ones', (
    tester,
  ) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // Over 30 days back, so it gets a month header of its own.
    final old = today.subtract(const Duration(days: 45));

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        conversations: [
          // The start of today is Today whatever the time, even in the
          // first minutes after midnight.
          _chat('Fresh chat', today),
          _chat('Last night chat', today.subtract(const Duration(hours: 2))),
          _chat('Last week chat', today.subtract(const Duration(days: 4))),
          _chat('Old chat', old),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final monthLabel = old.year == now.year
        ? DateFormat('LLLL', 'en').format(old)
        : DateFormat.yMMMM('en').format(old);
    final expectedOrder = [
      l10n.today,
      'Fresh chat',
      l10n.yesterday,
      'Last night chat',
      l10n.previous7Days,
      'Last week chat',
      monthLabel,
      'Old chat',
    ];
    final headers = {
      l10n.today,
      l10n.yesterday,
      l10n.previous7Days,
      monthLabel,
    };
    // A header's label can also be a row's date ("Yesterday"), so headers
    // are looked up inside the headers.
    Finder labelled(String text) => headers.contains(text)
        ? find.descendant(
            of: find.byType(SidebarSectionHeader),
            matching: find.text(text),
          )
        : find.text(text);
    final tops = [
      for (final text in expectedOrder) tester.getTopLeft(labelled(text)).dy,
    ];
    for (var i = 1; i < tops.length; i++) {
      expect(
        tops[i],
        greaterThan(tops[i - 1]),
        reason: '${expectedOrder[i]} below ${expectedOrder[i - 1]}',
      );
    }
    // No chat falls 8-30 days back, so that section is left out.
    expect(find.text(l10n.previous30Days), findsNothing);
    expect(find.text(l10n.recent), findsNothing);

    // Each row ends with when its chat last changed, as Mail dates mail.
    String stampOf(String title) {
      final row = find.ancestor(
        of: find.text(title),
        matching: find.byType(ConversationTile),
      );
      return tester
          .widget<Text>(
            find.descendant(
              of: find.descendant(
                of: row,
                matching: find.byKey(
                  const ValueKey<String>('conversation-updated-stamp'),
                ),
              ),
              matching: find.byType(Text),
            ),
          )
          .data!;
    }

    expect(stampOf('Fresh chat'), DateFormat.jm('en').format(today));
    expect(stampOf('Last night chat'), l10n.yesterday);
    expect(
      stampOf('Last week chat'),
      DateFormat('cccc', 'en').format(today.subtract(const Duration(days: 4))),
    );
    expect(stampOf('Old chat'), DateFormat('M/d/yy', 'en').format(old));
  });

  testWidgets('section headers start on the toolbar\'s leading edge and '
      'chat titles after their unread column', (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        slidingSidebarEnabled: false,
        conversations: [
          _chat('Pinned chat', now, pinned: true),
          _chat('Dated chat', today),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final largeTitle = find.descendant(
      of: find.byKey(const ValueKey<String>('chats-large-title')),
      matching: find.text(l10n.sidebarChatsTab),
    );
    expect(tester.getTopLeft(largeTitle).dx, kSidebarRowContentInset);
    for (final text in [l10n.pinned, l10n.today]) {
      expect(
        tester.getTopLeft(find.text(text)).dx,
        kSidebarRowContentInset,
        reason: text,
      );
    }
    for (final text in ['Pinned chat', 'Dated chat']) {
      expect(
        tester.getTopLeft(find.text(text)).dx,
        kSidebarRowTitleInset,
        reason: text,
      );
    }
  });

  testWidgets('pinned rows drop the pin glyph and the header collapses them', (
    tester,
  ) async {
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        conversations: [_chat('Pinned chat', DateTime.now(), pinned: true)],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Pinned chat'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('conversation-pinned-indicator')),
      findsNothing,
    );

    await tester.tap(find.text(l10n.pinned));
    await tester.pumpAndSettle();
    expect(find.text('Pinned chat'), findsNothing);
    expect(find.text(l10n.pinned), findsOneWidget);
  });

  testWidgets('an empty Folders group is hidden', (tester) async {
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        conversations: [_chat('Loose chat', DateTime.now())],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Loose chat'), findsOneWidget);
    expect(find.text(l10n.folders), findsNothing);
    expect(find.byTooltip(l10n.newFolder), findsNothing);
  });

  testWidgets('a Folders group with folders offers New Folder', (tester) async {
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        conversations: [_chat('Loose chat', DateTime.now())],
        folders: const [Folder(id: 'trips', name: 'Trips')],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(l10n.folders), findsOneWidget);
    expect(find.byTooltip(l10n.newFolder), findsOneWidget);
    expect(find.text('Trips'), findsOneWidget);
  });

  testWidgets('the tabbed sidebar opens on a large Chats title', (
    tester,
  ) async {
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        slidingSidebarEnabled: false,
        conversations: [_chat('Titled chat', DateTime.now())],
      ),
    );
    await tester.pumpAndSettle();

    final title = find.byKey(const ValueKey<String>('chats-large-title'));
    expect(title, findsOneWidget);
    expect(
      find.descendant(of: title, matching: find.text(l10n.sidebarChatsTab)),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.text(l10n.today)).dy,
      greaterThan(tester.getBottomLeft(title).dy),
    );
    expect(find.byType(SidebarLargeTitle), findsOneWidget);
  });
}
