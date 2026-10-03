import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import 'package:conduit_core/features/workspace/services/workspace_model_avatar_bounds.dart';

Uint8List _png(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(10, 120, 200));
  return img.encodePng(image);
}

Uint8List _jpg(int width, int height) =>
    img.encodeJpg(img.Image(width: width, height: height));

void main() {
  test('targetSize keeps images that fit and scales the longest side', () {
    check(WorkspaceModelAvatarBounds.targetSize(512, 300)).isNull();
    check(WorkspaceModelAvatarBounds.targetSize(1024, 600))
        .equals((width: 512, height: 300));
    check(WorkspaceModelAvatarBounds.targetSize(300, 2048))
        .equals((width: 75, height: 512));
    check(WorkspaceModelAvatarBounds.targetSize(5000, 2))
        .equals((width: 512, height: 1));
  });

  test('an image that fits comes back identical', () async {
    final bytes = _jpg(200, 100);

    final bounded = await WorkspaceModelAvatarBounds.bound(bytes);

    check(identical(bounded, bytes)).isTrue();
  });

  test('a large image is downscaled to a PNG', () async {
    final bounded = await WorkspaceModelAvatarBounds.bound(_jpg(1600, 900));

    final decoded = img.decodePng(bounded);
    check(decoded).isNotNull();
    check(decoded!.width).equals(512);
    check(decoded.height).equals(288);
  });

  test('undecodable bytes are kept without a platform decoder', () async {
    final bytes = Uint8List.fromList(utf8.encode('not an image'));

    check(identical(await WorkspaceModelAvatarBounds.bound(bytes), bytes))
        .isTrue();
  });

  test(
    'undecodable bytes go to the platform decoder when there is one',
    () async {
      final bytes = Uint8List.fromList(utf8.encode('heic stand-in'));
      final resized = _png(4, 4);
      int? askedEdge;

      final bounded = await WorkspaceModelAvatarBounds.bound(
        bytes,
        platformResize: (input, maxEdge) async {
          askedEdge = maxEdge;
          return resized;
        },
      );

      check(bounded).deepEquals(resized);
      check(askedEdge).equals(WorkspaceModelAvatarBounds.maxEdge);
    },
  );

  test('a failing platform decoder keeps the original bytes', () async {
    final bytes = Uint8List.fromList(utf8.encode('heic stand-in'));

    final bounded = await WorkspaceModelAvatarBounds.bound(
      bytes,
      platformResize: (_, _) async => throw StateError('decode failed'),
    );

    check(identical(bounded, bytes)).isTrue();
  });

  test(
    'prepare labels kept files by extension and resized ones as PNG',
    () async {
      final small = await WorkspaceModelAvatarBounds.prepare(
        _jpg(64, 64),
        extension: 'JPG',
      );
      check(small.mimeType).equals('image/jpeg');
      check(small.toDataUrl()).startsWith('data:image/jpeg;base64,');

      final large = await WorkspaceModelAvatarBounds.prepare(
        _jpg(1024, 1024),
        extension: 'jpg',
      );
      check(large.mimeType).equals('image/png');
    },
  );

  test('mimeTypeForExtension names HEIC and falls back to PNG', () {
    check(WorkspaceModelAvatarBounds.mimeTypeForExtension('webp'))
        .equals('image/webp');
    check(WorkspaceModelAvatarBounds.mimeTypeForExtension('gif'))
        .equals('image/gif');
    check(WorkspaceModelAvatarBounds.mimeTypeForExtension('heic'))
        .equals('image/heic');
    check(WorkspaceModelAvatarBounds.mimeTypeForExtension('tiff'))
        .equals('image/png');
    check(WorkspaceModelAvatarBounds.mimeTypeForExtension(null))
        .equals('image/png');
  });

  group('oversized and animated images', () {
    /// A PNG whose header declares [width] x [height] over a few real pixels:
    /// decoding it for real would try to allocate the declared size.
    Uint8List declaredSize(int width, int height) {
      final bytes = Uint8List.fromList(_png(4, 4));
      final header = ByteData.sublistView(bytes);
      header.setUint32(16, width);
      header.setUint32(20, height);
      return bytes;
    }

    test('an image declaring too many pixels is never decoded', () async {
      final bytes = declaredSize(20000, 20000);
      int? askedEdge;

      final bounded = await WorkspaceModelAvatarBounds.bound(
        bytes,
        platformResize: (given, edge) async {
          askedEdge = edge;
          return _png(8, 8);
        },
      );

      check(askedEdge).equals(WorkspaceModelAvatarBounds.maxEdge);
      check(img.decodePng(bounded)!.width).equals(8);
    });

    test('an oversized image with no host resizer is kept as it is', () async {
      final bytes = declaredSize(20000, 20000);

      check(identical(await WorkspaceModelAvatarBounds.bound(bytes), bytes))
          .isTrue();
    });

    test('an animated image that fits is returned without decoding', () async {
      final animation = img.Image(width: 64, height: 64);
      animation.addFrame(img.Image(width: 64, height: 64));
      animation.addFrame(img.Image(width: 64, height: 64));
      final bytes = img.encodeGif(animation);

      check(identical(await WorkspaceModelAvatarBounds.bound(bytes), bytes))
          .isTrue();
    });
  });

  group('mime type of an unchanged image', () {
    Uint8List ftyp(String brand) => Uint8List.fromList([
      0, 0, 0, 24, ...'ftyp'.codeUnits, ...brand.codeUnits, 0, 0, 0, 0, //
      ...'mif1heic'.codeUnits,
    ]);

    test('is read from the bytes before the extension', () {
      check(WorkspaceModelAvatarBounds.mimeTypeForBytes(_png(4, 4)))
          .equals('image/png');
      check(WorkspaceModelAvatarBounds.mimeTypeForBytes(_jpg(4, 4)))
          .equals('image/jpeg');
      check(WorkspaceModelAvatarBounds.mimeTypeForBytes(ftyp('heic')))
          .equals('image/heic');
      check(WorkspaceModelAvatarBounds.mimeTypeForBytes(ftyp('mif1')))
          .equals('image/heif');
      check(WorkspaceModelAvatarBounds.mimeTypeForBytes(ftyp('avif')))
          .equals('image/avif');
      check(
        WorkspaceModelAvatarBounds.mimeTypeForBytes(
          Uint8List.fromList(utf8.encode('plain text')),
        ),
      ).isNull();
    });

    test('a kept HEIC is not labelled PNG', () async {
      final heic = ftyp('heic');

      final avatar = await WorkspaceModelAvatarBounds.prepare(
        heic,
        extension: 'png',
      );

      check(avatar.mimeType).equals('image/heic');
      check(avatar.toDataUrl()).startsWith('data:image/heic;base64,');
    });

    test('falls back to the extension for bytes it cannot place', () async {
      final bytes = Uint8List.fromList(utf8.encode('unknown'));

      final avatar = await WorkspaceModelAvatarBounds.prepare(
        bytes,
        extension: 'webp',
      );

      check(avatar.mimeType).equals('image/webp');
    });
  });
}
