import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/services/image_viewer_files.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(List<int> head) =>
    Uint8List.fromList([...head, ...List.filled(16, 0)]);

void main() {
  group('detectImageFileType', () {
    test('recognizes common image signatures', () {
      check(detectImageFileType(_bytes([0x89, 0x50, 0x4E, 0x47])))
          .equals(const ImageFileType('png', 'image/png'));
      check(detectImageFileType(_bytes([0xFF, 0xD8, 0xFF, 0xE0])))
          .equals(const ImageFileType('jpg', 'image/jpeg'));
      check(detectImageFileType(_bytes(ascii.encode('GIF89a'))))
          .equals(const ImageFileType('gif', 'image/gif'));
      check(
        detectImageFileType(_bytes(ascii.encode('RIFF\x00\x00\x00\x00WEBP'))),
      ).equals(const ImageFileType('webp', 'image/webp'));
      check(
        detectImageFileType(_bytes(ascii.encode('\x00\x00\x00\x18ftypheic'))),
      ).equals(const ImageFileType('heic', 'image/heic'));
      check(
        detectImageFileType(_bytes(ascii.encode('\x00\x00\x00\x18ftypavif'))),
      ).equals(const ImageFileType('avif', 'image/avif'));
      // AVIF with the generic `mif1` major brand lists `avif` as compatible.
      check(
        detectImageFileType(
          _bytes(
            ascii.encode('\x00\x00\x00\x1cftypmif1\x00\x00\x00\x00avifmiaf'),
          ),
        ),
      ).equals(const ImageFileType('avif', 'image/avif'));
      check(
        detectImageFileType(
          _bytes(ascii.encode('\x00\x00\x00\x18ftypmif1\x00\x00\x00\x00heic')),
        ),
      ).equals(const ImageFileType('heic', 'image/heic'));
      check(
        detectImageFileType(
          Uint8List.fromList(utf8.encode('<svg xmlns="x"></svg>')),
        ).isSvg,
      ).isTrue();
    });

    test('content signature wins over a mislabeled content type', () {
      check(
        detectImageFileType(
          _bytes([0xFF, 0xD8, 0xFF, 0xE0]),
          contentType: 'image/png',
          sourceUrl: 'https://example.test/image.png',
        ),
      ).equals(const ImageFileType('jpg', 'image/jpeg'));
    });

    test('falls back to content type, data URL, then URL extension', () {
      final unknown = _bytes([1, 2, 3, 4]);
      check(detectImageFileType(unknown, contentType: 'image/webp; charset=x'))
          .equals(const ImageFileType('webp', 'image/webp'));
      check(
        detectImageFileType(unknown, contentType: 'data:image/jpeg;base64,AA'),
      ).equals(const ImageFileType('jpg', 'image/jpeg'));
      check(
        detectImageFileType(
          unknown,
          contentType: 'application/octet-stream',
          sourceUrl: 'https://example.test/a/b.GIF?sig=1',
        ),
      ).equals(const ImageFileType('gif', 'image/gif'));
      check(detectImageFileType(unknown))
          .equals(const ImageFileType('png', 'image/png'));
    });
  });

  group('purgeStaleImageSessions', () {
    late Directory base;
    setUp(() => base = Directory.systemTemp.createTempSync('image_sessions'));
    tearDown(() => base.deleteSync(recursive: true));

    test('deletes sessions once they pass the retention period', () async {
      final share = Directory('${base.path}/share/a')
        ..createSync(recursive: true);
      final viewer = Directory('${base.path}/viewer/b')
        ..createSync(recursive: true);
      final modified = share.statSync().modified;

      await purgeStaleImageSessions(
        base,
        now: modified.add(imageSessionRetention - const Duration(minutes: 1)),
      );
      check(share.existsSync()).isTrue();
      check(viewer.existsSync()).isTrue();

      await purgeStaleImageSessions(
        base,
        now: modified.add(imageSessionRetention + const Duration(minutes: 1)),
      );
      check(share.existsSync()).isFalse();
      check(viewer.existsSync()).isFalse();
    });
  });
}
