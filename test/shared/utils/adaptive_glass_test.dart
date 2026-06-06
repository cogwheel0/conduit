import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/shared/utils/adaptive_glass.dart';

void main() {
  group('conduitSupportsNativeGlass', () {
    test('requires iOS 26 or newer', () {
      expect(
        conduitSupportsNativeGlass(isIOS: true, iosMajorVersion: 26),
        true,
      );
      expect(
        conduitSupportsNativeGlass(isIOS: true, iosMajorVersion: 27),
        true,
      );
      expect(
        conduitSupportsNativeGlass(isIOS: true, iosMajorVersion: 25),
        false,
      );
      expect(
        conduitSupportsNativeGlass(isIOS: true, iosMajorVersion: 0),
        false,
      );
    });

    test('is false outside iOS', () {
      expect(
        conduitSupportsNativeGlass(isIOS: false, iosMajorVersion: 26),
        false,
      );
    });
  });

  group('conduitUsesOpaqueGlassFallback', () {
    test('uses fallback on Android and older iOS', () {
      expect(conduitUsesOpaqueGlassFallback(isAndroid: true), true);
      expect(
        conduitUsesOpaqueGlassFallback(
          isAndroid: false,
          isIOS: true,
          iosMajorVersion: 18,
        ),
        true,
      );
    });

    test('does not use fallback on iOS 26 or non-mobile platforms', () {
      expect(
        conduitUsesOpaqueGlassFallback(
          isAndroid: false,
          isIOS: true,
          iosMajorVersion: 26,
        ),
        false,
      );
      expect(
        conduitUsesOpaqueGlassFallback(isAndroid: false, isIOS: false),
        false,
      );
    });
  });
}
