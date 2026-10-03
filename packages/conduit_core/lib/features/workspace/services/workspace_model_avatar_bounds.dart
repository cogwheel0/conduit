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

  /// The most pixels this decoder will allocate for one image. A compressed
  /// file can declare far more than its size suggests, and decoding is one
  /// allocation of width x height x 4 bytes; larger images go to the host's
  /// resizer, which decodes straight to the bounded size.
  static const int maxDecodedPixels = 64 * 1000 * 1000;

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
        'heic' => 'image/heic',
        'heif' => 'image/heif',
        'avif' => 'image/avif',
        'bmp' => 'image/bmp',
        'tif' || 'tiff' => 'image/tiff',
        _ => 'image/png',
      };

  /// The mime type [bytes] announce in their first bytes, or null when they
  /// match no format this knows. Trusted over a file extension, which the
  /// picker can get wrong.
  static String? mimeTypeForBytes(Uint8List bytes) {
    bool startsWith(List<int> prefix, [int offset = 0]) {
      if (bytes.length < offset + prefix.length) return false;
      for (var i = 0; i < prefix.length; i++) {
        if (bytes[offset + i] != prefix[i]) return false;
      }
      return true;
    }

    String ascii(int start, int end) => bytes.length < end
        ? ''
        : String.fromCharCodes(bytes.sublist(start, end));

    if (startsWith(const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
    if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
    if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
    if (startsWith(const [0x42, 0x4D])) return 'image/bmp';
    if (startsWith(const [0x49, 0x49, 0x2A, 0x00]) ||
        startsWith(const [0x4D, 0x4D, 0x00, 0x2A])) {
      return 'image/tiff';
    }
    if (ascii(0, 4) == 'RIFF' && ascii(8, 12) == 'WEBP') return 'image/webp';
    if (ascii(4, 8) == 'ftyp') {
      // The major brand can be the generic `mif1` for an AVIF or HEIC file,
      // so every brand the box lists counts, the specific ones first.
      final boxSize = bytes.length < 8
          ? 0
          : (bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]);
      final end = boxSize < 16 || boxSize > bytes.length
          ? (bytes.length < 16 ? bytes.length : 16)
          : boxSize;
      final brands = <String>{
        ascii(8, 12),
        for (var at = 16; at + 4 <= end; at += 4) ascii(at, at + 4),
      };
      if (brands.any((brand) => brand == 'avif' || brand == 'avis')) {
        return 'image/avif';
      }
      if (brands.any(
        (brand) => const {
          'heic',
          'heix',
          'heim',
          'heis',
          'hevc',
          'hevx',
        }.contains(brand),
      )) {
        return 'image/heic';
      }
      if (brands.any((brand) => brand == 'mif1' || brand == 'msf1')) {
        return 'image/heif';
      }
      return null;
    }
    return null;
  }

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
  /// mime type its bytes announce, else that of its [extension].
  static Future<WorkspaceModelAvatarImage> prepare(
    Uint8List bytes, {
    String? extension,
    WorkspaceAvatarPlatformResize? platformResize,
  }) async {
    final bounded = await bound(bytes, platformResize: platformResize);
    return WorkspaceModelAvatarImage(
      bytes: bounded,
      mimeType: identical(bounded, bytes)
          ? mimeTypeForBytes(bytes) ?? mimeTypeForExtension(extension)
          : 'image/png',
    );
  }

  static _BoundResult _boundSync(Uint8List bytes) {
    // The header gives the size without decoding any pixels, so an image that
    // already fits is never decoded (an animated one would decode every
    // frame), and an oversized one is refused before it can allocate.
    try {
      final info = img.findDecoderForData(bytes)?.startDecode(bytes);
      if (info != null) {
        if (targetSize(info.width, info.height) == null) return const _Fits();
        if (info.width * info.height > maxDecodedPixels) {
          return const _Undecodable();
        }
      }
    } catch (_) {
      return const _Undecodable();
    }

    img.Image? decoded;
    try {
      // Only the first frame: an animated image keeps just that one, so
      // decoding the rest would be memory spent for nothing.
      decoded = img.decodeImage(bytes, frame: 0);
    } catch (_) {
      return const _Undecodable();
    }
    if (decoded == null) return const _Undecodable();
    // An animated image keeps its first frame, as the platform decoders do.
    if (decoded.numFrames > 1) decoded = decoded.getFrame(0);
    // Apply the EXIF orientation first: a photo stored sideways has its sides
    // swapped, and the target size must be worked out for what is shown.
    decoded = img.bakeOrientation(decoded);
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
