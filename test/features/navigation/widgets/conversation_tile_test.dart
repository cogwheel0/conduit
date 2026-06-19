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

  testWidgets('generating conversations show a spinner', (tester) async {
    await tester.pumpWidget(
      _harness(
        const ConversationTile(
          title: 'Generating chat',
          pinned: false,
          selected: false,
          unread: false,
          isLoading: false,
          isGenerating: true,
          onTap: null,
        ),
      ),
    );

    expect(
      find.byKey(
        const ValueKey<String>('conversation-generating-indicator'),
      ),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('tap-load spinner takes precedence over generating spinner', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const ConversationTile(
          title: 'Loading chat',
          pinned: false,
          selected: false,
          unread: false,
          isLoading: true,
          isGenerating: true,
          onTap: null,
        ),
      ),
    );

    // Only one spinner, and it is not keyed as the generating indicator.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey<String>('conversation-generating-indicator'),
      ),
      findsNothing,
    );
  });
}

Widget _harness(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    home: Scaffold(body: Center(child: child)),
  );
}
