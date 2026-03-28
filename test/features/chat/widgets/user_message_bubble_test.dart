import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/chat/widgets/user_message_bubble.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  Widget buildHarness(ChatMessage message) {
    return ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: UserMessageBubble(message: message, isUser: true),
          ),
        ),
      ),
    );
  }

  testWidgets('renders attached note cards from message files', (
    WidgetTester tester,
  ) async {
    final message = ChatMessage(
      id: 'user-1',
      role: 'user',
      content: '',
      timestamp: DateTime.utc(2026, 3, 28, 10),
      files: const [
        <String, dynamic>{
          'type': 'note',
          'id': 'note-1',
          'name': 'Sprint Plan',
        },
      ],
    );

    await tester.pumpWidget(buildHarness(message));
    await tester.pump();

    expect(find.text('Sprint Plan'), findsOneWidget);
    expect(find.byIcon(Icons.sticky_note_2_outlined), findsOneWidget);
  });
}
