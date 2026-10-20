import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/utils/image_attachment_sources.dart';
import 'package:test/test.dart';

void main() {
  group('imageAttachmentDataIsSvg', () {
    test('matches an svg data URL in any case', () {
      check(imageAttachmentDataIsSvg('data:image/svg+xml;base64,PHN2Zz4='))
          .isTrue();
      check(imageAttachmentDataIsSvg('DATA:IMAGE/SVG+XML,<svg/>')).isTrue();
    });

    test('rejects raster data URLs and plain URLs', () {
      check(imageAttachmentDataIsSvg('data:image/png;base64,AAAA')).isFalse();
      check(imageAttachmentDataIsSvg('https://example.test/a.svg')).isFalse();
    });
  });

  group('imageAttachmentUrlIsSvg', () {
    test('uses the path, not the fragment', () {
      check(imageAttachmentUrlIsSvg('https://example.test/icon.svg')).isTrue();
      check(
        imageAttachmentUrlIsSvg('https://example.test/icon.svg#dark-symbol'),
      ).isTrue();
      check(
        imageAttachmentUrlIsSvg('https://example.test/icon.png#fallback.svg'),
      ).isFalse();
    });

    test('accepts an svg content type in the query', () {
      check(
        imageAttachmentUrlIsSvg(
          'https://example.test/render?type=image/svg+xml',
        ),
      ).isTrue();
      check(
        imageAttachmentUrlIsSvg(
          'https://example.test/render?type=image%2Fsvg%2Bxml',
        ),
      ).isTrue();
    });

    test('rejects other images', () {
      check(imageAttachmentUrlIsSvg('https://example.test/a.png')).isFalse();
    });
  });

  group('imageAttachmentBytesAreSvg', () {
    Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

    test('finds the svg tag in the first kilobyte', () {
      check(
        imageAttachmentBytesAreSvg(
          bytes(
            '<?xml version="1.0"?>\n<SVG xmlns="http://www.w3.org/2000/svg"/>',
          ),
        ),
      ).isTrue();
    });

    test('ignores a tag past the first kilobyte', () {
      check(imageAttachmentBytesAreSvg(bytes('${' ' * 1100}<svg/>'))).isFalse();
    });

    test('rejects binary image data and empty input', () {
      check(
        imageAttachmentBytesAreSvg(
          Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0xff, 0xfe]),
        ),
      ).isFalse();
      check(imageAttachmentBytesAreSvg(Uint8List(0))).isFalse();
    });

    test('needs a markup document, not metadata (issue #768)', () {
      // A UTF-8 byte order mark, whitespace and a prolog may precede the root.
      check(
        imageAttachmentBytesAreSvg(
          Uint8List.fromList([
            0xEF, 0xBB, 0xBF, //
            ...utf8.encode('  <?xml version="1.0"?>\n<!-- icon -->\n<svg/>'),
          ]),
        ),
      ).isTrue();
      // A PNG whose C2PA metadata embeds an SVG icon early on.
      final png = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
        ...utf8.encode(
          'caBX c2pa.icon <svg xmlns="http://www.w3.org/2000/svg">',
        ),
      ]);
      check(imageAttachmentBytesAreSvg(png)).isFalse();
      check(imageAttachmentBytesAreSvg(bytes('plain <svg> in text'))).isFalse();
    });
  });

  test('imageAttachmentContentIsRemote follows the http prefix', () {
    check(imageAttachmentContentIsRemote('https://example.test/a')).isTrue();
    check(imageAttachmentContentIsRemote('/api/v1/files/1')).isFalse();
    check(imageAttachmentContentIsRemote('data:image/png;base64,AA')).isFalse();
  });
}
