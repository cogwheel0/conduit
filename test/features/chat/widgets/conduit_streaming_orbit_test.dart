import 'package:conduit/features/chat/widgets/conduit_streaming_orbit.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

ConduitStreamingOrbitPainter _painter(WidgetTester tester) {
  return tester
          .widget<CustomPaint>(
            find.byKey(const ValueKey<String>('conduit-streaming-orbit')),
          )
          .painter!
      as ConduitStreamingOrbitPainter;
}

void main() {
  testWidgets('renders one fixed custom-paint orbit without a ticker', (
    tester,
  ) async {
    const color = Color(0xFFAA3355);

    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: ConduitStreamingOrbit(color: color, size: 28, animate: false),
        ),
      ),
    );

    expect(_painter(tester).phase, 0);
    expect(_painter(tester).color, color);
    expect(
      tester.getSize(find.byType(ConduitStreamingOrbit)),
      const Size(28, 28),
    );
    expect(find.byType(AnimatedBuilder), findsNothing);
    expect(find.byType(AnimatedOpacity), findsNothing);
    expect(find.byType(FadeTransition), findsNothing);
    expect(find.byType(Transform), findsNothing);
  });

  testWidgets('advances one orbit phase per low-frequency timer step', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: ConduitStreamingOrbit(
            color: Color(0xFF3355AA),
            size: 28,
            stepInterval: Duration(milliseconds: 400),
          ),
        ),
      ),
    );

    expect(_painter(tester).phase, 0);
    await tester.pump(const Duration(milliseconds: 399));
    expect(_painter(tester).phase, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(_painter(tester).phase, 1);
    expect(find.byType(AnimatedBuilder), findsNothing);
  });

  testWidgets('pauses orbit updates while the app is backgrounded', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: ConduitStreamingOrbit(color: Color(0xFF3355AA), size: 28),
        ),
      ),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 800));
    expect(_painter(tester).phase, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 400));
    expect(_painter(tester).phase, 1);
  });

  testWidgets('pauses orbit updates when its TickerMode is disabled', (
    tester,
  ) async {
    Widget build({required bool enabled}) => Directionality(
      textDirection: TextDirection.ltr,
      child: TickerMode(
        enabled: enabled,
        child: const Center(
          child: ConduitStreamingOrbit(color: Color(0xFF3355AA), size: 28),
        ),
      ),
    );

    await tester.pumpWidget(build(enabled: true));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_painter(tester).phase, 1);

    await tester.pumpWidget(build(enabled: false));
    await tester.pump(const Duration(milliseconds: 800));
    expect(_painter(tester).phase, 0);

    await tester.pumpWidget(build(enabled: true));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_painter(tester).phase, 1);
    expect(tester.takeException(), isNull);
  });
}
