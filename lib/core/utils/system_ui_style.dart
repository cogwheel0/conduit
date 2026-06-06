import 'package:flutter/services.dart';

SystemUiOverlayStyle systemUiOverlayStyleForBrightness(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final iconBrightness = isDark ? Brightness.light : Brightness.dark;

  return SystemUiOverlayStyle(
    statusBarBrightness: brightness,
    statusBarIconBrightness: iconBrightness,
    systemNavigationBarIconBrightness: iconBrightness,
  );
}

/// Applies a single System UI overlay style after first frame to avoid flicker
/// at startup and to align with the active theme brightness.
void applySystemUiOverlayStyleOnce({required Brightness brightness}) {
  SystemChrome.setSystemUIOverlayStyle(
    systemUiOverlayStyleForBrightness(brightness),
  );
}
