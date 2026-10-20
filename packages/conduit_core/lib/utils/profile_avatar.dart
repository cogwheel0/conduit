import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// The avatar Open WebUI assigns when a user has none. Its profile update
/// accepts this exact path (`validate_image_url`'s safe static paths).
const String kDefaultProfileImagePath = '/user.png';

/// Pixel size of a generated or uploaded profile avatar, as the Flutter
/// account page has always sent.
const int kProfileAvatarDimension = 250;

/// The profile image URL a form starts from: the stored value, or the
/// default avatar when there is none.
String normalizeProfileImageUrl(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return kDefaultProfileImagePath;
  return trimmed;
}

/// Up to two initials for [name]: the first two characters of a single
/// word, or the first character of each of the first two words; `U` for an
/// empty name. Characters are Unicode code points, so a surrogate pair is
/// never split.
String extractAvatarInitials(String name) {
  final words = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (words.isEmpty) return 'U';
  String take(String word, int count) =>
      String.fromCharCodes(word.runes.take(count));
  if (words.length == 1) return take(words.first, 2).toUpperCase();
  return '${take(words[0], 1)}${take(words[1], 1)}'.toUpperCase();
}

/// The hue (0-359) the initials avatar derives from [seed]; 215 for an
/// empty seed. Stable for a given seed within a Dart runtime.
double initialsAvatarHue(String seed) {
  final normalized = seed.trim().toLowerCase();
  if (normalized.isEmpty) return 215;
  return (normalized.hashCode.abs() % 360).toDouble();
}

/// The opaque ARGB colour of the initials avatar for [seed]: HSL with the
/// seed's hue, 55 % saturation and 52 % lightness.
int initialsAvatarColorValue(String seed) =>
    hslToArgb(initialsAvatarHue(seed), 0.55, 0.52);

/// Converts HSL ([hue] in degrees, [saturation] and [lightness] in 0-1) to
/// an opaque 0xAARRGGBB value, as Flutter's `HSLColor.toColor` does.
int hslToArgb(double hue, double saturation, double lightness) {
  final chroma = (1 - (2 * lightness - 1).abs()) * saturation;
  final h = (hue % 360) / 60;
  final secondary = chroma * (1 - ((h % 2) - 1).abs());
  final match = lightness - chroma / 2;
  final (r, g, b) = switch (h) {
    < 1 => (chroma, secondary, 0.0),
    < 2 => (secondary, chroma, 0.0),
    < 3 => (0.0, chroma, secondary),
    < 4 => (0.0, secondary, chroma),
    < 5 => (secondary, 0.0, chroma),
    _ => (chroma, 0.0, secondary),
  };
  int channel(double value) => ((value + match) * 255).round().clamp(0, 255);
  return 0xFF000000 | channel(r) << 16 | channel(g) << 8 | channel(b);
}

/// A PNG of [name]'s initials in white on a circle of its
/// [initialsAvatarColorValue], [dimension] pixels square, drawn without a
/// UI toolkit (pure Dart).
///
/// The glyphs come from the `image` package's Arial bitmap font, scaled up,
/// which covers ASCII only: initials it cannot draw leave a plain circle.
Uint8List encodeInitialsAvatarPng(
  String name, {
  int dimension = kProfileAvatarDimension,
}) {
  final canvas = img.Image(width: dimension, height: dimension, numChannels: 4);
  final argb = initialsAvatarColorValue(name);
  final radius = dimension ~/ 2;
  img.fillCircle(
    canvas,
    x: radius,
    y: radius,
    radius: radius - 1,
    color: img.ColorRgba8(
      argb >> 16 & 0xFF,
      argb >> 8 & 0xFF,
      argb & 0xFF,
      255,
    ),
    antialias: true,
  );

  final glyphs = _renderInitials(extractAvatarInitials(name));
  if (glyphs != null) {
    // The Flutter avatar sets 88 pt text on 250 px: cap height about 64 px.
    final targetHeight = dimension * 0.256;
    final maxWidth = dimension * 0.72;
    final scale = math.min(
      targetHeight / glyphs.height,
      maxWidth / glyphs.width,
    );
    final scaled = img.copyResize(
      glyphs,
      width: math.max(1, (glyphs.width * scale).round()),
      height: math.max(1, (glyphs.height * scale).round()),
      interpolation: img.Interpolation.cubic,
    );
    img.compositeImage(
      canvas,
      scaled,
      dstX: (dimension - scaled.width) ~/ 2,
      dstY: (dimension - scaled.height) ~/ 2,
    );
  }
  return img.encodePng(canvas);
}

/// [encodeInitialsAvatarPng] as a `data:image/png` URL, the form Open WebUI's
/// profile update takes (`validate_image_url` accepts png, jpeg, gif and
/// webp data URIs; SVG is refused).
String initialsAvatarDataUrl(
  String name, {
  int dimension = kProfileAvatarDimension,
}) =>
    'data:image/png;base64,'
    '${base64Encode(encodeInitialsAvatarPng(name, dimension: dimension))}';

/// A profile image data URL from picked image bytes (JPEG, PNG, GIF, WebP,
/// BMP or TIFF), scaled to fit [maxDimension] and re-encoded: JPEG at
/// [jpegQuality] for an opaque image (a photo stays tens of kilobytes, not
/// a hundred as PNG), PNG when it has an alpha channel. Null when the bytes
/// cannot be decoded (HEIC, for one).
String? profileImageDataUrlFromBytes(
  Uint8List bytes, {
  int maxDimension = kProfileAvatarDimension,
  int jpegQuality = 85,
}) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    // The decoders throw on truncated or foreign data instead of answering
    // null (the PSD sniffer reads past a short buffer).
    decoded = null;
  }
  if (decoded == null || decoded.width == 0 || decoded.height == 0) {
    return null;
  }
  var image = img.bakeOrientation(decoded);
  if (image.width > maxDimension || image.height > maxDimension) {
    image = image.width >= image.height
        ? img.copyResize(
            image,
            width: maxDimension,
            interpolation: img.Interpolation.cubic,
          )
        : img.copyResize(
            image,
            height: maxDimension,
            interpolation: img.Interpolation.cubic,
          );
  }
  if (image.hasAlpha) {
    return 'data:image/png;base64,${base64Encode(img.encodePng(image))}';
  }
  final jpeg = img.encodeJpg(image, quality: jpegQuality);
  return 'data:image/jpeg;base64,${base64Encode(jpeg)}';
}

/// The initials in white, cropped to their inked pixels, or null when the
/// font has none of them.
img.Image? _renderInitials(String initials) {
  final font = img.arial48;
  var width = 0;
  for (final unit in initials.codeUnits) {
    final character = font.characters[unit];
    if (character != null) width += character.xAdvance;
  }
  if (width == 0) return null;
  final layer = img.Image(
    width: width + 4,
    height: font.lineHeight + 4,
    numChannels: 4,
  );
  img.drawString(
    layer,
    initials,
    font: font,
    x: 2,
    y: 2,
    color: img.ColorRgba8(255, 255, 255, 255),
  );

  var left = layer.width, top = layer.height, right = -1, bottom = -1;
  for (final pixel in layer) {
    if (pixel.a == 0) continue;
    left = math.min(left, pixel.x);
    right = math.max(right, pixel.x);
    top = math.min(top, pixel.y);
    bottom = math.max(bottom, pixel.y);
  }
  if (right < 0) return null;
  return img.copyCrop(
    layer,
    x: left,
    y: top,
    width: right - left + 1,
    height: bottom - top + 1,
  );
}
