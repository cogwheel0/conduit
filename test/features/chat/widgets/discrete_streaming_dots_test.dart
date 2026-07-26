import 'package:conduit/features/chat/widgets/discrete_streaming_dots.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Color _dotColor(WidgetTester tester, int index) {
  final container = tester.widget<Container>(
    find.byKey(ValueKey<String>('streaming-dot-$index')),
  );
  return (container.decoration! as BoxDecoration).color!;
}

void main() {
  testWidgets('renders three static dots when motion is disabled', (
    tester,
  ) async {
    const color = Color(0xFFAA3355);

    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: DiscreteStreamingDots(color: color, size: 28, animate: false),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('streaming-dot-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('streaming-dot-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('streaming-dot-2')), findsOneWidget);
    expect(_dotColor(tester, 0), color);
    expect(_dotColor(tester, 1), color);
    expect(_dotColor(tester, 2), color);
    expect(find.byType(AnimatedBuilder), findsNothing);
    expect(find.byType(AnimatedOpacity), findsNothing);
    expect(find.byType(FadeTransition), findsNothing);
    expect(find.byType(Transform), findsNothing);
  });

  testWidgets('advances one discrete dot per low-frequency timer step', (
    tester,
  ) async {
    const color = Color(0xFF3355AA);
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: DiscreteStreamingDots(
            color: color,
            size: 28,
            stepInterval: Duration(milliseconds: 400),
          ),
        ),
      ),
    );

    expect(_dotColor(tester, 0), color);
    expect(_dotColor(tester, 1), isNot(color));

    await tester.pump(const Duration(milliseconds: 399));
    expect(_dotColor(tester, 0), color);

    await tester.pump(const Duration(milliseconds: 1));
    expect(_dotColor(tester, 0), isNot(color));
    expect(_dotColor(tester, 1), color);
    expect(find.byType(AnimatedBuilder), findsNothing);
  });

  testWidgets('pauses discrete stepping while the app is backgrounded', (
    tester,
  ) async {
    const color = Color(0xFF3355AA);
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: DiscreteStreamingDots(
            color: color,
            size: 28,
            stepInterval: Duration(milliseconds: 400),
          ),
        ),
      ),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 800));
    expect(_dotColor(tester, 0), color);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 400));
    expect(_dotColor(tester, 1), color);
  });

  testWidgets('pauses discrete stepping when its TickerMode is disabled', (
    tester,
  ) async {
    const color = Color(0xFF3355AA);

    Widget build({required bool enabled}) => Directionality(
      textDirection: TextDirection.ltr,
      child: TickerMode(
        enabled: enabled,
        child: const Center(
          child: DiscreteStreamingDots(
            color: color,
            size: 28,
            stepInterval: Duration(milliseconds: 400),
          ),
        ),
      ),
    );

    await tester.pumpWidget(build(enabled: true));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_dotColor(tester, 1), color);

    await tester.pumpWidget(build(enabled: false));
    await tester.pump(const Duration(milliseconds: 800));
    expect(_dotColor(tester, 0), color);

    await tester.pumpWidget(build(enabled: true));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_dotColor(tester, 1), color);
    expect(tester.takeException(), isNull);
  });
}
