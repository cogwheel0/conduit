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

  test('mimeTypeForExtension falls back to PNG', () {
    check(WorkspaceModelAvatarBounds.mimeTypeForExtension('webp'))
        .equals('image/webp');
    check(WorkspaceModelAvatarBounds.mimeTypeForExtension('gif'))
        .equals('image/gif');
    check(WorkspaceModelAvatarBounds.mimeTypeForExtension('heic'))
        .equals('image/png');
    check(WorkspaceModelAvatarBounds.mimeTypeForExtension(null))
        .equals('image/png');
  });
}
