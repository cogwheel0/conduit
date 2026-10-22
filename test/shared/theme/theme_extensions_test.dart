import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/color_tokens.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:checks/checks.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('palette mixes interpolate rather than keeping the first color', () {
    expect(
      mix(const Color(0xFF000000), const Color(0xFFFFFFFF), .5).toARGB32(),
      0xFF808080,
    );
    expect(
      mix(const Color(0xFF000000), const Color(0xFFFFFFFF), 0),
      const Color(0xFF000000),
    );
    expect(
      mix(const Color(0xFF000000), const Color(0xFFFFFFFF), 1),
      const Color(0xFFFFFFFF),
    );
  });

  test('text and hints remain legible on every theme surface', () {
    for (final definition in TweakcnThemes.all) {
      for (final brightness in Brightness.values) {
        final theme =
            (brightness == Brightness.dark
                    ? AppTheme.dark(definition)
                    : AppTheme.light(definition))
                .extension<ConduitThemeExtension>()!;
        final surfaces = {
          'page': theme.surfaceBackground,
          'card': theme.cardBackground,
          'container': theme.surfaceContainer,
          'popover': theme.surfaces.popover,
          'input': theme.inputBackground,
          'chrome': theme.surfaceChrome,
          'message': theme.surfaceMessage,
          'user bubble': theme.chatBubbleUser,
          'assistant bubble': theme.chatBubbleAssistant,
        };
        for (final surface in surfaces.entries) {
          for (final text in {
            'primary': theme.textPrimary,
            'secondary': theme.textSecondary,
            'caption': theme.textTertiary,
          }.entries) {
            expect(
              contrastRatio(text.value, surface.value),
              greaterThanOrEqualTo(4.5),
              reason: '${definition.id} $brightness ${text.key}/${surface.key}',
            );
          }
        }
        for (final surface in [theme.inputBackground, theme.surfaceContainer]) {
          expect(
            contrastRatio(
              Color.alphaBlend(theme.inputPlaceholder, surface),
              surface,
            ),
            greaterThanOrEqualTo(4.5),
            reason: '${definition.id} $brightness placeholder',
          );
        }
      }
    }
  });

  test('Conduit dark surfaces have visible elevation and legible states', () {
    final theme = AppTheme.dark(TweakcnThemes.conduit)
        .extension<ConduitThemeExtension>()!;
    // A visual hierarchy threshold, not a WCAG requirement for card fills.
    expect(
      contrastRatio(theme.cardBackground, theme.surfaceBackground),
      greaterThan(1.4),
    );
    expect(
      theme.cardBackground.computeLuminance(),
      greaterThan(theme.surfaceBackground.computeLuminance()),
    );
    for (final surface in [
      theme.cardBackground,
      theme.surfaces.popover,
      theme.inputBackground,
    ]) {
      expect(contrastRatio(theme.error, surface), greaterThanOrEqualTo(4.5));
      expect(
        contrastRatio(theme.inputBorderFocused, surface),
        greaterThanOrEqualTo(3),
      );
    }
  });

  test('sidebar tint keeps legible accents and softens saturated ones', () {
    for (final definition in TweakcnThemes.all) {
      for (final brightness in Brightness.values) {
        final sidebar = SidebarThemeExtension.fromVariant(
          definition.variantFor(brightness),
        );
        // The folder count badge draws the densest fill under full text.
        final badge = Color.alphaBlend(
          sidebar.tint.withValues(alpha: SidebarThemeExtension.tintMaxOpacity),
          sidebar.background,
        );
        check(
          because: '${definition.id} $brightness',
          contrastRatio(sidebar.foreground, badge),
        ).isGreaterOrEqual(4.5);

        // The folder page draws the same badge on the plain page surface.
        final page =
            (brightness == Brightness.dark
                    ? AppTheme.dark(definition)
                    : AppTheme.light(definition))
                .extension<ConduitThemeExtension>()!
                .surfaceBackground;
        final pageBadge = Color.alphaBlend(
          sidebar.tint.withValues(alpha: SidebarThemeExtension.tintMaxOpacity),
          page,
        );
        check(
          because: '${definition.id} $brightness folder page',
          contrastRatio(sidebar.foreground, pageBadge),
        ).isGreaterOrEqual(4.5);
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

  test('grouped cards on the plain page never match the page', () {
    for (final definition in TweakcnThemes.all) {
      for (final brightness in Brightness.values) {
        final theme = brightness == Brightness.dark
            ? AppTheme.dark(definition)
            : AppTheme.light(definition);
        final conduit = theme.extension<ConduitThemeExtension>()!;
        check(
          because: '${definition.id} $brightness',
          conduit.groupedSurfaceOnPage,
        ).not((it) => it.equals(conduit.surfaceBackground));
      }
    }
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
