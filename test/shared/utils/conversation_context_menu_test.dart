import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
import 'package:conduit/features/navigation/widgets/conversation_tile.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildHarness(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  testWidgets('bypasses the platform wrapper when there are no actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildHarness(
        const ConduitContextMenu(
          actions: <ConduitContextMenuAction>[],
          child: Text('Child'),
        ),
      ),
    );

    expect(find.text('Child'), findsOneWidget);
    expect(find.byType(GestureDetector), findsNothing);
  });

  testWidgets('wraps the child when actions are available', (tester) async {
    await tester.pumpWidget(
      _buildHarness(
        ConduitContextMenu(
          actions: [
            ConduitContextMenuAction(
              cupertinoIcon: CupertinoIcons.doc_on_clipboard,
              materialIcon: Icons.copy,
              label: 'Copy',
              onSelected: () async {},
            ),
          ],
          child: const Text('Child'),
        ),
      ),
    );

    expect(find.text('Child'), findsOneWidget);
    expect(find.byType(GestureDetector), findsOneWidget);
  });

  testWidgets('does not build lazy top widget before the menu opens', (
    tester,
  ) async {
    var buildCount = 0;

    await tester.pumpWidget(
      _buildHarness(
        ConduitContextMenu(
          actions: [
            ConduitContextMenuAction(
              cupertinoIcon: CupertinoIcons.doc_on_clipboard,
              materialIcon: Icons.copy,
              label: 'Copy',
              onSelected: () async {},
            ),
          ],
          topWidgetBuilder: (_) {
            buildCount++;
            return const Text('Top widget');
          },
          child: const Text('Child'),
        ),
      ),
    );

    expect(find.text('Child'), findsOneWidget);
    expect(find.text('Top widget'), findsNothing);
    expect(buildCount, 0);
  });

  testWidgets('builds the chat preview surface only after a long press', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;

    await tester.pumpWidget(
      _buildHarness(
        ConduitContextMenu(
          actions: [
            ConduitContextMenuAction(
              cupertinoIcon: CupertinoIcons.doc_on_clipboard,
              materialIcon: Icons.copy,
              label: 'Copy',
              onSelected: () async {},
            ),
          ],
          previewBuilder: buildConversationTileContextPreview,
          child: ConversationTile(
            title: 'Preview chat',
            pinned: false,
            selected: false,
            isLoading: false,
            onTap: () {},
          ),
        ),
      ),
    );

    const previewKey = ValueKey<String>(
      'conversation-tile-context-preview-background',
    );
    expect(find.byKey(previewKey), findsNothing);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Preview chat')),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(previewKey), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();
  });
}
