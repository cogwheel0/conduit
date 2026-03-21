import 'package:conduit/shared/widgets/responsive_drawer_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('horizontal drag closes an open mobile drawer', (tester) async {
    final layoutKey = GlobalKey<ResponsiveDrawerLayoutState>();
    const drawerPanelKey = ValueKey<String>('drawer-panel');

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: ResponsiveDrawerLayout(
            key: layoutKey,
            drawer: const ColoredBox(key: drawerPanelKey, color: Colors.blue),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    final drawerPanel = find.byKey(drawerPanelKey);
    final closedLeft = tester.getTopLeft(drawerPanel).dx;

    layoutKey.currentState!.open();
    await tester.pumpAndSettle();

    expect(layoutKey.currentState!.isOpen, isTrue);
    expect(tester.getTopLeft(drawerPanel).dx, moreOrLessEquals(0));

    await tester.drag(drawerPanel, const Offset(-320, 0));
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(drawerPanel).dx, moreOrLessEquals(closedLeft));
  });
}
