import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A host's own decoder for formats `package:image` cannot read (HEIC on
/// iOS), and for images too large to scan here. Returns PNG bytes no larger
/// than [maxEdge] on either side; returns [bytes] itself when the image
/// already fits and needs no resize; and null when it cannot decode [bytes]
/// either.
typedef WorkspaceAvatarPlatformResize = Future<Uint8List?> Function(
  Uint8List bytes,
  int maxEdge,
);

/// An image that could not be bounded: it is too large to scan here and the
/// host could not resize it either, so embedding it would bloat the model.
final class WorkspaceAvatarTooLargeException implements Exception {
  const WorkspaceAvatarTooLargeException();

  @override
  String toString() => 'The image is too large to use as an avatar.';
}

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

  /// The largest file this decoder will scan. A decoder reads a file's own
  /// structure before it decodes any pixels (a GIF lists every frame), so a
  /// crafted file of many tiny frames could cost far more memory than its
  /// size or canvas suggests; larger files go to the host's resizer.
  static const int maxInputBytes = 16 * 1024 * 1024;

  /// The most a file this decoder cannot read (an unknown format the host
  /// could not resize either) is kept as it is. Past it the avatar is
  /// rejected rather than embedded at full size.
  static const int maxKeptBytes = 1024 * 1024;

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

  /// Returns [bytes] unchanged when the image fits, or a PNG downscaled so its
  /// longest side is [maxEdge].
  ///
  /// A format `package:image` cannot decode, or an image too large to scan
  /// here, goes to [platformResize] when the host has one. If that cannot
  /// bound it either, a file of at most [maxKeptBytes] in an unknown format is
  /// kept as it is; anything larger, or an image too large to scan, throws
  /// [WorkspaceAvatarTooLargeException].
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
        // The host returns the bytes themselves when the image already fits,
        // which is a valid avatar in a format only it can read.
        final resized = await _hostResize(bytes, platformResize);
        if (resized != null) return resized;
        if (bytes.length > maxKeptBytes) {
          throw const WorkspaceAvatarTooLargeException();
        }
        return bytes;
      case _TooLarge():
        // Too large to embed as it is, so only a smaller image from the host
        // will do, not the original handed back as "fits".
        final resized = await _hostResize(bytes, platformResize);
        if (resized != null && !identical(resized, bytes)) return resized;
        throw const WorkspaceAvatarTooLargeException();
    }
  }

  static Future<Uint8List?> _hostResize(
    Uint8List bytes,
    WorkspaceAvatarPlatformResize? platformResize,
  ) async {
    if (platformResize == null) return null;
    try {
      return await platformResize(bytes, maxEdge);
    } catch (_) {
      return null;
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

  /// The canvas of a GIF, read from its logical screen descriptor (the seven
  /// bytes after the six-byte `GIF87a` or `GIF89a` signature) without
  /// scanning the frames, which is what a decoder's own header pass would do.
  /// Null for anything that is not a GIF with a complete descriptor.
  static ({int width, int height})? _gifCanvasSize(Uint8List bytes) {
    if (bytes.length < 13) return null;
    final signature = String.fromCharCodes(bytes.sublist(0, 6));
    if (signature != 'GIF87a' && signature != 'GIF89a') return null;
    return (width: bytes[6] | bytes[7] << 8, height: bytes[8] | bytes[9] << 8);
  }

  static ({int width, int height})? _declaredSize(Uint8List bytes) {
    final info = img.findDecoderForData(bytes)?.startDecode(bytes);
    return info == null ? null : (width: info.width, height: info.height);
  }

  static _BoundResult _boundSync(Uint8List bytes) {
    // The header gives the size without decoding any pixels, so an image that
    // already fits is never decoded (an animated one would decode every
    // frame), and an oversized one is refused before it can allocate.
    // Nothing over the limit is scanned, however its header reads.
    if (bytes.length > maxInputBytes) return const _TooLarge();
    try {
      final size = _gifCanvasSize(bytes) ?? _declaredSize(bytes);
      if (size != null) {
        if (targetSize(size.width, size.height) == null) return const _Fits();
        if (size.width * size.height > maxDecodedPixels) {
          return const _TooLarge();
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
    // swapped, and the target size must be worked out for what is shown. Only
    // when there is a rotation to apply, since baking copies the whole image.
    final orientation = decoded.exif.imageIfd.orientation;
    if (orientation != null && orientation != 1) {
      decoded = img.bakeOrientation(decoded);
    }
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

final class _TooLarge extends _BoundResult {
  const _TooLarge();
}

final class _Undecodable extends _BoundResult {
  const _Undecodable();
}

final class _Resized extends _BoundResult {
  const _Resized(this.png);

  final Uint8List png;
}
