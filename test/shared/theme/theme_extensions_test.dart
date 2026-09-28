import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:checks/checks.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sidebar tint keeps legible accents and softens saturated ones', () {
    for (final definition in TweakcnThemes.all) {
      for (final brightness in Brightness.values) {
        final sidebar = SidebarThemeExtension.fromVariant(
          definition.variantFor(brightness),
        );
        final label = '${definition.id} $brightness';
        final underText = Color.alphaBlend(
          sidebar.tint.withValues(alpha: 0.5),
          sidebar.background,
        );
        final a = sidebar.foreground.computeLuminance();
        final b = underText.computeLuminance();
        final contrast =
            (a > b ? a + 0.05 : b + 0.05) / (a > b ? b + 0.05 : a + 0.05);
        check(because: label, contrast).isGreaterOrEqual(4.5);
      }
    }
    // Tweakcn's Catppuccin sidebar accent is saturated sky blue.
    final catppuccin = SidebarThemeExtension.fromVariant(
      TweakcnThemes.catppuccin.variantFor(Brightness.light),
    );
    check(catppuccin.tint).not((it) => it.equals(catppuccin.accent));
    final t3 = SidebarThemeExtension.fromVariant(
      TweakcnThemes.t3Chat.variantFor(Brightness.light),
    );
    check(t3.tint).equals(t3.accent);
  });

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
