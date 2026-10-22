import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conduit/features/hermes/widgets/hermes_keyboard_footer.dart';

void main() {
  for (final contentHeight in [53.0, 106.0]) {
    for (final safeBottom in [0.0, 24.0, 48.0]) {
      testWidgets(
        'footer follows measured height $contentHeight, safe area $safeBottom and reversal',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          Future<void> show(double inset) => tester.pumpWidget(
            Directionality(
              textDirection: TextDirection.ltr,
              child: MediaQuery(
                data: MediaQueryData(
                  size: const Size(390, 844),
                  viewPadding: EdgeInsets.only(bottom: safeBottom),
                  padding: EdgeInsets.only(bottom: inset == 0 ? safeBottom : 0),
                  viewInsets: EdgeInsets.only(bottom: inset),
                ),
                child: Column(
                  children: [
                    const Expanded(child: SizedBox()),
                    HermesKeyboardFooter(
                      key: const ValueKey('footer'),
                      inset: inset,
                      followSystemGeometry: true,
                      child: SafeArea(
                        top: false,
                        maintainBottomViewPadding: true,
                        minimum: const EdgeInsets.only(bottom: 8),
                        child: SizedBox(height: contentHeight),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          final height = contentHeight + (safeBottom < 8 ? 8 : safeBottom);
          for (final inset in [
            0.0,
            1.0,
            20.0,
            height - 1,
            height,
            300.0,
            height / 2,
            1.0,
            0.0,
          ]) {
            await show(inset);
            final box = tester.renderObject(
              find.byKey(const ValueKey('footer')),
            );
            expect(
              (box as dynamic).size.height,
              closeTo((height - inset).clamp(0, height), .001),
            );
            expect(tester.takeException(), isNull);
          }
        },
      );
    }
  }
  testWidgets('non-Android occupancy retains the prior immediate hide policy', (
    tester,
  ) async {
    Future<void> show(double inset) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            const Expanded(child: SizedBox()),
            HermesKeyboardFooter(
              key: const ValueKey('footer'),
              inset: inset,
              followSystemGeometry: false,
              child: const SizedBox(height: 80),
            ),
          ],
        ),
      ),
    );
    for (final inset in [0.0, 1.0, 400.0, 0.0]) {
      await show(inset);
      expect(
        tester.getSize(find.byKey(const ValueKey('footer'))).height,
        inset == 0 ? 80 : 0,
      );
    }
  });
}
