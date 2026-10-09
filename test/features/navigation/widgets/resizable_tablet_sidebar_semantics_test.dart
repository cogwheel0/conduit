import 'package:checks/checks.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../shared/widgets/responsive_drawer_layout_test_support.dart';

void main() {
  testWidgets('docked tablet drawer stays accessible beside a navigator', (
    tester,
  ) async {
    final semanticsHandle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        drawerTestBuildHarness(
          size: drawerTestTabletSize,
          drawer: Semantics(
            button: true,
            label: 'Sidebar row',
            child: const SizedBox.expand(),
          ),
          // The app's detail pane is go_router's shell navigator.
          child: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => const Text('Detail page'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      check(find.bySemanticsLabel('Detail page').evaluate()).length.equals(1);
      check(find.bySemanticsLabel('Sidebar row').evaluate()).length.equals(1);
    } finally {
      semanticsHandle.dispose();
    }
  });
}
