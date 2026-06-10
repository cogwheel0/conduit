import 'package:conduit/features/navigation/widgets/conversation_tile.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('unread conversations show an indicator and stronger title', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const ConversationTile(
          title: 'Unread chat',
          pinned: false,
          selected: false,
          unread: true,
          isLoading: false,
          onTap: null,
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('conversation-unread-indicator')),
      findsOneWidget,
    );
    final title = tester.widget<Text>(find.text('Unread chat'));
    expect(title.style?.fontWeight, FontWeight.w600);
  });

  testWidgets('read or selected conversations do not show unread indicator', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const ConversationTile(
          title: 'Read chat',
          pinned: false,
          selected: true,
          unread: false,
          isLoading: false,
          onTap: null,
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('conversation-unread-indicator')),
      findsNothing,
    );
    final title = tester.widget<Text>(find.text('Read chat'));
    expect(title.style?.fontWeight, FontWeight.w600);
  });
}

Widget _harness(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    home: Scaffold(body: Center(child: child)),
  );
}
