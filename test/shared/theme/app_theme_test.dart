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

  test('product typography is identical on Android and iOS', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final androidTextTheme = AppTheme.light(TweakcnThemes.t3Chat).textTheme;

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final iosTextTheme = AppTheme.light(TweakcnThemes.t3Chat).textTheme;

    check(androidTextTheme).equals(iosTextTheme);
    check(androidTextTheme.displaySmall?.fontSize).equals(24);
    check(androidTextTheme.headlineLarge?.fontSize).equals(22);
    check(androidTextTheme.headlineMedium?.fontSize).equals(20);
    check(androidTextTheme.headlineSmall?.fontSize).equals(17);
    check(androidTextTheme.bodyLarge?.fontSize).equals(17);
    check(androidTextTheme.bodyMedium?.fontSize).equals(16);
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

  test('app themes wire native ramps only into navigation chrome', () {
    final materialTheme = AppTheme.light(TweakcnThemes.t3Chat);
    final cupertinoTheme = AppTheme.cupertinoLight(TweakcnThemes.t3Chat);
    final darkTokens = AppColorTokens.dark(theme: TweakcnThemes.t3Chat);
    final darkMaterialTheme = AppTheme.dark(TweakcnThemes.t3Chat);
    final darkCupertinoTheme = AppTheme.cupertinoDark(TweakcnThemes.t3Chat);

    check(materialTheme.textTheme.titleLarge?.fontSize).equals(17);
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
