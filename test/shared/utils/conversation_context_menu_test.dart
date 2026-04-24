import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
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
    expect(find.byType(ContextMenuWidget), findsNothing);
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
    expect(find.byType(ContextMenuWidget), findsOneWidget);
  });
}
