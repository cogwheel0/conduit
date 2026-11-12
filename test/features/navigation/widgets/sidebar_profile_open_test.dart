import 'dart:async';

import 'package:conduit/features/navigation/widgets/sidebar_user_pill.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'sidebar_page_test_support.dart';

const _profileButton = ValueKey<String>('sidebar-profile-button');
const _settingsPage = ValueKey<String>('test-settings-page');

Future<void> _pumpSidebar(
  WidgetTester tester, {
  required bool sliding,
  SidebarNativeProfilePresenter? present,
}) async {
  await tester.pumpWidget(
    sidebarTestBuildHarness(
      controllers: SidebarTestSidebarHarnessControllers(),
      slidingSidebarEnabled: sliding,
      directPreferred: true,
      hasApiService: false,
      profilePresenter: present,
      profilePage: const Scaffold(
        key: _settingsPage,
        body: Text('Settings destination'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final sliding in [false, true]) {
    testWidgets(
      'rapid profile taps push one settings page (sliding: $sliding)',
      (tester) async {
        await _pumpSidebar(tester, sliding: sliding);
        for (var tap = 0; tap < 8; tap++) {
          await tester.tap(find.byKey(_profileButton));
        }
        await tester.pumpAndSettle();
        expect(find.byKey(_settingsPage, skipOffstage: false), findsOneWidget);
        NavigationService.router.pop();
        await tester.pumpAndSettle();
        expect(NavigationService.router.canPop(), isFalse);
        expect(find.byKey(_profileButton).hitTestable(), findsOneWidget);

        // Closing Settings must allow a deliberate new opening.
        await tester.tap(find.byKey(_profileButton));
        await tester.pumpAndSettle();
        expect(find.byKey(_settingsPage), findsOneWidget);
      },
    );

    testWidgets(
      'slow profile presentation falls back once (sliding: $sliding)',
      (tester) async {
        final pending = Completer<bool>();
        var presentations = 0;
        await _pumpSidebar(
          tester,
          sliding: sliding,
          present: (_) {
            presentations++;
            return pending.future;
          },
        );
        for (var tap = 0; tap < 8; tap++) {
          await tester.tap(find.byKey(_profileButton));
          // A loading update can rebuild the button between taps.
          tester
              .element(find.byType(SidebarProfileAppBarLeading))
              .markNeedsBuild();
          await tester.pumpAndSettle();
        }
        expect(presentations, 1);
        pending.complete(false);
        await tester.pumpAndSettle();
        expect(find.byKey(_settingsPage, skipOffstage: false), findsOneWidget);
        NavigationService.router.pop();
        await tester.pumpAndSettle();
        expect(NavigationService.router.canPop(), isFalse);
      },
    );
  }

  testWidgets('slow native Settings presentation only starts once', (
    tester,
  ) async {
    final pending = Completer<bool>();
    var presentations = 0;
    await _pumpSidebar(
      tester,
      sliding: true,
      present: (_) {
        presentations++;
        return pending.future;
      },
    );
    for (var tap = 0; tap < 8; tap++) {
      await tester.tap(find.byKey(_profileButton));
      await tester.pumpAndSettle();
    }
    expect(presentations, 1);
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(find.byKey(_settingsPage), findsNothing);
  });
}
