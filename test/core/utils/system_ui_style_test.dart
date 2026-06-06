import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/utils/system_ui_style.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';

void main() {
  group('systemUiOverlayStyleForBrightness', () {
    test('uses dark icons for light surfaces', () {
      final style = systemUiOverlayStyleForBrightness(Brightness.light);

      expect(style.statusBarBrightness, Brightness.light);
      expect(style.statusBarIconBrightness, Brightness.dark);
      expect(style.systemNavigationBarIconBrightness, Brightness.dark);
    });

    test('uses light icons for dark surfaces', () {
      final style = systemUiOverlayStyleForBrightness(Brightness.dark);

      expect(style.statusBarBrightness, Brightness.dark);
      expect(style.statusBarIconBrightness, Brightness.light);
      expect(style.systemNavigationBarIconBrightness, Brightness.light);
    });

    test('is applied by app bar themes', () {
      final lightStyle = AppTheme.light(
        TweakcnThemes.t3Chat,
      ).appBarTheme.systemOverlayStyle;
      final darkStyle = AppTheme.dark(
        TweakcnThemes.t3Chat,
      ).appBarTheme.systemOverlayStyle;

      expect(lightStyle?.statusBarBrightness, Brightness.light);
      expect(lightStyle?.statusBarIconBrightness, Brightness.dark);
      expect(darkStyle?.statusBarBrightness, Brightness.dark);
      expect(darkStyle?.statusBarIconBrightness, Brightness.light);
    });
  });
}
