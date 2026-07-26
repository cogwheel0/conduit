import 'dart:math' as math;

import 'package:flutter/material.dart';

enum RasterDecodeProfile {
  avatar(maxLongestEdge: 256),
  thumbnail(maxLongestEdge: 1024),
  inline(maxLongestEdge: 1536),
  fullScreen(maxLongestEdge: 3072);

  const RasterDecodeProfile({required this.maxLongestEdge});

  final int maxLongestEdge;
}

@immutable
final class RasterDecodeTarget {
  const RasterDecodeTarget({required this.width, required this.height});

  final int width;
  final int height;
}

/// One memory policy for raster images. Source/disk bytes remain original;
/// these dimensions only bound decoded frames retained by Flutter's cache.
abstract final class RasterMediaPolicy {
  static const int imageCacheMaximumBytes = 48 * 1024 * 1024;
  static const int imageCacheMaximumEntries = 128;
  static const int attachmentDecodedByteBudget = 32 * 1024 * 1024;
  static const int attachmentResolvedDataByteBudget = 16 * 1024 * 1024;

  static void configureGlobalImageCache() {
    final cache = PaintingBinding.instance.imageCache;
    cache.maximumSizeBytes = imageCacheMaximumBytes;
    cache.maximumSize = imageCacheMaximumEntries;
  }

  static RasterDecodeTarget target({
    required RasterDecodeProfile profile,
    required double devicePixelRatio,
    double? logicalWidth,
    double? logicalHeight,
    Size? logicalScreenSize,
  }) {
    final dpr = devicePixelRatio.isFinite && devicePixelRatio > 0
        ? devicePixelRatio
        : 1.0;
    final screen = profile == RasterDecodeProfile.fullScreen
        ? logicalScreenSize
        : null;
    final width = _validLogicalExtent(logicalWidth)
        ? logicalWidth!
        : _validLogicalExtent(screen?.width)
        ? screen!.width
        : null;
    final height = _validLogicalExtent(logicalHeight)
        ? logicalHeight!
        : _validLogicalExtent(screen?.height)
        ? screen!.height
        : null;
    final cap = profile.maxLongestEdge.toDouble();

    var physicalWidth = width == null ? cap : width * dpr;
    var physicalHeight = height == null ? cap : height * dpr;
    final longest = math.max(physicalWidth, physicalHeight);
    if (longest > cap) {
      final scale = cap / longest;
      physicalWidth *= scale;
      physicalHeight *= scale;
    }

    return RasterDecodeTarget(
      width: physicalWidth.round().clamp(1, profile.maxLongestEdge),
      height: physicalHeight.round().clamp(1, profile.maxLongestEdge),
    );
  }

  static RasterDecodeTarget forBox(
    BuildContext context, {
    required RasterDecodeProfile profile,
    BoxConstraints? constraints,
    double? logicalWidth,
    double? logicalHeight,
  }) {
    return target(
      profile: profile,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      logicalWidth: logicalWidth ?? constraints?.maxWidth,
      logicalHeight: logicalHeight ?? constraints?.maxHeight,
      logicalScreenSize: MediaQuery.sizeOf(context),
    );
  }

  static bool _validLogicalExtent(double? value) =>
      value != null && value.isFinite && value > 0;
}
