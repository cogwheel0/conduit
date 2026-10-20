import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/color_tokens.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:checks/checks.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS text selection uses the themed Android accent colors', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final definition = TweakcnThemes.catppuccin;
    final expectedAccent = definition.variantFor(Brightness.light).primary;

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final androidSelection = AppTheme.light(definition).textSelectionTheme;

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final iosSelection = AppTheme.light(definition).textSelectionTheme;

    check(iosSelection.cursorColor).equals(expectedAccent);
    check(iosSelection.selectionColor)
        .equals(expectedAccent.withValues(alpha: 0.2));
    check(iosSelection.selectionHandleColor).equals(expectedAccent);
    check(iosSelection).equals(androidSelection);
  });

  test('Material container roles come from the palette, not the seed', () {
    // fromSeed hue-shifts these roles (pink containers on the monochrome
    // Conduit palette), and Material controls read them directly.
    for (final definition in TweakcnThemes.all) {
      for (final brightness in Brightness.values) {
        final variant = definition.variantFor(brightness);
        final theme = brightness == Brightness.dark
            ? AppTheme.dark(definition)
            : AppTheme.light(definition);
        final scheme = theme.colorScheme;
        final surfaces = theme.extension<SurfaceThemeExtension>()!;
        final label = '${definition.id} $brightness';
        check(
          because: label,
          scheme.secondaryContainer,
        ).equals(variant.secondary);
        check(
          because: label,
          scheme.onSecondaryContainer,
        ).equals(variant.secondaryForeground);
        check(because: label, scheme.tertiaryContainer).equals(variant.muted);
        check(
          because: label,
          scheme.surfaceContainer,
        ).equals(surfaces.container);
        check(because: label, scheme.inverseSurface).equals(variant.foreground);
      }
    }
  });

  test('error color stays a legible red on every palette', () {
    // Palettes keep tweakcn's destructive verbatim (a button fill), but the
    // app also draws the error color as body-size text and icons on the page.
    for (final definition in TweakcnThemes.all) {
      for (final brightness in Brightness.values) {
        final variant = definition.variantFor(brightness);
        final error = _tokens(definition, brightness).statusError60;
        final label = '${definition.id} $brightness';
        check(
          because: label,
          contrastRatio(error, variant.background),
        ).isGreaterOrEqual(4.5);
        check(because: label, error.r > error.g && error.r > error.b).isTrue();
      }
    }
    // Legible presets pass through untouched.
    final catppuccin = TweakcnThemes.catppuccin.variantFor(Brightness.light);
    check(AppColorTokens.light(theme: TweakcnThemes.catppuccin).statusError60)
        .equals(catppuccin.destructive);
  });

  test('a failing red keeps its hue when lightened for contrast', () {
    // T3 Chat dark's destructive (#301015) nearly matches its page.
    final t3Dark = TweakcnThemes.t3Chat.variantFor(Brightness.dark);
    final error = _tokens(TweakcnThemes.t3Chat, Brightness.dark).statusError60;
    final sourceHue = HSLColor.fromColor(t3Dark.destructive).hue;
    check(HSLColor.fromColor(error).hue).isCloseTo(sourceHue, 1);
  });

  test('status text stays readable on every status fill', () {
    // Snackbars and badges draw on* text over the status fills.
    for (final definition in TweakcnThemes.all) {
      for (final brightness in Brightness.values) {
        final tokens = _tokens(definition, brightness);
        final label = '${definition.id} $brightness';
        for (final (name, fill, text) in [
          ('success', tokens.statusSuccess60, tokens.statusOnSuccess60),
          ('warning', tokens.statusWarning60, tokens.statusOnWarning60),
          ('info', tokens.statusInfo60, tokens.statusOnInfo60),
          ('error', tokens.statusError60, tokens.statusOnError60),
        ]) {
          check(
            because: '$label $name',
            contrastRatio(text, fill),
          ).isGreaterOrEqual(4.5);
        }
      }
    }
  });

  test('error container text uses the page text color', () {
    for (final definition in TweakcnThemes.all) {
      for (final brightness in Brightness.values) {
        final theme = brightness == Brightness.dark
            ? AppTheme.dark(definition)
            : AppTheme.light(definition);
        final scheme = theme.colorScheme;
        check(
          because: '${definition.id} $brightness',
          contrastRatio(scheme.onErrorContainer, scheme.errorContainer),
        ).isGreaterOrEqual(4.5);
      }
    }
  });

  test('inverse primary stays legible on the inverse surface', () {
    for (final definition in TweakcnThemes.all) {
      for (final brightness in Brightness.values) {
        final scheme =
            (brightness == Brightness.dark
                    ? AppTheme.dark(definition)
                    : AppTheme.light(definition))
                .colorScheme;
        check(
          because: '${definition.id} $brightness',
          contrastRatio(scheme.inversePrimary, scheme.inverseSurface),
        ).isGreaterOrEqual(4.5);
      }
    }
  });

  test('selected secondary containers keep their paired text legible', () {
    // Selected segments and active Mermaid controls draw
    // onSecondaryContainer on secondaryContainer.
    for (final definition in TweakcnThemes.all) {
      for (final brightness in Brightness.values) {
        final scheme =
            (brightness == Brightness.dark
                    ? AppTheme.dark(definition)
                    : AppTheme.light(definition))
                .colorScheme;
        check(
          because: '${definition.id} $brightness',
          contrastRatio(scheme.onSecondaryContainer, scheme.secondaryContainer),
        ).isGreaterOrEqual(3);
      }
    }
  });

  test('withMinContrast only moves colors that fall short', () {
    const surface = Color(0xFFFFFFFF);
    const passing = Color(0xFF1D4ED8);
    check(withMinContrast(passing, surface, 3)).equals(passing);
    const failing = Color(0xFFE8C468);
    final adjusted = withMinContrast(failing, surface, 3);
    check(contrastRatio(adjusted, surface)).isGreaterOrEqual(3);
    check(HSLColor.fromColor(adjusted).hue)
        .isCloseTo(HSLColor.fromColor(failing).hue, 1);
  });

  test('product typography uses one ramp on Android and iOS', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final androidTextTheme = AppTheme.light(TweakcnThemes.t3Chat).textTheme;

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final iosTextTheme = AppTheme.light(TweakcnThemes.t3Chat).textTheme;

    check(androidTextTheme.displaySmall?.fontSize).equals(24);
    check(androidTextTheme.headlineLarge?.fontSize).equals(22);
    check(androidTextTheme.headlineMedium?.fontSize).equals(20);
    check(androidTextTheme.headlineSmall?.fontSize).equals(17);
    check(androidTextTheme.bodyLarge?.fontSize).equals(17);
    check(androidTextTheme.bodyMedium?.fontSize).equals(16);
    check(iosTextTheme.displaySmall?.fontSize).equals(24);
    check(iosTextTheme.headlineLarge?.fontSize).equals(22);
    check(iosTextTheme.headlineMedium?.fontSize).equals(20);
    check(iosTextTheme.headlineSmall?.fontSize).equals(17);
    check(iosTextTheme.bodyLarge?.fontSize).equals(17);
    check(iosTextTheme.bodyMedium?.fontSize).equals(16);
  });

  test('native chrome retains explicit Material and Cupertino ramps', () {
    const primary = Color(0xFF111111);
    const secondary = Color(0xFF555555);
    const tertiary = Color(0xFF777777);

    final material = AppTypography.materialChromeTextTheme(
      primary: primary,
      secondary: secondary,
      tertiary: tertiary,
    );
    final cupertino = AppTypography.cupertinoChromeTextTheme(
      primary: primary,
      secondary: secondary,
      tertiary: tertiary,
    );

    check(material.displaySmall?.fontSize).equals(36);
    check(cupertino.displaySmall?.fontSize).equals(24);
    check(material.titleLarge?.fontSize).equals(22);
    check(cupertino.titleLarge?.fontSize).equals(17);
    check(material.bodyMedium?.fontSize).equals(14);
    check(cupertino.bodyMedium?.fontSize).equals(16);
    check(AppTypography.materialChromeLabelSmallStyle.fontSize).equals(12);
    check(AppTypography.cupertinoChromeMicroStyle.fontSize).equals(11);
  });

  test('app themes wire native ramps into product and navigation chrome', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    final materialTheme = AppTheme.light(TweakcnThemes.t3Chat);
    final cupertinoTheme = AppTheme.cupertinoLight(TweakcnThemes.t3Chat);
    final darkTokens = AppColorTokens.dark(theme: TweakcnThemes.t3Chat);
    final darkMaterialTheme = AppTheme.dark(TweakcnThemes.t3Chat);
    final darkCupertinoTheme = AppTheme.cupertinoDark(TweakcnThemes.t3Chat);
    final conduitTheme = materialTheme.extension<ConduitThemeExtension>()!;

    check(materialTheme.textTheme.titleLarge?.fontSize).equals(17);
    check(materialTheme.inputDecorationTheme.hintStyle?.fontWeight)
        .equals(FontWeight.w300);
    check(materialTheme.inputDecorationTheme.hintStyle?.color)
        .equals(conduitTheme.textSecondary.withValues(alpha: 0.5));
    check(materialTheme.appBarTheme.titleTextStyle?.fontSize).equals(22);
    check(cupertinoTheme.textTheme.navTitleTextStyle.fontSize).equals(17);
    check(cupertinoTheme.textTheme.navLargeTitleTextStyle.fontSize).equals(34);
    check(cupertinoTheme.textTheme.tabLabelTextStyle.fontSize).equals(11);
    check(darkMaterialTheme.appBarTheme.titleTextStyle?.color)
        .equals(darkTokens.neutralOnSurface);
    check(
      darkMaterialTheme
          .cupertinoOverrideTheme
          ?.textTheme
          ?.tabLabelTextStyle
          .color,
    ).equals(darkTokens.neutralTone80);
    check(darkCupertinoTheme.textTheme.navTitleTextStyle.color)
        .equals(darkTokens.neutralOnSurface);
    check(darkCupertinoTheme.textTheme.tabLabelTextStyle.color)
        .equals(darkTokens.neutralTone80);
  });

  test('platform control geometry remains adaptive', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final androidInputPadding = AppTypography.inputVerticalPadding;
    final androidBadgeSize = AppTypography.badgeLargeSize;

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final iosInputPadding = AppTypography.inputVerticalPadding;
    final iosBadgeSize = AppTypography.badgeLargeSize;

    check(androidInputPadding).equals(14);
    check(iosInputPadding).equals(12);
    check(androidBadgeSize).equals(24);
    check(iosBadgeSize).equals(22);
  });
}

AppColorTokens _tokens(
  TweakcnThemeDefinition definition,
  Brightness brightness,
) => brightness == Brightness.dark
    ? AppColorTokens.dark(theme: definition)
    : AppColorTokens.light(theme: definition);
