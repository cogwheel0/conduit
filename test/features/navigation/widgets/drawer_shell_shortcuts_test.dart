import 'package:conduit/features/navigation/providers/sidebar_providers.dart';
import 'package:conduit/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit/features/navigation/widgets/drawer_shell_page.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sidebar_page_test_support.dart';

void main() {
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  testWidgets('Mac shell exposes the complete desktop shortcut set', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSAppOnMacOverride = true;

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: MacDesktopShortcuts(child: Focus(child: Text('Content'))),
        ),
      ),
    );

    final bindings = tester
        .widget<CallbackShortcuts>(find.byType(CallbackShortcuts))
        .bindings;
    expect(
      bindings.keys,
      containsAll(<ShortcutActivator>[
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true),
        const SingleActivator(LogicalKeyboardKey.digit1, meta: true),
        const SingleActivator(LogicalKeyboardKey.digit2, meta: true),
        const SingleActivator(LogicalKeyboardKey.digit3, meta: true),
        const SingleActivator(LogicalKeyboardKey.digit4, meta: true),
        const SingleActivator(LogicalKeyboardKey.digit5, meta: true),
        const SingleActivator(LogicalKeyboardKey.comma, meta: true),
        const SingleActivator(LogicalKeyboardKey.escape),
      ]),
    );
  });

  testWidgets('Command-K focuses search and Escape closes it', (tester) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSAppOnMacOverride = true;

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: MacDesktopShortcuts(
            child: Consumer(builder: _searchShortcutTestChild),
          ),
        ),
      ),
    );
    final context = tester.element(find.text('Content'));
    final container = ProviderScope.containerOf(context);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();

    expect(container.read(sidebarHeaderSearchExpandedProvider), true);
    expect(container.read(sidebarSearchFieldFocusNodeProvider).hasFocus, true);

    container.read(sidebarSearchFieldControllerProvider).text = 'query';
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(container.read(sidebarHeaderSearchExpandedProvider), false);
    expect(container.read(sidebarSearchFieldControllerProvider).text, isEmpty);
  });

  testWidgets('number shortcuts select from the visible sidebar order', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSAppOnMacOverride = true;
    final activeTab = SidebarTestTestSidebarActiveTab(SidebarTabId.chats);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sidebarNavigationSnapshotProvider.overrideWithValue(
            SidebarNavigationSnapshot(
              tabs: const [SidebarTabId.chats, SidebarTabId.notes],
              selectedTab: SidebarTabId.chats,
            ),
          ),
          sidebarActiveTabProvider.overrideWith(() => activeTab),
        ],
        child: const MaterialApp(
          home: MacDesktopShortcuts(
            child: Focus(autofocus: true, child: Text('Content')),
          ),
        ),
      ),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();

    expect(activeTab.currentValue, SidebarTabId.notes);
  });

  testWidgets('non-Mac iOS does not install desktop shortcuts', (tester) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSAppOnMacOverride = false;

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: MacDesktopShortcuts(child: Text('Content'))),
      ),
    );

    expect(find.byType(CallbackShortcuts), findsNothing);
  });
}

Widget _searchShortcutTestChild(
  BuildContext context,
  WidgetRef ref,
  Widget? child,
) => Column(
  children: [
    const Focus(autofocus: true, child: Text('Content')),
    Focus(
      focusNode: ref.watch(sidebarSearchFieldFocusNodeProvider),
      child: const SizedBox.shrink(),
    ),
  ],
);
