import 'package:conduit/features/navigation/utils/chat_list_back.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'sidebar_page_test_support.dart';

void main() {
  testWidgets('the app shell lets Android hand back to the chat (#852)', (
    tester,
  ) async {
    debugChatBackIsAndroidOverride = true;
    addTearDown(() => debugChatBackIsAndroidOverride = null);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final reports = <bool>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
        reports.add(call.arguments as bool);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      sidebarTestBuildHarness(
        controllers: SidebarTestSidebarHarnessControllers(),
        shellChat: const PopScope(canPop: false, child: Text('Chat')),
      ),
    );
    await tester.pumpAndSettle();

    // A page over the shell coming and going makes the root navigator report
    // again, from the shell route.
    final dialog = showDialog<void>(
      context: tester.element(find.text('Chat')),
      builder: (context) => const Text('Over the shell'),
    );
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('Over the shell'))).pop();
    await dialog;
    await tester.pumpAndSettle();

    expect(reports, isNotEmpty);
    expect(reports.last, isTrue);
  });
}
