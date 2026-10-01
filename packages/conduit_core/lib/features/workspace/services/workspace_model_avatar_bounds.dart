import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A host's own decoder for formats `package:image` cannot read (HEIC on
/// iOS). Returns PNG bytes no larger than [maxEdge] on either side, or null
/// when it cannot decode [bytes] either.
typedef WorkspaceAvatarPlatformResize = Future<Uint8List?> Function(
  Uint8List bytes,
  int maxEdge,
);

/// An avatar ready to embed in a model's `meta.profile_image_url`.
final class WorkspaceModelAvatarImage {
  const WorkspaceModelAvatarImage({
    required this.bytes,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String mimeType;

  String toDataUrl() => 'data:$mimeType;base64,${base64Encode(bytes)}';
}

/// Bounds workspace-model avatars before they are embedded in model JSON, so
/// a large source image does not bloat the draft or the server's model row.
///
/// Pure Dart (`package:image`, decoded on a background isolate), so it needs
/// no widget raster path and is tested without Flutter.
abstract final class WorkspaceModelAvatarBounds {
  static const int maxEdge = 512;

  /// The size an image of [width] x [height] is scaled to, or null when its
  /// longest side already fits [maxEdge]. Each side is at least 1.
  static ({int width, int height})? targetSize(int width, int height) {
    final longest = width > height ? width : height;
    if (longest <= maxEdge) return null;
    final scale = maxEdge / longest;
    int side(int value) {
      final scaled = (value * scale).round();
      return scaled < 1 ? 1 : scaled;
    }

    return (width: side(width), height: side(height));
  }

  /// The mime type for a picked file kept as it is, from its extension.
  static String mimeTypeForExtension(String? extension) =>
      switch ((extension ?? 'png').toLowerCase()) {
        'jpg' || 'jpeg' => 'image/jpeg',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        _ => 'image/png',
      };

  /// Returns [bytes] unchanged when the image fits or cannot be decoded, or
  /// a PNG downscaled so its longest side is [maxEdge].
  ///
  /// A format `package:image` cannot decode goes to [platformResize] when the
  /// host has one; without it such a file is kept as it is.
  static Future<Uint8List> bound(
    Uint8List bytes, {
    WorkspaceAvatarPlatformResize? platformResize,
  }) async {
    final result = await Isolate.run(() => _boundSync(bytes));
    switch (result) {
      case _Fits():
        return bytes;
      case _Resized(:final png):
        return png;
      case _Undecodable():
        if (platformResize == null) return bytes;
        try {
          return await platformResize(bytes, maxEdge) ?? bytes;
        } catch (_) {
          return bytes;
        }
    }
  }

  /// [bound], labelled: a downscaled image is PNG; an unchanged one keeps the
  /// mime type of its [extension].
  static Future<WorkspaceModelAvatarImage> prepare(
    Uint8List bytes, {
    String? extension,
    WorkspaceAvatarPlatformResize? platformResize,
  }) async {
    final bounded = await bound(bytes, platformResize: platformResize);
    return WorkspaceModelAvatarImage(
      bytes: bounded,
      mimeType: identical(bounded, bytes)
          ? mimeTypeForExtension(extension)
          : 'image/png',
    );
  }

  static _BoundResult _boundSync(Uint8List bytes) {
    img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } catch (_) {
      return const _Undecodable();
    }
    if (decoded == null) return const _Undecodable();
    // An animated image keeps its first frame, as the platform decoders do.
    if (decoded.numFrames > 1) decoded = decoded.getFrame(0);
    final target = targetSize(decoded.width, decoded.height);
    if (target == null) return const _Fits();
    try {
      final resized = img.copyResize(
        decoded,
        width: target.width,
        height: target.height,
        interpolation: img.Interpolation.average,
      );
      return _Resized(img.encodePng(resized));
    } catch (_) {
      return const _Fits();
    }
  }
}

sealed class _BoundResult {
  const _BoundResult();
}

final class _Fits extends _BoundResult {
  const _Fits();
}

final class _Undecodable extends _BoundResult {
  const _Undecodable();
}

final class _Resized extends _BoundResult {
  const _Resized(this.png);

  final Uint8List png;
}
