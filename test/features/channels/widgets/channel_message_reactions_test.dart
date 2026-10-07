import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/features/channels/widgets/channel_message_reactions.dart';
import 'package:conduit_core/models/channel_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'reaction actions preserve highlights, accessible names and callback values',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final tapped = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ChannelMessageReactions(
                reactions: const [
                  MessageReaction(
                    name: 'like',
                    count: 2,
                    users: [
                      {'user_id': 'me'},
                    ],
                  ),
                  MessageReaction(
                    name: 'other',
                    count: 1,
                    users: [
                      {'user_id': 'someone-else'},
                    ],
                  ),
                ],
                currentUserId: 'me',
                onReactionTap: tapped.add,
              ),
            ),
          ),
        );
        final context = tester.element(find.byType(ChannelMessageReactions));
        final primary = Theme.of(context).colorScheme.primary;
        final theme = context.conduitTheme;
        final active = tester.widget<ActionChip>(
          find.widgetWithText(ActionChip, 'like 2'),
        );
        final inactive = tester.widget<ActionChip>(
          find.widgetWithText(ActionChip, 'other 1'),
        );
        expect(active.backgroundColor, primary.withValues(alpha: 0.15));
        expect(active.side?.color, primary.withValues(alpha: 0.4));
        expect(inactive.backgroundColor, theme.surfaceContainer);
        expect(inactive.side?.color, theme.dividerColor);
        expect(
          tester.getSemantics(find.bySemanticsLabel('like 2')),
          isSemantics(
            label: 'like 2',
            isButton: true,
            isEnabled: true,
            hasTapAction: true,
          ),
        );
        expect(
          tester.getSemantics(find.bySemanticsLabel('other 1')),
          isSemantics(
            label: 'other 1',
            isButton: true,
            isEnabled: true,
            hasTapAction: true,
          ),
        );
        await tester.tap(find.text('like 2'));
        await tester.pump();
        expect(tapped, ['like']);
        expect(find.text('like 2'), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    },
  );
}
