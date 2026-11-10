import 'package:conduit/features/navigation/widgets/conversation_tile.dart';
import 'package:conduit/features/navigation/widgets/sidebar_section_header.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:flutter_test/flutter_test.dart';
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

  testWidgets('lists the other chats under one Recent header, in order and '
      'without dates, and the header collapses them', (tester) async {
    final now = DateTime.now();
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        slidingSidebarEnabled: false,
        conversations: [
          _chat('Fresh chat', now),
          _chat('Last week chat', now.subtract(const Duration(days: 4))),
          _chat('Old chat', now.subtract(const Duration(days: 45))),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final expectedOrder = [
      l10n.recent,
      'Fresh chat',
      'Last week chat',
      'Old chat',
    ];
    final tops = [
      for (final text in expectedOrder) tester.getTopLeft(find.text(text)).dy,
    ];
    for (var i = 1; i < tops.length; i++) {
      expect(
        tops[i],
        greaterThan(tops[i - 1]),
        reason: '${expectedOrder[i]} below ${expectedOrder[i - 1]}',
      );
    }
    for (final dateHeader in [
      l10n.today,
      l10n.yesterday,
      l10n.previous7Days,
      l10n.previous30Days,
    ]) {
      expect(find.text(dateHeader), findsNothing, reason: dateHeader);
    }
    expect(
      find.byKey(const ValueKey<String>('conversation-updated-stamp')),
      findsNothing,
    );

    await tester.tap(find.text(l10n.recent));
    await tester.pumpAndSettle();
    expect(find.text('Fresh chat'), findsNothing);
    expect(find.text(l10n.recent), findsOneWidget);
  });

  testWidgets('section titles share one edge after the chevron column, and '
      'chat titles start on the row content edge', (tester) async {
    final now = DateTime.now();
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        slidingSidebarEnabled: false,
        conversations: [
          _chat('Pinned chat', now, pinned: true),
          _chat('Recent chat', now),
        ],
      ),
    );
    await tester.pumpAndSettle();

    for (final text in [l10n.pinned, l10n.recent]) {
      expect(
        tester.getTopLeft(find.text(text)).dx,
        kSidebarSectionHeaderInset + IconSize.listItem + Spacing.xxs,
        reason: text,
      );
    }
    for (final text in ['Pinned chat', 'Recent chat']) {
      expect(
        tester.getTopLeft(find.text(text)).dx,
        kSidebarRowContentInset,
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

  testWidgets('with no folders the Folders header still offers New Folder', (
    tester,
  ) async {
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        conversations: [_chat('Loose chat', DateTime.now())],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Loose chat'), findsOneWidget);
    expect(find.text(l10n.folders), findsOneWidget);
    expect(find.byTooltip(l10n.newFolder), findsOneWidget);
    // Nothing to collapse yet, so no chevron, but the title keeps its
    // column and starts where the other section titles do.
    expect(
      find.byKey(const ValueKey<String>('folders-section-leading')),
      findsNothing,
    );
    expect(
      tester.getTopLeft(find.text(l10n.folders)).dx,
      tester.getTopLeft(find.text(l10n.recent)).dx,
    );
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
    expect(
      find.byKey(const ValueKey<String>('folders-section-leading')),
      findsOneWidget,
    );
  });

  testWidgets('the tabbed sidebar has no Chats title over its list', (
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

    expect(find.text('Titled chat'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('chats-large-title')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('sidebar-collapsed-title')),
      findsNothing,
    );
  });
}
