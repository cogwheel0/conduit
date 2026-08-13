import 'package:checks/checks.dart';
import 'package:conduit/shared/widgets/sidebar_layout_contract.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('close command only runs for an overlay sidebar', (tester) async {
    final controller = _FakeSidebarDrawerController();

    Future<void> pumpAt(Size size) => tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: size),
          child: SidebarDrawerControllerScope(
            controller: controller,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => closeSidebarDrawerIfOverlay(context),
                child: const Text('close'),
              ),
            ),
          ),
        ),
      ),
    );

    await pumpAt(const Size(390, 844));
    await tester.tap(find.text('close'));
    check(controller.closeCalls).equals(1);

    await pumpAt(const Size(1024, 768));
    await tester.tap(find.text('close'));
    check(controller.closeCalls).equals(1);
  });
}

final class _FakeSidebarDrawerController implements SidebarDrawerController {
  var closeCalls = 0;

  @override
  bool get isOpen => true;

  @override
  void close({double velocity = 0.0}) => closeCalls++;

  @override
  void open({double velocity = 0.0}) {}

  @override
  void toggle() {}
}
