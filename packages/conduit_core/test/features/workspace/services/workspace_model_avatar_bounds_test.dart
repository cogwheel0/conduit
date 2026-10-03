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

/// CRC-32 as PNG chunks use it.
int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
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
        .equals('image/tiff');
    check(WorkspaceModelAvatarBounds.mimeTypeForExtension('TIF'))
        .equals('image/tiff');
    check(WorkspaceModelAvatarBounds.mimeTypeForExtension('bmp'))
        .equals('image/bmp');
    check(WorkspaceModelAvatarBounds.mimeTypeForExtension('xyz'))
        .equals('image/png');
    check(WorkspaceModelAvatarBounds.mimeTypeForExtension(null))
        .equals('image/png');
  });

  test('an EXIF-rotated photo is bounded as it is shown', () async {
    // 1600x900 stored sideways: shown as 900 wide and 1600 tall.
    final photo = img.Image(width: 1600, height: 900);
    img.fill(photo, color: img.ColorRgb8(10, 120, 200));
    photo.exif.imageIfd.orientation = 6;
    final bytes = img.encodeJpg(photo);

    final bounded = await WorkspaceModelAvatarBounds.bound(bytes);

    final decoded = img.decodePng(bounded)!;
    check(decoded.width).equals(288);
    check(decoded.height).equals(512);
  });

  group('oversized and animated images', () {
    /// A PNG whose header declares [width] x [height] over a few real pixels:
    /// decoding it for real would try to allocate the declared size.
    Uint8List declaredSize(int width, int height) {
      final bytes = Uint8List.fromList(_png(4, 4));
      final header = ByteData.sublistView(bytes);
      header.setUint32(16, width);
      header.setUint32(20, height);
      // A decoder rejects an IHDR whose checksum no longer matches, which
      // would make this look undecodable instead of oversized.
      header.setUint32(29, _crc32(bytes.sublist(12, 29)));
      return bytes;
    }

    test('the oversized fixture really declares its size to the decoder', () {
      final info = img
          .findDecoderForData(declaredSize(20000, 20000))!
          .startDecode(declaredSize(20000, 20000))!;

      check(info.width).equals(20000);
      check(info.height).equals(20000);
    });

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

    test('an oversized image no host can resize is rejected', () async {
      final bytes = declaredSize(20000, 20000);

      await check(WorkspaceModelAvatarBounds.bound(bytes))
          .throws<WorkspaceAvatarTooLargeException>();
      await check(
        WorkspaceModelAvatarBounds.bound(
          bytes,
          platformResize: (_, _) async => null,
        ),
      ).throws<WorkspaceAvatarTooLargeException>();
      await check(
        WorkspaceModelAvatarBounds.bound(
          bytes,
          platformResize: (_, _) async => throw StateError('codec failed'),
        ),
      ).throws<WorkspaceAvatarTooLargeException>();
    });

    test(
      'an oversized animated image is bounded from its first frame',
      () async {
        final animation = img.Image(width: 900, height: 450);
        img.fill(animation, color: img.ColorRgb8(200, 30, 30));
        for (var i = 0; i < 2; i++) {
          final frame = img.Image(width: 900, height: 450);
          img.fill(frame, color: img.ColorRgb8(30, 30, 200));
          animation.addFrame(frame);
        }

        final bounded = await WorkspaceModelAvatarBounds.bound(
          img.encodeGif(animation),
        );

        final decoded = img.decodePng(bounded)!;
        check(decoded.width).equals(512);
        check(decoded.height).equals(256);
        check(decoded.numFrames).equals(1);
      },
    );

    test(
      'a GIF is sized from its header, without scanning its frames',
      () async {
        // Only the header of a 64x64 GIF: a decoder that scans the frames would
        // fail on it and hand it to the host resizer, which must not happen.
        final header = Uint8List.fromList([
          ...'GIF89a'.codeUnits,
          64, 0, 64, 0, // logical screen: 64 x 64
          0, 0, 0,
        ]);
        var asked = false;

        final bounded = await WorkspaceModelAvatarBounds.bound(
          header,
          platformResize: (_, _) async {
            asked = true;
            return null;
          },
        );

        check(asked).isFalse();
        check(identical(bounded, header)).isTrue();
      },
    );

    test('a file over the scan limit goes to the host resizer', () async {
      final big = Uint8List(WorkspaceModelAvatarBounds.maxInputBytes + 1);
      final resized = _png(8, 8);
      int? askedEdge;

      final bounded = await WorkspaceModelAvatarBounds.bound(
        big,
        platformResize: (_, edge) async {
          askedEdge = edge;
          return resized;
        },
      );

      check(askedEdge).equals(WorkspaceModelAvatarBounds.maxEdge);
      check(identical(bounded, resized)).isTrue();
    });

    test(
      'a file over the scan limit that no host resizes is rejected',
      () async {
        final big = Uint8List(WorkspaceModelAvatarBounds.maxInputBytes + 1);

        await check(WorkspaceModelAvatarBounds.bound(big))
            .throws<WorkspaceAvatarTooLargeException>();
      },
    );

    test('a GIF whose canvas fits is kept however large the file is', () async {
      final big = Uint8List(WorkspaceModelAvatarBounds.maxInputBytes + 1)
        ..setAll(0, [...'GIF89a'.codeUnits, 64, 0, 64, 0]);
      var asked = false;

      final bounded = await WorkspaceModelAvatarBounds.bound(
        big,
        platformResize: (_, _) async {
          asked = true;
          return null;
        },
      );

      check(asked).isFalse();
      check(identical(bounded, big)).isTrue();
    });

    test('an unreadable file is kept only while it is small', () async {
      final small = Uint8List.fromList(utf8.encode('heic stand-in'));
      // Text, not zeros: a lenient decoder reads a run of zeros as an empty
      // image.
      final large = Uint8List.fromList(
        List.filled(WorkspaceModelAvatarBounds.maxKeptBytes + 1, 0x78),
      );

      check(identical(await WorkspaceModelAvatarBounds.bound(small), small))
          .isTrue();
      await check(WorkspaceModelAvatarBounds.bound(large))
          .throws<WorkspaceAvatarTooLargeException>();
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
      0, 0, 0, 16, ...'ftyp'.codeUnits, ...brand.codeUnits, 0, 0, 0, 0, //
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
          Uint8List.fromList([0x42, 0x4D, 0, 0]),
        ),
      ).equals('image/bmp');
      check(
        WorkspaceModelAvatarBounds.mimeTypeForBytes(
          Uint8List.fromList([0x49, 0x49, 0x2A, 0x00]),
        ),
      ).equals('image/tiff');
      check(
        WorkspaceModelAvatarBounds.mimeTypeForBytes(
          Uint8List.fromList([0x4D, 0x4D, 0x00, 0x2A]),
        ),
      ).equals('image/tiff');
      check(
        WorkspaceModelAvatarBounds.mimeTypeForBytes(
          Uint8List.fromList(utf8.encode('plain text')),
        ),
      ).isNull();
    });

    test('compatible brands decide when the major brand is generic', () {
      Uint8List box(String major, List<String> compatible) {
        final body = [
          ...'ftyp'.codeUnits,
          ...major.codeUnits,
          0, 0, 0, 0, //
          for (final brand in compatible) ...brand.codeUnits,
        ];
        final size = body.length + 4;
        return Uint8List.fromList([0, 0, 0, size, ...body]);
      }

      check(
        WorkspaceModelAvatarBounds.mimeTypeForBytes(
          box('mif1', ['mif1', 'avif']),
        ),
      ).equals('image/avif');
      check(
        WorkspaceModelAvatarBounds.mimeTypeForBytes(
          box('mif1', ['mif1', 'heic']),
        ),
      ).equals('image/heic');
      check(WorkspaceModelAvatarBounds.mimeTypeForBytes(box('mif1', ['mif1'])))
          .equals('image/heif');
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
