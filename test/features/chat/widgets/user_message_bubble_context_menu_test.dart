import 'package:checks/checks.dart';
import 'package:conduit/features/chat/widgets/user_message_bubble.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  for (final scenario in [
    (name: 'long portrait', size: const Size(400, 800), lines: 80, scale: 1.0),
    (name: 'long landscape', size: const Size(800, 400), lines: 80, scale: 1.0),
    (
      name: 'compact large text',
      size: const Size(320, 568),
      lines: 80,
      scale: 1.6,
    ),
    (name: 'short portrait', size: const Size(400, 800), lines: 1, scale: 1.0),
  ]) {
    testWidgets('message actions stay reachable: ${scenario.name}', (
      tester,
    ) async {
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      await tester.binding.setSurfaceSize(scenario.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = ScrollController();
      addTearDown(controller.dispose);
      var copies = 0;
      final message = ChatMessage(
        id: 'long-message',
        role: 'user',
        content: List.generate(
          scenario.lines,
          (i) => 'Sample line ${i + 1}: blue paper boats.',
        ).join('\n'),
        timestamp: DateTime.utc(2026, 1, 1),
      );

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: const EdgeInsets.only(top: 44, bottom: 34),
                textScaler: TextScaler.linear(scenario.scale),
              ),
              child: child!,
            ),
            home: Scaffold(
              body: SafeArea(
                child: ListView(
                  controller: controller,
                  children: [
                    UserMessageBubble(
                      message: message,
                      isUser: true,
                      onCopy: () => copies++,
                      onDelete: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.jumpTo(controller.position.maxScrollExtent / 2);
      await tester.pumpAndSettle();
      final bubble = find.byKey(const Key('user-message-bubble-surface'));
      final rect = tester.getRect(bubble);
      if (scenario.lines > 1) {
        check(rect.top).isLessThan(0);
        check(rect.bottom).isGreaterThan(scenario.size.height);
      }
      final scrollOffset = controller.offset;

      final gesture = await tester.startGesture(rect.center);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();
      check(tester.takeException()).isNull();
      check(find.text('Copy').evaluate()).isNotEmpty();
      // Hit testing ignores paint spilling past the capped preview, so check
      // that the clip itself keeps the message off the actions.
      final previewClip = tester.getRect(
        find.ancestor(of: bubble.last, matching: find.byType(ClipRect)).first,
      );
      for (final label in ['Edit', 'Copy', 'Delete']) {
        check(find.text(label).hitTestable().evaluate()).isNotEmpty();
        final actionRect = tester.getRect(find.text(label));
        check(actionRect.top).isGreaterOrEqual(44);
        check(actionRect.bottom).isLessOrEqual(scenario.size.height - 34);
        check(previewClip.overlaps(actionRect)).isFalse();
      }
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      check(copies).equals(1);
      check(find.text('Copy').evaluate()).isEmpty();
      check(controller.offset).equals(scrollOffset);
      check(tester.getRect(bubble)).equals(rect);
    });
  }
}
