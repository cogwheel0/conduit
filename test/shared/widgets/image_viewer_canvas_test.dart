import 'package:checks/checks.dart';
import 'package:conduit/shared/widgets/image_viewer/image_viewer_canvas.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('double tap zoom protects panning from dismiss and paging', (
    tester,
  ) async {
    var dismissed = 0;
    var pages = 0;
    var zoom = 1.0;
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.expand(
          child: ImageViewerCanvas(
            onTap: () {},
            onDismiss: () => dismissed++,
            onPage: (_) => pages++,
            onZoomSettled: (value) => zoom = value,
            zoomLabel: 'Zoom',
            resetLabel: 'Reset',
            child: const ColoredBox(color: Colors.blue),
          ),
        ),
      ),
    );
    final canvas = find.byType(ImageViewerCanvas);
    await tester.tap(canvas);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(canvas);
    await tester.pumpAndSettle();
    check(zoom).isGreaterThan(1);
    await tester.drag(canvas, const Offset(0, 220));
    await tester.pumpAndSettle();
    check(dismissed).equals(0);
    check(pages).equals(0);
    await tester.tap(canvas);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(canvas);
    await tester.pumpAndSettle();
    check(zoom).equals(1);
    final fittedPosition = tester.getTopLeft(find.byType(ColoredBox).last);
    await tester.drag(canvas, const Offset(0, 220));
    await tester.pumpAndSettle();
    check(dismissed).equals(1);
    expect(
      (tester.getTopLeft(find.byType(ColoredBox).last) - fittedPosition)
          .distance,
      lessThan(.1),
    );
    await tester.tap(canvas);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(canvas);
    await tester.pumpAndSettle();
    check(zoom).isGreaterThan(1);
    await tester.binding.setSurfaceSize(const Size(400, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpAndSettle();
    check(zoom).equals(1);
  });
}
