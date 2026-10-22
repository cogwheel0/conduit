import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'outside drag dismisses actions and scrolls in the same gesture',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              controller: scroll,
              children: [
                ScrollAwayContextMenu(
                  actions: [
                    AdaptiveContextMenuAction(
                      title: 'Reply',
                      onPressed: () {},
                      icon: Icons.reply,
                    ),
                  ],
                  child: const SizedBox(
                    height: 250,
                    child: Center(child: Text('Hold this message')),
                  ),
                ),
                const SizedBox(height: 1500),
              ],
            ),
          ),
        ),
      );
      await tester.longPress(find.text('Hold this message'));
      await tester.pumpAndSettle();
      expect(find.text('Reply'), findsOneWidget);
      await tester.dragFrom(const Offset(30, 450), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(find.text('Reply'), findsNothing);
      expect(scroll.offset, greaterThan(100));
      expect(tester.takeException(), isNull);
    },
  );
}
