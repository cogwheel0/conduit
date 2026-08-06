import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
import 'package:checks/checks.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
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

  testWidgets('iOS popup keeps descendant double taps in Flutter', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      var doubleTapCount = 0;

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
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: () => doubleTapCount++,
              child: const SizedBox(
                width: 160,
                height: 60,
                child: Text('Child'),
              ),
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('conduit-context-menu-popup-gesture')),
        findsOneWidget,
      );

      await tester.tap(find.text('Child'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Child'));
      await tester.pump();

      expect(doubleTapCount, 1);
      await tester.pump(const Duration(milliseconds: 400));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('iOS popup can show again after dismissal', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await tester.pumpWidget(
        _buildHarness(
          ConduitContextMenu(
            actions: [
              ConduitContextMenuAction(
                cupertinoIcon: CupertinoIcons.doc_on_clipboard,
                materialIcon: Icons.copy,
                label: 'Copy action',
                onSelected: () async {},
              ),
            ],
            child: const SizedBox(width: 160, height: 60, child: Text('Child')),
          ),
        ),
      );

      await tester.longPress(find.text('Child'));
      await tester.pump();
      expect(find.text('Copy action'), findsOneWidget);

      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      expect(find.text('Copy action'), findsNothing);

      await tester.longPress(find.text('Child'));
      await tester.pump();
      expect(find.text('Copy action'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('iOS popup closes when its actions change', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      ConduitContextMenu buildMenu(String label) {
        return ConduitContextMenu(
          actions: [
            ConduitContextMenuAction(
              cupertinoIcon: CupertinoIcons.doc_on_clipboard,
              materialIcon: Icons.copy,
              label: label,
              onSelected: () async {},
            ),
          ],
          child: const SizedBox(width: 160, height: 60, child: Text('Child')),
        );
      }

      await tester.pumpWidget(_buildHarness(buildMenu('Old action')));
      await tester.longPress(find.text('Child'));
      await tester.pump();
      expect(find.text('Old action'), findsOneWidget);

      await tester.pumpWidget(_buildHarness(buildMenu('New action')));
      await tester.pump();

      expect(find.text('Old action'), findsNothing);
      expect(find.text('New action'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('defaults to popup presentation and accepts preview opt-in', (
    tester,
  ) async {
    final actions = [
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.doc_on_clipboard,
        materialIcon: Icons.copy,
        label: 'Copy',
        onSelected: () async {},
      ),
    ];

    await tester.pumpWidget(
      _buildHarness(
        ConduitContextMenu(actions: actions, child: const Text('Popup')),
      ),
    );

    check(
      tester
          .widget<ConduitContextMenu>(find.byType(ConduitContextMenu))
          .presentation,
    ).equals(ConduitContextMenuPresentation.popup);

    await tester.pumpWidget(
      _buildHarness(
        ConduitContextMenu(
          actions: actions,
          presentation: ConduitContextMenuPresentation.preview,
          child: const Text('Preview'),
        ),
      ),
    );

    check(
      tester
          .widget<ConduitContextMenu>(find.byType(ConduitContextMenu))
          .presentation,
    ).equals(ConduitContextMenuPresentation.preview);
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
          presentation: ConduitContextMenuPresentation.preview,
          child: const Text('Child'),
        ),
      ),
    );

    expect(find.text('Child'), findsOneWidget);
    expect(find.text('Top widget'), findsNothing);
    expect(buildCount, 0);
  });
}
