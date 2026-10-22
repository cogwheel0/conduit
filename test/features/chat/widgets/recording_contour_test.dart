import 'package:conduit/features/chat/widgets/recording_contour.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Contour stops scheduling frames after finishing', (
    tester,
  ) async {
    final level = ValueNotifier<double>(0.5);
    addTearDown(level.dispose);
    Widget surface(bool active, bool reduced) => MaterialApp(
      home: Center(
        child: RecordingContour(
          active: active,
          level: level,
          color: Colors.white,
          borderRadius: BorderRadius.circular(999),
          reduceMotion: reduced,
          child: const SizedBox(width: 320, height: 44),
        ),
      ),
    );
    await tester.pumpWidget(surface(true, false));
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(surface(false, false));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(surface(true, true));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    level.value = 0.8;
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('elapsed time advances without changing meter layout', (
    tester,
  ) async {
    final level = ValueNotifier<double>(0);
    addTearDown(level.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 240,
            height: 44,
            child: RecordingContourMeter(
              level: level,
              color: Colors.white,
              recordingColor: Colors.red,
              label: 'Recording',
              reduceMotion: true,
            ),
          ),
        ),
      ),
    );
    expect(find.text('0:00'), findsOneWidget);
    final meterSize = tester.getSize(
      find.byKey(const ValueKey('composer-recording-meter')),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('0:02'), findsOneWidget);
    level.value = 1;
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const ValueKey('composer-recording-meter'))),
      meterSize,
    );
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
