import 'dart:ui' as ui;

import 'package:conduit/features/chat/widgets/response_activity_indicator.dart';
import 'package:conduit_core/models/response_animation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

ResponseActivityPainter _painter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.byKey(const ValueKey('response-activity-indicator')),
            )
            .painter!
        as ResponseActivityPainter;

Widget _harness({
  bool animate = true,
  bool ticker = true,
  ResponseIndicatorStyle style = ResponseIndicatorStyle.facets,
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: TickerMode(
    enabled: ticker,
    child: Center(
      child: ResponseActivityIndicator(
        style: style,
        color: const Color(0xFFB7BECC),
        animate: animate,
      ),
    ),
  ),
);

void main() {
  testWidgets('animation paints without rebuilding the fixed-size widget', (
    tester,
  ) async {
    await tester.pumpWidget(_harness());
    final widget = tester.widget<CustomPaint>(find.byType(CustomPaint));
    final clock = _painter(tester).progress;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));
    expect(clock.value, greaterThan(0));
    expect(
      identical(widget, tester.widget<CustomPaint>(find.byType(CustomPaint))),
      isTrue,
    );
    expect(
      tester.getSize(find.byType(ResponseActivityIndicator)),
      const Size(28, 28),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('reduced motion is static and schedules no ticker', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(animate: false));
    final before = _painter(tester).progress.value;
    await tester.pump(const Duration(seconds: 2));
    expect(_painter(tester).progress.value, before);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'background and disabled TickerMode pause without a catch-up jump',
    (tester) async {
      await tester.pumpWidget(_harness());
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final paused = _painter(tester).progress.value;
      await tester.pump(const Duration(seconds: 4));
      expect(_painter(tester).progress.value, paused);
      expect(tester.binding.transientCallbackCount, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_painter(tester).progress.value, greaterThan(paused));
      await tester.pumpWidget(_harness(ticker: false));
      final disabled = _painter(tester).progress.value;
      await tester.pump(const Duration(seconds: 4));
      expect(_painter(tester).progress.value, disabled);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(_harness());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_painter(tester).progress.value, greaterThan(disabled));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'each selected design renders differently and changes over a cycle',
    () async {
      Future<List<int>> pixels(
        ResponseIndicatorStyle style,
        double phase,
      ) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        ResponseActivityPainter(
          style: style,
          color: const Color(0xFFFFFFFF),
          progress: AlwaysStoppedAnimation(phase),
        ).paint(canvas, const Size(112, 112));
        final picture = recorder.endRecording();
        final image = await picture.toImage(112, 112);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List()
            .toList();
        image.dispose();
        picture.dispose();
        return bytes;
      }

      final signatures = <String>{};
      for (final style in ResponseIndicatorStyle.values) {
        final first = await pixels(style, .08);
        final later = await pixels(style, .35);
        expect(first, isNot(equals(later)), reason: style.name);
        signatures.add(first.join(','));
      }
      expect(signatures.length, ResponseIndicatorStyle.values.length);
    },
  );
}
