import 'package:conduit/features/navigation/widgets/conversation_tile.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:material_ui/material_ui.dart';
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

  testWidgets(
    'unselected conversations paint a neutral surface while pressed',
    (tester) async {
      await tester.pumpWidget(
        _harness(
          ConversationTile(
            title: 'Press me',
            pinned: false,
            selected: false,
            isLoading: false,
            onTap: () {},
          ),
        ),
      );

      const pressedKey = ValueKey<String>('conversation-tile-pressed-tint');
      expect(find.byKey(pressedKey), findsNothing);

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Press me')),
      );
      await tester.pump();

      final pressedSurface = tester.widget<DecoratedBox>(
        find.byKey(pressedKey),
      );
      final decoration = pressedSurface.decoration as BoxDecoration;
      expect(
        decoration.color,
        tester.element(find.text('Press me')).conduitTheme.surfaceContainer,
      );

      await gesture.up();
      await tester.pump();
      expect(find.byKey(pressedKey), findsNothing);
    },
  );

  testWidgets('selected tint takes precedence over pressed feedback', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        ConversationTile(
          title: 'Selected chat',
          pinned: false,
          selected: true,
          isLoading: false,
          onTap: () {},
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Selected chat')),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('conversation-tile-active-tint')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('conversation-tile-pressed-tint')),
      findsNothing,
    );

    await gesture.cancel();
  });

  testWidgets('chat-style sidebar rows stay flat until pressed', (
    tester,
  ) async {
    const pressedKey = ValueKey<String>('shared-row-pressed');
    await tester.pumpWidget(
      _harness(
        ChatStyleSidebarTile(
          selected: false,
          onTap: () {},
          pressedKey: pressedKey,
          child: const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Flat row'),
          ),
        ),
      ),
    );

    expect(find.byType(DecoratedBox), findsNothing);
    final outer = tester.widget<Container>(
      find
          .ancestor(of: find.text('Flat row'), matching: find.byType(Container))
          .first,
    );
    expect(outer.margin, kConversationTileMargin);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Flat row')),
    );
    await tester.pump();
    expect(find.byKey(pressedKey), findsOneWidget);

    await gesture.cancel();
    await tester.pump();
    expect(find.byKey(pressedKey), findsNothing);
  });

  testWidgets('selected sidebar rows keep the 4.0.3 Hermes edge gutter', (
    tester,
  ) async {
    const hostKey = ValueKey<String>('sidebar-row-host');
    const tintKey = ValueKey<String>('sidebar-row-tint');
    await tester.pumpWidget(
      _harness(
        SizedBox(
          key: hostKey,
          width: 320,
          child: ChatStyleSidebarTile(
            selected: true,
            onTap: () {},
            tintKey: tintKey,
            child: const SizedBox(height: TouchTarget.listItem),
          ),
        ),
      ),
    );

    final hostRect = tester.getRect(find.byKey(hostKey));
    final tintRect = tester.getRect(find.byKey(tintKey));
    expect(tintRect.left - hostRect.left, Spacing.sm);
    expect(hostRect.right - tintRect.right, Spacing.sm);
  });

  testWidgets('inactive sidebar rows keep the 4.0.3 Hermes edge gutter', (
    tester,
  ) async {
    const hostKey = ValueKey<String>('inactive-sidebar-row-host');
    const contentKey = ValueKey<String>('inactive-sidebar-row-content');
    await tester.pumpWidget(
      _harness(
        SizedBox(
          key: hostKey,
          width: 320,
          child: ChatStyleSidebarTile(
            selected: false,
            onTap: () {},
            child: const SizedBox(
              key: contentKey,
              height: TouchTarget.listItem,
              width: double.infinity,
            ),
          ),
        ),
      ),
    );

    final hostRect = tester.getRect(find.byKey(hostKey));
    final contentRect = tester.getRect(find.byKey(contentKey));
    expect(contentRect.left - hostRect.left, Spacing.sm);
    expect(hostRect.right - contentRect.right, Spacing.sm);
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
      find.byKey(const ValueKey<String>('conversation-generating-indicator')),
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
      find.byKey(const ValueKey<String>('conversation-generating-indicator')),
      findsNothing,
    );
  });

  testWidgets('long provenance badges stay compact and truncate', (
    tester,
  ) async {
    const badge = 'A very long direct connection profile name';

    await tester.pumpWidget(
      _harness(
        const ConversationTile(
          title: 'Direct chat',
          pinned: false,
          selected: false,
          isLoading: false,
          badge: badge,
          onTap: null,
        ),
      ),
    );

    final badgeText = tester.widget<Text>(find.text(badge));
    expect(badgeText.maxLines, 1);
    expect(badgeText.overflow, TextOverflow.ellipsis);
    expect(tester.getSize(find.text(badge)).width, lessThanOrEqualTo(104));
    expect(tester.takeException(), isNull);
  });
}

Widget _harness(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    home: Scaffold(body: Center(child: child)),
  );
}
