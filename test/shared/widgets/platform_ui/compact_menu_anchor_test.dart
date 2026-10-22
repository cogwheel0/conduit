import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final direction in TextDirection.values) {
    testWidgets(
      'menu follows its trigger through keyboard dismissal $direction',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        String? selected;
        const trigger = Key('plus');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              resizeToAvoidBottomInset: false,
              body: Builder(
                builder: (context) => Directionality(
                  textDirection: direction,
                  child: Stack(
                    children: [
                      Positioned(
                        left: 16,
                        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
                        child: Builder(
                          builder: (anchor) => SizedBox(
                            key: trigger,
                            width: 48,
                            height: 48,
                            child: TextButton(
                              onPressed: () async {
                                selected = await showCompactMenuAbove(
                                  context,
                                  anchor,
                                  const [
                                    CompactMenuChoice('camera', 'Camera'),
                                    CompactMenuChoice('photos', 'Photos'),
                                    CompactMenuChoice('files', 'Files'),
                                    CompactMenuChoice('call', 'Voice Call'),
                                  ],
                                );
                              },
                              child: const Text('+'),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(trigger));
        await tester.pumpAndSettle();
        final surface = find
            .ancestor(
              of: find.byType(PopupMenuItem<String>).first,
              matching: find.byType(Material),
            )
            .first;
        final initialGap =
            tester.getRect(find.byKey(trigger)).top -
            tester.getRect(surface).bottom;
        for (final inset in [240.0, 180.0, 60.0, 0.0]) {
          tester.view.viewInsets = FakeViewPadding(bottom: inset);
          await tester.pumpAndSettle();
          final gap =
              tester.getRect(find.byKey(trigger)).top -
              tester.getRect(surface).bottom;
          expect(
            gap,
            closeTo(initialGap, 1),
            reason: 'Menu must follow the plus button at keyboard inset $inset',
          );
        }
        expect(
          tester.getRect(find.byKey(trigger)).top -
              tester.getRect(surface).bottom,
          closeTo(8, 1),
        );
        expect(tester.binding.hasScheduledFrame, isFalse);
        await tester.tap(find.text('Voice Call'));
        await tester.pumpAndSettle();
        expect(selected, 'call');
        expect(find.byType(PopupMenuItem<String>), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
