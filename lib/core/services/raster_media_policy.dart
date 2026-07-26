import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:conduit/core/utils/debug_logger.dart';
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

  @override
  bool operator ==(Object other) {
    return other is RasterDecodeTarget &&
        other.width == width &&
        other.height == height;
  }

  @override
  int get hashCode => Object.hash(width, height);
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
      width: physicalWidth.round().clamp(1, profile.maxLongestEdge).toInt(),
      height: physicalHeight.round().clamp(1, profile.maxLongestEdge).toInt(),
    );
  }

  /// Applies both decode bounds while preserving the source aspect ratio.
  ///
  /// Flutter's default two-dimensional resize policy is exact and can stretch
  /// images. `fit` instead asks the codec for the largest intrinsic-aspect
  /// decode that fits inside this profile's physical-pixel box.
  static ImageProvider<Object> resizeProvider(
    ImageProvider<Object> provider,
    RasterDecodeTarget target,
  ) {
    return ResizeImage(
      provider,
      width: target.width,
      height: target.height,
      policy: ResizeImagePolicy.fit,
    );
  }

  /// Applies a bounded decode sized for a [BoxFit.cover] destination.
  ///
  /// Unlike [ResizeImagePolicy.fit], this asks the codec for enough pixels on
  /// the cropped axis to avoid immediately upscaling the preview. Extremely
  /// wide or tall sources still respect the profile's longest-edge ceiling.
  static ImageProvider<Object> resizeProviderForCover(
    ImageProvider<Object> provider,
    RasterDecodeTarget target, {
    required RasterDecodeProfile profile,
  }) {
    return RasterCoverResizeImage(
      provider,
      target: target,
      maxLongestEdge: profile.maxLongestEdge,
    );
  }

  @visibleForTesting
  static RasterDecodeTarget coverDecodeTarget({
    required int intrinsicWidth,
    required int intrinsicHeight,
    required RasterDecodeTarget destination,
    required int maxLongestEdge,
  }) {
    final safeWidth = math.max(1, intrinsicWidth);
    final safeHeight = math.max(1, intrinsicHeight);
    final coverScale = math.max(
      destination.width / safeWidth,
      destination.height / safeHeight,
    );
    final boundedScale = math.min(1.0, coverScale);
    var width = math.max(1, (safeWidth * boundedScale).ceil());
    var height = math.max(1, (safeHeight * boundedScale).ceil());
    final longest = math.max(width, height);
    if (longest > maxLongestEdge) {
      final capScale = maxLongestEdge / longest;
      width = math.max(1, (width * capScale).floor());
      height = math.max(1, (height * capScale).floor());
    }
    return RasterDecodeTarget(width: width, height: height);
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

@immutable
final class RasterCoverResizeImageKey {
  const RasterCoverResizeImageKey({
    required this.providerCacheKey,
    required this.target,
    required this.maxLongestEdge,
  });

  final Object providerCacheKey;
  final RasterDecodeTarget target;
  final int maxLongestEdge;

  @override
  bool operator ==(Object other) {
    return other is RasterCoverResizeImageKey &&
        other.providerCacheKey == providerCacheKey &&
        other.target == target &&
        other.maxLongestEdge == maxLongestEdge;
  }

  @override
  int get hashCode => Object.hash(providerCacheKey, target, maxLongestEdge);
}

/// Aspect-preserving bounded decode wrapper for images rendered with cover.
@immutable
final class RasterCoverResizeImage
    extends ImageProvider<RasterCoverResizeImageKey> {
  const RasterCoverResizeImage(
    this.imageProvider, {
    required this.target,
    required this.maxLongestEdge,
  });

  final ImageProvider<Object> imageProvider;
  final RasterDecodeTarget target;
  final int maxLongestEdge;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is RasterCoverResizeImage &&
            other.imageProvider == imageProvider &&
            other.target == target &&
            other.maxLongestEdge == maxLongestEdge;
  }

  @override
  int get hashCode => Object.hash(imageProvider, target, maxLongestEdge);

  @visibleForTesting
  RasterDecodeTarget targetForIntrinsic(int width, int height) {
    return RasterMediaPolicy.coverDecodeTarget(
      intrinsicWidth: width,
      intrinsicHeight: height,
      destination: target,
      maxLongestEdge: maxLongestEdge,
    );
  }

  @override
  Future<RasterCoverResizeImageKey> obtainKey(
    ImageConfiguration configuration,
  ) async {
    return RasterCoverResizeImageKey(
      providerCacheKey: await imageProvider.obtainKey(configuration),
      target: target,
      maxLongestEdge: maxLongestEdge,
    );
  }

  @override
  ImageStreamCompleter loadImage(
    RasterCoverResizeImageKey key,
    ImageDecoderCallback decode,
  ) {
    Future<ui.Codec> decodeCover(
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) {
      assert(
        getTargetSize == null,
        'RasterCoverResizeImage cannot wrap another resizing provider.',
      );
      return decode(
        buffer,
        getTargetSize: (intrinsicWidth, intrinsicHeight) {
          final decodeTarget = targetForIntrinsic(
            intrinsicWidth,
            intrinsicHeight,
          );
          return ui.TargetImageSize(
            width: decodeTarget.width,
            height: decodeTarget.height,
          );
        },
      );
    }

    final completer = imageProvider.loadImage(
      key.providerCacheKey,
      decodeCover,
    );
    completer.addEphemeralErrorListener((exception, stackTrace) {
      DebugLogger.error(
        'cover-decode-failed',
        scope: 'media/raster',
        error: exception,
        stackTrace: stackTrace,
      );
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
    });
    return completer;
  }
}
