import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final platform in TargetPlatform.values) {
    testWidgets('uses Cupertino chrome on ${platform.name}', (tester) async {
      late bool usesCupertinoChrome;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: Builder(
            builder: (context) {
              usesCupertinoChrome = context.usesCupertinoChrome;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(
        usesCupertinoChrome,
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS,
      );
    });
  }

  testWidgets('iOS reduce motion disables motion durations', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(reduceMotion: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    late bool reduceMotion;
    late Duration duration;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            reduceMotion = context.reduceMotion;
            duration = context.motionDuration(
              const Duration(milliseconds: 180),
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(reduceMotion, isTrue);
    expect(duration, Duration.zero);
  });

  testWidgets('MediaQuery can override platform disable animations', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    late bool reduceMotion;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: false),
        child: Builder(
          builder: (context) {
            reduceMotion = context.reduceMotion;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(reduceMotion, isFalse);
  });
}
