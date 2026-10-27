import 'package:conduit/features/navigation/widgets/drawer_shell_page.dart';
import 'package:conduit/features/navigation/widgets/responsive_drawer_layout.dart';
import 'package:conduit/shared/widgets/sidebar_layout_contract.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/user.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'sidebar_page_test_support.dart';

const _user = User(
  id: 'demo',
  username: 'demo',
  name: 'Demo Account',
  email: 'demo@example.test',
  role: 'user',
);

void main() {
  testWidgets(
    'phone menu leaves a curved, tappable slice of the chat visible',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      List<String> accessibleLabels() => tester.semantics
          .simulatedAccessibilityTraversal()
          .map((node) => node.getSemanticsData().label)
          .toList();
      try {
        await tester.pumpWidget(
          sidebarTestBuildHarness(
            controllers: SidebarTestSidebarHarnessControllers(),
            shellChat: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () =>
                        SidebarDrawerControllerScope.maybeOf(context)!.open(),
                    child: const Text('Open menu'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final layout = tester.widget<ResponsiveDrawerLayout>(
          find.descendant(
            of: find.byType(DrawerShellPage),
            matching: find.byType(ResponsiveDrawerLayout),
          ),
        );
        expect(layout.maxFraction, lessThan(1));
        expect(accessibleLabels(), contains('Open menu'));
        await tester.tap(find.text('Open menu'));
        await tester.pumpAndSettle();
        final curve = tester.widget<ClipRSuperellipse>(
          find.byType(ClipRSuperellipse).first,
        );
        expect(
          curve.borderRadius.resolve(TextDirection.ltr).topLeft.x,
          greaterThan(0),
        );
        expect(accessibleLabels(), isNot(contains('Open menu')));
        final chatX = tester.getTopLeft(find.text('Open menu')).dx;
        expect(chatX, greaterThan(300));
        await tester.tapAt(const Offset(380, 420));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(find.text('Open menu')).dx, lessThan(chatX));
        expect(accessibleLabels(), contains('Open menu'));
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('offscreen sidebar defers native header controls until opened', (
    tester,
  ) async {
    final child = sidebarTestBuildHarness(
      controllers: SidebarTestSidebarHarnessControllers(),
    );
    await tester.pumpWidget(
      DrawerChromeCompositionScope(composeNativeChrome: false, child: child),
    );
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey<String>('sidebar-search-button'));
    expect(search, findsNothing);
    await tester.pumpWidget(
      DrawerChromeCompositionScope(composeNativeChrome: true, child: child),
    );
    await tester.pumpAndSettle();
    expect(search, findsOneWidget);
  });

  testWidgets('settings stay at the bottom while chat history scrolls', (
    tester,
  ) async {
    final date = DateTime(2026, 1, 1);
    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        currentUser: _user,
        conversations: List.generate(
          40,
          (i) => Conversation(
            id: 'demo-$i',
            title: 'Example $i',
            createdAt: date,
            updatedAt: date,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final settings = find.byKey(
      const ValueKey<String>('sidebar-settings-button'),
    );
    expect(settings, findsOneWidget);
    final before = tester.getTopLeft(settings);
    await tester.drag(
      find.byKey(const PageStorageKey<String>('chats_drawer_scroll')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(settings), before);
    expect(
      tester
          .getBottomLeft(
            find.byKey(const ValueKey<String>('sidebar-destinations')),
          )
          .dy,
      lessThan(before.dy),
    );
  });

  for (final size in [const Size(320, 568), const Size(844, 390)]) {
    testWidgets('navigation stays usable at 2x text in $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controllers = SidebarTestSidebarHarnessControllers();
      await tester.pumpWidget(
        sidebarTestBuildHarness(
          controllers: controllers,
          currentUser: _user,
          textScale: 2,
          hermesEnabled: true,
        ),
      );
      await tester.pumpAndSettle();
      for (final label in ['Notes', 'Terminal', 'Channels', 'Chats']) {
        final destination = sidebarTestDestinationLabel(label);
        await tester.ensureVisible(destination);
        await tester.tap(destination);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      expect(
        find
            .byKey(const ValueKey<String>('sidebar-settings-button'))
            .hitTestable(),
        findsOneWidget,
      );
    });
  }
}
