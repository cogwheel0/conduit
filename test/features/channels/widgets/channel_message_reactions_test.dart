import 'package:conduit/features/channels/widgets/channel_message_reactions.dart';
import 'package:conduit_core/models/channel_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'reaction actions return the reaction name and keep the count visible',
    (tester) async {
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
              ],
              currentUserId: 'me',
              onReactionTap: tapped.add,
            ),
          ),
        ),
      );
      await tester.tap(find.text('like 2'));
      await tester.pump();
      expect(tapped, ['like']);
      expect(find.text('like 2'), findsOneWidget);
    },
  );
}
