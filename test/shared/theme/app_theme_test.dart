import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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

    expect(iosSelection.cursorColor, expectedAccent);
    expect(iosSelection.selectionColor, expectedAccent.withValues(alpha: 0.2));
    expect(iosSelection.selectionHandleColor, expectedAccent);
    expect(iosSelection, androidSelection);
  });

  test('product typography is identical on Android and iOS', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final androidTextTheme = AppTheme.light(TweakcnThemes.t3Chat).textTheme;

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final iosTextTheme = AppTheme.light(TweakcnThemes.t3Chat).textTheme;

    expect(androidTextTheme, iosTextTheme);
    expect(androidTextTheme.displaySmall?.fontSize, 24);
    expect(androidTextTheme.headlineLarge?.fontSize, 22);
    expect(androidTextTheme.headlineMedium?.fontSize, 20);
    expect(androidTextTheme.headlineSmall?.fontSize, 17);
    expect(androidTextTheme.bodyLarge?.fontSize, 17);
    expect(androidTextTheme.bodyMedium?.fontSize, 16);
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

    expect(material.displaySmall?.fontSize, 36);
    expect(cupertino.displaySmall?.fontSize, 24);
    expect(material.titleLarge?.fontSize, 22);
    expect(cupertino.titleLarge?.fontSize, 17);
    expect(material.bodyMedium?.fontSize, 14);
    expect(cupertino.bodyMedium?.fontSize, 16);
    expect(AppTypography.cupertinoChromeMicroStyle.fontSize, 11);
  });

  test('app themes wire native ramps only into navigation chrome', () {
    final materialTheme = AppTheme.light(TweakcnThemes.t3Chat);
    final cupertinoTheme = AppTheme.cupertinoLight(TweakcnThemes.t3Chat);

    expect(materialTheme.textTheme.titleLarge?.fontSize, 17);
    expect(materialTheme.appBarTheme.titleTextStyle?.fontSize, 22);
    expect(cupertinoTheme.textTheme.navTitleTextStyle.fontSize, 17);
    expect(cupertinoTheme.textTheme.navLargeTitleTextStyle.fontSize, 34);
    expect(cupertinoTheme.textTheme.tabLabelTextStyle.fontSize, 11);
  });

  test('platform control geometry remains adaptive', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final androidInputPadding = AppTypography.inputVerticalPadding;
    final androidBadgeSize = AppTypography.badgeLargeSize;

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final iosInputPadding = AppTypography.inputVerticalPadding;
    final iosBadgeSize = AppTypography.badgeLargeSize;

    expect(androidInputPadding, 14);
    expect(iosInputPadding, 12);
    expect(androidBadgeSize, 24);
    expect(iosBadgeSize, 22);
  });
}
