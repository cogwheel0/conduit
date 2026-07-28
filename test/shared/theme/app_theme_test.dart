import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/foundation.dart';
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
}
