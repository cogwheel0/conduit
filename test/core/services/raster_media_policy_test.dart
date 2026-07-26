import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/raster_media_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('decode targets scale with DPR and respect each profile cap', () {
    final oneX = RasterMediaPolicy.target(
      profile: RasterDecodeProfile.avatar,
      devicePixelRatio: 1,
      logicalWidth: 40,
      logicalHeight: 24,
    );
    check(oneX.width).equals(40);
    check(oneX.height).equals(24);

    final twoX = RasterMediaPolicy.target(
      profile: RasterDecodeProfile.avatar,
      devicePixelRatio: 2,
      logicalWidth: 40,
      logicalHeight: 24,
    );
    check(twoX.width).equals(80);
    check(twoX.height).equals(48);

    final threeX = RasterMediaPolicy.target(
      profile: RasterDecodeProfile.thumbnail,
      devicePixelRatio: 3,
      logicalWidth: 500,
      logicalHeight: 300,
    );
    check(threeX.width).equals(1024);
    check(threeX.height).equals(614);
  });

  test('invalid and unbounded constraints use the profile maximum', () {
    final target = RasterMediaPolicy.target(
      profile: RasterDecodeProfile.inline,
      devicePixelRatio: double.nan,
      logicalWidth: double.infinity,
      logicalHeight: -1,
    );
    check(target.width).equals(1536);
    check(target.height).equals(1536);
  });

  test('full-screen target uses physical screen size under the 3072 cap', () {
    final target = RasterMediaPolicy.target(
      profile: RasterDecodeProfile.fullScreen,
      devicePixelRatio: 3,
      logicalScreenSize: const Size(390, 844),
    );
    check(target.width).equals(1170);
    check(target.height).equals(2532);
  });

  test('global Flutter frame cache uses the shared memory ceiling', () {
    final cache = PaintingBinding.instance.imageCache;
    final previousBytes = cache.maximumSizeBytes;
    final previousEntries = cache.maximumSize;
    addTearDown(() {
      cache.maximumSizeBytes = previousBytes;
      cache.maximumSize = previousEntries;
    });

    RasterMediaPolicy.configureGlobalImageCache();

    check(cache.maximumSizeBytes).equals(48 * 1024 * 1024);
    check(cache.maximumSize).equals(128);
  });

  test('thumbnail and full-screen decode keys remain distinct', () async {
    final provider = MemoryImage(Uint8List.fromList(const [1, 2, 3]));
    final thumbnail = RasterMediaPolicy.target(
      profile: RasterDecodeProfile.thumbnail,
      devicePixelRatio: 2,
      logicalWidth: 300,
      logicalHeight: 200,
    );
    final fullScreen = RasterMediaPolicy.target(
      profile: RasterDecodeProfile.fullScreen,
      devicePixelRatio: 2,
      logicalScreenSize: const Size(390, 844),
    );
    final thumbnailProvider = RasterMediaPolicy.resizeProvider(
      provider,
      thumbnail,
    );
    final fullScreenProvider = RasterMediaPolicy.resizeProvider(
      provider,
      fullScreen,
    );

    check(thumbnailProvider).isA<ResizeImage>();
    check(
      (thumbnailProvider as ResizeImage).policy,
    ).equals(ResizeImagePolicy.fit);
    final thumbnailKey = await thumbnailProvider.obtainKey(
      ImageConfiguration.empty,
    );
    final fullScreenKey = await fullScreenProvider.obtainKey(
      ImageConfiguration.empty,
    );
    check(thumbnailKey == fullScreenKey).isFalse();
  });
}
