import 'package:conduit/features/navigation/widgets/chats_drawer.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'sidebar_page_test_support.dart';

List<MethodCall> _recordHaptics(WidgetTester tester) {
  final calls = <MethodCall>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'HapticFeedback.vibrate') calls.add(call);
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return calls;
}

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets(
      'opening, typing and clearing search stays silent on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          final calls = _recordHaptics(tester);
          await tester.pumpWidget(
            sidebarTestBuildHarness(
              controllers: SidebarTestSidebarHarnessControllers(),
            ),
          );
          await tester.pumpAndSettle();
          calls.clear();
          final search = find.byWidgetPredicate(
            (widget) =>
                widget is Icon &&
                (widget.icon == Icons.search ||
                    widget.icon == CupertinoIcons.search),
          );
          await tester.tap(search);
          await tester.pumpAndSettle();
          expect(calls, isEmpty);
          await tester.enterText(find.byType(EditableText), 'paper lantern');
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
          expect(calls, isEmpty);
          await tester.enterText(find.byType(EditableText), '');
          await tester.pumpAndSettle();
          expect(calls, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'reload action adds no pull haptic without a gesture on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          final calls = _recordHaptics(tester);
          final controllers = SidebarTestSidebarHarnessControllers();
          await tester.pumpWidget(
            sidebarTestBuildHarness(controllers: controllers),
          );
          await tester.pumpAndSettle();
          final context = tester.element(find.byType(ChatsDrawer));
          final label = MaterialLocalizations.of(context)
              .refreshIndicatorSemanticLabel;
          final button = tester.widget<ConduitButton>(
            find.descendant(
              of: find.byType(ChatsDrawer),
              matching: find.byWidgetPredicate(
                (widget) => widget is ConduitButton && widget.text == label,
              ),
            ),
          );
          calls.clear();
          final before = controllers.chatRefreshCalls;
          // Exercise the reload callback without the button's pre-existing tap-down feedback.
          button.onPressed!();
          await tester.pumpAndSettle();
          expect(controllers.chatRefreshCalls, before + 1);
          expect(calls, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'refresh emits one haptic after a committed pull on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          final calls = _recordHaptics(tester);
          final date = DateTime(2026, 1, 1);
          final controllers = SidebarTestSidebarHarnessControllers();
          await tester.pumpWidget(
            sidebarTestBuildHarness(
              controllers: controllers,
              conversations: [
                Conversation(
                  id: 'garden-plan',
                  title: 'Garden plan',
                  createdAt: date,
                  updatedAt: date,
                ),
              ],
            ),
          );
          await tester.pumpAndSettle();
          final scroll = find
              .descendant(
                of: find.byType(ChatsDrawer),
                matching: find.byType(Scrollable),
              )
              .first;
          calls.clear();
          final refreshesBefore = controllers.chatRefreshCalls;
          await tester.drag(scroll, const Offset(0, 20));
          await tester.pumpAndSettle();
          expect(calls, isEmpty);
          expect(controllers.chatRefreshCalls, refreshesBefore);
          await tester.drag(scroll, const Offset(0, 500));
          await tester.pumpAndSettle();
          expect(calls, hasLength(1));
          expect(calls.single.arguments, 'HapticFeedbackType.lightImpact');
          expect(controllers.chatRefreshCalls, refreshesBefore + 1);
          expect(tester.takeException(), isNull);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
}
